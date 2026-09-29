# Pester 3.x/4.x (legacy `Should Be` syntax) tests for scripts\doctor.ps1.
# Fully offline: a temp jrs.config.json (-ConfigPath) points every URL at a
# closed loopback port and "jrsWebappDir" at a fake exploded webapp, so the
# chart-customizer SHA check, the repo-port parse and the per-profile
# reachability check are exercised without a server. doctor never aborts on a
# failing check, so the assertions are about the printed check lines.

$script:Doctor = "$PSScriptRoot/../scripts/doctor.ps1"
$script:Bundled = "$PSScriptRoot/../chart_customizers/actian-chart-customizers.jar"

function New-FakeWebapp([string]$root, [int]$port, [bool]$staleJar) {
    $web = Join-Path $root 'webapp'
    New-Item -ItemType Directory -Path (Join-Path $web 'META-INF') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $web 'WEB-INF/lib') -Force | Out-Null
    ('<Context><Resource name="jdbc/jasperserver" url="jdbc:postgresql://127.0.0.1:{0}/jasperserver" username="postgres"/></Context>' -f $port) |
        Set-Content -LiteralPath (Join-Path $web 'META-INF/context.xml') -Encoding ASCII
    $jar = Join-Path $web 'WEB-INF/lib/actian-chart-customizers.jar'
    if ($staleJar) { 'not the real jar' | Set-Content -LiteralPath $jar -Encoding ASCII }
    elseif (Test-Path $script:Bundled) { Copy-Item -LiteralPath $script:Bundled -Destination $jar }
    return $web
}

function Invoke-Doctor([string]$cfgPath) {
    # -ServerUrl/-User/-Password keep Resolve-JrsConfig away from the real skill config
    $out = & $script:Doctor -ConfigPath $cfgPath -ServerUrl 'http://127.0.0.1:9/jasperserver-pro' -User u -Password p -DbHost 127.0.0.1 *>&1
    [pscustomobject]@{ Output = ($out | Out-String -Width 4000); Exit = $LASTEXITCODE }
}

Describe "doctor.ps1 (offline)" {

    It "reports the repo DB port from context.xml, agrees with repoDb, matches the jar SHA, and probes each env profile" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("dr_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $web = New-FakeWebapp $root 5433 $false
            $cfg = Join-Path $root 'jrs.config.json'
            @{
                serverUrl = 'http://127.0.0.1:9/jasperserver-pro'; user = 'u'; password = 'p'
                jrsWebappDir = $web
                repoDb = @{ host = '127.0.0.1'; port = 5433; database = 'jasperserver'; user = 'postgres' }
                environments = @{
                    stage = @{ serverUrl = 'http://127.0.0.1:9/jasperserver-pro' }
                    prod  = @{ serverUrl = 'http://127.0.0.1:9/prod' ; user = 'x'; password = 'y' }
                }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg -Encoding ASCII
            $r = Invoke-Doctor $cfg
            $r.Output | Should Match 'PASS  jrs.config.json'
            $r.Output | Should Match 'repo DB port \(webapp config\)  --  META-INF/context.xml -> 127.0.0.1:5433/jasperserver'
            $r.Output | Should Match 'do not assume 5432'
            $r.Output | Should Match 'repoDb agrees'
            $r.Output | Should Match "WARN  env profile 'stage'"
            $r.Output | Should Match "WARN  env profile 'prod'"
            $r.Output | Should Match 'doctor: \d+ passed, \d+ warned, \d+ failed'
            if (Test-Path $script:Bundled) {
                $r.Output | Should Match 'PASS  chart-customizer jar  --  on classpath: .*SHA-256 matches bundled jar'
            }
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "warns on a stale chart-customizer jar and on a repoDb port that disagrees with context.xml" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("dr_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $web = New-FakeWebapp $root 5433 $true
            $cfg = Join-Path $root 'jrs.config.json'
            @{
                serverUrl = 'http://127.0.0.1:9/jasperserver-pro'; user = 'u'; password = 'p'
                jrsWebappDir = $web
                repoDb = @{ port = 5432; database = 'jasperserver' }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg -Encoding ASCII
            $r = Invoke-Doctor $cfg
            $r.Output | Should Match 'WARN  repo DB port \(webapp config\)  --  jrs.config.json repoDb says localhost:5432/jasperserver but META-INF/context.xml says 127.0.0.1:5433/jasperserver'
            if (Test-Path $script:Bundled) {
                $r.Output | Should Match 'WARN  chart-customizer jar  --  on classpath but STALE'
                $r.Output | Should Match 'restart Tomcat'
            }
            $r.Output | Should Match 'PASS  environment profiles  --  none defined'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "warns (not fails) when the webapp dir is unknown or missing" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("dr_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $cfg = Join-Path $root 'jrs.config.json'
            @{ serverUrl = 'http://127.0.0.1:9/jasperserver-pro'; user = 'u'; password = 'p'
               jrsWebappDir = (Join-Path $root 'missing-webapp') } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding ASCII
            $r = Invoke-Doctor $cfg
            $r.Output | Should Match 'WARN  repo DB port \(webapp config\)  --  webapp dir not found'
            $r.Output | Should Match 'WARN  chart-customizer jar  --  not located on JRS classpath'
            $r.Output | Should Match 'Expected at'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
