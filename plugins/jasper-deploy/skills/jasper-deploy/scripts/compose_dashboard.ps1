<#
.SYNOPSIS
  Compose a JasperReports Server dashboard from a manifest and deploy it -- no
  designer needed.

.DESCRIPTION
  JRS 10 dashboards cannot be created by PUTting a model to /rest_v2/resources
  (the server stores it but renders it blank). The supported path is import of
  the designer's own export archive. This script reproduces that archive
  programmatically:

    1. Export the already-deployed dashlet reports named in the manifest -- this
       yields a real, importable envelope (reportUnit descriptors + their jrxml,
       the datasource, the folder chain, a valid index.xml).
    2. Synthesize the dashboard descriptor + the three companion files
       (components.data / layout / wiring.data) from the manifest, via
       gen_dashboard.py. (The model shape was reverse-engineered from a real
       designer export; every field matches.)
    3. Inject the dashboard into the exported envelope, point index.xml's
       repositoryResources at the dashboard, re-zip (forward-slash entries so the
       Java importer reads them), and import.

  Because the resulting archive is structurally identical to a designer export,
  the imported dashboard renders correctly (unlike a raw resource PUT).

  RECOMPOSE = REPLACE. JRS import (update=true) does NOT overwrite an existing
  dashboard's companion files (layout/components/wiring), so a recompose over a
  live dashboard would silently keep the OLD layout. The script therefore runs
  ONE logged transaction: [backup] -> DELETE existing dashboard -> import fresh
  archive -> verify. That is the default and what -Replace names explicitly
  (the idempotent path: same manifest in, same dashboard out, any number of
  times). -KeepExisting skips the delete (rarely wanted; the import then
  cannot change the layout and a tile redeploy will keep 403ing with
  resource.in.use).

  The dashlet reports MUST already be deployed (use build_dashlets.ps1 or
  deploy_report.ps1 first). Credentials resolve via _jrs_common.ps1 (-Env picks
  a named profile from jrs.config.json).

.PARAMETER Manifest
  Dashboard manifest JSON: { folder, name, label, dashlets:[{resource,label,
  x,y,width,height}, ...] }. See references/manifest.schema.json; the optional
  "controls" key is consumed by -EnsureControls.

.PARAMETER Replace
  Explicit name for the default delete+import recompose (idempotent). Cannot be
  combined with -KeepExisting.

.PARAMETER KeepExisting
  Skip the delete. The import will NOT update the layout of an existing
  dashboard; use only when you know the dashboard is absent.

.PARAMETER Backup
  Export the existing dashboard (descriptor + companions) to -BackupDir before
  deleting it; the archive path is returned as BackupPath.

.PARAMETER EnsureControls
  Before composing, run ensure_controls.ps1 against the manifest's "controls"
  key (create-if-absent). No-op when the manifest has no such key.

.PARAMETER AutoGrid
  Auto-place any dashlet missing x/y/width/height on a two-column 40-wide grid.

.PARAMETER WorkDir
  Scratch directory for the intermediate archives (default out\dash_build).

.OUTPUTS
  [pscustomobject] { Uri; Code; Replaced; BackupPath; Dashlets; ModelResources; ViewUrl }
  on the pipeline (progress goes to the host stream).

.EXAMPLE
  .\compose_dashboard.ps1 -Manifest report\foodmart\dashboard.json -AutoGrid

.EXAMPLE
  $r = .\compose_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Replace -Backup -Env prod
  $r.BackupPath
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [switch]$AutoGrid,
    [string]$WorkDir = "out/dash_build",
    [int]$TimeoutSec = 120,
    [switch]$Replace,           # explicit alias for the default delete+import recompose
    [switch]$KeepExisting,      # skip the delete (import then cannot change the layout)
    [switch]$Apply,             # PLAN BY DEFAULT (1.3.0): without -Apply the plan is printed and nothing is written
    [switch]$Backup,            # accepted for compatibility: a backup is now taken by default before the delete
    [switch]$NoBackup,          # skip that backup (the delete step is then journaled as irreversible)
    [string]$BackupDir,         # where the backup archive goes (default: skill out\backups)
    [switch]$EnsureControls,    # create the manifest's "controls" (ensure_controls.ps1) first
    [string]$Env,               # named profile in jrs.config.json "environments"
    [string]$ServerUrl,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($Replace -and $KeepExisting) { throw "-Replace and -KeepExisting are mutually exclusive" }
if (-not (Test-Path $Manifest)) { throw "manifest not found: $Manifest" }
# Plan mode is enforced by the write guard in _jrs_common.ps1 for everything
# below (and for every child script), not just by the early return: a clobbered
# switch cannot turn writes on. Restored in the finally at the end of the file.
$prevMode = Enter-JrsPlanMode -Apply:$Apply
try {
$jrs  = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
$auth = "$($jrs.User):$($jrs.Password)"
$replaceMode = -not $KeepExisting

# --- read manifest (tolerate a UTF-8 BOM) -------------------------------------
$m = (Get-Content $Manifest -Raw) -replace "^\xEF\xBB\xBF", "" | ConvertFrom-Json
$folder = $m.folder.TrimEnd("/")
$name   = $m.name
$dashUri = "$folder/$name"
# only report tiles need exporting (text/image tiles carry no repository report)
$reportUris = @($m.dashlets | Where-Object { -not $_.kind -or $_.kind -eq "report" } |
    ForEach-Object { if ($_.resource) { $_.resource } else { "$folder/$($_.name)" } } |
    Select-Object -Unique)
if (-not $reportUris) { throw "manifest has no report dashlets to export" }
Write-Host "composing dashboard $dashUri from $($reportUris.Count) dashlet(s) on $($jrs.ServerUrl) [mode: $(if ($replaceMode) { 'replace (delete+import)' } else { 'keep-existing' })]"

# --- plan (GET only) ------------------------------------------------------------
$existed = ("$((Invoke-JrsGet -Jrs $jrs -Uri $dashUri).Code)" -match '^2\d\d$')
$bkWord = if ($NoBackup) { "no backup (irreversible)" } else { "backup then" }
$plan = @()
if ($EnsureControls -and ($m.PSObject.Properties.Name -contains "controls") -and $m.controls) {
    $plan += [pscustomobject]@{ Order = $plan.Count + 1; Kind = "controls"; Uri = $dashUri; Action = "ENSURE $(@($m.controls).Count) input control(s) from the manifest (create-if-absent)" }
}
if ($existed -and $replaceMode) { $plan += [pscustomobject]@{ Order = $plan.Count + 1; Kind = "delete"; Uri = $dashUri; Action = "$bkWord DELETE the live dashboard (releases its tile locks)" } }
elseif ($existed)               { $plan += [pscustomobject]@{ Order = $plan.Count + 1; Kind = "keep";   Uri = $dashUri; Action = "KEEP (-KeepExisting): the import will NOT change the live layout" } }
$plan += [pscustomobject]@{ Order = $plan.Count + 1; Kind = "import"; Uri = $dashUri; Action = "IMPORT composed archive ($($reportUris.Count) dashlet(s))$(if (-not $existed) { ' [new]' })" }
Write-Host ""
Write-Host "COMPOSE PLAN  $dashUri on $($jrs.ServerUrl)$(if ($jrs.Env) { " [env $($jrs.Env)]" }) (exists on target: $existed)"
foreach ($s in $plan) { Write-Host ("  [{0,3}] {1,-8} {2,-52} {3}" -f $s.Order, $s.Kind, $s.Uri, $s.Action) }
Write-Host ""
if (-not $Apply) {
    Write-Host "[plan] nothing was written to $($jrs.ServerUrl); pass -Apply to compose"
    return [pscustomobject]@{ Uri = $dashUri; Code = "PLAN"; Replaced = $false; BackupPath = $null; Dashlets = $reportUris.Count; ModelResources = 0; ViewUrl = $null; Plan = $plan }
}
Assert-JrsWriteAllowed -Jrs $jrs -Method APPLY -Url $jrs.ServerUrl   # precheck: refuse an unconfirmed prod target before any export runs
$run = New-JrsRun -Operation "compose" -Target $jrs -Mode apply -Plan $plan -Arguments @{ Manifest = $Manifest; Replace = [bool]$replaceMode; NoBackup = [bool]$NoBackup }

# --- 0. optional: ensure the manifest's input controls ------------------------
if ($EnsureControls) {
    if ($m.PSObject.Properties.Name -contains "controls" -and $m.controls) {
        Write-Host "--- ensure input controls (manifest 'controls' key) ---"
        & (Join-Path $PSScriptRoot "ensure_controls.ps1") -Spec $Manifest `
            -ServerUrl $jrs.ServerUrl -User $jrs.User -Password $jrs.Password | Out-Null
    } else { Write-Host "  (manifest has no 'controls' key; nothing to ensure)" }
}

# fresh workspace
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$baseZip = Join-Path $WorkDir "base.zip"
$genZip  = Join-Path $WorkDir "gen.zip"
$tree    = Join-Path $WorkDir "tree"
$finalZip = Join-Path $WorkDir "$name.zip"

# --- 1. export the dashlet reports -> real importable envelope ----------------
$body = @{ uris = $reportUris; parameters = @("repository-permissions") } | ConvertTo-Json -Compress
$reqFile = [IO.Path]::GetTempFileName()
$body | Set-Content -Path $reqFile -Encoding utf8
try {
    $resp = & (Get-JrsCurl) -s -S -u $auth -X POST -H "Content-Type: application/json" `
        -H "Accept: application/json" --data-binary "@$reqFile" "$($jrs.ServerUrl)/rest_v2/export"
} finally { Remove-Item $reqFile -ErrorAction SilentlyContinue }
$eid = ($resp | ConvertFrom-Json).id
if (-not $eid) { throw "export request failed: $resp" }
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
    Start-Sleep -Milliseconds 800
    $phase = (& (Get-JrsCurl) -s -u $auth -H "Accept: application/json" "$($jrs.ServerUrl)/rest_v2/export/$eid/state" | ConvertFrom-Json).phase
    if ($phase -eq "failed") { throw "export failed for dashlet reports" }
} while ($phase -ne "finished" -and (Get-Date) -lt $deadline)
if ($phase -ne "finished") { throw "export timed out (phase=$phase)" }
$code = & (Get-JrsCurl) -s -o $baseZip -w "%{http_code}" -u $auth -H "Accept: application/zip" "$($jrs.ServerUrl)/rest_v2/export/$eid/exportFile"
if ("$code".Trim() -ne "200") { throw "export download failed (HTTP $code)" }
Write-Host "  exported envelope: $((Get-Item $baseZip).Length) bytes"

# --- 2. synthesize the dashboard descriptor + companion files -----------------
$genArgs = @("$PSScriptRoot/gen_dashboard.py", "--manifest", $Manifest, "--out", $genZip)
if ($AutoGrid) { $genArgs += "--auto-grid" }
& (Get-JrsPython) @genArgs | Write-Host
if ($LASTEXITCODE -ne 0) { throw "gen_dashboard.py failed" }

# --- 3. inject dashboard into the envelope ------------------------------------
# Resolve extraction targets so this works whether -WorkDir was given relative
# (resolved against the PS location) or absolute (used as-is). A bare
# Join-Path (Get-Location) on an already-rooted path yields an invalid
# "C:\cwd\C:\abs" string -> ExtractToDirectory "path's format is not supported".
function Resolve-OutPath($p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p } }
[System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $baseZip).Path, (Resolve-OutPath $tree))
$genX = Join-Path $WorkDir "gen_x"
[System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $genZip).Path, (Resolve-OutPath $genX))

$rel = "resources$folder"
$dst = Join-Path $tree $rel
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item (Join-Path $genX "$rel/$name.xml") $dst -Force
Copy-Item (Join-Path $genX "$rel/${name}_files") $dst -Recurse -Force

# point index.xml's repositoryResources at the dashboard (reports stay as deps)
$indexPath = Join-Path $tree "index.xml"
$idx = Get-Content $indexPath -Raw
# (?s): a real export keeps <export> on one line, but tolerate a pretty-printed index
$idx = [regex]::Replace($idx, '(?s)<module id="repositoryResources">.*?</module>',
    "<module id=`"repositoryResources`"><resource>$dashUri</resource></module>")
Set-Content $indexPath -Value $idx -Encoding utf8 -NoNewline

# --- 4. re-zip with forward-slash entries (Java importer requires it) ---------
if (Test-Path $finalZip) { Remove-Item $finalZip -Force }
$treeFull = (Resolve-Path $tree).Path
& (Get-JrsPython) -c @"
import zipfile, os, sys
root = sys.argv[1]
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk(root):
        for f in fs:
            full = os.path.join(d, f)
            z.write(full, os.path.relpath(full, root).replace(os.sep, '/'))
"@ $treeFull $finalZip
if ($LASTEXITCODE -ne 0) { throw "re-zip failed" }

# --- 5. the replace transaction: [backup] -> delete -> import -> verify --------
# JRS import won't overwrite an existing dashboard's companion files, so a
# recompose must delete first (default) so the fresh model takes. Deleting the
# dashboard also releases the resource.in.use locks on its dashlet reports.
$bkPath = $null
$replaced = $false
# ($existed was determined at plan time, above, with a GET.) Re-check live: the
# dashboard may have been created/removed by a sibling step of a promote run.
$existed = ("$((Invoke-JrsGet -Jrs $jrs -Uri $dashUri).Code)" -match '^2\d\d$')
Write-Host "--- replace transaction for $dashUri (exists on target: $existed) ---"
if ($replaceMode -and $existed) {
    # rollback safety: export the existing dashboard (descriptor + companions)
    # before deleting -- by default; the step's 'reimport' compensation needs it.
    $delStep = "compose.delete:$dashUri"
    $delComp = $null; $delIrrev = $null
    if ($NoBackup) { Write-Host "  [1/3] backup  skipped (-NoBackup: the delete is irreversible)"; $delIrrev = "-NoBackup" }
    else {
        $bkPath = Export-JrsBackup -Jrs $jrs -Uri $dashUri -BackupDir $BackupDir
        if ($bkPath) { Write-Host "  [1/3] backup  $dashUri -> $bkPath"; $delComp = @{ type = "reimport"; zip = $bkPath; uri = $dashUri } }
        else { $delIrrev = "backup export failed" }
    }
    Write-JrsStep -Run $run -Step $delStep -State RUNNING -Compensation $delComp -Irreversible $delIrrev
    $del = Invoke-JrsRest -Jrs $jrs -Method DELETE -Path "/rest_v2/resources$dashUri"    # guarded (plan mode / prod)
    $delCode = "$($del.Code)".Trim(); $delBody = "$($del.Body)"
    if ($delCode -match '^(204|404)$') {
        $replaced = ($delCode -eq "204")
        Write-Host "  [2/3] delete  $dashUri -> HTTP $delCode (will recreate)"
        Write-JrsStep -Run $run -Step $delStep -State SUCCEEDED -Detail "HTTP $delCode"
    } else {
        $hint = Get-GotchaHint -Code "$delCode" -Body "$delBody"
        Write-JrsStep -Run $run -Step $delStep -State FAILED -Detail "HTTP $delCode"
        throw "delete of $dashUri failed (HTTP $delCode): $delBody$(if ($hint) { "`n  -> hint: $hint" })"
    }
} elseif (-not $replaceMode -and $existed) {
    Write-Host "  [2/3] delete  skipped (-KeepExisting): the import will NOT change the live layout;"
    Write-Host "        re-run with -Replace (default) or teardown_dashboard.ps1 -Uri $dashUri first"
} else {
    Write-Host "  [2/3] delete  nothing to delete (dashboard absent)"
}

$impStep = "compose.import:$dashUri"
# a dashboard created from nothing is undone by deleting it; a replaced one is
# undone by the delete step's reimport (which pre-deletes the new copy)
$impComp = if (-not $existed) { @{ type = "delete"; uri = $dashUri } } else { $null }
Write-JrsStep -Run $run -Step $impStep -State RUNNING -Compensation $impComp
try {
    & (Join-Path $PSScriptRoot "import_resource.ps1") -Zip $finalZip `
        -ServerUrl $jrs.ServerUrl -User $jrs.User -Password $jrs.Password | ForEach-Object { Write-Host "        $_" }
} catch {
    Write-JrsStep -Run $run -Step $impStep -State FAILED -Detail "$_"
    $msg = "$_"
    if ($msg -match 'resource\.in\.use') {
        throw ("import of $dashUri was blocked by 403 resource.in.use: a tile is still owned by a live dashboard. " +
               "Fix: re-run with -Replace (the default; do not pass -KeepExisting), or tear the owning dashboard down first: " +
               "teardown_dashboard.ps1 -Uri $dashUri  (then redeploy the tile with deploy_report.ps1 -Overwrite). Original: $msg")
    }
    if ($msg -match 'import\.decode\.failed') {
        throw ("import of $dashUri failed with import.decode.failed: the archive was encrypted by a different server's key. " +
               "Compose on the target itself (-Env <target>) instead of importing an archive exported elsewhere. Original: $msg")
    }
    throw
}
Write-Host "  [3/3] import  $finalZip"

$check = & (Get-JrsCurl) -s -u $auth -H "Accept: application/json" "$($jrs.ServerUrl)/rest_v2/resources$dashUri"
if ($check -match "resource.not.found") {
    Write-JrsStep -Run $run -Step $impStep -State FAILED -Detail "import finished but the dashboard is absent"
    Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error "import reported success but $dashUri was not created"
    throw "import reported success but $dashUri was not created (run $($run.RunId); undo: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply)"
}
Write-JrsStep -Run $run -Step $impStep -State SUCCEEDED
Complete-JrsRun -Run $run -Status SUCCEEDED
$n = ($check | ConvertFrom-Json).resources.Count
$enc = [uri]::EscapeDataString($dashUri)
$view = "$($jrs.ServerUrl)/dashboard/viewer.html#$enc"
Write-Host ""
Write-Host "OK: composed dashboard $dashUri ($($reportUris.Count) dashlets, $n model resources)$(if ($replaced) { ' [replaced]' } else { ' [created]' })$(if ($run.RunId -and -not $run.Nested) { " run $($run.RunId)" })"
Write-Host "    view: $view"

[pscustomobject]@{
    Uri = $dashUri; Code = 200; Replaced = $replaced; BackupPath = $bkPath
    Dashlets = $reportUris.Count; ModelResources = $n; ViewUrl = $view; RunId = $run.RunId
}
} catch {
    # any failure after the run opened: close the journal so recover_run.ps1 can act on it
    if ($run -and -not $run.Nested) {
        try { Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error "$_" } catch { }
        Write-Host "FAILED (run $($run.RunId)); undo what was done with: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply"
    }
    throw
} finally { Restore-JrsPlanMode $prevMode }
