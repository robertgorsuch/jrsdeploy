# Pester 3.x/4.x (legacy `Should Be` syntax) tests for the write guard in
# scripts\_jrs_common.ps1: plan mode and the PROD guard live BELOW the scripts,
# inside Invoke-JrsPut / Invoke-JrsDelete / Invoke-JrsRest, so a script that
# forgets (or whose -Apply switch was clobbered) cannot write. No live server:
# every request that gets past the guard targets 127.0.0.1:9 (nothing listens)
# and comes back as HTTP 000.

. "$PSScriptRoot/../scripts/_jrs_common.ps1"
# A caller such as smoke_test.ps1 runs Pester under $ErrorActionPreference = 'Stop';
# PS 5.1 then turns a child's stderr (curl: (7) ..., python WARN: ...) into a terminating
# error. These tests expect that stderr, so pin the preference for this file.
$ErrorActionPreference = 'Continue'

$script:Dead = [pscustomobject]@{ ServerUrl = "http://127.0.0.1:9/jasperserver-pro"; User = "u"; Password = "p"; Env = $null; IsProd = $false }
$script:Prod = [pscustomobject]@{ ServerUrl = "http://127.0.0.1:9/jasperserver-pro"; User = "u"; Password = "p"; Env = "prod"; IsProd = $true }

function Reset-Guard {
    $Global:JrsPlanMode = $null
    [Environment]::SetEnvironmentVariable("JRS_ALLOW_PROD_WRITE", $null)
}

Describe "plan mode (Enter-JrsPlanMode / Restore-JrsPlanMode)" {
    BeforeEach { Reset-Guard }
    AfterEach  { Reset-Guard }

    It "is off by default so existing create-style scripts keep working" {
        $Global:JrsPlanMode | Should Be $null
        (Test-JrsPlanMode) | Should Be $false
    }

    It "Enter-JrsPlanMode without -Apply turns plan mode on and returns the previous state" {
        $prev = Enter-JrsPlanMode -Apply:$false
        $prev | Should Be $null
        (Test-JrsPlanMode) | Should Be $true
    }

    It "Enter-JrsPlanMode -Apply leaves plan mode off when no parent is planning" {
        Enter-JrsPlanMode -Apply:$true | Out-Null
        (Test-JrsPlanMode) | Should Be $false
    }

    It "a child called with -Apply cannot escape a parent's plan mode" {
        Enter-JrsPlanMode -Apply:$false | Out-Null
        $prev = Enter-JrsPlanMode -Apply:$true
        $prev | Should Be $true
        (Test-JrsPlanMode) | Should Be $true
    }

    It "Restore-JrsPlanMode puts the previous state back" {
        $prev = Enter-JrsPlanMode -Apply:$false
        Restore-JrsPlanMode $prev
        $Global:JrsPlanMode | Should Be $null
    }

    It "Invoke-JrsPut refuses in plan mode before any request is sent" {
        Enter-JrsPlanMode -Apply:$false | Out-Null
        $err = $null
        try { Invoke-JrsPut -Jrs $script:Dead -Uri /reports/x -ContentType application/json -JsonFile "nope.json" 6>$null } catch { $err = $_.Exception.Message }
        $err | Should Match 'PLAN MODE'
        $err | Should Match '-Apply'
    }

    It "Invoke-JrsDelete refuses in plan mode" {
        Enter-JrsPlanMode -Apply:$false | Out-Null
        { Invoke-JrsDelete -Jrs $script:Dead -Uri /reports/x } | Should Throw
    }

    It "Invoke-JrsRest refuses a POST import in plan mode but lets GET and export through" {
        Enter-JrsPlanMode -Apply:$false | Out-Null
        { Invoke-JrsRest -Jrs $script:Dead -Method POST -Path "/rest_v2/import?update=true" } | Should Throw
        (Invoke-JrsRest -Jrs $script:Dead -Method GET -Path "/rest_v2/serverInfo").Code | Should Be "000"
        (Invoke-JrsRest -Jrs $script:Dead -Method POST -Path "/rest_v2/export").Code | Should Be "000"
    }
}

Describe "PROD guard" {
    BeforeEach { Reset-Guard }
    AfterEach  { Reset-Guard }

    It "refuses a write to a prod target unless JRS_ALLOW_PROD_WRITE=1" {
        $err = $null
        try { Invoke-JrsDelete -Jrs $script:Prod -Uri /reports/x } catch { $err = $_.Exception.Message }
        $err | Should Match 'PROD GUARD'
        $err | Should Match 'JRS_ALLOW_PROD_WRITE'
    }

    It "lets the write through when JRS_ALLOW_PROD_WRITE=1 (request then reaches the network)" {
        [Environment]::SetEnvironmentVariable("JRS_ALLOW_PROD_WRITE", "1")
        (Invoke-JrsDelete -Jrs $script:Prod -Uri /reports/x) | Should Be "000"
    }

    It "plan mode wins over JRS_ALLOW_PROD_WRITE" {
        [Environment]::SetEnvironmentVariable("JRS_ALLOW_PROD_WRITE", "1")
        Enter-JrsPlanMode -Apply:$false | Out-Null
        { Invoke-JrsDelete -Jrs $script:Prod -Uri /reports/x } | Should Throw
    }

    It "never guards reads on prod" {
        (Invoke-JrsGet -Jrs $script:Prod -Uri /reports/x).Code | Should Be "000"
    }
}

Describe "Test-JrsProdTarget (pure)" {
    $cfg = [pscustomobject]@{
        serverUrl = "http://stage:8081/jasperserver-pro"
        environments = [pscustomobject]@{
            stage = [pscustomobject]@{ serverUrl = "http://stage:8081/jasperserver-pro" }
            prod  = [pscustomobject]@{ serverUrl = "http://PROD-HOST:8080/jasperserver-pro/" }
        }
    }
    It "is true for a profile named prod" { (Test-JrsProdTarget -Env "prod" -ServerUrl "http://x" -Config $cfg) | Should Be $true }
    It "is true for a profile named production" { (Test-JrsProdTarget -Env "production" -ServerUrl "http://x" -Config $cfg) | Should Be $true }
    It "is true for an explicit URL that equals the prod profile URL (case/slash-insensitive)" {
        (Test-JrsProdTarget -Env $null -ServerUrl "http://prod-host:8080/jasperserver-pro" -Config $cfg) | Should Be $true
    }
    It "is false for stage by name and by URL" {
        (Test-JrsProdTarget -Env "stage" -ServerUrl "http://stage:8081/jasperserver-pro" -Config $cfg) | Should Be $false
        (Test-JrsProdTarget -Env $null -ServerUrl "http://stage:8081/jasperserver-pro" -Config $cfg) | Should Be $false
    }
    It "is false with no config at all" { (Test-JrsProdTarget -Env $null -ServerUrl "http://x" -Config $null) | Should Be $false }
}
