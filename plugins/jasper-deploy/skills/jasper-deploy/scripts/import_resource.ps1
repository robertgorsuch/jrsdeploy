<#
.SYNOPSIS
  Import a JasperReports Server export .zip (from export_resource.ps1) via the
  REST v2 import service.

.DESCRIPTION
  Restores/promotes whatever is in the archive to the repository at the URIs it
  was exported from. Use this to promote a dashboard (or any resource) authored
  on one server to another, or to restore from version control. Because the
  archive is the designer's own output, an imported dashboard renders identically
  to the original.

  Flow: POST /rest_v2/import?update=...&skipUserUpdate=... (multipart file) ->
  {id}; poll GET /rest_v2/import/{id}/state until phase=finished.

  Credentials resolve via _jrs_common.ps1.

.PARAMETER Zip
  Local export archive to import.

.PARAMETER Update
  Overwrite resources that already exist (default true). With -Update:$false an
  import that hits an existing resource fails.

.EXAMPLE
  .\import_resource.ps1 -Zip backups\sales_dashboard.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [bool]$Update = $true,
    [int]$TimeoutSec = 120,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env                 # named profile in jrs.config.json "environments"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
if (-not (Test-Path $Zip)) { throw "archive not found: $Zip" }
$zipFull = (Resolve-Path $Zip).Path
$jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
$auth = "$($jrs.User):$($jrs.Password)"
$base = "$($jrs.ServerUrl)/rest_v2/import"
$q = "?update=$($Update.ToString().ToLower())"

# --- post the archive (multipart) ---------------------------------------------
# Through the shared helper so the write guard applies: an import is a
# repository write and is refused in plan mode / on an unconfirmed prod target.
$r = Invoke-JrsRest -Jrs $jrs -Method POST -Path "/rest_v2/import$q" -FormFile $zipFull
$resp = $r.Body
$id = try { ($resp | ConvertFrom-Json).id } catch { $null }
if (-not $id) { throw "import request failed (HTTP $($r.Code)): $resp" }
Write-Host "import id: $id"

# --- poll state ---------------------------------------------------------------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
    Start-Sleep -Milliseconds 800
    $state = & (Get-JrsCurl) -s -u $auth -H "Accept: application/json" "$base/$id/state"
    $phase = ($state | ConvertFrom-Json).phase
    if ($phase -eq "failed") { throw "import failed: $state" }
} while ($phase -ne "finished" -and (Get-Date) -lt $deadline)
if ($phase -ne "finished") { throw "import timed out after ${TimeoutSec}s (phase=$phase)" }
# A "finished" import can still have skipped resources: the state carries
# warnings[] (broken dependencies, skipped resources) and errorDescriptor.
# Print them -- a silently skipped dashboard otherwise looks like success.
try {
    $st = $state | ConvertFrom-Json
    if ($st.errorDescriptor) { Write-Warning ("import errorDescriptor: " + ($st.errorDescriptor | ConvertTo-Json -Compress -Depth 5)) }
    foreach ($w in @($st.warnings)) {
        $wt = if ($w -is [string]) { $w } else { ($w | ConvertTo-Json -Compress -Depth 5) }
        if ("$wt".Trim() -and "$wt".Trim() -ne "{}" -and "$wt".Trim() -ne "null") { Write-Warning "import warning: $wt" }
    }
} catch { }
Write-Host "OK: imported $Zip"
