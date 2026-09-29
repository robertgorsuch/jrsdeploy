# Pester 3.x (Windows-bundled 3.4.0) unit tests for the offline/pure helpers in
# scripts\_jrs_common.ps1. NO live server is contacted -- only Get-GotchaHint,
# Resolve-JrsConfig (env-var path) and Assert-JrsOk are exercised.

. "$PSScriptRoot/../scripts/_jrs_common.ps1"

Describe "Get-GotchaHint" {
    It "returns the strict-Jackson hint for UnrecognizedPropertyException" {
        $h = Get-GotchaHint -Code '400' -Body 'com.fasterxml...UnrecognizedPropertyException: foo'
        $h | Should Match 'strict-Jackson'
    }
    It "returns the dashboards hint for resource.in.use" {
        $h = Get-GotchaHint -Code '400' -Body 'error: resource.in.use somewhere'
        $h | Should Match 'dashlet'
    }
    It "returns the SQL hint for JSSecurityException" {
        $h = Get-GotchaHint -Code '400' -Body 'net.sf...JSSecurityException at validateSQL'
        $h | Should Match 'SELECT'
    }
    It "returns empty string for an unmatched body" {
        $h = Get-GotchaHint -Code '200' -Body 'everything is fine'
        $h | Should Be ''
    }
}

Describe "Resolve-JrsConfig env-var precedence" {
    AfterEach {
        Remove-Item Env:JRS_URL  -ErrorAction SilentlyContinue
        Remove-Item Env:JRS_USER -ErrorAction SilentlyContinue
        Remove-Item Env:JRS_PASS -ErrorAction SilentlyContinue
    }

    It "reads ServerUrl/User/Password from env vars and trims a trailing slash" {
        $env:JRS_URL  = 'http://jrs.example:8080/'
        $env:JRS_USER = 'envuser'
        $env:JRS_PASS = 'envpass'
        $cfg = Resolve-JrsConfig
        $cfg.ServerUrl | Should Be 'http://jrs.example:8080'
        $cfg.User      | Should Be 'envuser'
        $cfg.Password  | Should Be 'envpass'
    }

    It "lets the -ServerUrl param override the env var" {
        $env:JRS_URL  = 'http://from-env:8080'
        $env:JRS_USER = 'envuser'
        $env:JRS_PASS = 'envpass'
        $cfg = Resolve-JrsConfig -ServerUrl 'http://from-param:9090'
        $cfg.ServerUrl | Should Be 'http://from-param:9090'
    }
}

Describe "Resolve-JrsConfig named environment profiles" {
    # These tests only run meaningfully when the local (gitignored)
    # jrs.config.json defines an "environments" block; the unknown-name test
    # works either way.
    AfterEach {
        Remove-Item Env:JRS_ENV -ErrorAction SilentlyContinue
        Remove-Item Env:JRS_URL -ErrorAction SilentlyContinue
    }

    It "throws (listing defined names) for an unknown profile" {
        { Resolve-JrsConfig -Env definitely_not_a_real_env } | Should Throw
    }

    It "honors `$env:JRS_ENV and ignores a stale JRS_URL while a profile is active" {
        $cfgPath = "$PSScriptRoot/../jrs.config.json"
        if (-not (Test-Path $cfgPath)) { return }   # config-less machine: skip
        $names = (Get-Content $cfgPath -Raw | ConvertFrom-Json).environments.PSObject.Properties.Name
        if (-not $names) { return }                 # no profiles defined: skip
        $env:JRS_ENV = $names[0]
        $env:JRS_URL = 'http://stale-export:9/x'
        $cfg = Resolve-JrsConfig
        $cfg.ServerUrl | Should Not Be 'http://stale-export:9/x'
        $cfg.Env       | Should Be $names[0]
    }
}

Describe "Test-JrsResource / Assert-JrsResource (Invoke-JrsGet mocked)" {
    $fake = [pscustomobject]@{ ServerUrl = 'http://jrs.example:8080'; User = 'u'; Password = 'p'; Env = 'stage' }

    It "returns `$true only on HTTP 200" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '200'; Body = '{"uri":"/x"}' } }
        (Test-JrsResource -Jrs $fake -Uri '/reports/x') | Should Be $true
    }
    It "returns `$false on 404 (Invoke-JrsGet does not throw, so a bare truthiness test would pass)" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '404'; Body = 'resource.does.not.exist' } }
        (Test-JrsResource -Jrs $fake -Uri '/reports/missing') | Should Be $false
    }
    It "returns `$false on a non-200 success-ish code (204) and on 000 (no response)" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '000'; Body = '' } }
        (Test-JrsResource -Jrs $fake -Uri '/reports/x') | Should Be $false
    }
    It "prefixes a missing leading slash" {
        Mock Invoke-JrsGet { param($Jrs, $Uri) [pscustomobject]@{ Code = $(if ($Uri -eq '/reports/x') { '200' } else { '404' }); Body = '' } }
        (Test-JrsResource -Jrs $fake -Uri 'reports/x') | Should Be $true
    }
    It "Assert-JrsResource returns the URI when it exists" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '200'; Body = '{}' } }
        Assert-JrsResource -Jrs $fake -Uri '/reports/x' | Should Be '/reports/x'
    }
    It "Assert-JrsResource throws naming server, env, uri and code when absent" {
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '404'; Body = '' } }
        $err = $null
        try { Assert-JrsResource -Jrs $fake -Uri '/reports/missing' -What 'report unit' } catch { $err = $_.Exception.Message }
        $err | Should Match 'report unit not found'
        $err | Should Match 'jrs\.example:8080'
        $err | Should Match 'env stage'
        $err | Should Match '/reports/missing'
        $err | Should Match 'HTTP 404'
    }
}

Describe "Get-JrsDashboardsReferencing (REST mocked)" {
    $fake = [pscustomobject]@{ ServerUrl = 'http://jrs.example:8080'; User = 'u'; Password = 'p'; Env = '' }
    $script:dashA = '{"uri":"/d/a","resources":[{"name":"t","type":"reportUnit","resource":{"resourceReference":{"uri":"/reports/x","version":0}}}]}'
    $script:dashB = '{"uri":"/d/b","resources":[{"name":"t","type":"reportUnit","resource":{"resourceReference":{"uri":"/reports/y","version":0}}}]}'

    It "lists only the dashboards whose descriptor references the uri" {
        Mock Invoke-JrsRest { [pscustomobject]@{ Code = '200'; Body = '{"resourceLookup":[{"uri":"/d/a","resourceType":"dashboard"},{"uri":"/d/b","resourceType":"dashboard"}]}' } }
        Mock Invoke-JrsGet { param($Jrs, $Uri) [pscustomobject]@{ Code = '200'; Body = $(if ($Uri -eq '/d/a') { $script:dashA } else { $script:dashB }) } }
        $hits = @(Get-JrsDashboardsReferencing -Jrs $fake -Uri '/reports/x')
        $hits.Count | Should Be 1
        $hits[0]    | Should Be '/d/a'
    }
    It "returns an empty array when the search fails or nothing matches" {
        Mock Invoke-JrsRest { [pscustomobject]@{ Code = '500'; Body = 'boom' } }
        @(Get-JrsDashboardsReferencing -Jrs $fake -Uri '/reports/x').Count | Should Be 0
        Mock Invoke-JrsRest { [pscustomobject]@{ Code = '200'; Body = '{"resourceLookup":[{"uri":"/d/b"}]}' } }
        Mock Invoke-JrsGet { [pscustomobject]@{ Code = '200'; Body = $script:dashB } }
        @(Get-JrsDashboardsReferencing -Jrs $fake -Uri '/reports/x').Count | Should Be 0
    }
}

Describe "New-JrsDeployResult (deploy_report.ps1 pipeline object)" {
    It "has exactly the documented properties with sane defaults" {
        $r = New-JrsDeployResult -Uri '/reports/x' -Code 201
        ($r.PSObject.Properties.Name -join ',') | Should Be 'Uri,Code,Status,ControlsAttached,Message'
        $r.Uri | Should Be '/reports/x'
        $r.Code | Should Be '201'
        $r.Status | Should Be 'OK'
        $r.ControlsAttached | Should Be 0
    }
    It "rejects a Status outside OK|FAIL" {
        { New-JrsDeployResult -Uri '/x' -Status 'MAYBE' } | Should Throw
    }
}

Describe "Assert-JrsOk" {
    It "returns the response on a 2xx code" {
        $r = Assert-JrsOk -Response @{ Code = '200'; Body = 'ok' } -Operation 'x'
        $r.Code | Should Be '200'
        $r.Body | Should Be 'ok'
    }
    It "throws on a non-2xx code" {
        { Assert-JrsOk -Response @{ Code = '404'; Body = 'nope' } -Operation 'x' } | Should Throw
    }
}
