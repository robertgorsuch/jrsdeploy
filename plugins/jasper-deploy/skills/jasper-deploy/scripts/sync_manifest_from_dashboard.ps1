<#
.SYNOPSIS
  Rebuild -- or update in place -- a compose manifest from a LIVE (possibly
  designer-edited) dashboard.

.DESCRIPTION
  Exports the dashboard, then derives a manifest whose dashlet positions/sizes
  and designer presentation keys (scaleToFit, showTitleBar, autoRefresh,
  export/print buttons, canvasColor, filter strip docking/buttons/height)
  match the live layout (via sync_manifest.py). Use this after someone
  rearranges the dashboard in the JRS designer so a later
  `compose_dashboard.ps1` reproduces the hand-edited layout instead of
  reverting it. sync then gen_dashboard reproduces the live model exactly.

  Two ways to call it:
    -Uri <dash> -Out <new.json>       write a fresh manifest from scratch
    -Manifest <existing.json>         update that manifest IN PLACE (the
                                      dashboard URI comes from its folder/name;
                                      queries, outDir, controls and every other
                                      key survive; a unified diff is printed)
  -WhatIf prints the diff and writes nothing.

.EXAMPLE
  .\sync_manifest_from_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Env stage -WhatIf

.EXAMPLE
  .\sync_manifest_from_dashboard.ps1 -Uri /reports/foodmart/foodmart_sales_dashboard_2dashlet `
      -Out report\foodmart\sales_dashboard_2dashlet.json
#>
[CmdletBinding()]
param(
    [string]$Uri,
    [string]$Out,
    [string]$Manifest,          # existing manifest to update in place
    [switch]$WhatIf,
    [string]$Env,               # named profile in jrs.config.json "environments"
    [string]$ServerUrl,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

if ($Manifest) {
    if (-not (Test-Path $Manifest)) { throw "manifest not found: $Manifest" }
    $m = (Get-Content $Manifest -Raw) -replace "^\xEF\xBB\xBF", "" | ConvertFrom-Json
    if (-not $Uri) { $Uri = "$("$($m.folder)".TrimEnd('/'))/$($m.name)" }
    if (-not $Out) { $Out = $Manifest }
} elseif (-not $Uri -or -not $Out) {
    throw "pass -Manifest <existing.json>, or -Uri <dashboard uri> with -Out <new.json>"
}
if (-not $Uri.StartsWith("/")) { $Uri = "/$Uri" }

$jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
Write-Host "sync manifest from live $Uri on $($jrs.ServerUrl)$(if ($WhatIf) { ' [whatif]' })"

$tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "dash_sync_" + [IO.Path]::GetRandomFileName() + ".zip")
try {
    & (Join-Path $PSScriptRoot "export_resource.ps1") -Uri $Uri -Out $tmp `
        -ServerUrl $jrs.ServerUrl -User $jrs.User -Password $jrs.Password | Write-Host
    $pyArgs = @((Join-Path $PSScriptRoot "sync_manifest.py"), "--zip", $tmp, "--out", $Out)
    if ($Manifest) { $pyArgs += @("--merge", $Manifest) }
    if ($WhatIf) { $pyArgs += "--dry-run" }
    & (Get-JrsPython) @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "sync_manifest.py failed" }
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}
