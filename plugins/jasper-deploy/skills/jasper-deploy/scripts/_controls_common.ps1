# _controls_common.ps1 -- shared input-control helpers (ConvertTo-ControlSpec,
# Get-ControlDescriptors, Invoke-EnsureControls, Read-ControlSpecFile).
#
# This file deliberately has NO param() block. Dot-sourcing a script that has a
# param() block re-binds every one of its parameters to their defaults in the
# CALLER's scope (so `. ensure_controls.ps1` silently reset promote.ps1's
# $WhatIf to $false and a -WhatIf promotion wrote to the target server).
# Shared functions live here; ensure_controls.ps1 and promote.ps1 dot-source
# this file, never each other. tests/dotsource.Tests.ps1 enforces the rule.
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

# --- pure helpers (unit-tested; no server contact) ---------------------------

function ConvertTo-JrsJsonString([string]$s) {
    # JSON-escape a scalar string (JSON is hand-built below because PS 5.1's
    # ConvertTo-Json unwraps one-element arrays into scalars).
    if ($null -eq $s) { return '""' }
    $e = $s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
    return '"' + $e + '"'
}

function ConvertTo-ControlType($c) {
    # Resolve numeric JRS inputControl type from 'type' or 'kind'.
    if ($c.PSObject.Properties.Name -contains "type" -and "$($c.type)" -match '^\d$') { return [int]$c.type }
    $k = if ($c.PSObject.Properties.Name -contains "kind") { "$($c.kind)".ToLower() } elseif ($c.PSObject.Properties.Name -contains "type") { "$($c.type)".ToLower() } else { "" }
    switch ($k) {
        "bool"        { return 1 }
        "boolean"     { return 1 }
        "single"      { return 2 }
        "value"       { return 2 }
        "lov"         { return 3 }
        "select"      { return 3 }
        "query"       { return 4 }
        "multivalue"  { return 5 }
        "multilov"    { return 6 }
        "multiselect" { return 6 }
        "multiquery"  { return 7 }
    }
    if ($c.PSObject.Properties.Name -contains "query") { return 4 }
    if ($c.PSObject.Properties.Name -contains "values") { return 3 }
    throw "control '$($c.name)': cannot determine type (set type 1..7 or kind bool|single|lov|multilov|query|multiquery)"
}

function ConvertTo-ControlSpec {
    # Normalise any accepted spec shape into { Folder; DataSourceUri; Controls[] }
    # where each control is a PSCustomObject with Name/Label/Type/Folder/
    # DataSourceUri/Values/Query/ValueColumn/VisibleColumns/DataType/flags.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Raw, [string]$DefaultFolder, [string]$DefaultDataSourceUri)

    # spec-supplied folder/datasource win; -Folder/-DataSourceUri only fill gaps
    $items = $null; $folder = $null; $ds = $null
    if ($Raw -is [System.Array]) { $items = $Raw }
    elseif ($Raw.PSObject.Properties.Name -contains "controls") {
        $c = $Raw.controls
        if ($c -is [System.Array]) {
            # manifest/spec with a bare array under "controls"
            $items = $c
            if ($Raw.PSObject.Properties.Name -contains "controlsFolder" -and $Raw.controlsFolder) { $folder = $Raw.controlsFolder }
            elseif ($Raw.PSObject.Properties.Name -contains "filterControlFolder" -and $Raw.filterControlFolder) { $folder = $Raw.filterControlFolder }
            elseif (-not $folder -and $Raw.PSObject.Properties.Name -contains "folder" -and $Raw.folder) { $folder = "$($Raw.folder)".TrimEnd("/") + "/controls" }
            if (-not $ds -and $Raw.PSObject.Properties.Name -contains "dataSourceUri") { $ds = $Raw.dataSourceUri }
        } else {
            # { controls: { folder, dataSourceUri, controls|items:[...] } }  (manifest "controls" object)
            $items = if ($c.PSObject.Properties.Name -contains "controls") { $c.controls } elseif ($c.PSObject.Properties.Name -contains "items") { $c.items } else { @() }
            if ($c.PSObject.Properties.Name -contains "folder" -and $c.folder) { $folder = $c.folder }
            elseif ($Raw.PSObject.Properties.Name -contains "filterControlFolder" -and $Raw.filterControlFolder) { $folder = $Raw.filterControlFolder }
            elseif (-not $folder -and $Raw.PSObject.Properties.Name -contains "folder" -and $Raw.folder) { $folder = "$($Raw.folder)".TrimEnd("/") + "/controls" }
            if ($c.PSObject.Properties.Name -contains "dataSourceUri" -and $c.dataSourceUri) { $ds = $c.dataSourceUri }
            elseif (-not $ds -and $Raw.PSObject.Properties.Name -contains "dataSourceUri") { $ds = $Raw.dataSourceUri }
        }
        # a standalone spec file: top-level folder is the controls folder itself
        if (-not ($Raw.PSObject.Properties.Name -contains "dashlets") -and ($Raw.PSObject.Properties.Name -contains "folder") -and $Raw.folder -and $c -is [System.Array]) { $folder = $Raw.folder }
    } else { throw "spec has no 'controls' array" }

    if (-not $folder) { $folder = $DefaultFolder }
    if (-not $ds) { $ds = $DefaultDataSourceUri }
    if (-not $folder) { throw "spec has no controls folder (set 'folder' in the spec, or -Folder)" }
    $folder = "$folder".TrimEnd("/")
    $out = @()
    foreach ($c in @($items)) {
        if (-not $c.name) { throw "every control needs a 'name'" }
        $t = ConvertTo-ControlType $c
        $p = $c.PSObject.Properties.Name
        $cf = if ($p -contains "folder" -and $c.folder) { "$($c.folder)".TrimEnd("/") } else { $folder }
        $cds = if ($p -contains "dataSourceUri" -and $c.dataSourceUri) { $c.dataSourceUri } else { $ds }
        $vals = @()
        if ($p -contains "values") {
            foreach ($v in @($c.values)) {
                if ($v -is [string]) { $kv = $v.Split("=", 2); $vals += [pscustomobject]@{ label = $kv[0]; value = $(if ($kv.Count -gt 1) { $kv[1] } else { $kv[0] }) } }
                else { $vals += [pscustomobject]@{ label = "$($v.label)"; value = "$($v.value)" } }
            }
        }
        $vis = @()
        if ($p -contains "visibleColumns") { $vis = @($c.visibleColumns) }
        elseif ($p -contains "labelColumn" -and $c.labelColumn) { $vis = @($c.labelColumn) }
        elseif ($p -contains "valueColumn") { $vis = @($c.valueColumn) }
        if ($t -in 3, 6 -and $vals.Count -eq 0) { throw "control '$($c.name)' (type $t) needs 'values'" }
        if ($t -in 4, 7) {
            if (-not ($p -contains "query") -or -not $c.query) { throw "control '$($c.name)' (type $t) needs 'query'" }
            if (-not ($p -contains "valueColumn") -or -not $c.valueColumn) { throw "control '$($c.name)' (type $t) needs 'valueColumn'" }
            if (-not $cds) { throw "control '$($c.name)' (type $t) needs a dataSourceUri (spec or -DataSourceUri)" }
        }
        $out += [pscustomobject]@{
            Name = "$($c.name)"; Label = $(if ($p -contains "label" -and $c.label) { "$($c.label)" } else { "$($c.name)" })
            Type = $t; Folder = $cf; Uri = "$cf/$($c.name)"; DataSourceUri = $cds
            Values = $vals; Query = $(if ($p -contains "query") { "$($c.query)" } else { $null })
            ValueColumn = $(if ($p -contains "valueColumn") { "$($c.valueColumn)" } else { $null })
            VisibleColumns = $vis
            DataType = $(if ($p -contains "dataType" -and $c.dataType) { "$($c.dataType)".ToLower() } else { "text" })
            Mandatory = $(if ($p -contains "mandatory") { [bool]$c.mandatory } else { $false })
            ReadOnly  = $(if ($p -contains "readOnly")  { [bool]$c.readOnly }  else { $false })
            Visible   = $(if ($p -contains "visible")   { [bool]$c.visible }   else { $true })
        }
    }
    return [pscustomobject]@{ Folder = $folder; DataSourceUri = $ds; Controls = $out }
}

function Get-ControlDescriptors($c) {
    # Build the JSON bodies: an optional sub-resource (LOV / query / dataType)
    # and the inputControl referencing it. Returns { SubUri; SubType; SubJson; IcJson }.
    $flags = ('"mandatory":' + $c.Mandatory.ToString().ToLower() + ',"readOnly":' + $c.ReadOnly.ToString().ToLower() + ',"visible":' + $c.Visible.ToString().ToLower())
    $lab = ConvertTo-JrsJsonString $c.Label
    $sub = $null; $subType = $null; $subJson = $null; $ref = ""
    switch ($c.Type) {
        { $_ -in 3, 6 } {
            $sub = "$($c.Folder)/$($c.Name)_lov"; $subType = "application/repository.listOfValues+json"
            $items = ($c.Values | ForEach-Object { '{"label":' + (ConvertTo-JrsJsonString $_.label) + ',"value":' + (ConvertTo-JrsJsonString $_.value) + '}' }) -join ","
            $subJson = '{"label":' + (ConvertTo-JrsJsonString "$($c.Label) values") + ',"items":[' + $items + ']}'
            $ref = ',"listOfValues":{"listOfValuesReference":{"uri":"' + $sub + '"}}'
        }
        { $_ -in 4, 7 } {
            $sub = "$($c.Folder)/$($c.Name)_query"; $subType = "application/repository.query+json"
            $subJson = '{"label":' + (ConvertTo-JrsJsonString "$($c.Name) query") + ',"language":"sql","value":' + (ConvertTo-JrsJsonString $c.Query) +
                ',"dataSource":{"dataSourceReference":{"uri":"' + $c.DataSourceUri + '"}}}'
            $vis = ($c.VisibleColumns | ForEach-Object { ConvertTo-JrsJsonString $_ }) -join ","
            $ref = ',"valueColumn":' + (ConvertTo-JrsJsonString $c.ValueColumn) + ',"visibleColumns":[' + $vis + '],"query":{"queryReference":{"uri":"' + $sub + '"}}'
        }
        { $_ -in 2, 5 } {
            $sub = "$($c.Folder)/$($c.Name)_dt"; $subType = "application/repository.dataType+json"
            $subJson = '{"label":' + (ConvertTo-JrsJsonString "$($c.Name) type") + ',"type":"' + $c.DataType + '","strictMin":false,"strictMax":false}'
            $ref = ',"dataType":{"dataTypeReference":{"uri":"' + $sub + '"}}'
        }
    }
    $ic = '{"label":' + $lab + ',' + $flags + ',"type":' + $c.Type + $ref + '}'
    return [pscustomobject]@{ SubUri = $sub; SubType = $subType; SubJson = $subJson; IcJson = $ic }
}

# --- server-facing core (mockable: Invoke-JrsGet / Invoke-JrsPut) ------------

function Invoke-JrsPutJsonText {
    param($Jrs, [string]$Uri, [string]$ContentType, [string]$Json)
    $f = [IO.Path]::GetTempFileName()
    $Json | Set-Content $f -Encoding utf8
    try { return Invoke-JrsPut -Jrs $Jrs -Uri $Uri -Overwrite -ContentType $ContentType -JsonFile $f }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
}

function Invoke-EnsureControls {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Jrs, [Parameter(Mandatory)]$Spec, [switch]$Update, [switch]$WhatIf)
    $results = @()
    foreach ($c in @($Spec.Controls)) {
        $g = Invoke-JrsGet -Jrs $Jrs -Uri $c.Uri
        $exists = "$($g.Code)" -match '^2\d\d$'
        if (-not $exists -and "$($g.Code)" -ne "404") { throw "GET $($c.Uri) returned HTTP $($g.Code): $($g.Body)" }
        $d = Get-ControlDescriptors $c
        $action = $null
        if ($exists -and -not $Update) {
            $action = "exists"; Write-Host "  exists      $($c.Uri)"
        } elseif ($WhatIf) {
            $action = if ($exists) { "would-update" } else { "would-create" }
            Write-Host "  [whatif] $action $($c.Uri) (type $($c.Type)$(if ($d.SubUri) { ', sub ' + $d.SubUri }))"
        } else {
            $ok = $true
            foreach ($step in @(@{ u = $d.SubUri; t = $d.SubType; j = $d.SubJson }, @{ u = $c.Uri; t = "application/repository.inputControl+json"; j = $d.IcJson })) {
                if (-not $step.u) { continue }
                $r = Invoke-JrsPutJsonText -Jrs $Jrs -Uri $step.u -ContentType $step.t -Json $step.j
                if ("$($r.Code)" -match '^2\d\d$') { continue }
                if ("$($r.Code)" -eq "403" -and "$($r.Body)" -match 'resource\.in\.use') {
                    $ok = $false
                    Write-Warning ("{0} is referenced (attached to a report unit / its control) and was NOT updated in place. " -f $step.u +
                        "Fix: detach it from the report units (or tear down the owning dashboards with teardown_dashboard.ps1), DELETE it, then re-run; or leave it -- the existing definition keeps working.")
                    continue
                }
                Assert-JrsOk -Response $r -Operation "PUT $($step.u)" | Out-Null
            }
            $action = if (-not $ok) { "in-use" } elseif ($exists) { "updated" } else { "created" }
            Write-Host "  $action  $($c.Uri)"
        }
        $results += [pscustomobject]@{ Name = $c.Name; Uri = $c.Uri; Type = $c.Type; Action = $action }
    }
    return $results
}

function Read-ControlSpecFile([string]$Path, [string]$DefaultFolder, [string]$DefaultDataSourceUri) {
    if (-not (Test-Path $Path)) { throw "spec not found: $Path" }
    $raw = ((Get-Content $Path -Raw) -replace "^\xEF\xBB\xBF", "") | ConvertFrom-Json
    return ConvertTo-ControlSpec -Raw $raw -DefaultFolder $DefaultFolder -DefaultDataSourceUri $DefaultDataSourceUri
}

# --- main (skipped when dot-sourced, e.g. by promote.ps1 / tests) ------------
