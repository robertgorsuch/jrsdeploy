<#
.SYNOPSIS
  Declarative "desired state" applier for JasperReports Server -- a
  Terraform-for-JasperReports. Reads an ENVIRONMENT MANIFEST describing the
  resources that SHOULD exist in the repository, compares it against the live
  server, and (only with -Apply) reconciles the difference by delegating to the
  existing jasper-deploy scripts.

.DESCRIPTION
  The manifest (JSON, -Manifest) has a top-level "resources" array. Each entry
  carries a "type" discriminator (datasource | domain | report | dashboard), a
  repository "uri", and the type-specific fields the matching create/deploy
  script needs. The schema for the manifest is
  references/environment.schema.json.

  For every desired resource reconcile.ps1:
    (a) GETs the live resource (Invoke-JrsGet) to learn whether it EXISTS;
    (b) decides an ACTION:
          create  - absent on the server
          update  - present but the live label differs from the desired label
                    (or no desired label is given to confirm a match)
          ok      - present and the live label already matches the desired one
                    (nothing to do);
    (c) with -Apply ONLY, performs create/update by calling the matching script:
          datasource -> create_datasource.ps1   (-Overwrite)
          domain     -> create_domain.ps1        (-Overwrite)
          report     -> deploy_report.ps1        (-Overwrite)
          dashboard  -> build_dashlets.ps1 -Compose
        "ok" resources are skipped. On the first failure it stops (the called
        scripts throw under $ErrorActionPreference=Stop; Assert-JrsOk adds a
        gotchas.md hint when the failure matches a known signature).

  DEFAULT MODE IS A SAFE PLAN. With no -Apply it only QUERIES the server, prints
  the planned actions as a table, prints a summary (n to create / n to update /
  n ok), and makes NO changes -- like `terraform plan`. Pass -Apply to execute
  (like `terraform apply`).

  Credentials resolve the standard jasper-deploy way (first wins):
    1. -ServerUrl / -User / -Password parameters
    2. environment variables JRS_URL / JRS_USER / JRS_PASS
    3. jrs.config.json in the skill root (gitignored)

  Relative jrxml/schemaFile/dashboard-manifest paths in the manifest are
  resolved against the manifest file's own directory, then the current
  directory.

.PARAMETER Manifest
  Path to the environment manifest JSON (see references/environment.schema.json).

.PARAMETER Apply
  Perform the create/update actions. WITHOUT this switch the script only plans
  (queries + prints) and changes nothing.

.PARAMETER ServerUrl
  JasperReports Server base URL, e.g. http://localhost:8081/jasperserver-pro.
  Overrides $env:JRS_URL and jrs.config.json.

.PARAMETER User
  REST user (overrides $env:JRS_USER / config).

.PARAMETER Password
  REST password (overrides $env:JRS_PASS / config).

.EXAMPLE
  # SAFE PLAN (default) -- queries the server, prints the plan, changes nothing
  .\reconcile.ps1 -Manifest env\prod.json

.EXAMPLE
  # APPLY -- create/update everything the plan listed as create/update
  .\reconcile.ps1 -Manifest env\prod.json -Apply

.EXAMPLE
  # A minimal environment manifest (env\prod.json):
  #
  # {
  #   "resources": [
  #     {
  #       "type": "datasource",
  #       "uri": "/datasources/postgis_34_sample",
  #       "label": "PostGIS 34 Sample",
  #       "dsType": "jdbc",
  #       "database": "postgis_34_sample",
  #       "dbUser": "postgres",
  #       "dbPassword": "postgres"
  #     },
  #     {
  #       "type": "report",
  #       "uri": "/reports/geocoder/county_summary",
  #       "label": "County Edge Summary",
  #       "jrxml": "report\\county_summary.jrxml",
  #       "dataSourceUri": "/datasources/postgis_34_sample"
  #     },
  #     {
  #       "type": "domain",
  #       "uri": "/domains/tx_counties",
  #       "label": "TX Counties Domain",
  #       "schemaFile": "out\\tx_counties_schema.xml",
  #       "dataSourceUri": "/datasources/postgis_34_sample"
  #     },
  #     {
  #       "type": "dashboard",
  #       "uri": "/reports/foodmart/sales_dashboard",
  #       "manifest": "report\\foodmart\\dashboard.json"
  #     }
  #   ]
  # }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [switch]$Apply,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env                 # named profile in jrs.config.json "environments"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

if (-not (Test-Path $Manifest)) { throw "manifest not found: $Manifest" }
$manifestFull = (Resolve-Path $Manifest).Path
$manifestDir  = Split-Path -Parent $manifestFull

# --- resolve config (param -> env -> jrs.config.json, validated) ----------
$jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env

# --- load + validate-shape the manifest -----------------------------------
$envManifest = (Get-Content $manifestFull -Raw) -replace "^\xEF\xBB\xBF", "" | ConvertFrom-Json
if (-not $envManifest.resources) { throw "manifest has no 'resources' array (see references/environment.schema.json)" }
$validTypes = @("datasource", "domain", "report", "dashboard")

# Resolve a manifest-relative path against the manifest dir, then the cwd.
function Resolve-RelPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    $cand = Join-Path $manifestDir $p
    if (Test-Path $cand) { return $cand }
    return $p
}

# PSCustomObject -> ordered hashtable (for -Properties / -SubDataSources splat).
function ConvertTo-OrderedHash($obj) {
    $h = [ordered]@{}
    if ($null -ne $obj) { foreach ($pr in $obj.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
    return $h
}

# --- PLAN: query the live server + decide an action per resource ----------
$plan = @()
$i = 0
foreach ($r in $envManifest.resources) {
    $i++
    $type = "$($r.type)".ToLower()
    $uri  = "$($r.uri)"
    if ($type -notin $validTypes) { throw "resource #$i has invalid type '$($r.type)' (expected: $($validTypes -join ', '))" }
    if (-not $uri) { throw "resource #$i (type $type) is missing 'uri'" }
    if (-not $uri.StartsWith("/")) { $uri = "/$uri" }

    $get  = Invoke-JrsGet -Jrs $jrs -Uri $uri
    $code = "$($get.Code)".Trim()

    $exists = $false; $liveLabel = $null; $action = $null; $note = ""
    if ($code -match '^2\d\d$') {
        $exists = $true
        try { $liveLabel = ($get.Body | ConvertFrom-Json).label } catch { $liveLabel = $null }
    } elseif ($code -eq "404") {
        $exists = $false
    } else {
        # Any other status (403/500/000...) is not a clean absent/present answer.
        $note = "GET returned HTTP $code"
        $exists = $null
    }

    $desiredLabel = "$($r.label)"
    if ($exists -eq $true) {
        if ($desiredLabel -and $liveLabel -and ($desiredLabel -eq $liveLabel)) {
            $action = "ok"
        } else {
            $action = "update"
            if (-not $desiredLabel) { $note = "no desired label to confirm match" }
        }
    } elseif ($exists -eq $false) {
        $action = "create"
    } else {
        $action = "error"   # ambiguous server response; surfaced, never applied
    }

    $plan += [pscustomobject]@{
        '#'      = $i
        Type     = $type
        Uri      = $uri
        Exists   = if ($exists -eq $true) { "yes" } elseif ($exists -eq $false) { "no" } else { "?" }
        Action   = $action
        Note     = $note
        Resource = $r
        FullUri  = $uri
    }
}

# --- print the plan table + summary ---------------------------------------
$mode = if ($Apply) { "APPLY" } else { "PLAN (no changes; pass -Apply to execute)" }
Write-Host ""
Write-Host "jasper-deploy reconcile -- $mode"
Write-Host "  server   : $($jrs.ServerUrl)"
Write-Host "  manifest : $manifestFull"
Write-Host ""
$plan | Format-Table -AutoSize '#', Type, Action, Exists, Uri, Note | Out-String | Write-Host

$nCreate = @($plan | Where-Object { $_.Action -eq "create" }).Count
$nUpdate = @($plan | Where-Object { $_.Action -eq "update" }).Count
$nOk     = @($plan | Where-Object { $_.Action -eq "ok" }).Count
$nErr    = @($plan | Where-Object { $_.Action -eq "error" }).Count
Write-Host ("Summary: {0} to create / {1} to update / {2} ok" -f $nCreate, $nUpdate, $nOk)
if ($nErr) { Write-Host ("  WARNING: {0} resource(s) returned an ambiguous server status (see Note)." -f $nErr) }

if (-not $Apply) {
    Write-Host ""
    Write-Host "Plan only -- no changes made. Re-run with -Apply to reconcile."
    return
}

if ($nErr) { throw "$nErr resource(s) have an ambiguous server status; resolve before -Apply." }
if (($nCreate + $nUpdate) -eq 0) { Write-Host ""; Write-Host "Nothing to do -- desired state already matches."; return }

# --- APPLY: perform create/update via the matching existing script --------
$creds = @{ ServerUrl = $jrs.ServerUrl; User = $jrs.User; Password = $jrs.Password }
Write-Host ""
Write-Host "--- applying ($($nCreate + $nUpdate) change(s)) ---"
foreach ($p in $plan) {
    if ($p.Action -in @("ok", "error")) { continue }
    $r = $p.Resource
    $uri = $p.FullUri
    Write-Host ""
    Write-Host ("[{0}] {1} {2}: {3}" -f $p.'#', $p.Action, $p.Type, $uri)

    switch ($p.Type) {
        "datasource" {
            # Map manifest fields -> create_datasource.ps1 params (splat). Only
            # the keys present in the manifest are forwarded.
            $a = @{ Uri = $uri; Overwrite = $true } + $creds
            if ($r.dsType)         { $a.Type          = "$($r.dsType)" }
            if ($r.label)          { $a.Label         = "$($r.label)" }
            if ($r.description)    { $a.Description    = "$($r.description)" }
            if ($r.connectionUrl)  { $a.ConnectionUrl = "$($r.connectionUrl)" }
            if ($r.driverClass)    { $a.DriverClass   = "$($r.driverClass)" }
            if ($r.dbHost)         { $a.DbHost        = "$($r.dbHost)" }
            if ($r.dbPort)         { $a.DbPort        = [int]$r.dbPort }
            if ($r.database)       { $a.Database      = "$($r.database)" }
            if ($r.dbUser)         { $a.DbUser        = "$($r.dbUser)" }
            if ($r.dbPassword)     { $a.DbPassword    = "$($r.dbPassword)" }
            if ($r.jndiName)       { $a.JndiName      = "$($r.jndiName)" }
            if ($r.beanName)       { $a.BeanName      = "$($r.beanName)" }
            if ($r.beanMethod)     { $a.BeanMethod    = "$($r.beanMethod)" }
            if ($r.serviceClass)   { $a.ServiceClass  = "$($r.serviceClass)" }
            if ($r.accessKey)      { $a.AccessKey     = "$($r.accessKey)" }
            if ($r.secretKey)      { $a.SecretKey     = "$($r.secretKey)" }
            if ($r.roleArn)        { $a.RoleArn       = "$($r.roleArn)" }
            if ($r.region)         { $a.Region        = "$($r.region)" }
            if ($r.dbInstanceIdentifier) { $a.DbInstanceIdentifier = "$($r.dbInstanceIdentifier)" }
            if ($r.dbService)      { $a.DbService     = "$($r.dbService)" }
            if ($r.properties)     { $a.Properties     = ConvertTo-OrderedHash $r.properties }
            if ($r.subDataSources) { $a.SubDataSources = ConvertTo-OrderedHash $r.subDataSources }
            & (Join-Path $PSScriptRoot "create_datasource.ps1") @a
        }
        "domain" {
            if (-not $r.schemaFile)    { throw "domain $uri needs 'schemaFile'" }
            if (-not $r.dataSourceUri) { throw "domain $uri needs 'dataSourceUri'" }
            $schema = Resolve-RelPath "$($r.schemaFile)"
            $a = @{ Uri = $uri; SchemaFile = $schema; DataSourceUri = "$($r.dataSourceUri)"; Overwrite = $true } + $creds
            if ($r.label)       { $a.Label       = "$($r.label)" }
            if ($r.description) { $a.Description = "$($r.description)" }
            & (Join-Path $PSScriptRoot "create_domain.ps1") @a
        }
        "report" {
            # jrxml path OR a scaffold spec. A scaffold spec is materialized to a
            # jrxml via scaffold_jrxml.py first, then deployed.
            $jrxml = $null
            if ($r.jrxml) {
                $jrxml = Resolve-RelPath "$($r.jrxml)"
                if (-not (Test-Path $jrxml)) { throw "report $uri jrxml not found: $jrxml" }
            } elseif ($r.scaffold) {
                $s = $r.scaffold
                if (-not $s.name) { throw "report $uri scaffold spec needs 'name'" }
                $outDir = if ($s.outDir) { Resolve-RelPath "$($s.outDir)" } else { Join-Path $manifestDir "report" }
                New-Item -ItemType Directory -Force $outDir | Out-Null
                $jrxml = Join-Path $outDir "$($s.name).jrxml"
                $sa = @("$PSScriptRoot/scaffold_jrxml.py", "--name", "$($s.name)", "--out", $jrxml)
                if ($s.db)       { $sa += @("--db", "$($s.db)") }
                if ($s.host)     { $sa += @("--host", "$($s.host)") }
                if ($s.port)     { $sa += @("--port", "$($s.port)") }
                if ($s.user)     { $sa += @("--user", "$($s.user)") }
                if ($s.title)    { $sa += @("--title", "$($s.title)") }
                if ($s.subtitle) { $sa += @("--subtitle", "$($s.subtitle)") }
                if ($s.chart)    { $sa += @("--chart", "$($s.chart)") }
                if ($s.queryFile) { $sa += @("--query-file", (Resolve-RelPath "$($s.queryFile)")) }
                elseif ($s.query) { $sa += @("--query", "$($s.query)") }
                else { throw "report $uri scaffold spec needs 'query' or 'queryFile'" }
                & (Get-JrsPython) @sa | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "scaffold failed for report $uri" }
            } else {
                throw "report $uri needs 'jrxml' (a path) or 'scaffold' (a spec)"
            }
            $a = @{ Jrxml = $jrxml; TargetUri = $uri; Overwrite = $true; Apply = $true } + $creds   # reconcile -Apply already gates this branch
            if ($r.label)         { $a.Label         = "$($r.label)" }
            if ($r.description)   { $a.Description    = "$($r.description)" }
            if ($r.dataSourceUri) { $a.DataSourceUri = "$($r.dataSourceUri)" }
            & (Join-Path $PSScriptRoot "deploy_report.ps1") @a
        }
        "dashboard" {
            if (-not $r.manifest) { throw "dashboard $uri needs 'manifest' (a build_dashlets manifest path)" }
            $dm = Resolve-RelPath "$($r.manifest)"
            if (-not (Test-Path $dm)) { throw "dashboard $uri build manifest not found: $dm" }
            # NOTE: recomposing an EXISTING dashboard may require deleting it first
            # (import won't overwrite a dashboard's companion files). If apply fails
            # with resource.in.use / a stale dashboard, run teardown_dashboard.ps1.
            $a = @{ Manifest = $dm; Compose = $true } + $creds
            & (Join-Path $PSScriptRoot "build_dashlets.ps1") @a
        }
    }
    Write-Host ("  done: {0} {1}" -f $p.Action, $uri)
}

Write-Host ""
Write-Host ("Applied: {0} created / {1} updated / {2} left ok." -f $nCreate, $nUpdate, $nOk)
