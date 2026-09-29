# scripts/pos_perf/jrs_controls.ps1 -- create the shared finance controls once
# under /reports/pos_perf/controls and attach any subset to a report unit.
# Usage:
#   . .\scripts\pos_perf\jrs_controls.ps1
#   New-FinanceControls                      # rerun-safe: creates what's missing;
#                                             # for a control that already exists,
#                                             # attempts to update BOTH its LOV/
#                                             # query sub-resource and its own
#                                             # inputControl fields, warning
#                                             # loudly (never silently) on either
#                                             # one it could not update in place.
#   New-FinanceControls -Force               # also replaces content a plain
#                                             # rerun could not touch (see below).
#   Attach-Controls -ReportUri /reports/pos_perf/trs_ar_aging -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions")
#
# Two independent FK layers can block an in-place -Overwrite PUT (both found
# empirically against STAGE, not assumed): (1) the LOV/query sub-resource is
# referenced by its own inputControl; (2) the inputControl itself becomes
# referenced the moment ANY report unit attaches it (e.g. via Attach-Controls),
# via the jireportunitinputcontrol join table. So the inputControl is not
# automatically safe to overwrite just because it's "the referencing side" for
# layer 1 -- it can simultaneously be the REFERENCED side for layer 2. See
# Update-FinanceControl for how both are attempted-and-warned (or, under
# -Force, deleted-and-recreated) independently.
#
# -Force replace note: for each of the sub-resource and the inputControl, it
# deletes the referenced resource's OWN referencing rows first (the
# inputControl, for the sub-resource layer) and recreates at the SAME uri, so
# any report unit already holding an inputControlReference to that uri keeps
# working across the replace. -Force's DELETE can itself still 403 if some
# OTHER report unit currently has the inputControl attached (this script never
# reaches into any report unit besides /reports/pos_perf/smoke_kpi to detach
# it for you) -- that case throws a clear, actionable error rather than
# silently doing nothing or corrupting the reference.
param([string]$Env = $env:JRS_ENV)
. (Join-Path $PSScriptRoot "..\..\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1")
$script:jrs = Resolve-JrsConfig -Env $Env
$script:ctl = "/reports/pos_perf/controls"
$script:ds  = "/datasources/pos_data_avalanche"

function Put-Json([string]$Uri, [string]$ContentType, [string]$Json) {
    $f = [IO.Path]::GetTempFileName()
    $Json | Set-Content $f -Encoding utf8
    try { $r = Invoke-JrsPut -Jrs $script:jrs -Uri $Uri -Overwrite -ContentType $ContentType -JsonFile $f }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
    Assert-JrsOk -Response $r -Operation "PUT $Uri" | Out-Null
    Write-Host "OK: $Uri"
}

function Try-PutJson([string]$Uri, [string]$ContentType, [string]$Json) {
    # Like Put-Json, but treats the one known "referenced, can't overwrite in
    # place" failure as a soft result instead of throwing: HTTP 403 whose body
    # carries errorCode resource.in.use (JRS does a delete+insert of a
    # listOfValues/query row under -Overwrite, which trips the FK from the
    # referencing JIInputControl row). Returns $true on 2xx, $false on that
    # specific 403, and still throws (via Assert-JrsOk, with its gotcha hint)
    # on any other error.
    $f = [IO.Path]::GetTempFileName()
    $Json | Set-Content $f -Encoding utf8
    try { $r = Invoke-JrsPut -Jrs $script:jrs -Uri $Uri -Overwrite -ContentType $ContentType -JsonFile $f }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
    if ("$($r.Code)" -match '^2\d\d$') { Write-Host "OK: $Uri"; return $true }
    if ("$($r.Code)" -eq '403' -and "$($r.Body)" -match 'resource\.in\.use') { return $false }
    Assert-JrsOk -Response $r -Operation "PUT $Uri" | Out-Null
    return $true
}

function Test-JrsExists([string]$Uri) {
    # $true on 2xx, $false ONLY on 404 (does-not-exist). Anything else (403,
    # 500, a network failure surfacing as a non-HTTP code, ...) throws instead
    # of being silently read as "does not exist" -- an existence check must
    # not misreport a real server/auth problem as a missing resource, which
    # would make a caller wrongly fall through to a create attempt whose
    # eventual failure then misdiagnoses the actual cause.
    $r = Invoke-JrsGet -Jrs $script:jrs -Uri $Uri
    if ("$($r.Code)" -match '^2\d\d$') { return $true }
    if ("$($r.Code)" -eq '404') { return $false }
    throw "Test-JrsExists: GET $Uri returned unexpected HTTP $($r.Code): $($r.Body)"
}

function Update-FinanceControl([string]$Name, [string]$SubName, [string]$SubContentType, [string]$SubJson, [string]$IcContentType, [string]$IcJson, [switch]$Force) {
    # Shared body for New-LovControl/New-QueryControl. There are TWO independent
    # FK layers that can block an in-place -Overwrite PUT, and both were found
    # empirically against STAGE (not assumed):
    #   1. JIListOfValues/JIQuery <- JIInputControl (the sub-resource is
    #      referenced by its own $Name inputControl).
    #   2. JIInputControl <- JIReportUnit, via jireportunitinputcontrol (the
    #      inputControl itself is referenced once ANY report unit has attached
    #      it, e.g. via Attach-Controls -- this is not just a hypothetical: it
    #      is exactly what happens to p_yyyymm/p_asof once smoke_kpi attaches
    #      them). Overwriting the inputControl is therefore NOT automatically
    #      safe just because it's "the referencing side" for layer 1 -- it can
    #      simultaneously be the REFERENCED side for layer 2.
    # So both the sub-resource and the inputControl get the same treatment:
    # attempt the update, and if JRS answers 403 resource.in.use, either warn
    # (default) or -Force a delete+recreate. -Force's delete is not assumed to
    # succeed either: if some report unit still references the inputControl,
    # DELETE hits the identical FK and throws a clear, actionable error rather
    # than silently doing nothing or reaching into that other report unit
    # (out of scope -- this script only ever touches /reports/pos_perf/smoke_kpi
    # among report units, per the task's hard rule).
    $subUri = "$script:ctl/$SubName"
    $icUri  = "$script:ctl/$Name"

    if (-not (Test-JrsExists $icUri)) {
        Put-Json $subUri $SubContentType $SubJson
        Put-Json $icUri $IcContentType $IcJson
        return
    }

    if ($Force) {
        $delCode = Invoke-JrsDelete -Jrs $script:jrs -Uri $icUri
        if ("$delCode" -notmatch '^2\d\d$') {
            throw "-Force replace of $icUri failed: DELETE returned HTTP $delCode -- it is still referenced " +
                  "(most likely attached to a report unit's inputControls); detach it there first, then retry -Force"
        }
        Write-Host "Deleted (for -Force replace): $icUri"
        Put-Json $subUri $SubContentType $SubJson
        Put-Json $icUri $IcContentType $IcJson
        return
    }

    # Not forcing: attempt both updates independently and warn (never throw)
    # on either specific "referenced, can't overwrite in place" 403.
    $subOk = Try-PutJson $subUri $SubContentType $SubJson
    if (-not $subOk) {
        Write-Warning "$subUri is referenced and was NOT updated; rerun with -Force to replace it"
    }
    $icOk = Try-PutJson $icUri $IcContentType $IcJson
    if (-not $icOk) {
        Write-Warning "$icUri is referenced (attached to a report unit) and was NOT updated; rerun with -Force to replace it"
    }
}

function New-LovControl([string]$Name, [string]$Label, [string[]]$Items, [switch]$Force) {
    # Items are "label=value" pairs. JSON is built by hand: PS 5.1 unwraps 1-element arrays.
    $itemJson = ($Items | ForEach-Object { $kv = $_.Split("=", 2); "{`"label`":`"$($kv[0])`",`"value`":`"$($kv[1])`"}" }) -join ","
    $lovJson = "{`"label`":`"$Label values`",`"items`":[$itemJson]}"
    $icJson  = ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":3," +
        "`"listOfValues`":{`"listOfValuesReference`":{`"uri`":`"$script:ctl/${Name}_lov`",`"version`":0}}}")
    Update-FinanceControl -Name $Name -SubName "${Name}_lov" -SubContentType "application/repository.listOfValues+json" -SubJson $lovJson `
        -IcContentType "application/repository.inputControl+json" -IcJson $icJson -Force:$Force
}

function New-QueryControl([string]$Name, [string]$Label, [string]$ValueCol, [string]$Sql, [int]$Type, [switch]$Force) {
    $queryJson = ("{`"label`":`"$Name query`",`"language`":`"sql`",`"value`":`"$($Sql -replace '"','\"')`"," +
        "`"dataSource`":{`"dataSourceReference`":{`"uri`":`"$script:ds`",`"version`":0}}}")
    $icJson = ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":$Type," +
        "`"valueColumn`":`"$ValueCol`",`"visibleColumns`":[`"$ValueCol`"]," +
        "`"query`":{`"queryReference`":{`"uri`":`"$script:ctl/${Name}_query`",`"version`":0}}}")
    Update-FinanceControl -Name $Name -SubName "${Name}_query" -SubContentType "application/repository.query+json" -SubJson $queryJson `
        -IcContentType "application/repository.inputControl+json" -IcJson $icJson -Force:$Force
}

function New-FinanceControls([switch]$Force) {
    $months = @()
    foreach ($y in 2019, 2020) { foreach ($m in 1..12) { $ym = "{0}{1:00}" -f $y, $m; $months += "$ym=$ym" } }
    New-LovControl -Name "p_yyyymm"  -Label "Month"          -Items $months -Force:$Force
    New-LovControl -Name "p_asof"    -Label "As of month"    -Items $months -Force:$Force
    New-LovControl -Name "p_version" -Label "Budget version" -Items @("Original=Original", "Reforecast Q2 2020=Reforecast Q2 2020") -Force:$Force
    New-LovControl -Name "p_province" -Label "Province" -Items @("All=All","ON=ON","QC=QC","BC=BC","AB=AB","SK=SK","MB=MB","NB=NB","NL=NL","NS=NS","PE=PE","YT=YT","NT=NT") -Force:$Force
    New-QueryControl -Name "p_franchisee" -Label "Franchisee" -ValueCol "franchisee_id" -Sql "SELECT DISTINCT franchisee_id FROM franchisees ORDER BY 1" -Type 7 -Force:$Force
    New-QueryControl -Name "p_store" -Label "Store" -ValueCol "storenumber" -Sql "SELECT DISTINCT storenumber FROM stores ORDER BY 1" -Type 4 -Force:$Force
}

function Attach-Controls([string]$ReportUri, [string[]]$ControlUris) {
    $cur = Invoke-JrsGet -Jrs $script:jrs -Uri $ReportUri
    Assert-JrsOk -Response $cur -Operation "GET $ReportUri" | Out-Null
    $ru = $cur.Body | ConvertFrom-Json
    # Drop any existing inputControls property before serializing (a prior
    # Attach-Controls call may have left one, as an object OR an array) so
    # ConvertTo-Json never has a chance to touch it -- PS 5.1's ConvertTo-Json
    # unwraps a one-element array into a scalar object, which the server
    # rejects with a 400 "ArrayList from String value". The array is instead
    # built as literal JSON text below and spliced in, for both the
    # one-control and N-control cases, so the trap never applies.
    if ($ru.PSObject.Properties.Name -contains "inputControls") {
        $ru.PSObject.Properties.Remove("inputControls")
    }
    $ru | Add-Member -NotePropertyName controlsLayout -NotePropertyValue "popupScreen" -Force
    $json = $ru | ConvertTo-Json -Depth 12
    $icJson = "[" + (($ControlUris | ForEach-Object { "{`"inputControlReference`":{`"uri`":`"$_`"}}" }) -join ",") + "]"
    $json = $json -replace '^\{', ('{"inputControls":' + $icJson + ',')
    Put-Json $ReportUri "application/repository.reportUnit+json" $json
}
