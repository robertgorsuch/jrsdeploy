# Pester 3.x/4.x (legacy `Should Be` syntax; CI installs Pester 4 for pwsh)
# tests for scripts\lint_jrxml.ps1. Each test writes a temporary fixture to the
# platform temp dir, runs the linter against it (capturing all streams +
# $LASTEXITCODE), then removes the fixture.

$script:Linter = "$PSScriptRoot/../scripts/lint_jrxml.ps1"

function Invoke-Linter($file) {
    $out = & $script:Linter -Path $file *>&1
    [pscustomobject]@{ Output = ($out | Out-String -Width 4000); Exit = $LASTEXITCODE }
}

Describe "lint_jrxml.ps1" {

    It "flags a .jrtx with isDefault true (exit 1, jrtx-default-attr)" {
        $f = Join-Path ([IO.Path]::GetTempPath())("lint_jrtx_{0}.jrtx" -f ([guid]::NewGuid().ToString('N')))
        @'
<?xml version="1.0" encoding="UTF-8"?>
<jasperTemplate>
  <style name="Base" isDefault="true" forecolor="#000000"/>
</jasperTemplate>
'@ | Set-Content -LiteralPath $f -Encoding ASCII
        try {
            $r = Invoke-Linter $f
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'jrtx-default-attr'
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }

    It "flags an area chart plot with tick props (exit 1, areaplot-plot-props)" {
        $f = Join-Path ([IO.Path]::GetTempPath())("lint_area_{0}.jrxml" -f ([guid]::NewGuid().ToString('N')))
        @'
<?xml version="1.0" encoding="UTF-8"?>
<jasperReport name="r">
  <summary>
    <band height="200">
      <element kind="chart" chartType="area">
        <plot showTickMarks="true"/>
      </element>
    </band>
  </summary>
</jasperReport>
'@ | Set-Content -LiteralPath $f -Encoding ASCII
        try {
            $r = Invoke-Linter $f
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'areaplot-plot-props'
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }

    It "manifest: warns when filters set without filterFloating (manifest-filter-floating)" {
        $f = Join-Path ([IO.Path]::GetTempPath())("lint_man_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        @'
{ "folder": "/reports/pos", "name": "board", "label": "Board", "dataSourceUri": "/ds/x",
  "filters": ["p_from", "p_to"],
  "dashlets": [ {"name": "tile_a", "query": "SELECT 1"}, {"name": "tile_b", "query": "SELECT 2"} ] }
'@ | Set-Content -LiteralPath $f -Encoding ASCII
        try {
            $r = Invoke-Linter $f
            $r.Exit   | Should Be 0
            $r.Output | Should Match 'manifest-filter-floating'
            $r2 = & $script:Linter -Manifest $f -WarningsAsErrors *>&1
            $LASTEXITCODE | Should Be 1
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }

    It "manifest: flags a dashlet outside the folder and duplicate names (exit 1)" {
        $f = Join-Path ([IO.Path]::GetTempPath())("lint_man2_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        @'
{ "folder": "/reports/pos", "name": "board", "filterFloating": false, "filters": ["p_from"],
  "controls": {"future": "key tolerated"},
  "dashlets": [
    {"name": "tile_a", "resource": "/reports/other/tile_a"},
    {"name": "tile_a", "resource": "/reports/pos/tile_a"},
    {"kind": "text", "name": "hdr", "text": "x"},
    {"kind": "image", "name": "logo", "url": "repo:/images/actian_logo"} ] }
'@ | Set-Content -LiteralPath $f -Encoding ASCII
        try {
            $r = Invoke-Linter $f
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'manifest-dashlet-outside-folder'
            $r.Output | Should Match 'manifest-duplicate-dashlet'
            $r.Output | Should Not Match 'manifest-filter-floating'
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }

    It "manifest: passes a clean manifest and flags invalid JSON / missing keys" {
        $ok  = Join-Path ([IO.Path]::GetTempPath())("lint_man3_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $bad = Join-Path ([IO.Path]::GetTempPath())("lint_man4_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        '{ "folder": "/reports/pos", "name": "b", "dashlets": [ {"name": "t1", "query": "SELECT 1"} ] }' | Set-Content -LiteralPath $ok -Encoding ASCII
        '{ "name": "b", "dashlets": [ { "name": "t1" } ' | Set-Content -LiteralPath $bad -Encoding ASCII
        try {
            $r = Invoke-Linter $ok
            $r.Exit | Should Be 0
            $r = Invoke-Linter $bad
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'manifest-invalid-json'
            '{ "name": "b", "dashlets": [ { "name": "t1" } ] }' | Set-Content -LiteralPath $bad -Encoding ASCII
            $r = Invoke-Linter $bad
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'manifest-missing-key'
        } finally { Remove-Item $ok, $bad -ErrorAction SilentlyContinue }
    }

    It "passes a clean minimal .jrxml (exit 0)" {
        $f = Join-Path ([IO.Path]::GetTempPath())("lint_clean_{0}.jrxml" -f ([guid]::NewGuid().ToString('N')))
        @'
<?xml version="1.0" encoding="UTF-8"?>
<jasperReport name="clean">
  <detail>
    <band height="20">
      <element kind="staticText"/>
    </band>
  </detail>
</jasperReport>
'@ | Set-Content -LiteralPath $f -Encoding ASCII
        try {
            $r = Invoke-Linter $f
            $r.Exit | Should Be 0
        } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}
