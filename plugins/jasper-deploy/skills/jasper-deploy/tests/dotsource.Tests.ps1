# Guards against the dot-source/param() trap that let `promote.ps1 -WhatIf`
# write to the target server: dot-sourcing a script that declares param()
# re-binds those parameters (e.g. $WhatIf, $Env) to defaults in the caller.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Join-Path (Split-Path -Parent $here) "scripts"

Describe "dot-source safety" {
    $files = Get-ChildItem $scripts -Filter *.ps1
    $withParam = @{}
    foreach ($f in $files) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $withParam[$f.Name] = [bool]$ast.ParamBlock
    }
    foreach ($f in $files) {
        $src = Get-Content $f.FullName -Raw
        $targets = [regex]::Matches($src, '(?m)^\s*\.\s+\(Join-Path\s+\$PSScriptRoot\s+"([^"]+\.ps1)"\)') | ForEach-Object { $_.Groups[1].Value }
        foreach ($t in $targets) {
            It "$($f.Name) does not dot-source $t (which has a param() block)" {
                $withParam[$t] | Should Be $false
            }
        }
    }
    It "_controls_common.ps1 has no param block" { $withParam["_controls_common.ps1"] | Should Be $false }
    It "promote.ps1 keeps -WhatIf after dot-sourcing its helpers" {
        $src = Get-Content (Join-Path $scripts "promote.ps1") -Raw
        $src | Should Not Match '\.\s+\(Join-Path\s+\$PSScriptRoot\s+"ensure_controls\.ps1"\)'
    }
}
