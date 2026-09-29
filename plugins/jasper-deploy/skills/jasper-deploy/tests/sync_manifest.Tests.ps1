# Pester 3.x/4.x (legacy `Should Be` syntax) round-trip tests for
# scripts\gen_dashboard.py + scripts\sync_manifest.py: a manifest generated to
# an archive, synced back into the manifest, and generated again must yield the
# SAME companion files (layout / components.data / wiring.data). No server.

# A caller such as smoke_test.ps1 runs Pester under $ErrorActionPreference = 'Stop';
# PS 5.1 then turns a child's stderr (curl: (7) ..., python WARN: ...) into a terminating
# error. These tests expect that stderr, so pin the preference for this file.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot/../scripts/_jrs_common.ps1"      # Get-JrsPython
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Gen  = "$PSScriptRoot/../scripts/gen_dashboard.py"
$script:Sync = "$PSScriptRoot/../scripts/sync_manifest.py"
$script:Py   = Get-JrsPython
$script:HasPython = [bool](Get-Command $script:Py -ErrorAction SilentlyContinue)

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("sync_t_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}

function Read-ZipEntries($zip) {
    # companion files only (the descriptor carries timestamps)
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $out = @{}
        foreach ($e in $z.Entries) {
            if ($e.FullName -match '_files/(components\.data|layout|wiring\.data)$') {
                $sr = New-Object IO.StreamReader($e.Open()); try { $out[$matches[1]] = $sr.ReadToEnd() } finally { $sr.Dispose() }
            }
        }
        return $out
    } finally { $z.Dispose() }
}

$script:ManifestJson = @'
{
  "folder": "/reports/t",
  "name": "rt_dash",
  "label": "Round Trip",
  "autoRefresh": true,
  "showExportButton": true,
  "canvasColor": "#000032",
  "filters": ["p_asof", "p_regions"],
  "filterButtonsPosition": "right",
  "filterStripHeight": 4,
  "outDir": "report\\t",
  "dashlets": [
    { "resource": "/reports/t/kpi", "label": "Key Metrics", "scaleToFit": "container", "showTitleBar": false, "x": 0, "y": 0, "width": 40, "height": 4, "queryFile": "report\\t\\kpi.sql" },
    { "resource": "/reports/t/trend", "label": "Trend", "scaleToFit": "width", "showTitleBar": true, "x": 0, "y": 4, "width": 20, "height": 10 },
    { "kind": "text", "name": "Hdr", "text": "Hello", "size": 18, "bold": true, "align": "center", "italic": false, "color": "rgba(0, 0, 0, 1)", "background": "rgba(0, 0, 0, 0)", "valign": "top", "x": 20, "y": 4, "width": 20, "height": 3 }
  ]
}
'@

Describe "sync_manifest.py round-trip with gen_dashboard.py" {
    if (-not $script:HasPython) {
        It "is skipped (no python launcher on this machine)" { $true | Should Be $true }
        return
    }
    $dir = New-TempDir
    $m1 = Join-Path $dir "m1.json"; $z1 = Join-Path $dir "z1.zip"
    $m2 = Join-Path $dir "m2.json"; $z2 = Join-Path $dir "z2.zip"
    Set-Content -LiteralPath $m1 -Value $script:ManifestJson -Encoding ASCII

    It "gen -> sync(--merge) -> gen is a fixed point on the companion files" {
        & $script:Py $script:Gen --manifest $m1 --out $z1 | Out-Null
        $LASTEXITCODE | Should Be 0
        Copy-Item $m1 $m2
        & $script:Py $script:Sync --zip $z1 --merge $m2 --out $m2 | Out-Null
        $LASTEXITCODE | Should Be 0
        & $script:Py $script:Gen --manifest $m2 --out $z2 | Out-Null
        $LASTEXITCODE | Should Be 0
        $a = Read-ZipEntries $z1; $b = Read-ZipEntries $z2
        $b["layout"]          | Should Be $a["layout"]
        $b["components.data"] | Should Be $a["components.data"]
        $b["wiring.data"]     | Should Be $a["wiring.data"]
    }

    It "merge preserves non-layout keys, key order and the manifest label; syncs presentation keys" {
        $j = (Get-Content $m2 -Raw) | ConvertFrom-Json
        $j.outDir | Should Be "report\t"
        $j.dashlets[0].queryFile | Should Be "report\t\kpi.sql"
        $j.dashlets[0].label | Should Be "Key Metrics"
        $j.dashlets[0].scaleToFit | Should Be "container"
        $j.dashlets[0].showTitleBar | Should Be $false
        $j.dashlets[1].showTitleBar | Should Be $true
        $j.dashlets[1].y | Should Be 4                       # strip offset removed again
        $j.dashlets[2].kind | Should Be "text"
        $j.dashlets[2].text | Should Be "Hello"
        $j.autoRefresh | Should Be $true
        $j.showExportButton | Should Be $true
        $j.canvasColor | Should Be "#000032"
        $j.filters.Count | Should Be 2
        $j.filterButtonsPosition | Should Be "right"
        $j.filterFloating | Should Be $false                 # docked (a8503f2)
        $j.filterStripHeight | Should Be 4
        $j.filterControlFolder | Should Be "/reports/t/controls"
        ((Get-Content $m2 -Raw) -split "`n")[1] | Should Match '"folder"'   # key order kept
    }

    It "--dry-run writes nothing" {
        $m3 = Join-Path $dir "m3.json"
        '{ "folder": "/reports/t", "name": "rt_dash", "dashlets": [ { "resource": "/reports/t/kpi", "x": 0, "y": 0, "width": 10, "height": 10 } ] }' | Set-Content -LiteralPath $m3 -Encoding ASCII
        $before = Get-Content $m3 -Raw
        $out = & $script:Py $script:Sync --zip $z1 --merge $m3 --dry-run 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        (Get-Content $m3 -Raw) | Should Be $before
        $out | Should Match 'dry-run'
        $out | Should Match '(?m)^\+.*"filters"'
    }

    It "writes a fresh manifest with --out that regenerates the same layout" {
        $m4 = Join-Path $dir "m4.json"; $z4 = Join-Path $dir "z4.zip"
        & $script:Py $script:Sync --zip $z1 --out $m4 | Out-Null
        $LASTEXITCODE | Should Be 0
        & $script:Py $script:Gen --manifest $m4 --out $z4 | Out-Null
        $LASTEXITCODE | Should Be 0
        (Read-ZipEntries $z4)["layout"] | Should Be (Read-ZipEntries $z1)["layout"]
    }

    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
