<#
.SYNOPSIS
  Promote a repository resource (dashboard, report, folder, datasource, ...) from
  one JasperReports Server to another by export + import -- or promote a whole
  dashboard suite from its compose manifests (-Manifest).

.DESCRIPTION
  URI MODE (unchanged): exports -Uri from the SOURCE server to a local archive,
  then imports it into the TARGET server. Because the archive is the server's
  own export format, the resource lands at the same URI and renders identically
  -- the supported dev->prod promotion path. Export a folder URI to promote a
  whole app at once.

  MANIFEST MODE (-Manifest <file|dir|glob>): replays the hand-run PROD
  promotion (RUNBOOK "PROD promotion" sections) from the dashboard manifests,
  in dependency-safe order across ALL manifests given:
    1. tear down every target dashboard (frees the resource.in.use locks on
       the tiles) -- teardown_dashboard.ps1
    2. ensure the target folder(s)
    3. ensure input controls (-EnsureControls; manifest "controls" key, or the
       source server's definition of each filter control) -- ensure_controls.ps1
    4. deploy every distinct report tile: a local jrxml (dashlet "jrxml",
       manifest outDir, or next to the manifest) goes through deploy_report.ps1
       -Overwrite; otherwise the tile is export+imported from the source
       (note: cross-server import can fail with import.decode.failed; a local
       jrxml avoids that)
    5. re-attach each tile's input controls (deploy -Overwrite drops them):
       dashlet "controls" list, else whatever the SOURCE report unit has
    6. recompose every dashboard on the target -- compose_dashboard.ps1 -Replace
  SAFETY MODEL (1.3.0, ported from jrsctl; spec specs/2026-09-28-*):
    * PLAN BY DEFAULT. Without -Apply both modes print the full plan (what
      exists on the target, what would change, a byte-level jrxml comparison
      for tiles with a local jrxml) and write NOTHING: plan mode is enforced
      below this script by _jrs_common.ps1's write guard for every child
      script, so a clobbered switch (G60) can only fail safe. -WhatIf is the
      legacy name for the default.
    * -Apply runs under a journaled run (out\runs\<runId>): every delete and
      overwrite is backed up first (-NoBackup skips), each mutating step
      records a 'reimport'/'delete' compensation, and a failed step rolls the
      run back automatically (-NoRollback to leave it for recover_run.ps1).
      Exit codes: 0 ok, 2 nothing mutated, 3 failed and rolled back, 4 rollback
      incomplete (manual action required). Undo a finished run any time with
      recover_run.ps1 -RunId <id> -Rollback -Apply.
    * A prod* target needs $env:JRS_ALLOW_PROD_WRITE = '1' set by a human (G65).

  Servers can be named environment profiles from jrs.config.json "environments"
  (-FromEnv / -ToEnv) or explicit URLs + credentials (-From* / -To*). Source
  defaults to the skill's top-level jrs.config.json (or env vars) when neither
  is given; the TARGET must be identified by -ToEnv or the full -To* triple.

.PARAMETER Uri
  Repository URI to promote, e.g. /reports/foodmart/foodmart_kpi_dashboard_auto
  (a folder promotes everything under it).

.PARAMETER Manifest
  One manifest path, a directory (every *.json in it that has "dashlets"), or a
  glob such as report\pos_perf\*_dashboard.json.

.PARAMETER ToEnv / FromEnv
  Named environment profiles under "environments" in jrs.config.json, e.g.
  -FromEnv stage -ToEnv prod. A profile supplies serverUrl/user/password (or
  passwordCommand); explicit -To*/-From* params override individual values.

.PARAMETER ToServerUrl / ToUser / ToPassword
  Explicit target server; required as a triple when -ToEnv is not given.

.PARAMETER Archive
  Where to write the intermediate .zip (default backups/promote_<name>.zip).

.PARAMETER Apply
  Actually write. Without it (both modes) the plan is printed and nothing is
  written; -WhatIf is the legacy name for that default.

.PARAMETER EnsureControls
  Manifest mode: create missing input controls on the target before deploying.

.PARAMETER NoBackup
  Skip the export taken before every delete/overwrite (those steps become
  irreversible for recover_run.ps1). -Backup is accepted for compatibility.

.PARAMETER NoRollback
  Do not compensate automatically when an -Apply run fails (exit 4; undo later
  with recover_run.ps1 -RunId <id> -Rollback -Apply).

.EXAMPLE
  .\promote.ps1 -Uri /reports/geocoder/sales_dashboard -FromEnv stage -ToEnv prod          # plan
  .\promote.ps1 -Uri /reports/geocoder/sales_dashboard -FromEnv stage -ToEnv prod -Apply   # write (JRS_ALLOW_PROD_WRITE=1)

.EXAMPLE
  .\promote.ps1 -Manifest report\pos_perf\*_dashboard.json -FromEnv stage -ToEnv prod -EnsureControls
  .\promote.ps1 -Manifest report\pos_perf\*_dashboard.json -FromEnv stage -ToEnv prod -EnsureControls -Apply

.EXAMPLE
  .\promote.ps1 -Uri /reports/geocoder/sales_dashboard `
      -ToServerUrl https://prod:8443/jasperserver-pro -ToUser admin -ToPassword secret
#>
[CmdletBinding()]
param(
    [string]$Uri,
    [string]$Manifest,
    [string]$ToServerUrl,
    [string]$ToUser,
    [string]$ToPassword,
    [string]$ToEnv,
    [string]$FromServerUrl,
    [string]$FromUser,
    [string]$FromPassword,
    [string]$FromEnv,
    [string]$Archive,
    [bool]$Update = $true,
    [switch]$Apply,             # PLAN BY DEFAULT (1.3.0): without -Apply the plan is printed and nothing is written
    [switch]$WhatIf,            # legacy name for the default (plan) mode; cannot be combined with -Apply
    [switch]$EnsureControls,
    [switch]$Backup,            # accepted for compatibility: backups are now taken by default before every delete/overwrite
    [switch]$NoBackup,          # skip them (those steps are journaled as irreversible)
    [switch]$NoRollback,        # on a failed -Apply run, do NOT compensate automatically (leave it for recover_run.ps1)
    [string]$WorkDir = "out/promote"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
. (Join-Path $PSScriptRoot "_controls_common.ps1")    # ConvertTo-ControlSpec / Invoke-EnsureControls. NEVER dot-source a script
                                                       # that has a param() block: it re-binds $WhatIf etc. in THIS scope (see _controls_common.ps1)

# =============================================================================
# Manifest mode -- pure helpers (unit-tested, no server contact)
# =============================================================================

function Resolve-ManifestPaths([string]$Spec) {
    # file | directory (every *.json with a "dashlets" array) | glob
    $paths = @()
    if (Test-Path $Spec -PathType Container) {
        $paths = @(Get-ChildItem -Path $Spec -Filter *.json -File | ForEach-Object { $_.FullName })
    } elseif (Test-Path $Spec -PathType Leaf) {
        $paths = @((Resolve-Path $Spec).Path)
    } else {
        $paths = @(Get-ChildItem -Path $Spec -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    $out = @()
    foreach ($p in $paths | Sort-Object) {
        try { $j = ((Get-Content $p -Raw) -replace "^\xEF\xBB\xBF", "") | ConvertFrom-Json } catch { continue }
        if ($j.PSObject.Properties.Name -contains "dashlets" -and $j.PSObject.Properties.Name -contains "folder" -and $j.PSObject.Properties.Name -contains "name") { $out += $p }
    }
    if (-not $out) { throw "no dashboard manifest(s) found for '$Spec'" }
    return $out
}

function Resolve-TileJrxml($d, $m, [string]$ManifestDir, [string]$Leaf) {
    # dashlet "jrxml" (relative to the manifest dir, then cwd) -> manifest outDir -> beside the manifest
    $cands = @()
    if ($d.PSObject.Properties.Name -contains "jrxml" -and $d.jrxml) { $cands += (Join-Path $ManifestDir $d.jrxml); $cands += $d.jrxml }
    if ($m.PSObject.Properties.Name -contains "outDir" -and $m.outDir) { $cands += (Join-Path $m.outDir "$Leaf.jrxml"); $cands += (Join-Path $ManifestDir (Join-Path $m.outDir "$Leaf.jrxml")) }
    $cands += (Join-Path $ManifestDir "$Leaf.jrxml")
    foreach ($c in $cands) { if ($c -and (Test-Path $c -PathType Leaf)) { return (Resolve-Path $c).Path } }
    return $null
}

function Read-DashboardManifest([string]$Path) {
    $m = ((Get-Content $Path -Raw) -replace "^\xEF\xBB\xBF", "") | ConvertFrom-Json
    $dir = Split-Path -Parent (Resolve-Path $Path).Path
    $folder = "$($m.folder)".TrimEnd("/")
    $ctlFolder = if ($m.PSObject.Properties.Name -contains "filterControlFolder" -and $m.filterControlFolder) { "$($m.filterControlFolder)".TrimEnd("/") } else { "$folder/controls" }
    $tiles = @()
    $needsGrid = $false
    foreach ($d in @($m.dashlets)) {
        $kind = if ($d.PSObject.Properties.Name -contains "kind" -and $d.kind) { $d.kind } else { "report" }
        if ($kind -ne "report") { continue }
        $uri = if ($d.PSObject.Properties.Name -contains "resource" -and $d.resource) { $d.resource } else { "$folder/$($d.name)" }
        $leaf = ($uri -split "/")[-1]
        if (@("x", "y", "width", "height") | Where-Object { -not ($d.PSObject.Properties.Name -contains $_) }) { $needsGrid = $true }
        $ctls = $null
        if ($d.PSObject.Properties.Name -contains "controls") {
            $ctls = @(@($d.controls) | ForEach-Object { if ("$_".StartsWith("/")) { "$_" } else { "$ctlFolder/$_" } })
        }
        $tiles += [pscustomobject]@{
            Uri = $uri; Leaf = $leaf
            Label = $(if ($d.PSObject.Properties.Name -contains "title" -and $d.title) { $d.title } elseif ($d.PSObject.Properties.Name -contains "label" -and $d.label) { $d.label } else { $leaf })
            Jrxml = (Resolve-TileJrxml $d $m $dir $leaf)
            DataSourceUri = $(if ($d.PSObject.Properties.Name -contains "dataSourceUri" -and $d.dataSourceUri) { $d.dataSourceUri } elseif ($m.PSObject.Properties.Name -contains "dataSourceUri") { $m.dataSourceUri } else { $null })
            Controls = $ctls          # $null = inherit from the source report unit
        }
    }
    $controlSpec = $null
    if ($m.PSObject.Properties.Name -contains "controls" -and $m.controls) {
        $controlSpec = ConvertTo-ControlSpec -Raw $m -DefaultFolder $ctlFolder -DefaultDataSourceUri $(if ($m.PSObject.Properties.Name -contains "dataSourceUri") { $m.dataSourceUri } else { $null })
    }
    $filters = @()
    if ($m.PSObject.Properties.Name -contains "filters" -and $m.filters) { $filters = @(@($m.filters) | ForEach-Object { "$ctlFolder/$_" }) }
    return [pscustomobject]@{
        Path = (Resolve-Path $Path).Path; Folder = $folder; Name = "$($m.name)"; Uri = "$folder/$($m.name)"
        Tiles = $tiles; ControlSpec = $controlSpec; FilterControlUris = $filters; NeedsAutoGrid = $needsGrid
    }
}

function Get-PromotePlanOrder($Manifests) {
    # Dependency-safe step list across all manifests:
    #   teardown (every dashboard) -> folders -> controls -> tiles (distinct) ->
    #   attach controls -> compose (every dashboard). Pure; no server contact.
    $steps = @(); $i = 0
    foreach ($mf in @($Manifests)) { $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 1; Kind = "teardown"; Uri = $mf.Uri; Manifest = $mf.Path; Tile = $null } }
    foreach ($f in @(@($Manifests) | ForEach-Object { $_.Folder } | Select-Object -Unique)) { $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 2; Kind = "folder"; Uri = $f; Manifest = $null; Tile = $null } }
    $seenCtl = @{}
    foreach ($mf in @($Manifests)) {
        if ($mf.ControlSpec) { foreach ($c in @($mf.ControlSpec.Controls)) { if (-not $seenCtl[$c.Uri]) { $seenCtl[$c.Uri] = $true; $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 3; Kind = "control"; Uri = $c.Uri; Manifest = $mf.Path; Tile = $c } } } }
        foreach ($u in @($mf.FilterControlUris)) { if (-not $seenCtl[$u]) { $seenCtl[$u] = $true; $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 3; Kind = "control"; Uri = $u; Manifest = $mf.Path; Tile = $null } } }
    }
    $seenTile = @{}
    foreach ($mf in @($Manifests)) { foreach ($t in @($mf.Tiles)) { if (-not $seenTile[$t.Uri]) { $seenTile[$t.Uri] = $true; $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 4; Kind = "tile"; Uri = $t.Uri; Manifest = $mf.Path; Tile = $t } } } }
    foreach ($s in @($steps | Where-Object { $_.Kind -eq "tile" })) { $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 5; Kind = "attach"; Uri = $s.Uri; Manifest = $s.Manifest; Tile = $s.Tile } }
    foreach ($mf in @($Manifests)) { $i++; $steps += [pscustomobject]@{ Order = $i; Phase = 6; Kind = "compose"; Uri = $mf.Uri; Manifest = $mf.Path; Tile = $null } }
    return $steps
}

# =============================================================================
# Manifest mode -- server-facing helpers (GET-only ones are safe under -WhatIf)
# =============================================================================

function Get-JrsResourceOrNull($Jrs, [string]$Uri) {
    $r = Invoke-JrsGet -Jrs $Jrs -Uri $Uri
    if ("$($r.Code)" -match '^2\d\d$') { try { return ($r.Body | ConvertFrom-Json) } catch { return [pscustomobject]@{} } }
    if ("$($r.Code)" -eq "404") { return $null }
    throw "GET $Uri returned HTTP $($r.Code): $($r.Body)"
}

function Get-JrsReportJrxmlBytes($Jrs, [string]$Uri) {
    # expanded=true inlines the jrxml file (base64) into the reportUnit descriptor
    # ${Uri}: under PS 5.1 a bare "$Uri?" parses as the variable named "Uri?"
    $r = Invoke-JrsGet -Jrs $Jrs -Uri "${Uri}?expanded=true"
    if ("$($r.Code)" -notmatch '^2\d\d$') { return $null }
    try {
        $j = $r.Body | ConvertFrom-Json
        $c = $j.jrxml.jrxmlFile.content
        if ($c) { return [Convert]::FromBase64String($c) }
    } catch { }
    return $null
}

function Get-ReportControlUris($Ru) {
    # ",@()" -- a bare "return @()" emits NOTHING to the caller ($null), and @($null)
    # then has Count 1, which made "keep"/"ATTACH" decisions compare 0 vs 1.
    if (-not $Ru -or -not ($Ru.PSObject.Properties.Name -contains "inputControls") -or -not $Ru.inputControls) { return ,@() }
    return ,@(@($Ru.inputControls) | ForEach-Object { $_.inputControlReference.uri } | Where-Object { $_ })
}

function Get-JrxmlCompare([byte[]]$Local, [byte[]]$Remote) {
    if (-not $Local) { return "no local jrxml (export+import from source)" }
    if (-not $Remote) { return "target has no jrxml (new: $($Local.Length) B)" }
    if ($Local.Length -eq $Remote.Length) {
        $same = $true
        for ($k = 0; $k -lt $Local.Length; $k++) { if ($Local[$k] -ne $Remote[$k]) { $same = $false; break } }
        if ($same) { return "identical ($($Local.Length) B)" }
        return "differs (same size $($Local.Length) B, first diff at byte $k)"
    }
    return "differs (local $($Local.Length) B vs target $($Remote.Length) B)"
}

function Get-PromotePlan($Steps, $From, $To) {
    # Annotate the ordered steps with target state + intended action. GET only.
    foreach ($s in @($Steps)) {
        $exists = $null; $note = ""; $action = ""
        switch ($s.Kind) {
            "teardown" { $exists = [bool](Get-JrsResourceOrNull $To $s.Uri); $action = if ($exists) { "DELETE dashboard (frees tile locks)" } else { "skip (absent)" } }
            "folder"   { $exists = [bool](Get-JrsResourceOrNull $To $s.Uri); $action = if ($exists) { "keep" } else { "CREATE folder" } }
            "control"  {
                $exists = [bool](Get-JrsResourceOrNull $To $s.Uri)
                if ($exists) { $action = "keep" }
                elseif ($s.Tile) { $action = "CREATE from manifest spec (type $($s.Tile.Type))" }
                else {
                    $src = Get-JrsResourceOrNull $From $s.Uri
                    $action = if ($src) { "CREATE by copying the source definition" } else { "MISSING on both servers -- filter strip will not bind" }
                }
            }
            "tile"     {
                $ru = Get-JrsResourceOrNull $To $s.Uri; $exists = [bool]$ru
                $local = if ($s.Tile.Jrxml) { [IO.File]::ReadAllBytes($s.Tile.Jrxml) } else { $null }
                $remote = if ($exists) { Get-JrsReportJrxmlBytes $To $s.Uri } else { $null }
                $note = Get-JrxmlCompare $local $remote
                $action = if ($s.Tile.Jrxml) { "$(if ($exists) { 'OVERWRITE' } else { 'DEPLOY' }) via deploy_report.ps1 ($(Split-Path -Leaf $s.Tile.Jrxml))" } else { "$(if ($exists) { 'REPLACE' } else { 'CREATE' }) via export+import from source" }
                if ($s.Tile.Jrxml -and $note.StartsWith("identical")) { $action = "keep (jrxml identical); re-attach controls only" }
            }
            "attach"   {
                $want = $s.Tile.Controls
                if ($null -eq $want) { $want = Get-ReportControlUris (Get-JrsResourceOrNull $From $s.Uri); $note = "from source" } else { $note = "from manifest" }
                $have = Get-ReportControlUris (Get-JrsResourceOrNull $To $s.Uri)
                $exists = ($have.Count -gt 0)
                $want = @($want); $have = @($have)
                $same = ($want.Count -eq $have.Count) -and -not @($want | Where-Object { $have -notcontains $_ })
                $action = if ($want.Count -eq 0) { "none to attach" } elseif ($same) { "keep ($($want.Count) attached; re-verified live after the tile step)" } else { "ATTACH $($want.Count): $($want -join ', ')" }
                $s.Tile | Add-Member -NotePropertyName ResolvedControls -NotePropertyValue @($want) -Force
            }
            "compose"  { $exists = [bool](Get-JrsResourceOrNull $To $s.Uri); $action = "COMPOSE (replace) from $(Split-Path -Leaf $s.Manifest)" }
        }
        $s | Add-Member -NotePropertyName ExistsOnTarget -NotePropertyValue $exists -Force
        $s | Add-Member -NotePropertyName Action -NotePropertyValue $action -Force
        $s | Add-Member -NotePropertyName Note -NotePropertyValue $note -Force
    }
    return $Steps
}

function Write-PromotePlan($Plan, $From, $To) {
    $names = @{ 1 = "teardown dashboards"; 2 = "folders"; 3 = "input controls"; 4 = "report tiles"; 5 = "attach controls"; 6 = "compose dashboards" }
    Write-Host ""
    Write-Host "PROMOTION PLAN  $($From.ServerUrl)  ->  $($To.ServerUrl)"
    $cur = 0
    foreach ($s in @($Plan)) {
        if ($s.Phase -ne $cur) { $cur = $s.Phase; Write-Host ""; Write-Host "  phase $cur - $($names[$cur])" }
        $ex = if ($null -eq $s.ExistsOnTarget) { "  ?  " } elseif ($s.ExistsOnTarget) { "exists" } else { "absent" }
        $line = "    [{0,3}] {1,-6} {2,-52} {3}" -f $s.Order, $ex, $s.Uri, $s.Action
        if ($s.Note) { $line += "  ($($s.Note))" }
        Write-Host $line
    }
    Write-Host ""
}

function Invoke-ChildScript([string]$Name, [hashtable]$Splat) {
    # single choke point for every write-capable child script (mockable in tests)
    & (Join-Path $PSScriptRoot $Name) @Splat
}

function Set-JrsReportControls($Jrs, [string]$ReportUri, [string[]]$ControlUris) {
    # PUT the report unit back with an inputControls[] built as literal JSON text
    # (PS 5.1's ConvertTo-Json unwraps a one-element array -> 400 from the server).
    $cur = Invoke-JrsGet -Jrs $Jrs -Uri $ReportUri
    Assert-JrsOk -Response $cur -Operation "GET $ReportUri" | Out-Null
    $ru = $cur.Body | ConvertFrom-Json
    if ($ru.PSObject.Properties.Name -contains "inputControls") { $ru.PSObject.Properties.Remove("inputControls") }
    if (-not ($ru.PSObject.Properties.Name -contains "controlsLayout")) { $ru | Add-Member -NotePropertyName controlsLayout -NotePropertyValue "popupScreen" -Force }
    $json = $ru | ConvertTo-Json -Depth 12
    $icJson = "[" + (($ControlUris | ForEach-Object { '{"inputControlReference":{"uri":"' + $_ + '"}}' }) -join ",") + "]"
    $json = $json -replace '^\{', ('{"inputControls":' + $icJson + ',')
    $f = [IO.Path]::GetTempFileName()
    $json | Set-Content $f -Encoding utf8
    try { $r = Invoke-JrsPut -Jrs $Jrs -Uri $ReportUri -Overwrite -ContentType "application/repository.reportUnit+json" -JsonFile $f }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
    Assert-JrsOk -Response $r -Operation "PUT $ReportUri (attach controls)" | Out-Null
}

function Copy-JrsInputControl($From, $To, [string]$Uri) {
    # Recreate a control on the target from the source's descriptors: the
    # referenced LOV/query/dataType first, then the inputControl itself.
    $src = Invoke-JrsGet -Jrs $From -Uri $Uri
    Assert-JrsOk -Response $src -Operation "GET $Uri (source control)" | Out-Null
    $ic = $src.Body | ConvertFrom-Json
    foreach ($pair in @(@("listOfValues", "listOfValuesReference", "application/repository.listOfValues+json"),
                        @("query", "queryReference", "application/repository.query+json"),
                        @("dataType", "dataTypeReference", "application/repository.dataType+json"))) {
        if (-not ($ic.PSObject.Properties.Name -contains $pair[0])) { continue }
        $refUri = $ic.($pair[0]).($pair[1]).uri
        if (-not $refUri) { continue }
        $sub = Invoke-JrsGet -Jrs $From -Uri $refUri
        Assert-JrsOk -Response $sub -Operation "GET $refUri (source sub-resource)" | Out-Null
        $f = [IO.Path]::GetTempFileName(); $sub.Body | Set-Content $f -Encoding utf8
        try { $r = Invoke-JrsPut -Jrs $To -Uri $refUri -Overwrite -ContentType $pair[2] -JsonFile $f } finally { Remove-Item $f -ErrorAction SilentlyContinue }
        Assert-JrsOk -Response $r -Operation "PUT $refUri" | Out-Null
    }
    $f = [IO.Path]::GetTempFileName(); $src.Body | Set-Content $f -Encoding utf8
    try { $r = Invoke-JrsPut -Jrs $To -Uri $Uri -Overwrite -ContentType "application/repository.inputControl+json" -JsonFile $f } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    Assert-JrsOk -Response $r -Operation "PUT $Uri" | Out-Null
}

function Invoke-PromotePlan($Plan, $Manifests, $From, $To, [switch]$EnsureControls, [switch]$NoBackup, [string]$WorkDir, $Run) {
    # Executes an annotated plan in apply mode. Every child script is called with
    # -Apply (they plan by default, 1.3.0) and journals into $Run (nested runs join
    # the parent); steps done here directly journal their own compensation.
    $toArgs = @{ ServerUrl = $To.ServerUrl; User = $To.User; Password = $To.Password }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    foreach ($s in @($Plan)) {
        Write-Host "=== [$($s.Order)] $($s.Kind) $($s.Uri): $($s.Action)"
        $stepId = "promote.$($s.Kind):$($s.Uri)"
        switch ($s.Kind) {
            "teardown" {
                if ($s.ExistsOnTarget) { Invoke-ChildScript "teardown_dashboard.ps1" ($toArgs + @{ Uri = $s.Uri; Apply = $true; NoBackup = [bool]$NoBackup }) }
                else { Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "absent on target" }
            }
            "folder"   {
                if (-not $s.ExistsOnTarget) {
                    Write-JrsStep -Run $Run -Step $stepId -State RUNNING -Compensation @{ type = "delete"; uri = $s.Uri }
                    $f = [IO.Path]::GetTempFileName(); ('{"label":"' + (($s.Uri -split "/")[-1]) + '"}') | Set-Content $f -Encoding utf8
                    try { $r = Invoke-JrsPut -Jrs $To -Uri $s.Uri -ContentType "application/repository.folder+json" -JsonFile $f } finally { Remove-Item $f -ErrorAction SilentlyContinue }
                    if ("$($r.Code)" -notmatch '^2\d\d$') { Write-JrsStep -Run $Run -Step $stepId -State FAILED -Detail "HTTP $($r.Code)" }
                    Assert-JrsOk -Response $r -Operation "PUT folder $($s.Uri)" | Out-Null
                    Write-JrsStep -Run $Run -Step $stepId -State SUCCEEDED -Detail "HTTP $($r.Code)"
                } else { Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "exists" }
            }
            "control"  {
                if ($s.ExistsOnTarget) { Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "exists"; break }
                if (-not $EnsureControls) { Write-Warning "control $($s.Uri) is absent on the target; pass -EnsureControls to create it"; Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "absent; -EnsureControls not given"; break }
                Write-JrsStep -Run $Run -Step $stepId -State RUNNING -Compensation @{ type = "delete"; uri = $s.Uri } -Detail "sub-resources (LOV/query/dataType) are left in place by the rollback"
                try {
                    if ($s.Tile) { Invoke-EnsureControls -Jrs $To -Spec ([pscustomobject]@{ Controls = @($s.Tile) }) | Out-Null }
                    elseif ($s.Action -match '^CREATE by copying') { Copy-JrsInputControl $From $To $s.Uri }
                    else { Write-Warning "control $($s.Uri) exists on neither server; skipped"; Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "exists on neither server"; break }
                } catch { Write-JrsStep -Run $Run -Step $stepId -State FAILED -Detail "$_"; throw }
                Write-JrsStep -Run $Run -Step $stepId -State SUCCEEDED
            }
            "tile"     {
                if ($s.Action.StartsWith("keep")) { Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "jrxml identical"; break }
                if ($s.Tile.Jrxml) {
                    $ds = $s.Tile.DataSourceUri
                    if (-not $ds) { $srcRu = Get-JrsResourceOrNull $From $s.Uri; if ($srcRu -and $srcRu.dataSource) { $ds = $srcRu.dataSource.dataSourceReference.uri } }
                    if (-not $ds) { $ds = $To.DataSourceUri }
                    $label = $s.Tile.Label
                    $srcRu2 = Get-JrsResourceOrNull $From $s.Uri
                    if ($srcRu2 -and $srcRu2.label) { $label = $srcRu2.label }
                    # deploy_report -Overwrite -Apply journals its own step (backup -> reimport / delete)
                    $a = $toArgs + @{ Jrxml = $s.Tile.Jrxml; TargetUri = $s.Uri; Label = $label; Overwrite = $true; Apply = $true; NoBackup = [bool]$NoBackup }
                    if ($ds) { $a.DataSourceUri = $ds }
                    Invoke-ChildScript "deploy_report.ps1" $a | ForEach-Object { Write-Host "    $_" }
                } else {
                    $comp = $null; $irrev = $null
                    if ($s.ExistsOnTarget) {
                        if ($NoBackup) { $irrev = "-NoBackup" }
                        else { $bk = Export-JrsBackup -Jrs $To -Uri $s.Uri; if ($bk) { $comp = @{ type = "reimport"; zip = $bk; uri = $s.Uri } } else { $irrev = "backup export failed" } }
                    } else { $comp = @{ type = "delete"; uri = $s.Uri } }
                    Write-JrsStep -Run $Run -Step $stepId -State RUNNING -Compensation $comp -Irreversible $irrev
                    $zip = Join-Path $WorkDir ("tile_" + ($s.Uri.TrimStart("/") -replace "[^0-9A-Za-z]", "_") + ".zip")
                    Invoke-ChildScript "export_resource.ps1" @{ Uri = $s.Uri; Out = $zip; ServerUrl = $From.ServerUrl; User = $From.User; Password = $From.Password } | ForEach-Object { Write-Host "    $_" }
                    try { Invoke-ChildScript "import_resource.ps1" ($toArgs + @{ Zip = $zip; Update = $true }) | ForEach-Object { Write-Host "    $_" } }
                    catch {
                        Write-JrsStep -Run $Run -Step $stepId -State FAILED -Detail "$_"
                        if ("$_" -match 'import\.decode\.failed') { throw "import of $($s.Uri) failed with import.decode.failed (per-server export key). Put the tile's jrxml next to the manifest (or set dashlet 'jrxml' / manifest 'outDir') so it deploys via deploy_report.ps1 instead. Original: $_" }
                        throw
                    }
                    Write-JrsStep -Run $Run -Step $stepId -State SUCCEEDED
                }
            }
            "attach"   {
                # Decide from LIVE target state, not the plan: the tile step above may
                # have re-created the report unit (PUT ?overwrite=true assigns version 0
                # and drops inputControls), so a plan-time "keep (N attached)" is stale.
                # 2026-08-28 incident: this staleness left 22 PROD tiles with no
                # controls and made every dashboard import silently skip.
                $want = @($s.Tile.ResolvedControls)
                if ($want.Count -gt 0) {
                    $have = @(Get-ReportControlUris (Get-JrsResourceOrNull $To $s.Uri))
                    $same = ($want.Count -eq $have.Count) -and -not @($want | Where-Object { $have -notcontains $_ })
                    if ($same) { Write-Host "    controls already attached ($($have.Count), verified live)"; Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "already attached ($($have.Count))" }
                    else {
                        # the tile step's backup (when it ran) already covers this unit; a kept
                        # tile gets its own backup here so the attach is reversible too
                        $comp = $null; $irrev = $null
                        if ($NoBackup) { $irrev = "-NoBackup" }
                        else { $bk = Export-JrsBackup -Jrs $To -Uri $s.Uri; if ($bk) { $comp = @{ type = "reimport"; zip = $bk; uri = $s.Uri } } else { $irrev = "backup export failed" } }
                        Write-JrsStep -Run $Run -Step $stepId -State RUNNING -Compensation $comp -Irreversible $irrev
                        try { Set-JrsReportControls $To $s.Uri $want } catch { Write-JrsStep -Run $Run -Step $stepId -State FAILED -Detail "$_"; throw }
                        Write-Host "    attached $($want.Count) control(s) (live had $($have.Count))"
                        Write-JrsStep -Run $Run -Step $stepId -State SUCCEEDED -Detail "attached $($want.Count), live had $($have.Count)"
                    }
                } else { Write-JrsStep -Run $Run -Step $stepId -State SKIPPED -Detail "none to attach" }
            }
            "compose"  {
                $mf = @($Manifests | Where-Object { $_.Path -eq $s.Manifest })[0]
                # compose -Replace -Apply journals its own delete (backup -> reimport) and import steps
                $a = $toArgs + @{ Manifest = $s.Manifest; Replace = $true; Apply = $true; NoBackup = [bool]$NoBackup; WorkDir = (Join-Path $WorkDir ("dash_" + $mf.Name)) }
                if ($mf.NeedsAutoGrid) { $a.AutoGrid = $true }
                Invoke-ChildScript "compose_dashboard.ps1" $a | ForEach-Object { if ($_ -is [string]) { Write-Host "    $_" } else { $_ } }
            }
        }
    }
}

function Invoke-PromoteManifest {
    # Plan mode (default, or -WhatIf) returns the annotated plan and issues GETs
    # only. -Apply runs it under a journaled run; on failure the run is rolled
    # back automatically (unless -NoRollback) and $script:PromoteExitCode is set
    # to 3 (rolled back) or 4 (rollback incomplete) before the error is rethrown.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Manifest, [Parameter(Mandatory)]$From, [Parameter(Mandatory)]$To,
          [switch]$Apply, [switch]$WhatIf, [switch]$EnsureControls, [switch]$Backup, [switch]$NoBackup, [switch]$NoRollback,
          [string]$WorkDir = "out/promote")
    if ($Apply -and $WhatIf) { throw "-Apply and -WhatIf are mutually exclusive" }
    $paths = Resolve-ManifestPaths $Manifest
    $mfs = @($paths | ForEach-Object { Read-DashboardManifest $_ })
    Write-Host "manifest mode: $($mfs.Count) dashboard(s), $((@($mfs | ForEach-Object { $_.Tiles }) | Select-Object -Unique -Property Uri).Count) distinct tile(s)"
    $steps = Get-PromotePlanOrder $mfs
    $plan = Get-PromotePlan $steps $From $To
    Write-PromotePlan $plan $From $To
    if (-not $Apply) {
        Write-Host "[plan] nothing was written to $($To.ServerUrl); pass -Apply to promote (backups + run journal; undo with recover_run.ps1)"
        return $plan
    }
    $script:PromoteExitCode = 0
    $run = New-JrsRun -Operation "promote" -Target $To -Mode apply -Plan $plan -Arguments @{ Manifest = $Manifest; From = $From.ServerUrl; EnsureControls = [bool]$EnsureControls; NoBackup = [bool]$NoBackup }
    try {
        Invoke-PromotePlan $plan $mfs $From $To -EnsureControls:$EnsureControls -NoBackup:$NoBackup -WorkDir $WorkDir -Run $run
        Complete-JrsRun -Run $run -Status SUCCEEDED
        Write-Host "OK: promoted $($mfs.Count) dashboard(s) -> $($To.ServerUrl) (run $($run.RunId))"
        return $plan
    } catch {
        $err = "$_"
        Write-Host ""
        Write-Host "FAILED: $err"
        if ($NoRollback) {
            Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error $err
            $script:PromoteExitCode = 4
            Write-Host "run $($run.RunId) left as FAILED (-NoRollback); undo with: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply"
            throw
        }
        Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error $err
        Write-Host "rolling back run $($run.RunId) (the failing step first, then every succeeded step, newest first) ..."
        $rb = Invoke-JrsRollback -Run (Get-JrsRun -RunId $run.RunId) -Jrs $To -Apply
        $script:PromoteExitCode = $rb.ExitCode
        if ($rb.Status -ne "ROLLED_BACK") { Write-Host "MANUAL ACTION REQUIRED: recover_run.ps1 -RunId $($run.RunId) lists what is left" }
        throw
    }
}

# =============================================================================
# main (skipped when dot-sourced by the tests)
# =============================================================================
if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Uri -and -not $Manifest) { throw "pass -Uri <repository uri> or -Manifest <file|dir|glob>" }
    if ($Uri -and $Manifest) { throw "-Uri and -Manifest are mutually exclusive" }
    if ($Apply -and $WhatIf) { throw "-Apply and -WhatIf are mutually exclusive (-WhatIf is the default plan mode)" }

    # Plan mode is enforced BELOW this script by the write guard in _jrs_common.ps1
    # (Invoke-JrsPut/Delete/Rest refuse), for this process and every child script,
    # so a clobbered switch (G60) can no longer turn a plan into writes.
    $prevMode = Enter-JrsPlanMode -Apply:$Apply
    $script:PromoteExitCode = 0
    try {
        # Resolve the TARGET up front so a bad profile name or missing credential fails
        # before the export runs, and so the summary line can print the real URL.
        if (-not $ToEnv -and -not ($ToServerUrl -and $ToUser -and $ToPassword)) {
            throw "Target server required: pass -ToEnv <name> (a jrs.config.json `"environments`" profile) or the full -ToServerUrl/-ToUser/-ToPassword triple"
        }
        $to = Resolve-JrsConfig -ServerUrl $ToServerUrl -User $ToUser -Password $ToPassword -Env $ToEnv
        $from = Resolve-JrsConfig -ServerUrl $FromServerUrl -User $FromUser -Password $FromPassword -Env $FromEnv
        if ($to.ServerUrl -eq $from.ServerUrl) {
            throw "source and target are the same server ($($to.ServerUrl)) -- nothing to promote"
        }
        Write-Host "mode: $(if ($Apply) { 'APPLY' } else { 'plan (pass -Apply to write)' })  target: $($to.ServerUrl)$(if ($to.Env) { " [env $($to.Env)]" })$(if ($to.IsProd) { '  ** PROD: needs JRS_ALLOW_PROD_WRITE=1 **' })"
        if ($Apply) { Assert-JrsWriteAllowed -Jrs $to -Method APPLY -Url $to.ServerUrl }   # precheck (exit 2): refuse an unconfirmed prod target before any work

        if ($Manifest) {
            Invoke-PromoteManifest -Manifest $Manifest -From $from -To $to -Apply:$Apply -WhatIf:$WhatIf -EnsureControls:$EnsureControls `
                -NoBackup:$NoBackup -NoRollback:$NoRollback -WorkDir $WorkDir | Out-Null
        } else {
            if (-not $Uri.StartsWith("/")) { $Uri = "/$Uri" }
            $leaf = ($Uri -split "/")[-1]
            if (-not $Archive) { $Archive = "backups/promote_$leaf.zip" }
            $exists = ("$((Invoke-JrsGet -Jrs $to -Uri $Uri).Code)" -match '^2\d\d$')
            $bkWord = if ($NoBackup) { "no backup (irreversible)" } else { "backup the target copy, then" }
            $action = if ($exists) { "$bkWord IMPORT over it (update=$Update)" } else { "IMPORT [new]" }
            Write-Host ""
            Write-Host "PROMOTION PLAN  $Uri  $($from.ServerUrl)  ->  $($to.ServerUrl) (exists on target: $exists)"
            Write-Host "  [  1] export $Uri from the source -> $Archive"
            Write-Host "  [  2] $action"
            Write-Host ""
            if (-not $Apply) { Write-Host "[plan] nothing was written to $($to.ServerUrl); pass -Apply to promote"; return }

            $run = New-JrsRun -Operation "promote-uri" -Target $to -Mode apply -Plan @([pscustomobject]@{ Order = 1; Kind = "import"; Uri = $Uri; Action = $action }) -Arguments @{ Uri = $Uri; From = $from.ServerUrl; Update = $Update }
            try {
                Write-Host "=== export $Uri from $($from.ServerUrl) ==="
                & (Join-Path $PSScriptRoot "export_resource.ps1") -Uri $Uri -Out $Archive `
                    -ServerUrl $from.ServerUrl -User $from.User -Password $from.Password

                $stepId = "promote.import:$Uri"; $comp = $null; $irrev = $null
                if ($exists) {
                    if ($NoBackup) { $irrev = "-NoBackup" }
                    else { $bk = Export-JrsBackup -Jrs $to -Uri $Uri; if ($bk) { $comp = @{ type = "reimport"; zip = $bk; uri = $Uri }; Write-Host "backup $Uri -> $bk" } else { $irrev = "backup export failed" } }
                } else { $comp = @{ type = "delete"; uri = $Uri } }
                Write-JrsStep -Run $run -Step $stepId -State RUNNING -Compensation $comp -Irreversible $irrev
                Write-Host "=== import into target $($to.ServerUrl) ==="
                try {
                    & (Join-Path $PSScriptRoot "import_resource.ps1") -Zip $Archive -Update $Update `
                        -ServerUrl $to.ServerUrl -User $to.User -Password $to.Password
                } catch { Write-JrsStep -Run $run -Step $stepId -State FAILED -Detail "$_"; throw }
                Write-JrsStep -Run $run -Step $stepId -State SUCCEEDED
                Complete-JrsRun -Run $run -Status SUCCEEDED
                Write-Host "OK: promoted $Uri -> $($to.ServerUrl) (archive: $Archive; run $($run.RunId))"
            } catch {
                $err = "$_"
                Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error $err
                Write-Host "FAILED: $err"
                if ($NoRollback) { $script:PromoteExitCode = 4; Write-Host "undo with: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply"; throw }
                $rb = Invoke-JrsRollback -Run (Get-JrsRun -RunId $run.RunId) -Jrs $to -Apply
                $script:PromoteExitCode = $rb.ExitCode
                throw
            }
        }
    } catch {
        # exit codes follow jrsctl: 2 = nothing mutated (precheck/plan), 3 = rolled back, 4 = rollback incomplete
        $code = if ($script:PromoteExitCode) { $script:PromoteExitCode } else { 2 }
        Write-Host "promote.ps1: $_"
        Write-Host "exit $code ($(switch ($code) { 2 { 'failed before any write' } 3 { 'failed; rolled back cleanly' } 4 { 'failed; rollback incomplete -- manual action required' } default { 'error' } }))"
        exit $code
    } finally { Restore-JrsPlanMode $prevMode }
}
