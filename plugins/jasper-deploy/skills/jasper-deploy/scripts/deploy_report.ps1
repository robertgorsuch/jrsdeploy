<#
.SYNOPSIS
  Deploy a .jrxml to JasperReports Server as a reportUnit via the REST v2 API.

.DESCRIPTION
  Builds a reportUnit descriptor with the jrxml inlined as base64 content and
  PUTs it to /rest_v2/resources (creating intermediate folders). The jrxml is
  uploaded as-is; JasperReports Server compiles it server-side on first run.
  A datasource reference is optional but a report won't run without one.

  Server URL and credentials are resolved in this order (first wins):
    1. -ServerUrl / -User / -Password parameters
    2. environment variables JRS_URL / JRS_USER / JRS_PASS
    3. jrs.config.json in the skill root (gitignored)

.PARAMETER Jrxml
  Path to the .jrxml to deploy.

.PARAMETER TargetUri
  Repository URI for the report unit, e.g. /reports/geocoder/county_summary
  (no spaces). The last segment becomes the resource id.

.PARAMETER Label
  Human-readable label. Defaults to the file base name.

.PARAMETER DataSourceUri
  Repository URI of an EXISTING datasource, e.g. /datasources/postgis_34_sample.

.PARAMETER Env
  Named profile under "environments" in jrs.config.json (e.g. stage, prod).

.OUTPUTS
  One PSCustomObject on the pipeline (New-JrsDeployResult in _jrs_common.ps1):
    Uri, Code (HTTP), Status (OK), ControlsAttached (int), Message.
  The human-readable progress lines go to the host stream only, which a
  `2>&1` redirect does NOT capture under Windows PowerShell 5.1 -- test the
  object instead:  $r = & .\deploy_report.ps1 ...; if ($r.Status -ne "OK") { ... }
  Failures throw (terminating error, exit code 1 from powershell -File). A
  403/400 `resource.in.use` (the report is a dashlet of a live dashboard and
  its lock also blocks an ?overwrite=true PUT) is explained with the list of
  dashboards that reference the report and the recompose hint.

.EXAMPLE
  .\deploy_report.ps1 -Jrxml ..\..\report\county_summary.jrxml `
      -TargetUri /reports/geocoder/county_summary `
      -Label "County Edge Summary" `
      -DataSourceUri /datasources/postgis_34_sample
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Jrxml,
    [Parameter(Mandatory = $true)][string]$TargetUri,
    [string]$Label,
    [string]$Description = "",
    [string]$DataSourceUri,
    [string[]]$ResourceFiles,   # companion resources: "name=localpath" (bundles, images, subreports)
    [switch]$Overwrite,
    [switch]$SkipSqlLint,       # bypass the SELECT-first / leading-WITH guard
    [switch]$SkipLint,          # bypass the lint_jrxml.ps1 pre-deploy gate
    [switch]$Apply,             # -Overwrite PLANS BY DEFAULT (1.3.0): pass -Apply to actually overwrite. A plain
                                # create (no -Overwrite) is not gated.
    [switch]$Backup,            # accepted for compatibility: an -Overwrite of an existing unit backs up by default
    [switch]$NoBackup,          # skip that backup (the overwrite is then journaled as irreversible)
    [string]$BackupDir,         # where the backup archive goes (default: skill out\backups)
    [string[]]$Control,         # input controls: "param:kind[:label[:extra]]"
                                #   kind=select|multiselect  extra="Food;Drink" (or lab=val;..)
                                #   kind=single              extra=text|number|date|datetime
    [string[]]$QueryControl,    # query-backed single-select control:
                                #   "param|valueCol|visibleCols|SQL"  (SQL is last, may contain |;
                                #   visibleCols comma-separated, defaults to valueCol). Cascade by
                                #   referencing a parent control as $P{parent} in the SQL.
    [string[]]$QueryMultiControl,  # same format, multi-select (type 7)
    [string]$ControlsLayout = "popupScreen",
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env                # named profile in jrs.config.json "environments"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

# -Overwrite without -Apply runs the whole script in plan mode: the write guard
# in _jrs_common.ps1 refuses any PUT/DELETE below (and in child scripts) even if
# a later edit forgets the early return. Restored in the finally at the end.
$prevMode = Enter-JrsPlanMode -Apply:($Apply -or -not $Overwrite)
$run = $null
try {
if (-not (Test-Path $Jrxml)) { throw "jrxml not found: $Jrxml" }
$jrxmlFull = (Resolve-Path $Jrxml).Path

# --- SQL lint: a leading WITH (CTE) or non-SELECT query compiles locally but
#     the JRS SQL security validator rejects it at fill time (JSSecurityException
#     surfaced as a generic 400). Catch it before deploying.
if (-not $SkipSqlLint) {
    $jx = Get-Content $jrxmlFull -Raw
    $mq = [regex]::Match($jx, '(?s)<query[^>]*language="SQL"[^>]*>\s*<!\[CDATA\[(.*?)\]\]>')
    if ($mq.Success) {
        $q = $mq.Groups[1].Value.Trim()
        while ($true) {                              # strip leading SQL comments
            if ($q.StartsWith("--"))     { $i = $q.IndexOf("`n"); $q = if ($i -ge 0) { $q.Substring($i + 1).TrimStart() } else { "" } }
            elseif ($q.StartsWith("/*")) { $i = $q.IndexOf("*/");  $q = if ($i -ge 0) { $q.Substring($i + 2).TrimStart() } else { "" } }
            else { break }
        }
        $kw = ([regex]::Match($q, "(?i)^[a-z]+")).Value.ToLower()
        if ($kw -eq "with") {
            throw "SQL lint: query begins with WITH (CTE). JRS rejects this at fill time though it compiles locally. Rewrite each CTE as a FROM subquery so the statement starts with SELECT, or pass -SkipSqlLint. (See SKILL.md gotchas.)"
        } elseif ($kw -and $kw -ne "select") {
            Write-Warning "SQL lint: query begins with '$kw', not SELECT; JRS requires report queries to start with SELECT."
        }
    }
}

# --- jrxml lint: catch strict-Jackson / chart-plot / control gotchas that
#     compile clean locally but 400 at fill time. lint_jrxml.ps1 exits 1 on any
#     ERROR. This is the real deploy gate (the smoke test lints too).
if (-not $SkipLint) {
    $linter = Join-Path $PSScriptRoot "lint_jrxml.ps1"
    if (Test-Path $linter) {
        $lintOut = & $linter -Path $jrxmlFull *>&1
        if ($LASTEXITCODE -ne 0) {
            $lintOut | ForEach-Object { Write-Host $_ }
            throw "jrxml lint found blocking issue(s) in $Jrxml -- fix them or pass -SkipLint. See references/jr7-valid-elements.md."
        }
    }
}

# --- resolve config (param -> env -> jrs.config.json, validated) ----------
$jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
if (-not $DataSourceUri) { $DataSourceUri = $jrs.DataSourceUri }
if (-not $TargetUri.StartsWith("/")) { $TargetUri = "/$TargetUri" }
if (-not $Label) { $Label = [System.IO.Path]::GetFileNameWithoutExtension($jrxmlFull) }

# --- build reportUnit descriptor -----------------------------------------
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($jrxmlFull))

$desc = [ordered]@{
    label       = $Label
    description = $Description
    jrxml       = [ordered]@{
        jrxmlFile = [ordered]@{
            label   = "$Label main jrxml"
            type    = "jrxml"
            content = $b64
        }
    }
}
if ($DataSourceUri) {
    $desc.dataSource = [ordered]@{ dataSourceReference = [ordered]@{ uri = $DataSourceUri } }
} else {
    Write-Warning "No datasource specified; report unit will be created but won't run until one is attached."
}

# optional companion resources embedded in the report unit (resource bundles,
# images, subreport .jasper, etc.). -ResourceFiles entries are "name=localpath".
if ($ResourceFiles) {
    $extType = @{ ".properties"="prop"; ".png"="img"; ".gif"="img"; ".jpg"="img"; ".jpeg"="img";
                  ".jrxml"="jrxml"; ".jasper"="jrxml"; ".ttf"="font"; ".xml"="xml" }
    $list = @()
    foreach ($rf in $ResourceFiles) {
        $name, $path = $rf -split "=", 2
        if (-not (Test-Path $path)) { throw "resource file not found: $path" }
        $ext = [IO.Path]::GetExtension($path).ToLower()
        $rtype = if ($extType.ContainsKey($ext)) { $extType[$ext] } else { "txt" }
        $rb64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $path)))
        $list += [ordered]@{ name = $name; file = [ordered]@{ fileResource = [ordered]@{ label = $name; type = $rtype; content = $rb64 } } }
    }
    $desc.resources = [ordered]@{ resource = $list }
}

# --- PUT to REST v2 -------------------------------------------------------
# JRS uses optimistic locking, so a plain re-PUT over an existing report unit
# fails with 409 "versions not match". -Overwrite passes ?overwrite=true.
# Observed on JRS 10.0.0: overwrite=true RE-CREATES the unit (version resets to
# 0, creationDate = now, inputControls dropped unless the body carries them --
# see the preserve block below) and it is still refused with 403
# resource.in.use while a live dashboard references the report. Tear the
# dashboard down / recompose with -Replace first (promote.ps1 -Manifest orders
# this for you).

# --- -Overwrite: plan gate, default backup, run journal ----------------------
$deployStep = "deploy:$TargetUri"; $deployComp = $null; $deployIrrev = $null
if ($Overwrite) {
    $exists = ("$((Invoke-JrsGet -Jrs $jrs -Uri $TargetUri).Code)" -match '^2\d\d$')
    $bkWord = if ($NoBackup) { "no backup (irreversible)" } else { "backup then" }
    $action = if ($exists) { "$bkWord OVERWRITE (re-creates the unit at version 0; live input controls carried over)" } else { "CREATE (absent on target)" }
    $plan = @([pscustomobject]@{ Order = 1; Kind = "deploy"; Uri = $TargetUri; Action = $action })
    Write-Host ""
    Write-Host "DEPLOY PLAN  $TargetUri on $($jrs.ServerUrl)$(if ($jrs.Env) { " [env $($jrs.Env)]" }) (exists on target: $exists)"
    Write-Host ("  [  1] {0,-52} {1}" -f $TargetUri, $action)
    Write-Host ""
    if (-not $Apply) {
        Write-Host "[plan] nothing was written to $($jrs.ServerUrl); pass -Apply to overwrite"
        Write-Output (New-JrsDeployResult -Uri $TargetUri -Code "PLAN" -Status PLAN -ControlsAttached 0 -Message "plan only: $action")
        return
    }
    Assert-JrsWriteAllowed -Jrs $jrs -Method APPLY -Url $jrs.ServerUrl   # precheck: refuse an unconfirmed prod target BEFORE any backup/export runs
    $run = New-JrsRun -Operation "deploy" -Target $jrs -Mode apply -Plan $plan -Arguments @{ Jrxml = $Jrxml; TargetUri = $TargetUri; Overwrite = $true; NoBackup = [bool]$NoBackup }
    if ($exists) {
        # rollback safety: the pre-overwrite export is the step's 'reimport' compensation
        if ($NoBackup) { $deployIrrev = "-NoBackup" }
        else {
            $bkPath = Export-JrsBackup -Jrs $jrs -Uri $TargetUri -BackupDir $BackupDir
            if ($bkPath) { Write-Host "  backup: $TargetUri -> $bkPath"; $deployComp = @{ type = "reimport"; zip = $bkPath; uri = $TargetUri } }
            else { $deployIrrev = "backup export failed" }
        }
    } else { $deployComp = @{ type = "delete"; uri = $TargetUri } }
    Write-JrsStep -Run $run -Step $deployStep -State RUNNING -Compensation $deployComp -Irreversible $deployIrrev
}

# --- -Overwrite preserves the existing input-control attachments ---------------
# PUT ?overwrite=true re-creates the unit (version 0) and DROPS inputControls.
# Unless this call attaches its own (-Control / -QueryControl / -QueryMultiControl),
# carry the live list over so a redeploy never silently strips a filter board.
# (2026-08-28: a manifest promotion redeployed 22 PROD tiles this way and every
# dashboard import then skipped because its filter wiring had no controls.)
$keepIcJson = $null
if ($Overwrite -and -not ($Control -or $QueryControl -or $QueryMultiControl)) {
    $cur0 = Invoke-JrsGet -Jrs $jrs -Uri $TargetUri
    if ("$($cur0.Code)" -eq "200") {
        try {
            $o0 = $cur0.Body | ConvertFrom-Json
            $keep = @()
            if ($o0.PSObject.Properties.Name -contains "inputControls") { $keep = @($o0.inputControls | ForEach-Object { $_.inputControlReference.uri } | Where-Object { $_ }) }
            if ($keep.Count -gt 0) {
                # literal JSON: PS 5.1 ConvertTo-Json unwraps a one-element array (gotcha G56)
                $keepIcJson = "[" + (($keep | ForEach-Object { '{"inputControlReference":{"uri":"' + $_ + '"}}' }) -join ",") + "]"
                Write-Host "  preserving $($keep.Count) attached input control(s) across the overwrite"
            }
        } catch { }
    }
}

$jsonFile = [IO.Path]::GetTempFileName()
$descJson = ($desc | ConvertTo-Json -Depth 8)
if ($keepIcJson) { $descJson = $descJson -replace '^\{', ('{"inputControls":' + $keepIcJson + ',') }
$descJson | Set-Content -Path $jsonFile -Encoding utf8
try {
    $r = Invoke-JrsPut -Jrs $jrs -Uri $TargetUri -Overwrite:$Overwrite `
        -ContentType "application/repository.reportUnit+json" -JsonFile $jsonFile
} finally {
    Remove-Item $jsonFile -ErrorAction SilentlyContinue
}

# --- resource.in.use: the report is a dashlet of a live dashboard and this PUT
#     (with or without -Overwrite -- the lock blocks both). The dashboard holds
#     a delete-lock on its tiles, so say WHICH dashboard(s) so the operator can
#     recompose them (compose_dashboard.ps1 -Replace -Backup) instead of
#     guessing from a bare 403.
if ("$($r.Code)" -notmatch '^2\d\d$' -and "$($r.Body)" -match 'resource\.in\.use') {
    $owners = @()
    try { $owners = @(Get-JrsDashboardsReferencing -Jrs $jrs -Uri $TargetUri) } catch { $owners = @() }
    $who = if ($owners.Count -gt 0) { "referenced by dashboard(s): " + ($owners -join ", ") }
           else { "referenced by a dashboard (search via GET rest_v2/resources?type=dashboard found no match; it may live in another folder or organization)" }
    Write-Host "resource.in.use: $TargetUri is $who"
    throw ("deploy of $TargetUri failed (HTTP $($r.Code)): resource.in.use -- $who. " +
           "-Overwrite does not help (the lock blocks ?overwrite=true too). Take the dashboard down and back up: " +
           "compose_dashboard.ps1 -Manifest <manifest> -Replace -Backup (exports it first, deletes it, releases the lock, " +
           "redeploy the tile, recompose) -- or promote.ps1 -Manifest, which orders teardown -> tiles -> compose. " +
           "See references/gotchas.md (G21).")
}
if ($run -and "$($r.Code)" -notmatch '^2\d\d$') { Write-JrsStep -Run $run -Step $deployStep -State FAILED -Detail "HTTP $($r.Code)" }
Assert-JrsOk -Response $r -Operation "deploy of $TargetUri failed" | Out-Null
if ($run) { Write-JrsStep -Run $run -Step $deployStep -State SUCCEEDED -Detail "HTTP $($r.Code)" }
Write-Host "OK ($($r.Code)): deployed $TargetUri"
if ($r.Body) { Write-Host $r.Body }
$deployCode = "$($r.Code)"
$controlsAttached = 0

# --- input controls -------------------------------------------------------
# Build each control as a standalone repository resource (the verified JRS
# pattern -- embedding in the report unit is rejected) whose NAME equals the
# report parameter ($P{name}), then reference it from the report unit. select/
# multiselect get a listOfValues resource; single gets an embedded dataType.
if ($Control -or $QueryControl -or $QueryMultiControl) {
    $parent = $TargetUri.Substring(0, $TargetUri.LastIndexOf("/"))
    $rname  = $TargetUri.Substring($TargetUri.LastIndexOf("/") + 1)
    $ctlFolder = "$parent/${rname}_controls"

    function Put-Resource($uri, $ctype, $obj) {
        $f = [IO.Path]::GetTempFileName()
        ($obj | ConvertTo-Json -Depth 8) | Set-Content $f -Encoding utf8
        try { $rr = Invoke-JrsPut -Jrs $jrs -Uri $uri -Overwrite -ContentType $ctype -JsonFile $f }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
        Assert-JrsOk -Response $rr -Operation "input control PUT $uri failed" | Out-Null
    }

    $icRefs = @()
    foreach ($spec in $Control) {
        $p = $spec.Split(":", 4)
        $cname = $p[0]; $kind = $p[1].ToLower()
        $label = if ($p.Count -ge 3 -and $p[2]) { $p[2] } else { $cname }
        $extra = if ($p.Count -ge 4) { $p[3] } else { "" }
        $icUri = "$ctlFolder/$cname"
        if ($kind -eq "select" -or $kind -eq "multiselect") {
            $items = @()
            foreach ($v in ($extra -split ";")) {
                if (-not $v) { continue }
                if ($v -match "=") { $kv = $v.Split("=", 2); $items += [ordered]@{ label = $kv[0]; value = $kv[1] } }
                else { $items += [ordered]@{ label = $v; value = $v } }
            }
            $lovUri = "$ctlFolder/${cname}_lov"
            Put-Resource $lovUri "application/repository.listOfValues+json" ([ordered]@{ label = "$label values"; items = $items })
            $type = if ($kind -eq "select") { 3 } else { 6 }
            Put-Resource $icUri "application/repository.inputControl+json" ([ordered]@{
                label = $label; mandatory = $false; readOnly = $false; visible = $true; type = $type
                listOfValues = [ordered]@{ listOfValuesReference = [ordered]@{ uri = $lovUri; version = 0 } } })
        } elseif ($kind -eq "single") {
            $dt = if ($extra) { $extra } else { "text" }
            Put-Resource $icUri "application/repository.inputControl+json" ([ordered]@{
                label = $label; mandatory = $false; readOnly = $false; visible = $true; type = 2
                dataType = [ordered]@{ dataType = [ordered]@{ type = $dt; label = "$cname type" } } })
        } else { throw "unknown control kind '$kind' (use select|multiselect|single)" }
        $icRefs += [ordered]@{ inputControlReference = [ordered]@{ uri = $icUri } }
        Write-Host "  input control: $cname ($kind) -> $icUri"
    }

    # query-backed controls (single = type 4, multi = type 7). Each gets a
    # companion `query` resource on the report's datasource; cascading works by
    # referencing a parent control as $P{parent} in the SQL (parent must be
    # listed/created first so it resolves). Process parents before children by
    # passing them earlier in -QueryControl.
    $queryGroups = @()
    if ($QueryControl)      { $queryGroups += ,@($QueryControl, 4) }
    if ($QueryMultiControl) { $queryGroups += ,@($QueryMultiControl, 7) }
    foreach ($grp in $queryGroups) {
        $specs, $qtype = $grp
        if (-not $DataSourceUri) { throw "query controls require a datasource (-DataSourceUri); the control's query runs on it" }
        foreach ($spec in $specs) {
            $f = $spec -split "\|", 4    # param|valueCol|visibleCols|SQL (SQL last, may contain |)
            if ($f.Count -lt 4) { throw "query control '$spec' must be 'param|valueCol|visibleCols|SQL'" }
            $cname = $f[0]; $valueCol = $f[1]
            $visible = if ($f[2]) { @($f[2] -split ",") } else { @($valueCol) }
            $sql = $f[3]
            $qUri  = "$ctlFolder/${cname}_query"
            $icUri = "$ctlFolder/$cname"
            Put-Resource $qUri "application/repository.query+json" ([ordered]@{
                label = "$cname query"; language = "sql"; value = $sql
                dataSource = [ordered]@{ dataSourceReference = [ordered]@{ uri = $DataSourceUri; version = 0 } } })
            # Build visibleColumns JSON by hand: PS 5.1 ConvertTo-Json unwraps a
            # single-element array to a scalar string, which the server rejects
            # (ArrayList from String value). Emit an explicit JSON array.
            $visJson = "[" + (($visible | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ",") + "]"
            $icJson = "{`"label`":`"$cname`",`"mandatory`":false,`"readOnly`":false,`"visible`":true," +
                      "`"type`":$qtype,`"valueColumn`":`"$valueCol`",`"visibleColumns`":$visJson," +
                      "`"query`":{`"queryReference`":{`"uri`":`"$qUri`",`"version`":0}}}"
            $icf = [IO.Path]::GetTempFileName()
            $icJson | Set-Content $icf -Encoding utf8
            try { $icr = Invoke-JrsPut -Jrs $jrs -Uri $icUri -Overwrite -ContentType "application/repository.inputControl+json" -JsonFile $icf }
            finally { Remove-Item $icf -ErrorAction SilentlyContinue }
            Assert-JrsOk -Response $icr -Operation "query control PUT $icUri failed" | Out-Null
            $icRefs += [ordered]@{ inputControlReference = [ordered]@{ uri = $icUri } }
            Write-Host "  input control: $cname (query type $qtype, value=$valueCol) -> $icUri"
        }
    }

    # reference the controls from the report unit
    $cur = Invoke-JrsGet -Jrs $jrs -Uri $TargetUri
    Assert-JrsOk -Response $cur -Operation "could not re-read $TargetUri to attach controls" | Out-Null
    $ru = $cur.Body | ConvertFrom-Json
    $ru | Add-Member -NotePropertyName inputControls -NotePropertyValue $icRefs -Force
    $ru | Add-Member -NotePropertyName controlsLayout -NotePropertyValue $ControlsLayout -Force
    $f2 = [IO.Path]::GetTempFileName()
    ($ru | ConvertTo-Json -Depth 12) | Set-Content $f2 -Encoding utf8
    try { $ur = Invoke-JrsPut -Jrs $jrs -Uri $TargetUri -Overwrite -ContentType "application/repository.reportUnit+json" -JsonFile $f2 }
    finally { Remove-Item $f2 -ErrorAction SilentlyContinue }
    Assert-JrsOk -Response $ur -Operation "attaching controls to $TargetUri failed" | Out-Null
    Write-Host "OK: attached $($icRefs.Count) input control(s) to $TargetUri"
    $controlsAttached = $icRefs.Count
}

# --- pipeline result (the only thing this script writes to the output stream) --
if ($run) { Complete-JrsRun -Run $run -Status SUCCEEDED }
$msg = "deployed $TargetUri (HTTP $deployCode)"
if ($controlsAttached -gt 0) { $msg += ", $controlsAttached input control(s) attached" }
if ($run -and $run.RunId -and -not $run.Nested) { $msg += " [run $($run.RunId)]" }
Write-Output (New-JrsDeployResult -Uri $TargetUri -Code $deployCode -Status OK `
    -ControlsAttached $controlsAttached -Message $msg)
} catch {
    if ($run -and -not $run.Nested) {
        try { Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error "$_" } catch { }
        Write-Host "FAILED (run $($run.RunId)); undo what was done with: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply"
    }
    throw
} finally { Restore-JrsPlanMode $prevMode }
