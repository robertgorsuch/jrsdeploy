<#
.SYNOPSIS
  Build, compile, deploy, and verify a set of dashboard dashlets from one
  manifest -- then optionally compose them into a dashboard.

.DESCRIPTION
  Drives the full dashlet pipeline for every entry in a dashboard manifest:
    scaffold (scaffold_jrxml.py) -> compile (CompileReport.java, fast JR7 check)
    -> deploy (deploy_report.ps1, bound to the manifest datasource)
    -> verify (run server-side to PDF; assert HTTP 200 + %PDF- magic + size).
  Prints a results table. With -Compose it then calls compose_dashboard.ps1 to
  assemble the deployed dashlets into the dashboard described by the same
  manifest (no designer needed).

  The dashlet reports are tabular JR7 reports with a chart in the summary band;
  see scaffold_jrxml.py for the chart options.

.PARAMETER Manifest
  Unified dashboard manifest JSON. Top level:
    db, host, port, user            - PostgreSQL introspection target (db required)
    dataSourceUri                   - JRS JDBC datasource the reports bind to
    folder, name, label             - dashboard repo folder / name / display label
    outDir                          - where to write .jrxml (default report\<name>)
    dashlets: [ {                   - one per KPI tile:
        name, title, subtitle,        report name (no spaces) + heading text
        chart,                        pie|pie3d|bar|bar3d|line|area|stackedbar
        query | queryFile,            inline SQL or path to a .sql file
        chartCategory, chartValue, chartSeries, chartHeight, chartLabelRotation,
        landscape,                    bool
        x, y, width, height           grid placement (40-wide) for the dashboard
    }, ... ]

.PARAMETER Compose
  After all dashlets verify, compose the dashboard via compose_dashboard.ps1.

.PARAMETER AutoGrid
  Passed through to the composer: auto-place dashlets missing x/y/width/height.

.PARAMETER SkipVerify
  Deploy without the run-to-PDF check (faster; skips the CTE/security-validator
  class of failures that only surface at fill time).

.EXAMPLE
  .\build_dashlets.ps1 -Manifest report\foodmart\dashboard.json -Compose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [switch]$Compose,
    [switch]$AutoGrid,
    [switch]$SkipVerify,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
if (-not (Test-Path $Manifest)) { throw "manifest not found: $Manifest" }
if (-not $env:PGPASSWORD) { Write-Warning "PGPASSWORD not set; scaffold introspection may fail" }

$jrs  = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password
$auth = "$($jrs.User):$($jrs.Password)"
$m = (Get-Content $Manifest -Raw) -replace "^\xEF\xBB\xBF", "" | ConvertFrom-Json

$folder = $m.folder.TrimEnd("/")
$ds     = $m.dataSourceUri
if (-not $ds) { throw "manifest needs dataSourceUri" }
$outDir = if ($m.outDir) { $m.outDir } else { "report\$($m.name)" }
New-Item -ItemType Directory -Force $outDir | Out-Null

$results = @()
foreach ($d in $m.dashlets) {
    $rname = $d.name
    $jrxml = Join-Path $outDir "$rname.jrxml"
    $uri   = "$folder/$rname"
    $row = [ordered]@{ name = $rname; compile = "-"; deploy = "-"; verify = "-" }

    # --- scaffold ---
    $sa = @("$PSScriptRoot/scaffold_jrxml.py", "--name", $rname, "--out", $jrxml,
            "--db", $m.db)
    if ($m.host) { $sa += @("--host", $m.host) }
    if ($m.port) { $sa += @("--port", "$($m.port)") }
    if ($m.user) { $sa += @("--user", $m.user) }
    if ($d.title)    { $sa += @("--title", $d.title) }
    if ($d.subtitle) { $sa += @("--subtitle", $d.subtitle) }
    if ($d.chart)    { $sa += @("--chart", $d.chart) }
    if ($d.chartCategory) { $sa += @("--chart-category", $d.chartCategory) }
    if ($d.chartValue)    { $sa += @("--chart-value", $d.chartValue) }
    if ($d.chartSeries)   { $sa += @("--chart-series", $d.chartSeries) }
    if ($d.chartHeight)   { $sa += @("--chart-height", "$($d.chartHeight)") }
    if ($d.chartLabelRotation) { $sa += @("--chart-label-rotation", "$($d.chartLabelRotation)") }
    if ($d.landscape) { $sa += "--landscape" }
    if ($d.queryFile) { $sa += @("--query-file", $d.queryFile) }
    elseif ($d.query) { $sa += @("--query", $d.query) }
    else { throw "dashlet $rname needs query or queryFile" }
    & (Get-JrsPython) @sa | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scaffold failed for $rname" }

    # --- compile (fast local JR7 validity check; shared helper handles the
    #     harmless SLF4J-on-stderr that would otherwise abort under Stop) ---
    $row.compile = if (Invoke-JrCompile -Jrxml $jrxml) { "OK" } else { "FAIL" }
    if ($row.compile -eq "FAIL") { $results += [pscustomobject]$row; Write-Host "FAIL compile: $rname"; continue }

    # --- deploy (the script throws on failure rather than setting an exit code) ---
    # A report already referenced by a dashboard is modification-locked by JRS
    # (403 resource.in.use). That is not a pipeline failure -- the deployed
    # version is retained and we carry on (and still verify it renders). Detach
    # or delete the owning dashboard to push report changes.
    $depLabel = if ($d.title) { $d.title } else { $rname }
    try {
        $depOut = & (Join-Path $PSScriptRoot "deploy_report.ps1") -Jrxml $jrxml -TargetUri $uri `
            -Label $depLabel -DataSourceUri $ds -Overwrite -Apply `
            -ServerUrl $jrs.ServerUrl -User $jrs.User -Password $jrs.Password 2>&1 | Out-String
        $row.deploy = "OK"
    } catch {
        $depOut += ($_ | Out-String)
        if ($depOut -match "resource\.in\.use") {
            $row.deploy = "in-use (kept)"
        } else {
            $row.deploy = "FAIL"; Write-Host "  deploy error ($rname): $_"
        }
    }

    # --- verify (run to PDF; written to a scratch dir, not the source folder) ---
    if (-not $SkipVerify -and $row.deploy -in @("OK", "in-use (kept)")) {
        $verifyDir = "out/dashlet_verify"
        New-Item -ItemType Directory -Force $verifyDir | Out-Null
        $pdf = Join-Path $verifyDir "$rname.pdf"
        $code = & (Get-JrsCurl) -s -o $pdf -w "%{http_code}" -u $auth "$($jrs.ServerUrl)/rest_v2/reports$uri.pdf"
        $isPdf = (Test-Path $pdf) -and ((Get-Content $pdf -Raw -ErrorAction SilentlyContinue) -like "%PDF-*")
        $sz = if (Test-Path $pdf) { (Get-Item $pdf).Length } else { 0 }
        $row.verify = if ("$code".Trim() -eq "200" -and $isPdf -and $sz -gt 800) { "OK ($sz b)" } else { "FAIL (http=$code sz=$sz)" }
    }
    $results += [pscustomobject]$row
    Write-Host ("  {0,-40} compile={1} deploy={2} verify={3}" -f $rname, $row.compile, $row.deploy, $row.verify)
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host
$bad = $results | Where-Object { $_.compile -eq "FAIL" -or $_.deploy -eq "FAIL" -or $_.verify -like "FAIL*" }
$kept = @($results | Where-Object { $_.deploy -eq "in-use (kept)" })
if ($kept) { Write-Host "note: $($kept.Count) report(s) left unchanged (in use by an existing dashboard)" }
if ($bad) { throw "$($bad.Count) dashlet(s) failed; not composing" }

if ($Compose) {
    Write-Host "--- composing dashboard ---"
    # compose plans by default (1.3.0); this pipeline IS the explicit deploy+compose command
    $ca = @{ Manifest = $Manifest; Apply = $true; ServerUrl = $jrs.ServerUrl; User = $jrs.User; Password = $jrs.Password }
    if ($AutoGrid) { $ca.AutoGrid = $true }
    & (Join-Path $PSScriptRoot "compose_dashboard.ps1") @ca
}
