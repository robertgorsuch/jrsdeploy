<#
.SYNOPSIS
  List, show, and roll back journaled runs (promote / compose / teardown /
  deploy -Overwrite). Plans by default; -Rollback -Apply replays the
  compensations.

.DESCRIPTION
  Every write-capable run journals itself under out\runs\<runId> (run.json +
  transitions.jsonl; $env:JRS_RUNS_DIR overrides the root). Each mutating step
  carries a compensation record: 'reimport' (put the pre-change backup archive
  back) or 'delete' (remove what the run created from nothing). This script:

    -List                      newest-first table of runs (id, operation, status,
                               target, started, exit code)
    -RunId <id|prefix|latest>  show one run: plan, transitions, rollback plan
    -Rollback                  print the rollback plan (compensations newest first,
                               for every step that ran and is not already undone)
    -Rollback -Apply           replay them against the run's own target server and
                               record COMPENSATED / COMPENSATE_FAILED transitions;
                               exit 3 = ROLLED_BACK, 4 = ROLLBACK_INCOMPLETE

  The target is resolved from the run record (its env profile, else its URL
  with the credentials of the matching profile or the top-level config), so
  the PROD guard ($env:JRS_ALLOW_PROD_WRITE) applies exactly as it did to the
  original run. Pass -ServerUrl/-User/-Password/-Env to override.

  Ported from jrsctl's `runs list|show|recover <id> --rollback`.

.EXAMPLE
  .\recover_run.ps1 -List
  .\recover_run.ps1 -RunId latest
  .\recover_run.ps1 -RunId r-20260928-2015 -Rollback
  .\recover_run.ps1 -RunId r-20260928-2015 -Rollback -Apply
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$RunId,
    [switch]$Rollback,
    [switch]$Apply,
    [int]$Limit = 20,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")

if ($MyInvocation.InvocationName -eq ".") { return }   # dot-sourced by tests: functions only

if ($List -or -not $RunId) {
    $runs = @(Get-JrsRuns)
    if ($runs.Count -eq 0) { Write-Host "no runs recorded under $(Get-JrsRunsRoot)"; exit 0 }
    Write-Host ""
    Write-Host ("  {0,-24} {1,-10} {2,-20} {3,-44} {4,-24} {5}" -f "run", "operation", "status", "target", "started (UTC)", "exit")
    foreach ($r in ($runs | Select-Object -First $Limit)) {
        $tgt = "$($r.Target.serverUrl)$(if ($r.Target.env) { " [$($r.Target.env)]" })"
        Write-Host ("  {0,-24} {1,-10} {2,-20} {3,-44} {4,-24} {5}" -f $r.RunId, $r.Operation, $r.Status, $tgt, $r.StartedAt, $r.ExitCode)
    }
    Write-Host ""
    if ($runs.Count -gt $Limit) { Write-Host "  ($($runs.Count - $Limit) older run(s) not shown; -Limit)" }
    exit 0
}

$run = Get-JrsRun -RunId $RunId
Write-Host ""
Write-Host "RUN $($run.RunId)  $($run.Operation)  $($run.Status)$(if ($null -ne $run.ExitCode) { " (exit $($run.ExitCode))" })"
Write-Host "  target   $($run.Target.serverUrl)$(if ($run.Target.env) { " [env $($run.Target.env)]" })  as $($run.Target.user)"
Write-Host "  started  $($run.StartedAt)   ended  $($run.EndedAt)"
if ($run.Error) { Write-Host "  error    $($run.Error)" }
Write-Host "  dir      $($run.Dir)"
if ($run.Plan.Count -gt 0) {
    Write-Host ""
    Write-Host "  plan:"
    foreach ($p in $run.Plan) { Write-Host ("    [{0,3}] {1,-10} {2,-52} {3}" -f $p.order, $p.kind, $p.uri, $p.action) }
}
Write-Host ""
Write-Host "  transitions:"
foreach ($t in $run.Transitions) {
    $extra = ""
    if ($t.PSObject.Properties.Name -contains "compensation" -and $t.compensation) { $extra += "  undo: $($t.compensation.type) $($t.compensation.uri)$($t.compensation.zip)" }
    if ($t.PSObject.Properties.Name -contains "irreversible" -and $t.irreversible) { $extra += "  IRREVERSIBLE: $($t.irreversible)" }
    if ($t.PSObject.Properties.Name -contains "detail" -and $t.detail) { $extra += "  ($($t.detail))" }
    Write-Host ("    {0}  {1,-18} {2,-44}{3}" -f $t.ts, $t.state, $t.step, $extra)
}

if (-not $Rollback) {
    $n = @(Get-JrsRollbackPlan -Run $run).Count
    Write-Host ""
    Write-Host "  $n step(s) can be rolled back: recover_run.ps1 -RunId $($run.RunId) -Rollback [-Apply]"
    exit 0
}

# --- resolve the run's own target (profile first, else URL + matching creds) ---
$envName = if ($Env) { $Env } elseif ($run.Target.env) { "$($run.Target.env)" } else { $null }
$jrs = Resolve-JrsConfig -ServerUrl $(if ($ServerUrl) { $ServerUrl } elseif (-not $envName) { "$($run.Target.serverUrl)" } else { $null }) -User $User -Password $Password -Env $envName
if ($jrs.ServerUrl -ne "$($run.Target.serverUrl)".TrimEnd("/")) {
    throw "resolved target $($jrs.ServerUrl) is not the run's target $($run.Target.serverUrl); pass -ServerUrl/-Env explicitly to override"
}

$res = Invoke-JrsRollback -Run $run -Jrs $jrs -Apply:$Apply
if ($Apply) { exit $res.ExitCode } else { exit 0 }
