<#
.SYNOPSIS
  Verify a deployed dashboard suite against its manifests -- without a browser
  and WITHOUT writing to the server.

.DESCRIPTION
  One script for the "verify the build on STAGE without a browser" loop that
  RUNBOOK.md used to spell out by hand per phase. For every dashboard manifest
  (references/manifest.schema.json; the real ones live under report/<suite>/)
  it runs, per report dashlet:
    report_exists     GET the report unit; PASS only on HTTP 200 (Test-JrsResource)
    render            -Render: run the unit with default parameters to PDF (or
                      -RenderFormat html) via GET rest_v2/reports<uri>.<fmt>;
                      records HTTP code, byte size, page count (%PDF magic +
                      /Type /Page objects) and keeps the file under -OutDir
    jrxml_bytediff    -ByteDiff: GET the deployed main jrxml
                      (rest_v2/resources<uri>_files/main_jrxml) and compare it
                      byte for byte (SHA-256) against the local git jrxml the
                      manifest points at. A mismatch is a FAIL even when the
                      difference is only line endings -- the RUNBOOK precondition
                      for promotion is exact bytes (a re-serialized server copy
                      grows uuid attributes and loses comments).
  and per dashboard:
    dashboard_exists  GET the dashboard resource
    dashboard_controls  count resources[].type == inputControl in the dashboard
                      descriptor and compare it to the manifest "filters" list
                      (0 expected when the manifest has no filters)
    control_exists    each manifest filter name exists as
                      <filterControlFolder or folder/controls>/<name>

  Each check is one object on the pipeline:
    Manifest, Dashboard, Check, Target, Status (PASS|FAIL|SKIP), Code, Bytes,
    Pages, Detail, LocalFile
  followed by a summary line on the host stream. Exit code 1 when any check
  FAILed, 0 otherwise. -FailFast stops at the first FAIL.

  Local jrxml lookup order for a dashlet (first hit wins): dashlet "jrxml"
  (relative to the manifest dir), manifest "outDir"/<leaf>.jrxml (relative to
  the current dir, then the manifest dir), <manifest dir>/<leaf>.jrxml,
  report/<manifest name>/<leaf>.jrxml (build_dashlets.ps1's default outDir).

  Server resolution: -ServerUrl/-User/-Password, else -Env <profile> from
  jrs.config.json "environments" (same resolution promote.ps1 uses for
  -FromEnv/-ToEnv), else env vars / top-level config. Every call is a GET.

.PARAMETER Manifest
  A manifest path, a glob (report\pos_perf\*_dashboard.json) or a directory
  (every *.json in it that has a top-level "dashlets" array). Repeatable.

.PARAMETER Env
  Named profile in jrs.config.json "environments", e.g. stage or prod.

.PARAMETER Render
  Also run every report dashlet to -RenderFormat (pdf default) with default
  parameters. Files land under -OutDir (default <skill>/out/verify/<env>).

.PARAMETER ByteDiff
  Also byte-compare each deployed main jrxml against the local git file.

.PARAMETER Out
  Write the result table to a .csv or .json file (by extension).

.PARAMETER FailFast
  Stop at the first FAIL (the summary and exit code still reflect it).

.PARAMETER Offline
  Do not contact any server: only resolve the manifests, validate their shape
  and locate the local jrxml for every report dashlet (check local_jrxml). Used
  by the Pester tests and as a pre-flight before a live run.

.EXAMPLE
  .\verify_suite.ps1 -Manifest report\pos_perf -Env stage -Render -ByteDiff -Out out\verify_stage.csv

.EXAMPLE
  .\verify_suite.ps1 -Manifest report\pos_perf\trs_dashboard.json -Env prod

.EXAMPLE
  $rows = & .\verify_suite.ps1 -Manifest report\pos_perf -Env stage
  $rows | Where-Object Status -eq FAIL | Format-Table Dashboard, Check, Target, Detail
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Manifest,
    [string]$Env,
    [switch]$Render,
    [ValidateSet("pdf", "html")][string]$RenderFormat = "pdf",
    [switch]$ByteDiff,
    [string]$Out,
    [switch]$FailFast,
    [switch]$Offline,
    [string]$OutDir,
    [int]$TimeoutSec = 300,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

# ---------------------------------------------------------------------------
# manifest discovery
# ---------------------------------------------------------------------------
function Resolve-ManifestFiles {
    param([string[]]$Specs)
    $files = New-Object System.Collections.ArrayList
    foreach ($spec in $Specs) {
        $hits = @()
        if (Test-Path -LiteralPath $spec -PathType Container) {
            $hits = @(Get-ChildItem -LiteralPath $spec -Filter *.json -File | ForEach-Object { $_.FullName })
        } elseif (Test-Path -LiteralPath $spec -PathType Leaf) {
            $hits = @((Resolve-Path -LiteralPath $spec).Path)
        } else {
            $hits = @(Get-ChildItem -Path $spec -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($hits.Count -eq 0) { throw "manifest not found: $spec (path, glob or directory)" }
        }
        foreach ($h in $hits) { if (-not $files.Contains($h)) { [void]$files.Add($h) } }
    }
    return @($files)
}

function Test-IsDashboardManifest {
    # A dashboard manifest has a top-level "dashlets" array plus folder + name.
    # (manifest.schema.json itself mentions "dashlets" only under "properties",
    # so it is filtered out here.)
    param($Obj)
    if (-not $Obj) { return $false }
    $names = @($Obj.PSObject.Properties.Name)
    if (-not ($names -contains "dashlets") -or -not ($names -contains "folder") -or -not ($names -contains "name")) { return $false }
    return ($null -ne $Obj.dashlets) -and (@($Obj.dashlets).Count -gt 0)
}

function Find-LocalJrxml {
    param($Dashlet, $ManifestObj, [string]$ManifestDir, [string]$Leaf)
    $cands = @()
    if ($Dashlet.PSObject.Properties.Name -contains "jrxml" -and $Dashlet.jrxml) {
        $cands += (Join-Path $ManifestDir $Dashlet.jrxml)
        $cands += $Dashlet.jrxml
    }
    if ($ManifestObj.PSObject.Properties.Name -contains "outDir" -and $ManifestObj.outDir) {
        $cands += (Join-Path $ManifestObj.outDir "$Leaf.jrxml")
        $cands += (Join-Path $ManifestDir (Join-Path $ManifestObj.outDir "$Leaf.jrxml"))
    }
    $cands += (Join-Path $ManifestDir "$Leaf.jrxml")
    $cands += (Join-Path (Join-Path "report" $ManifestObj.name) "$Leaf.jrxml")
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Get-ManifestPlan {
    # Parse one manifest file into the checks verify_suite will run: the
    # dashboard URI, its report dashlets (URI + local jrxml), the expected
    # filter controls. Pure / offline.
    param([string]$Path)
    $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not (Test-IsDashboardManifest $obj)) { return $null }
    $dir = Split-Path -Parent $Path
    $folder = "$($obj.folder)".TrimEnd("/")
    $dashUri = "$folder/$($obj.name)"
    $reports = @()
    foreach ($d in @($obj.dashlets)) {
        $kind = if ($d.PSObject.Properties.Name -contains "kind" -and $d.kind) { "$($d.kind)" } else { "report" }
        if ($kind -ne "report") { continue }
        $uri = $null
        if ($d.PSObject.Properties.Name -contains "resource" -and $d.resource) { $uri = "$($d.resource)" }
        elseif ($d.PSObject.Properties.Name -contains "name" -and $d.name) { $uri = "$folder/$($d.name)" }
        if (-not $uri) { throw "${Path}: report dashlet needs 'resource' or 'name': $($d | ConvertTo-Json -Compress)" }
        if (-not $uri.StartsWith("/")) { $uri = "/$uri" }
        $leaf = $uri.Substring($uri.LastIndexOf("/") + 1)
        $reports += [pscustomobject]@{
            Uri = $uri; Leaf = $leaf
            Label = if ($d.PSObject.Properties.Name -contains "label" -and $d.label) { "$($d.label)" } else { $leaf }
            LocalJrxml = Find-LocalJrxml -Dashlet $d -ManifestObj $obj -ManifestDir $dir -Leaf $leaf
        }
    }
    $filters = @()
    if ($obj.PSObject.Properties.Name -contains "filters" -and $obj.filters) { $filters = @($obj.filters | ForEach-Object { "$_" }) }
    $ctlFolder = if ($obj.PSObject.Properties.Name -contains "filterControlFolder" -and $obj.filterControlFolder) { "$($obj.filterControlFolder)".TrimEnd("/") } else { "$folder/controls" }
    return [pscustomobject]@{
        Path = $Path; Name = "$($obj.name)"; Folder = $folder; DashboardUri = $dashUri
        Reports = @($reports); Filters = @($filters); ControlFolder = $ctlFolder
    }
}

# ---------------------------------------------------------------------------
# result rows
# ---------------------------------------------------------------------------
$script:rows = New-Object System.Collections.ArrayList
$script:stop = $false
function Add-Row {
    param([string]$ManifestPath, [string]$Dashboard, [string]$Check, [string]$Target,
          [string]$Status, [string]$Code = "", $Bytes = $null, $Pages = $null,
          [string]$Detail = "", [string]$LocalFile = "")
    $row = [pscustomobject]@{
        Manifest = (Split-Path -Leaf $ManifestPath); Dashboard = $Dashboard; Check = $Check; Target = $Target
        Status = $Status; Code = $Code; Bytes = $Bytes; Pages = $Pages; Detail = $Detail; LocalFile = $LocalFile
    }
    [void]$script:rows.Add($row)
    $mark = switch ($Status) { "PASS" { "ok  " } "FAIL" { "FAIL" } default { "skip" } }
    Write-Host ("  [{0}] {1,-19} {2}{3}" -f $mark, $Check, $Target, $(if ($Detail) { "  -- $Detail" } else { "" }))
    if ($Status -eq "FAIL" -and $FailFast) { $script:stop = $true }
    return $row
}

function Get-PdfPageCount {
    # Cheap page count without a PDF library: count "/Type /Page" objects that
    # are not "/Type /Pages". Good enough for PASS/FAIL and the results table.
    param([string]$Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $txt = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        return ([regex]::Matches($txt, '/Type\s*/Page(?![s\w])')).Count
    } catch { return -1 }
}

function Get-FileSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace "-", "" } finally { $sha.Dispose() }
}

function Normalize-Text {
    # For the "differs only in line endings / BOM" diagnostic (still a FAIL).
    param([byte[]]$Bytes)
    $s = [Text.Encoding]::UTF8.GetString($Bytes)
    return ($s.TrimStart([char]0xFEFF) -replace "`r`n", "`n").TrimEnd()
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$files = Resolve-ManifestFiles -Specs $Manifest
$plans = @()
foreach ($f in $files) {
    $p = Get-ManifestPlan -Path $f
    if ($p) { $plans += $p } else { Write-Verbose "skipping $f (no top-level dashlets/folder/name)" }
}
if ($plans.Count -eq 0) { throw "no dashboard manifest found under: $($Manifest -join ', ')" }

$jrs = $null
$where = "(offline)"
if (-not $Offline) {
    $jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
    $where = if ($jrs.Env) { "$($jrs.ServerUrl) [env $($jrs.Env)]" } else { $jrs.ServerUrl }
    if (-not $OutDir) {
        $tag = if ($jrs.Env) { $jrs.Env } else { "default" }
        $OutDir = Join-Path $PSScriptRoot (Join-Path "../out/verify" $tag)
    }
    if ($Render -or $ByteDiff) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
}
Write-Host "verify_suite: $($plans.Count) manifest(s) against $where"

:manifests foreach ($p in $plans) {
    Write-Host "== $($p.DashboardUri)  ($($p.Reports.Count) report dashlet(s), $($p.Filters.Count) filter(s))  [$($p.Path)]"

    if ($Offline) {
        foreach ($r in $p.Reports) {
            if ($r.LocalJrxml) { Add-Row $p.Path $p.DashboardUri "local_jrxml" $r.Uri "PASS" -LocalFile $r.LocalJrxml | Out-Null }
            else { Add-Row $p.Path $p.DashboardUri "local_jrxml" $r.Uri "FAIL" -Detail "no local jrxml found for $($r.Leaf) (dashlet jrxml / outDir / manifest dir / report/$($p.Name))" | Out-Null }
            if ($script:stop) { break manifests }
        }
        foreach ($c in $p.Filters) {
            Add-Row $p.Path $p.DashboardUri "control_expected" "$($p.ControlFolder)/$c" "SKIP" -Detail "offline" | Out-Null
        }
        continue
    }

    # (a) every report dashlet exists
    foreach ($r in $p.Reports) {
        $g = Invoke-JrsGet -Jrs $jrs -Uri $r.Uri
        $exists = ("$($g.Code)".Trim() -eq "200")
        if ($exists) { Add-Row $p.Path $p.DashboardUri "report_exists" $r.Uri "PASS" -Code "$($g.Code)" -LocalFile $r.LocalJrxml | Out-Null }
        else { Add-Row $p.Path $p.DashboardUri "report_exists" $r.Uri "FAIL" -Code "$($g.Code)" -Detail "GET rest_v2/resources$($r.Uri) returned HTTP $($g.Code)" -LocalFile $r.LocalJrxml | Out-Null }
        if ($script:stop) { break manifests }

        # (b) render with default parameters
        if ($Render) {
            if (-not $exists) {
                Add-Row $p.Path $p.DashboardUri "render" $r.Uri "SKIP" -Detail "report unit missing" | Out-Null
            } else {
                $outFile = Join-Path $OutDir ("$($r.Uri.TrimStart('/') -replace '[^0-9A-Za-z]', '_').$RenderFormat")
                $url = "$($jrs.ServerUrl)/rest_v2/reports$($r.Uri).$RenderFormat"
                $code = "000"
                try { $code = Invoke-JrsDownload -Jrs $jrs -Url $url -OutFile $outFile -AllowError -TimeoutSec $TimeoutSec } catch { $code = "000" }
                $size = if (Test-Path -LiteralPath $outFile) { (Get-Item -LiteralPath $outFile).Length } else { 0 }
                $pages = $null
                $ok = ("$code" -eq "200" -and $size -gt 0)
                $detail = ""
                if ($ok -and $RenderFormat -eq "pdf") {
                    $head = ""
                    try { $head = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($outFile), 0, [Math]::Min(5, $size)) } catch { }
                    if ($head -ne "%PDF-") { $ok = $false; $detail = "no %PDF- magic (server returned an error page?)" }
                    else { $pages = Get-PdfPageCount $outFile }
                }
                if (-not $ok -and -not $detail) {
                    $detail = if ("$code" -eq "000") { "request timed out or never sent (TimeoutSec=$TimeoutSec)" } else { "HTTP $code from $url" }
                    if ("$code" -match '^4|^5' -and $size -gt 0) {
                        try { $body = (Get-Content -LiteralPath $outFile -Raw); $hint = Get-GotchaHint -Code "$code" -Body $body; if ($hint) { $detail += " -- hint: $hint" } } catch { }
                    }
                }
                Add-Row $p.Path $p.DashboardUri "render" $r.Uri $(if ($ok) { "PASS" } else { "FAIL" }) -Code "$code" -Bytes $size -Pages $pages -Detail $detail -LocalFile $outFile | Out-Null
            }
            if ($script:stop) { break manifests }
        }

        # (c) deployed jrxml == git jrxml, byte for byte
        if ($ByteDiff) {
            if (-not $exists) {
                Add-Row $p.Path $p.DashboardUri "jrxml_bytediff" $r.Uri "SKIP" -Detail "report unit missing" | Out-Null
            } elseif (-not $r.LocalJrxml) {
                Add-Row $p.Path $p.DashboardUri "jrxml_bytediff" $r.Uri "FAIL" -Detail "no local jrxml found for $($r.Leaf) (dashlet jrxml / outDir / manifest dir / report/$($p.Name))" | Out-Null
            } else {
                $remoteFile = Join-Path $OutDir ("$($r.Uri.TrimStart('/') -replace '[^0-9A-Za-z]', '_').server.jrxml")
                # The jrxml file resource is named after the unit's LABEL at
                # deploy time (<uri>_files/<label>_main_jrxml), so read its real
                # URI from the report unit descriptor instead of guessing. A
                # non-descriptor Accept makes the file resource return its raw
                # bytes rather than the repository.file+json descriptor.
                $jrxmlUri = "$($r.Uri)_files/main_jrxml"
                try {
                    $ruDesc = $g.Body | ConvertFrom-Json
                    if ($ruDesc.jrxml -and $ruDesc.jrxml.jrxmlFileReference -and $ruDesc.jrxml.jrxmlFileReference.uri) { $jrxmlUri = "$($ruDesc.jrxml.jrxmlFileReference.uri)" }
                } catch { }
                $url = "$($jrs.ServerUrl)/rest_v2/resources$jrxmlUri"
                $code = "000"
                try { $code = Invoke-JrsDownload -Jrs $jrs -Url $url -OutFile $remoteFile -Accept "application/xml" -AllowError -TimeoutSec $TimeoutSec } catch { $code = "000" }
                if ("$code" -ne "200") {
                    Add-Row $p.Path $p.DashboardUri "jrxml_bytediff" $r.Uri "FAIL" -Code "$code" -Detail "GET $url returned HTTP $code" -LocalFile $r.LocalJrxml | Out-Null
                } else {
                    $rb = [IO.File]::ReadAllBytes($remoteFile)
                    $lb = [IO.File]::ReadAllBytes($r.LocalJrxml)
                    $rh = Get-FileSha256 $rb; $lh = Get-FileSha256 $lb
                    if ($rh -eq $lh) {
                        Add-Row $p.Path $p.DashboardUri "jrxml_bytediff" $r.Uri "PASS" -Code "$code" -Bytes $lb.Length -Detail "sha256 match" -LocalFile $r.LocalJrxml | Out-Null
                    } else {
                        $why = "server $($rb.Length) B vs git $($lb.Length) B, sha256 differ"
                        if ((Normalize-Text $rb) -eq (Normalize-Text $lb)) { $why += " (line endings / BOM only)" }
                        elseif ([Text.Encoding]::UTF8.GetString($rb) -match '\suuid="') { $why += " (server copy carries uuid attrs: JRS re-serialization -- redeploy from git)" }
                        $why += "; server copy kept at $remoteFile"
                        Add-Row $p.Path $p.DashboardUri "jrxml_bytediff" $r.Uri "FAIL" -Code "$code" -Bytes $rb.Length -Detail $why -LocalFile $r.LocalJrxml | Out-Null
                    }
                }
            }
            if ($script:stop) { break manifests }
        }
    }

    # (d) the dashboard itself + its filter controls
    $dg = Invoke-JrsGet -Jrs $jrs -Uri $p.DashboardUri
    if ("$($dg.Code)".Trim() -ne "200") {
        Add-Row $p.Path $p.DashboardUri "dashboard_exists" $p.DashboardUri "FAIL" -Code "$($dg.Code)" -Detail "GET rest_v2/resources$($p.DashboardUri) returned HTTP $($dg.Code)" | Out-Null
        Add-Row $p.Path $p.DashboardUri "dashboard_controls" $p.DashboardUri "SKIP" -Detail "dashboard missing" | Out-Null
    } else {
        Add-Row $p.Path $p.DashboardUri "dashboard_exists" $p.DashboardUri "PASS" -Code "$($dg.Code)" | Out-Null
        $ctlCount = 0; $tileCount = 0; $ctlUris = @()
        try {
            $desc = $dg.Body | ConvertFrom-Json
            if ($desc.PSObject.Properties.Name -contains "resources") {
                foreach ($res in @($desc.resources)) {
                    $t = "$($res.type)"
                    if ($t -eq "inputControl") {
                        $ctlCount++
                        $ru = if ($res.resource -and $res.resource.resourceReference) { "$($res.resource.resourceReference.uri)" } else { "$($res.name)" }
                        $ctlUris += $ru
                    }
                    elseif ($t -eq "reportUnit") { $tileCount++ }
                }
            }
        } catch { }
        $expected = $p.Filters.Count
        $detail = "descriptor: $ctlCount inputControl(s), $tileCount reportUnit tile(s); manifest expects $expected filter(s)"
        if ($ctlUris.Count -gt 0) { $detail += " [" + ($ctlUris -join ", ") + "]" }
        Add-Row $p.Path $p.DashboardUri "dashboard_controls" $p.DashboardUri $(if ($ctlCount -eq $expected) { "PASS" } else { "FAIL" }) -Code "$($dg.Code)" -Detail $detail | Out-Null
    }
    if ($script:stop) { break manifests }
    foreach ($c in $p.Filters) {
        $cu = "$($p.ControlFolder)/$c"
        $cg = Invoke-JrsGet -Jrs $jrs -Uri $cu
        if ("$($cg.Code)".Trim() -eq "200") { Add-Row $p.Path $p.DashboardUri "control_exists" $cu "PASS" -Code "$($cg.Code)" | Out-Null }
        else { Add-Row $p.Path $p.DashboardUri "control_exists" $cu "FAIL" -Code "$($cg.Code)" -Detail "GET rest_v2/resources$cu returned HTTP $($cg.Code)" | Out-Null }
        if ($script:stop) { break manifests }
    }
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
$all = @($script:rows)
$nPass = @($all | Where-Object { $_.Status -eq "PASS" }).Count
$nFail = @($all | Where-Object { $_.Status -eq "FAIL" }).Count
$nSkip = @($all | Where-Object { $_.Status -eq "SKIP" }).Count

if ($Out) {
    $outParent = Split-Path -Parent $Out
    if ($outParent -and -not (Test-Path $outParent)) { New-Item -ItemType Directory -Force $outParent | Out-Null }
    if ($Out -match '\.json$') { ($all | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Out -Encoding utf8 }
    else { $all | Export-Csv -LiteralPath $Out -NoTypeInformation -Encoding utf8 }
    Write-Host "results written: $Out"
}

$verdict = if ($nFail -gt 0) { "FAIL" } else { "PASS" }
$stopped = if ($script:stop) { " (stopped early: -FailFast)" } else { "" }
Write-Host ("verify_suite {0}: {1} check(s) -- {2} pass, {3} fail, {4} skip across {5} manifest(s) on {6}{7}" -f `
    $verdict, $all.Count, $nPass, $nFail, $nSkip, $plans.Count, $where, $stopped)

Write-Output $all
if ($nFail -gt 0) { exit 1 }
exit 0
