# Pester 3.x/4.x (legacy `Should Be` syntax) tests for the run journal in
# scripts\_jrs_run.ps1 (dot-sourced by _jrs_common.ps1). Pure file I/O under a
# temp JRS_RUNS_DIR; no server contact.

. "$PSScriptRoot/../scripts/_jrs_common.ps1"
# A caller such as smoke_test.ps1 runs Pester under $ErrorActionPreference = 'Stop';
# PS 5.1 then turns a child's stderr (curl: (7) ..., python WARN: ...) into a terminating
# error. These tests expect that stderr, so pin the preference for this file.
$ErrorActionPreference = 'Continue'

function New-TempRuns {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("jrs_runs_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}
$script:Target = [pscustomobject]@{ ServerUrl = "http://127.0.0.1:9/jasperserver-pro"; User = "u"; Password = "secret"; Env = "stage"; IsProd = $false }

Describe "run journal" {
    BeforeEach {
        $script:Runs = New-TempRuns
        [Environment]::SetEnvironmentVariable("JRS_RUNS_DIR", $script:Runs)
        $Global:JrsCurrentRun = $null
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable("JRS_RUNS_DIR", $null)
        $Global:JrsCurrentRun = $null
        Remove-Item $script:Runs -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "New-JrsRun writes run.json with a sortable id, the target (no password) and the plan" {
        $plan = @([pscustomobject]@{ Order = 1; Kind = "teardown"; Uri = "/reports/t/d"; Action = "DELETE" })
        $run = New-JrsRun -Operation "promote" -Target $script:Target -Mode apply -Plan $plan -Arguments @{ Manifest = "x.json"; Password = "secret" }
        $run.RunId | Should Match '^r-\d{8}-\d{6}-[0-9a-f]{4}$'
        (Test-Path (Join-Path $run.Dir "run.json")) | Should Be $true
        $j = Get-Content (Join-Path $run.Dir "run.json") -Raw | ConvertFrom-Json
        $j.operation | Should Be "promote"
        $j.status | Should Be "RUNNING"
        $j.mode | Should Be "apply"
        $j.target.serverUrl | Should Be $script:Target.ServerUrl
        $j.target.env | Should Be "stage"
        $j.plan.Count | Should Be 1
        (Get-Content (Join-Path $run.Dir "run.json") -Raw) | Should Not Match 'secret'
        $Global:JrsCurrentRun.RunId | Should Be $run.RunId
    }

    It "Write-JrsStep appends one JSON line per transition with the compensation record" {
        $run = New-JrsRun -Operation "teardown" -Target $script:Target -Mode apply
        Write-JrsStep -Run $run -Step "delete:/reports/t/d" -State RUNNING
        Write-JrsStep -Run $run -Step "delete:/reports/t/d" -State SUCCEEDED -Compensation @{ type = "reimport"; zip = "C:\b.zip" } -Detail "HTTP 204"
        $lines = @(Get-Content (Join-Path $run.Dir "transitions.jsonl"))
        $lines.Count | Should Be 2
        $t = $lines[1] | ConvertFrom-Json
        $t.step | Should Be "delete:/reports/t/d"
        $t.state | Should Be "SUCCEEDED"
        $t.compensation.type | Should Be "reimport"
        $t.compensation.zip | Should Be "C:\b.zip"
        $t.detail | Should Be "HTTP 204"
    }

    It "Complete-JrsRun records status, end time and exit code" {
        $run = New-JrsRun -Operation "teardown" -Target $script:Target -Mode apply
        Complete-JrsRun -Run $run -Status ROLLED_BACK -ExitCode 3 -Error "boom"
        $j = Get-Content (Join-Path $run.Dir "run.json") -Raw | ConvertFrom-Json
        $j.status | Should Be "ROLLED_BACK"
        $j.exitCode | Should Be 3
        $j.error | Should Be "boom"
        $j.endedAt | Should Not BeNullOrEmpty
        $Global:JrsCurrentRun | Should Be $null
    }

    It "a nested New-JrsRun joins the parent run and Complete-JrsRun on it is a no-op" {
        $parent = New-JrsRun -Operation "promote" -Target $script:Target -Mode apply
        $child = New-JrsRun -Operation "compose" -Target $script:Target -Mode apply
        $child.RunId | Should Be $parent.RunId
        $child.Nested | Should Be $true
        Write-JrsStep -Run $child -Step "import:/reports/t/d" -State SUCCEEDED -Compensation @{ type = "delete"; uri = "/reports/t/d" }
        Complete-JrsRun -Run $child -Status SUCCEEDED
        (Get-Content (Join-Path $parent.Dir "run.json") -Raw | ConvertFrom-Json).status | Should Be "RUNNING"
        $Global:JrsCurrentRun.RunId | Should Be $parent.RunId
        @(Get-Content (Join-Path $parent.Dir "transitions.jsonl")).Count | Should Be 1
    }

    It "plan-mode runs are not journaled to disk" {
        $run = New-JrsRun -Operation "promote" -Target $script:Target -Mode plan
        $run.RunId | Should Be $null
        Write-JrsStep -Run $run -Step "x" -State SUCCEEDED
        Complete-JrsRun -Run $run -Status SUCCEEDED
        @(Get-ChildItem $script:Runs).Count | Should Be 0
    }

    It "Get-JrsRun reads a run back by id or 'latest' and Get-JrsRuns lists newest first" {
        $a = New-JrsRun -Operation "one" -Target $script:Target -Mode apply
        Complete-JrsRun -Run $a -Status SUCCEEDED
        Start-Sleep -Milliseconds 1100
        $b = New-JrsRun -Operation "two" -Target $script:Target -Mode apply
        Write-JrsStep -Run $b -Step "s" -State SUCCEEDED
        Complete-JrsRun -Run $b -Status FAILED -ExitCode 4
        (Get-JrsRun -RunId $a.RunId).Operation | Should Be "one"
        $latest = Get-JrsRun -RunId latest
        $latest.RunId | Should Be $b.RunId
        $latest.Transitions.Count | Should Be 1
        @(Get-JrsRuns)[0].RunId | Should Be $b.RunId
        @(Get-JrsRuns).Count | Should Be 2
    }

    It "Get-JrsRollbackPlan returns compensations newest-first for steps that ran, skipping compensated and irreversible ones" {
        $run = New-JrsRun -Operation "promote" -Target $script:Target -Mode apply
        Write-JrsStep -Run $run -Step "1" -State SUCCEEDED -Compensation @{ type = "reimport"; zip = "a.zip" }
        Write-JrsStep -Run $run -Step "2" -State SUCCEEDED -Compensation @{ type = "delete"; uri = "/r/new" }
        Write-JrsStep -Run $run -Step "3" -State SUCCEEDED -Irreversible "no backup"
        Write-JrsStep -Run $run -Step "4" -State RUNNING -Compensation @{ type = "delete"; uri = "/r/half" }
        Write-JrsStep -Run $run -Step "4" -State FAILED -Detail "HTTP 500"
        Write-JrsStep -Run $run -Step "0" -State COMPENSATED
        Write-JrsStep -Run $run -Step "5" -State SKIPPED -Compensation @{ type = "delete"; uri = "/r/never" }
        Complete-JrsRun -Run $run -Status FAILED -ExitCode 4
        $plan = @(Get-JrsRollbackPlan -Run (Get-JrsRun -RunId $run.RunId))
        ($plan | ForEach-Object { $_.Step }) -join "," | Should Be "4,2,1"
        $plan[0].Compensation.uri | Should Be "/r/half"
        $plan[2].Compensation.zip | Should Be "a.zip"
    }

    It "Get-JrsRollbackPlan excludes a step already COMPENSATED in a later transition" {
        $run = New-JrsRun -Operation "promote" -Target $script:Target -Mode apply
        Write-JrsStep -Run $run -Step "1" -State SUCCEEDED -Compensation @{ type = "delete"; uri = "/r/a" }
        Write-JrsStep -Run $run -Step "2" -State SUCCEEDED -Compensation @{ type = "delete"; uri = "/r/b" }
        Write-JrsStep -Run $run -Step "2" -State COMPENSATED
        Complete-JrsRun -Run $run -Status ROLLBACK_INCOMPLETE -ExitCode 4
        $plan = @(Get-JrsRollbackPlan -Run (Get-JrsRun -RunId $run.RunId))
        $plan.Count | Should Be 1
        $plan[0].Step | Should Be "1"
    }
}
