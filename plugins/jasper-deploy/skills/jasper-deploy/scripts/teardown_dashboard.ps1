<#
.SYNOPSIS
  Delete a dashboard and (optionally) the report dashlets it owns, in the order
  JRS requires. Plans by default; -Apply deletes.

.DESCRIPTION
  A report that is a dashlet of a dashboard is modification/delete-locked
  (403 resource.in.use) while the dashboard exists. This deletes the dashboard
  first, then -- with -IncludeReports -- each report tile it referenced (plus the
  "<report>_controls" folder that deploy_report.ps1 -Control creates). A report
  still referenced by ANOTHER dashboard returns 403 and is skipped with a note,
  so a shared report is never half-deleted.

  SAFETY MODEL (1.3.0, ported from jrsctl):
    * Without -Apply the script prints the teardown plan and writes nothing.
      Plan mode is enforced below the script by _jrs_common.ps1's write guard,
      so a clobbered switch cannot turn writes on (incident 2026-08-28, G60).
    * With -Apply every resource is EXPORTED to out\backups first (unless
      -NoBackup) and the run is journaled under out\runs\<runId> with a
      'reimport' compensation per delete. Undo with:
          recover_run.ps1 -RunId <id> -Rollback -Apply
    * A prod profile additionally needs $env:JRS_ALLOW_PROD_WRITE = '1'.

.PARAMETER Uri
  Dashboard repository URI, e.g. /reports/foodmart/foodmart_kpi_dashboard_auto.

.PARAMETER IncludeReports
  Also delete the report dashlets (and their _controls folders).

.PARAMETER Apply
  Actually delete. Without it the plan is printed and nothing is written.

.PARAMETER DryRun
  Legacy alias for the default (plan) mode; cannot be combined with -Apply.

.PARAMETER NoBackup
  Skip the export before each delete. The steps are then journaled as
  irreversible and recover_run.ps1 cannot put them back.

.EXAMPLE
  .\teardown_dashboard.ps1 -Uri /reports/foodmart/foodmart_kpi_dashboard_auto -IncludeReports
  .\teardown_dashboard.ps1 -Uri /reports/foodmart/foodmart_kpi_dashboard_auto -IncludeReports -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [switch]$IncludeReports,
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$NoBackup,
    [string]$BackupDir,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
if ($Apply -and $DryRun) { throw "-Apply and -DryRun are mutually exclusive" }

$prevMode = Enter-JrsPlanMode -Apply:$Apply
try {
    $jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env
    if (-not $Uri.StartsWith("/")) { $Uri = "/$Uri" }

    $cur = Invoke-JrsGet -Jrs $jrs -Uri $Uri
    if ($cur.Code -notmatch '^2\d\d$') { Write-Host "dashboard $Uri not found ($($cur.Code)); nothing to do"; return }
    $model = $cur.Body | ConvertFrom-Json
    $reportUris = @($model.resources | Where-Object { $_.type -eq "reportUnit" } |
        ForEach-Object { $_.resource.resourceReference.uri } | Where-Object { $_ } | Select-Object -Unique)

    # --- plan ------------------------------------------------------------------
    $where = "$($jrs.ServerUrl)$(if ($jrs.Env) { " [env $($jrs.Env)]" })"
    $bk = if ($NoBackup) { "no backup (irreversible)" } else { "backup then" }
    $plan = @([pscustomobject]@{ Order = 1; Kind = "delete-dashboard"; Uri = $Uri; Action = "$bk DELETE dashboard (frees $($reportUris.Count) tile lock(s))" })
    if ($IncludeReports) {
        foreach ($r in $reportUris) { $plan += [pscustomobject]@{ Order = $plan.Count + 1; Kind = "delete-report"; Uri = $r; Action = "$bk DELETE report (+ ${r}_controls); skipped if another dashboard still uses it" } }
    }
    Write-Host ""
    Write-Host "TEARDOWN PLAN  $Uri on $where"
    foreach ($s in $plan) { Write-Host ("  [{0,3}] {1,-52} {2}" -f $s.Order, $s.Uri, $s.Action) }
    Write-Host ""
    if (-not $Apply) {
        Write-Host "[plan] nothing was written to $($jrs.ServerUrl); pass -Apply to delete (undo later with recover_run.ps1 -RunId <id> -Rollback -Apply)"
        return
    }

    # --- apply (journaled) -------------------------------------------------------
    Assert-JrsWriteAllowed -Jrs $jrs -Method APPLY -Url $jrs.ServerUrl   # precheck: refuse an unconfirmed prod target BEFORE any backup/export runs
    $run = New-JrsRun -Operation "teardown" -Target $jrs -Mode apply -Plan $plan -Arguments @{ Uri = $Uri; IncludeReports = [bool]$IncludeReports; NoBackup = [bool]$NoBackup }
    try {
        # 1. dashboard first (frees the report locks)
        $step = "teardown:$Uri"
        $comp = $null; $irrev = $null
        if ($NoBackup) { $irrev = "-NoBackup" }
        else {
            $zip = Export-JrsBackup -Jrs $jrs -Uri $Uri -BackupDir $BackupDir
            if ($zip) { $comp = @{ type = "reimport"; zip = $zip; uri = $Uri }; Write-Host "backup $Uri -> $zip" } else { $irrev = "backup export failed" }
        }
        Write-JrsStep -Run $run -Step $step -State RUNNING -Compensation $comp -Irreversible $irrev
        $dc = Invoke-JrsDelete -Jrs $jrs -Uri $Uri
        Write-Host "DELETE $Uri -> $dc"
        if ($dc -notmatch '^(2\d\d|404)$') { Write-JrsStep -Run $run -Step $step -State FAILED -Detail "HTTP $dc"; throw "could not delete dashboard $Uri ($dc)" }
        Write-JrsStep -Run $run -Step $step -State SUCCEEDED -Detail "HTTP $dc"

        # 2. report tiles + their control folders
        if ($IncludeReports) {
            foreach ($r in $reportUris) {
                $step = "teardown:$r"
                $comp = $null; $irrev = $null
                if ($NoBackup) { $irrev = "-NoBackup" }
                else {
                    $zip = Export-JrsBackup -Jrs $jrs -Uri $r -BackupDir $BackupDir
                    if ($zip) { $comp = @{ type = "reimport"; zip = $zip; uri = $r }; Write-Host "backup $r -> $zip" } else { $irrev = "backup export failed" }
                }
                Write-JrsStep -Run $run -Step $step -State RUNNING -Compensation $comp -Irreversible $irrev
                $rc = Invoke-JrsDelete -Jrs $jrs -Uri $r
                if ($rc -eq "403") { Write-Host "skip   $r (still in use by another dashboard)"; Write-JrsStep -Run $run -Step $step -State SKIPPED -Detail "HTTP 403 resource.in.use"; continue }
                Write-Host "DELETE $r -> $rc"
                if ($rc -notmatch '^(2\d\d|404)$') { Write-JrsStep -Run $run -Step $step -State FAILED -Detail "HTTP $rc"; throw "could not delete report $r ($rc)" }
                $ctl = "${r}_controls"
                $cc = Invoke-JrsDelete -Jrs $jrs -Uri $ctl
                if ($cc -match '^2\d\d$') { Write-Host "DELETE $ctl -> $cc" }
                Write-JrsStep -Run $run -Step $step -State SUCCEEDED -Detail "HTTP $rc; ${ctl}: HTTP $cc (its controls travel with the report export)"
            }
        }
        Complete-JrsRun -Run $run -Status SUCCEEDED
        Write-Host "OK: torn down $Uri (run $($run.RunId))"
    } catch {
        Complete-JrsRun -Run $run -Status FAILED -ExitCode 4 -Error "$_"
        Write-Host "FAILED (run $($run.RunId)); undo what was done with: recover_run.ps1 -RunId $($run.RunId) -Rollback -Apply"
        throw
    }
} finally { Restore-JrsPlanMode $prevMode }
