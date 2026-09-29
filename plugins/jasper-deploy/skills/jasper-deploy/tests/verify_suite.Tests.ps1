# Pester 3.x/4.x (legacy `Should Be` syntax) offline tests for
# scripts\verify_suite.ps1: manifest discovery (file / glob / directory),
# report-dashlet + filter parsing, local jrxml lookup and the -Offline
# pass/fail table + exit code. No server is contacted (-Offline).

$script:Script = "$PSScriptRoot/../scripts/verify_suite.ps1"

function New-Fixture {
    # builds <tmp>/vs_<guid>/ with two manifests + one non-manifest json + jrxmls
    $root = Join-Path ([IO.Path]::GetTempPath()) ("vs_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force $root | Out-Null
    $jrxml = '<?xml version="1.0" encoding="UTF-8"?><jasperReport name="x"/>'
    Set-Content (Join-Path $root 'tile_a.jrxml') $jrxml -Encoding utf8
    Set-Content (Join-Path $root 'tile_b.jrxml') $jrxml -Encoding utf8
    @'
{
  "folder": "/reports/suite",
  "name": "board_one",
  "label": "Board One",
  "filters": ["p_from", "p_to"],
  "dashlets": [
    { "resource": "/reports/suite/tile_a", "label": "A", "x": 0, "y": 0, "width": 20, "height": 10 },
    { "name": "tile_b", "label": "B", "x": 20, "y": 0, "width": 20, "height": 10 },
    { "kind": "text", "name": "hdr", "text": "hello", "x": 0, "y": 10, "width": 40, "height": 2 }
  ]
}
'@ | Set-Content (Join-Path $root 'one_dashboard.json') -Encoding utf8
    @'
{
  "folder": "/reports/suite",
  "name": "board_two",
  "filterControlFolder": "/reports/suite/ctl",
  "filters": ["p_x"],
  "dashlets": [
    { "resource": "/reports/suite/tile_missing", "label": "M", "x": 0, "y": 0, "width": 40, "height": 10 }
  ]
}
'@ | Set-Content (Join-Path $root 'two_dashboard.json') -Encoding utf8
    @'
{ "properties": { "dashlets": { "type": "array" } }, "title": "not a manifest" }
'@ | Set-Content (Join-Path $root 'schema_like.json') -Encoding utf8
    return $root
}

function Invoke-Suite {
    param([string[]]$Manifest, [hashtable]$Extra = @{})
    $rows = & $script:Script -Manifest $Manifest -Offline @Extra 6>$null
    [pscustomobject]@{ Rows = @($rows); Exit = $LASTEXITCODE }
}

Describe "verify_suite.ps1 -Offline" {

    It "parses without syntax errors" {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:Script).Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should Be 0
    }

    It "single manifest: one local_jrxml row per REPORT dashlet (text tile skipped), resource or folder/name, filters listed" {
        $root = New-Fixture
        try {
            $r = Invoke-Suite -Manifest (Join-Path $root 'one_dashboard.json')
            $r.Exit | Should Be 0
            $jr = @($r.Rows | Where-Object { $_.Check -eq 'local_jrxml' })
            $jr.Count | Should Be 2
            ($jr | ForEach-Object { $_.Target }) -join ',' | Should Be '/reports/suite/tile_a,/reports/suite/tile_b'
            ($jr | ForEach-Object { $_.Status }) -join ',' | Should Be 'PASS,PASS'
            $jr[0].Dashboard | Should Be '/reports/suite/board_one'
            $jr[0].LocalFile | Should Match 'tile_a\.jrxml$'
            $ctl = @($r.Rows | Where-Object { $_.Check -eq 'control_expected' })
            ($ctl | ForEach-Object { $_.Target }) -join ',' | Should Be '/reports/suite/controls/p_from,/reports/suite/controls/p_to'
            ($ctl | ForEach-Object { $_.Status }) -join ',' | Should Be 'SKIP,SKIP'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "missing local jrxml is a FAIL and the exit code is 1; filterControlFolder is honored" {
        $root = New-Fixture
        try {
            $r = Invoke-Suite -Manifest (Join-Path $root 'two_dashboard.json')
            $r.Exit | Should Be 1
            $f = @($r.Rows | Where-Object { $_.Status -eq 'FAIL' })
            $f.Count | Should Be 1
            $f[0].Check  | Should Be 'local_jrxml'
            $f[0].Target | Should Be '/reports/suite/tile_missing'
            $f[0].Detail | Should Match 'no local jrxml'
            ($r.Rows | Where-Object { $_.Check -eq 'control_expected' } | ForEach-Object { $_.Target }) | Should Be '/reports/suite/ctl/p_x'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "directory input picks up only real manifests (schema-like json ignored)" {
        $root = New-Fixture
        try {
            $r = Invoke-Suite -Manifest $root
            ($r.Rows | ForEach-Object { $_.Manifest } | Sort-Object -Unique) -join ',' | Should Be 'one_dashboard.json,two_dashboard.json'
            $r.Exit | Should Be 1     # board_two's missing jrxml
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "glob input works and -FailFast stops after the first FAIL" {
        $root = New-Fixture
        try {
            $r = Invoke-Suite -Manifest (Join-Path $root 'two_*.json') -Extra @{ FailFast = $true }
            $r.Exit | Should Be 1
            @($r.Rows).Count | Should Be 1
            $r.Rows[0].Status | Should Be 'FAIL'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "-Out writes csv and json result files" {
        $root = New-Fixture
        try {
            $csv = Join-Path $root 'res.csv'; $json = Join-Path $root 'res.json'
            Invoke-Suite -Manifest (Join-Path $root 'one_dashboard.json') -Extra @{ Out = $csv } | Out-Null
            Invoke-Suite -Manifest (Join-Path $root 'one_dashboard.json') -Extra @{ Out = $json } | Out-Null
            (Test-Path $csv)  | Should Be $true
            (Test-Path $json) | Should Be $true
            @(Import-Csv $csv).Count | Should Be 4
            @((Get-Content $json -Raw | ConvertFrom-Json)).Count | Should Be 4
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "throws on a manifest path that does not exist" {
        { & $script:Script -Manifest (Join-Path ([IO.Path]::GetTempPath()) 'no_such_manifest_dir_xyz') -Offline 6>$null } | Should Throw
    }

    It "the repo's own report/pos_perf manifests all resolve their git jrxml (when present)" {
        $dir = Join-Path $PSScriptRoot '../../../../../report/pos_perf'
        if (-not (Test-Path $dir)) { return }   # skill used outside this repo: skip
        $r = Invoke-Suite -Manifest $dir
        $r.Exit | Should Be 0
        @($r.Rows | Where-Object { $_.Check -eq 'local_jrxml' -and $_.Status -ne 'PASS' }).Count | Should Be 0
    }
}
