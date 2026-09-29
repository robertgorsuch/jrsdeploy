# Pester 3.x/4.x (legacy `Should Be` syntax) tests for scripts\check_docs.ps1,
# focused on check 5 (junction / duplication guard). Each test builds a throwaway
# skill dir in the platform temp dir (SKILL.md + scripts\ + references\), points
# -ClaudeSkillDir at a sibling copy, and captures output + $LASTEXITCODE.

$script:Checker = "$PSScriptRoot/../scripts/check_docs.ps1"

function New-FakeSkill {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("cd_{0}" -f ([guid]::NewGuid().ToString('N')))
    $skill = Join-Path $root 'skill'
    New-Item -ItemType Directory -Path (Join-Path $skill 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $skill 'references') -Force | Out-Null
    'Write-Host hi' | Set-Content -LiteralPath (Join-Path $skill 'scripts/a.ps1') -Encoding ASCII
    @'
# fake skill

## Capability map

| Need | Script(s) | Notes |
|---|---|---|
| a | `a.ps1` | x |

'@ | Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Encoding ASCII
    return [pscustomobject]@{ Root = $root; Skill = $skill }
}

function Invoke-Checker([hashtable]$ArgMap) {
    $out = & $script:Checker @ArgMap *>&1
    [pscustomobject]@{ Output = ($out | Out-String -Width 4000); Exit = $LASTEXITCODE }
}

Describe "check_docs.ps1 junction guard" {

    It "passes when the .claude copy is absent (nothing to compare)" {
        $fs = New-FakeSkill
        try {
            $r = Invoke-Checker @{ SkillDir = $fs.Skill; ClaudeSkillDir = (Join-Path $fs.Root 'nope') }
            $r.Exit   | Should Be 0
            $r.Output | Should Match 'absent \(nothing to compare\)'
            $r.Output | Should Match '0 junction duplicate\(s\)'
        } finally { Remove-Item $fs.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "passes when a real-directory copy is byte-identical" {
        $fs = New-FakeSkill
        try {
            $copy = Join-Path $fs.Root 'copy'
            Copy-Item -LiteralPath $fs.Skill -Destination $copy -Recurse
            $r = Invoke-Checker @{ SkillDir = $fs.Skill; ClaudeSkillDir = $copy }
            $r.Exit   | Should Be 0
            $r.Output | Should Match 'real directory'
            $r.Output | Should Match 'byte-compared'
        } finally { Remove-Item $fs.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "fails when a real-directory copy diverges (changed + extra file)" {
        $fs = New-FakeSkill
        try {
            $copy = Join-Path $fs.Root 'copy'
            Copy-Item -LiteralPath $fs.Skill -Destination $copy -Recurse
            'Write-Host CHANGED' | Set-Content -LiteralPath (Join-Path $copy 'scripts/a.ps1') -Encoding ASCII
            'x' | Set-Content -LiteralPath (Join-Path $copy 'references/extra.md') -Encoding ASCII
            $r = Invoke-Checker @{ SkillDir = $fs.Skill; ClaudeSkillDir = $copy }
            $r.Exit   | Should Be 1
            $r.Output | Should Match 'DIVERGES'
            $r.Output | Should Match 'scripts/a.ps1'
            $r.Output | Should Match 'references/extra.md'
            $r.Output | Should Match '2 junction duplicate\(s\)'
        } finally { Remove-Item $fs.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "degrades gracefully outside a git checkout (skipped note, still exits 0)" {
        $fs = New-FakeSkill
        try {
            # the fake skill lives in the temp dir: no .git anywhere above it
            $r = Invoke-Checker @{ SkillDir = $fs.Skill; ClaudeSkillDir = (Join-Path $fs.Root 'nope') }
            $r.Exit   | Should Be 0
            $r.Output | Should Match 'tracked-duplicate check skipped'
        } finally { Remove-Item $fs.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "honours -SkipJunctionCheck" {
        $fs = New-FakeSkill
        try {
            $copy = Join-Path $fs.Root 'copy'
            Copy-Item -LiteralPath $fs.Skill -Destination $copy -Recurse
            'DIFFERENT' | Set-Content -LiteralPath (Join-Path $copy 'scripts/a.ps1') -Encoding ASCII
            $r = Invoke-Checker @{ SkillDir = $fs.Skill; ClaudeSkillDir = $copy; SkipJunctionCheck = $true }
            $r.Exit   | Should Be 0
            $r.Output | Should Match 'Junction guard: skipped'
        } finally { Remove-Item $fs.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "reports nothing tracked under .claude/skills/jasper-deploy in this repo (when run inside git)" {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { Set-TestInconclusive "git not on PATH" }
        $repo = (Resolve-Path "$PSScriptRoot/../../../..").Path
        $null = & git -C $repo rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) { Set-TestInconclusive "not a git checkout" }
        $tracked = @(& git -C $repo ls-files -- .claude/skills/jasper-deploy 2>$null | Where-Object { $_ })
        $tracked.Count | Should Be 0
    }
}
