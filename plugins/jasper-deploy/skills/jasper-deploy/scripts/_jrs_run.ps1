# _jrs_run.ps1 -- the run journal: one directory per mutating run with a run
# record and an append-only transition log, plus the rollback plan/executor
# that replays the compensations those transitions carry.
#
# NO param() block on purpose: this file is dot-sourced by _jrs_common.ps1 (so
# every script gets it) and a param block would re-bind the caller's variables
# (gotcha G60, the 2026-08-28 incident). tests/dotsource.Tests.ps1 enforces it.
#
# Model (ported from jrsctl, spec specs/2026-09-28-*):
#   New-JrsRun          - open a run (apply mode writes <runs>/<runId>/run.json;
#                         plan mode returns a handle that journals nothing; a
#                         run opened while $Global:JrsCurrentRun is set JOINS
#                         that parent run so child scripts share one journal)
#   Write-JrsStep       - append a transition: PLANNED RUNNING SUCCEEDED FAILED
#                         SKIPPED COMPENSATED COMPENSATE_FAILED, optionally with
#                         the step's compensation record (data, replayed later)
#                         or an -Irreversible reason
#   Complete-JrsRun     - close the run: SUCCEEDED FAILED ROLLED_BACK
#                         ROLLBACK_INCOMPLETE CANCELLED + exit code
#   Get-JrsRuns / Get-JrsRun ('latest' or an id prefix) - read runs back
#   Get-JrsRollbackPlan - compensations to replay, newest first, for every step
#                         that ran (SUCCEEDED/RUNNING/FAILED) and is not already
#                         COMPENSATED or marked irreversible
#   Invoke-JrsRollback  - print that plan; with -Apply replay it and record
#                         COMPENSATED / COMPENSATE_FAILED transitions and the
#                         final status (ROLLED_BACK -> exit 3, ROLLBACK_INCOMPLETE -> 4)
#
# Compensation records:
#   @{ type = 'delete';   uri = '/reports/x' }               remove what the run created from nothing
#   @{ type = 'reimport'; zip = 'C:\...\x.zip'; uri = '/reports/x' }
#                                                             put a backup archive back (delete first when the
#                                                             resource exists, because import update=true does
#                                                             not overwrite a dashboard's companion files)
#
# Location: $env:JRS_RUNS_DIR, else <skill>/out/runs (gitignored).
# Exit codes (jrsctl table): 0 ok, 2 precheck failed / nothing mutated,
# 3 failed and rolled back, 4 rollback incomplete, 5 cancelled.

$script:JrsRunStates = @("PLANNED", "RUNNING", "SUCCEEDED", "FAILED", "SKIPPED", "COMPENSATED", "COMPENSATE_FAILED")

function Get-JrsRunsRoot {
    $r = [Environment]::GetEnvironmentVariable("JRS_RUNS_DIR")
    if (-not [string]::IsNullOrEmpty($r)) { return $r }
    return (Join-Path $PSScriptRoot "../out/runs")
}

function New-JrsRunId {
    $rand = -join ((1..4) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
    return "r-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + $rand
}

function Get-JrsIsoNow { return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function ConvertTo-JrsRedactedArgs([hashtable]$Arguments) {
    # never persist a credential-looking argument value
    $o = [ordered]@{}
    if (-not $Arguments) { return $o }
    foreach ($k in ($Arguments.Keys | Sort-Object)) {
        if ("$k" -match '(?i)pass|secret|token|credential') { $o["$k"] = "<redacted>" }
        else { $v = $Arguments[$k]; $o["$k"] = $(if ($v -is [switch]) { [bool]$v } else { $v }) }
    }
    return $o
}

function Write-JrsRunRecord([string]$Dir, $Doc) {
    $json = $Doc | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $Dir "run.json"), $json, (New-Object Text.UTF8Encoding($false)))
}

function New-JrsRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)]$Target,                      # Resolve-JrsConfig object (password is NOT persisted)
        [ValidateSet("plan", "apply")][string]$Mode = "apply",
        $Plan = @(),                                        # objects with Order/Kind/Uri/Action (others ignored)
        [hashtable]$Arguments = @{}
    )
    $parent = $Global:JrsCurrentRun
    if ($parent) {
        return [pscustomobject]@{ RunId = $parent.RunId; Dir = $parent.Dir; Nested = $true; Mode = $parent.Mode; Operation = $Operation }
    }
    if ($Mode -eq "plan") {
        return [pscustomobject]@{ RunId = $null; Dir = $null; Nested = $false; Mode = "plan"; Operation = $Operation }
    }
    $id = New-JrsRunId
    $dir = Join-Path (Get-JrsRunsRoot) $id
    New-Item -ItemType Directory -Force $dir | Out-Null
    $planRows = @()
    foreach ($p in @($Plan)) {
        if ($null -eq $p) { continue }
        $row = [ordered]@{}
        foreach ($k in @("Order", "Kind", "Uri", "Action")) {
            if ($p.PSObject.Properties.Name -contains $k) { $row[$k.ToLower()] = $p.$k }
        }
        $planRows += $row
    }
    $doc = [ordered]@{
        runId = $id; operation = $Operation; mode = $Mode; status = "RUNNING"
        startedAt = (Get-JrsIsoNow); endedAt = $null; exitCode = $null; error = $null
        target = [ordered]@{ serverUrl = "$($Target.ServerUrl)"; env = $(if ($Target.Env) { "$($Target.Env)" } else { $null }); user = "$($Target.User)" }
        args = (ConvertTo-JrsRedactedArgs $Arguments)
        plan = $planRows
        host = [ordered]@{ machine = [Environment]::MachineName; cwd = (Get-Location).Path }
    }
    Write-JrsRunRecord $dir $doc
    $run = [pscustomobject]@{ RunId = $id; Dir = $dir; Nested = $false; Mode = $Mode; Operation = $Operation }
    $Global:JrsCurrentRun = $run
    Write-Host "run $id -> $dir"
    return $run
}

function Write-JrsStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet("PLANNED", "RUNNING", "SUCCEEDED", "FAILED", "SKIPPED", "COMPENSATED", "COMPENSATE_FAILED")][string]$State,
        [hashtable]$Compensation,
        [string]$Detail,
        [string]$Irreversible                               # reason a step cannot be undone (no backup taken, ...)
    )
    if (-not $Run -or -not $Run.Dir) { return }             # plan mode: nothing to journal
    $line = [ordered]@{ ts = (Get-JrsIsoNow); op = $Run.Operation; step = $Step; state = $State }
    if ($Compensation) { $line.compensation = $Compensation }
    if ($Irreversible) { $line.irreversible = $Irreversible }
    if ($Detail)       { $line.detail = $Detail }
    $text = ($line | ConvertTo-Json -Compress -Depth 8) + "`n"
    [IO.File]::AppendAllText((Join-Path $Run.Dir "transitions.jsonl"), $text, (New-Object Text.UTF8Encoding($false)))
}

function Complete-JrsRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet("SUCCEEDED", "FAILED", "ROLLED_BACK", "ROLLBACK_INCOMPLETE", "CANCELLED")][string]$Status,
        [int]$ExitCode = 0,
        [string]$Error
    )
    if ($Run.Nested) { return }                             # the parent closes the shared run
    if ($Run.Dir) {
        $doc = Get-Content (Join-Path $Run.Dir "run.json") -Raw | ConvertFrom-Json
        $doc.status = $Status; $doc.endedAt = (Get-JrsIsoNow); $doc.exitCode = $ExitCode
        $doc.error = $(if ($Error) { $Error } else { $null })
        Write-JrsRunRecord $Run.Dir $doc
    }
    $Global:JrsCurrentRun = $null
}

function Get-JrsRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)             # full id, unique prefix, or 'latest'
    $root = Get-JrsRunsRoot
    if (-not (Test-Path $root)) { throw "no runs recorded under $root" }
    $dirs = @(Get-ChildItem $root -Directory | Where-Object { $_.Name -like "r-*" } | Sort-Object Name -Descending)
    $dir = $null
    if ($RunId -eq "latest") { $dir = $dirs | Select-Object -First 1 }
    else {
        $hits = @($dirs | Where-Object { $_.Name -eq $RunId -or $_.Name.StartsWith($RunId) })
        if ($hits.Count -gt 1 -and -not ($hits | Where-Object { $_.Name -eq $RunId })) { throw "run id '$RunId' is ambiguous: $(($hits | ForEach-Object { $_.Name }) -join ', ')" }
        $dir = $hits | Where-Object { $_.Name -eq $RunId } | Select-Object -First 1
        if (-not $dir) { $dir = $hits | Select-Object -First 1 }
    }
    if (-not $dir) { throw "run '$RunId' not found under $root" }
    $doc = Get-Content (Join-Path $dir.FullName "run.json") -Raw | ConvertFrom-Json
    $tf = Join-Path $dir.FullName "transitions.jsonl"
    $trans = @()
    if (Test-Path $tf) { $trans = @(Get-Content $tf | Where-Object { "$_".Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
    return [pscustomobject]@{
        RunId = $doc.runId; Dir = $dir.FullName; Operation = $doc.operation; Mode = $doc.mode; Status = $doc.status
        StartedAt = $doc.startedAt; EndedAt = $doc.endedAt; ExitCode = $doc.exitCode; Error = $doc.error
        Target = $doc.target; Args = $doc.args; Plan = @($doc.plan); Transitions = $trans
    }
}

function Get-JrsRuns {
    $root = Get-JrsRunsRoot
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    foreach ($d in @(Get-ChildItem $root -Directory | Where-Object { $_.Name -like "r-*" } | Sort-Object Name -Descending)) {
        try { $out += (Get-JrsRun -RunId $d.Name) } catch { }
    }
    return @($out)
}

function Get-JrsRollbackPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)                       # object from Get-JrsRun
    $steps = [ordered]@{}
    foreach ($t in @($Run.Transitions)) {
        $k = "$($t.step)"
        if (-not $steps.Contains($k)) { $steps[$k] = @{ Step = $k; State = $null; Compensation = $null; Irreversible = $null; Seq = $steps.Count } }
        $s = $steps[$k]
        $s.State = "$($t.state)"
        if ($t.PSObject.Properties.Name -contains "compensation" -and $t.compensation) { $s.Compensation = $t.compensation }
        if ($t.PSObject.Properties.Name -contains "irreversible" -and $t.irreversible) { $s.Irreversible = "$($t.irreversible)" }
    }
    $out = @()
    foreach ($s in $steps.Values) {
        if (@("SUCCEEDED", "RUNNING", "FAILED") -notcontains $s.State) { continue }
        if (-not $s.Compensation -or $s.Irreversible) { continue }
        $out += [pscustomobject]@{ Step = $s.Step; State = $s.State; Compensation = $s.Compensation; Seq = $s.Seq }
    }
    return @($out | Sort-Object Seq -Descending)   # callers wrap with @(): an empty result emits nothing
}

function Get-JrsIrreversibleSteps($Run) {
    $seen = @{}; $out = @()
    foreach ($t in @($Run.Transitions)) {
        if (($t.PSObject.Properties.Name -contains "irreversible") -and $t.irreversible -and -not $seen["$($t.step)"]) {
            $seen["$($t.step)"] = $true; $out += [pscustomobject]@{ Step = "$($t.step)"; Reason = "$($t.irreversible)" }
        }
    }
    return @($out)
}

function Invoke-JrsCompensation {
    # Replay ONE compensation record against $Jrs. Returns a detail string; throws on failure.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Jrs, [Parameter(Mandatory)]$Comp)
    $type = "$($Comp.type)"
    switch ($type) {
        "delete" {
            $uri = "$($Comp.uri)"
            $code = Invoke-JrsDelete -Jrs $Jrs -Uri $uri
            if ($code -notmatch '^(2\d\d|404)$') { throw "DELETE $uri -> HTTP $code" }
            return "DELETE $uri -> HTTP $code"
        }
        "reimport" {
            $zip = "$($Comp.zip)"
            if (-not (Test-Path $zip)) { throw "backup archive missing: $zip" }
            $note = ""
            if ($Comp.PSObject.Properties.Name -contains "uri" -and $Comp.uri) {
                # import update=true does not replace a live dashboard's companion files
                # (layout/components/wiring): remove the current copy first when we can
                # (a 403 resource.in.use tile stays and is updated in place by the import).
                $code = Invoke-JrsDelete -Jrs $Jrs -Uri "$($Comp.uri)"
                $note = " (pre-delete $($Comp.uri) -> HTTP $code)"
            }
            & (Join-Path $PSScriptRoot "import_resource.ps1") -Zip $zip -Update $true `
                -ServerUrl $Jrs.ServerUrl -User $Jrs.User -Password $Jrs.Password | Out-Null
            return "re-imported $zip$note"
        }
        default { throw "unknown compensation type '$type'" }
    }
}

function Invoke-JrsRollback {
    # Print the rollback plan for a run; with -Apply replay it newest-first and
    # record the outcome in the same run directory. Returns
    # { Status; ExitCode; Total; Failed; Plan }.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Jrs, [switch]$Apply)
    $plan = @(Get-JrsRollbackPlan -Run $Run)
    $irrev = @(Get-JrsIrreversibleSteps $Run)
    Write-Host ""
    Write-Host "ROLLBACK PLAN for run $($Run.RunId) ($($Run.Operation), $($Run.Status)) on $($Jrs.ServerUrl)$(if ($Jrs.Env) { " [env $($Jrs.Env)]" })"
    if ($plan.Count -eq 0) { Write-Host "  (nothing to compensate)" }
    $n = 0
    foreach ($p in $plan) {
        $n++
        $what = switch ("$($p.Compensation.type)") {
            "delete"   { "DELETE $($p.Compensation.uri)" }
            "reimport" { "RE-IMPORT $($p.Compensation.zip)$(if ($p.Compensation.uri) { " -> $($p.Compensation.uri)" })" }
            default    { "?? $($p.Compensation.type)" }
        }
        Write-Host ("  [{0,3}] {1,-40} {2,-9} {3}" -f $n, $p.Step, $p.State, $what)
    }
    foreach ($i in $irrev) { Write-Host ("  [ - ] {0,-40} IRREVERSIBLE: {1}" -f $i.Step, $i.Reason) }
    Write-Host ""
    if (-not $Apply) {
        Write-Host "[plan] nothing was written; pass -Apply to replay these $($plan.Count) compensation(s)"
        return [pscustomobject]@{ Status = $Run.Status; ExitCode = 0; Total = $plan.Count; Failed = 0; Plan = $plan }
    }
    $handle = [pscustomobject]@{ RunId = $Run.RunId; Dir = $Run.Dir; Nested = $false; Mode = "apply"; Operation = "rollback" }
    $failed = 0
    foreach ($p in $plan) {
        try {
            $d = Invoke-JrsCompensation -Jrs $Jrs -Comp $p.Compensation
            Write-JrsStep -Run $handle -Step $p.Step -State COMPENSATED -Detail $d
            Write-Host "  compensated $($p.Step): $d"
        } catch {
            $failed++
            Write-JrsStep -Run $handle -Step $p.Step -State COMPENSATE_FAILED -Detail "$_"
            Write-Warning "compensation of $($p.Step) FAILED: $_"
        }
    }
    $status = if ($failed -gt 0 -or $irrev.Count -gt 0) { "ROLLBACK_INCOMPLETE" } else { "ROLLED_BACK" }
    $exit = if ($status -eq "ROLLED_BACK") { 3 } else { 4 }
    $err = if ($failed -gt 0) { "$failed compensation(s) failed" } elseif ($irrev.Count -gt 0) { "$($irrev.Count) irreversible step(s)" } else { $null }
    Complete-JrsRun -Run $handle -Status $status -ExitCode $exit -Error $err
    Write-Host "rollback $status ($($plan.Count - $failed)/$($plan.Count) compensated$(if ($irrev.Count) { ", $($irrev.Count) irreversible" }))"
    return [pscustomobject]@{ Status = $status; ExitCode = $exit; Total = $plan.Count; Failed = $failed; Plan = $plan }
}

function Export-JrsBackup {
    # Export ONE repository URI to a timestamped zip before a delete/overwrite so
    # the step can carry a 'reimport' compensation. Returns the archive path, or
    # $null (with a warning) when the export fails or the resource is absent --
    # the caller then records the step as irreversible instead of failing.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Jrs, [Parameter(Mandatory)][string]$Uri, [string]$BackupDir)
    if (-not $BackupDir) { $BackupDir = Join-Path $PSScriptRoot "../out/backups" }
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $BackupDir (($Uri.TrimStart("/") -replace "[^0-9A-Za-z]", "_") + "-$stamp.zip")
    try {
        & (Join-Path $PSScriptRoot "export_resource.ps1") -Uri $Uri -Out $path `
            -ServerUrl $Jrs.ServerUrl -User $Jrs.User -Password $Jrs.Password *>$null
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) { return (Resolve-Path $path).Path }
        Write-Warning "backup of $Uri produced no archive"
    } catch { Write-Warning "backup of $Uri failed: $_" }
    return $null
}
