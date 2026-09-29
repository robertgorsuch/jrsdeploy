<#
.SYNOPSIS
  Documentation consistency checker for the jasper-deploy skill -- guards the
  lean SKILL.md index and its references/*.md against doc rot (dangling file
  links, capability-map scripts that no longer exist, stale step counts).

.DESCRIPTION
  SKILL.md is deliberately thin: it points at scripts\ and many references\*.md
  files. When a script is renamed or a reference is split, the index silently
  goes stale -- the link still reads fine but the target is gone. This script
  catches that offline, before it bites someone mid-deploy.

  Against the skill base dir (default: the skill root = parent of scripts\,
  overridable with -SkillDir) it runs five checks:

    1. Broken file links. Parses SKILL.md and every references\*.md for relative
       file references -- both markdown `[text](path)` links and inline-code
       paths like `references\X.md`, `scripts\Y.ps1`, `..\..\FILE.md` -- and
       asserts each target EXISTS on disk. http(s):// URLs, mailto:, anchor-only
       (#...) links, ellipsis abbreviations (.../foo) and templated tokens
       ($var, {id}) are ignored; only paths ending in a known local extension
       (.md .ps1 .py .json .wadl .xml .jrxml .jrtx .jrdax .png) are checked.
       A `..\..\X` style link resolves against the repo root; bare and
       references\ / scripts\ style paths resolve against the skill dir,
       references\ and scripts\.

    2. Capability-map scripts. Every .ps1/.py named in the backticked "Script(s)"
       column of SKILL.md's Capability map table must exist in scripts\.

    3. Stale step counts. The smoke gate is now 24 steps; any leftover
       "18/19/21-step" / "18/19/21 steps" / "each of the 18/19/21" prose is
       flagged (file + line).

    4. Script coverage. The inverse of check 2: every *.ps1 / *.py that exists
       in scripts\ must be MENTIONED somewhere in SKILL.md (capability map or
       prose). A script nobody indexed is invisible to a skill user -- this is
       how scaffold_kpi_dial.py, gen_dashboard.py, sync_manifest.py and
       pdf_verify.py once went missing from the map.

    5. Junction / duplication guard. The canonical skill source is
       plugins\jasper-deploy\skills\jasper-deploy; .claude\skills\jasper-deploy
       is only a local junction to it. Two failure modes are caught:
         a) files under .claude\skills\jasper-deploy tracked in git as a SEPARATE
            path (`git ls-files .claude/skills/jasper-deploy` must be empty --
            this is how commit f2184cf's duplicates crept in through the junction);
         b) .claude\skills\jasper-deploy exists as a REAL directory (not a
            junction/symlink) whose content diverges byte-for-byte from the
            plugin skill dir -- two copies silently drift apart.
       Degrades gracefully: skipped (not failed) when git is unavailable, the
       checkout is not a git repo, or the .claude path does not exist; runs the
       same on Windows (junction) and macOS/Linux (symlink).

  Prints a PASS/FAIL summary with counts (files scanned, links checked, broken).
  Exits 0 when clean, 1 if any broken link, missing capability-map script,
  stale step count, unindexed script, or junction duplicate is found -- so it
  slots into a docs/CI gate.

.PARAMETER SkillDir
  Skill base directory (the skill root holding SKILL.md, references\ and
  scripts\). Defaults to the parent of this script's folder.

.PARAMETER ClaudeSkillDir
  Override for the .claude\skills\jasper-deploy path used by check 5 (default:
  <repo root>\.claude\skills\jasper-deploy). Mainly for tests.

.PARAMETER SkipJunctionCheck
  Skip check 5 entirely.

.EXAMPLE
  & check_docs.ps1
  # check the skill this script lives in

.EXAMPLE
  & check_docs.ps1 -SkillDir <repo>\plugins\jasper-deploy\skills\jasper-deploy
  if ($LASTEXITCODE) { throw "skill docs are stale" }

.NOTES
  Exit code 0 = clean; 1 = at least one broken link / missing script / stale count.
#>
[CmdletBinding()]
param(
    [string]$SkillDir,
    [string]$ClaudeSkillDir,
    [switch]$SkipJunctionCheck
)

$ErrorActionPreference = 'Stop'

# --- locate the skill, references, scripts and repo root ----------------------
if (-not $SkillDir) { $SkillDir = Join-Path $PSScriptRoot '..' }
if (-not (Test-Path $SkillDir -PathType Container)) { throw "skill dir not found: $SkillDir" }
$SkillDir       = (Resolve-Path $SkillDir).Path
$referencesDir  = Join-Path $SkillDir 'references'
$scriptsDir     = Join-Path $SkillDir 'scripts'
$skillMd        = Join-Path $SkillDir 'SKILL.md'
if (-not (Test-Path $skillMd -PathType Leaf)) { throw "SKILL.md not found under $SkillDir" }

# repo root = nearest ancestor containing a tracked root marker. .claude/ is
# gitignored (exists locally, absent in CI checkouts), so test .git and
# .claude-plugin too; fall back to the known skill depth
# (plugins/jasper-deploy/skills/jasper-deploy = 4 levels below root).
$repoRoot = $null
$d = $SkillDir
while ($d) {
    $isRoot = (Test-Path (Join-Path $d '.git')) -or
              (Test-Path (Join-Path $d '.claude-plugin/marketplace.json') -PathType Leaf) -or
              (Test-Path (Join-Path $d '.claude') -PathType Container)
    if ($isRoot) { $repoRoot = $d; break }
    $parent = Split-Path $d -Parent
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
}
if (-not $repoRoot) { $repoRoot = (Resolve-Path (Join-Path $SkillDir '../../../..')).Path }

# known local-file extensions worth resolving (everything else is prose/URL)
$ExtPattern = '(?i)\.(md|ps1|py|json|wadl|xml|jrxml|jrtx|jrdax|png)$'

# --- helpers ------------------------------------------------------------------

# Expand a single brace list, e.g. references/{a,b}.md -> two paths.
function Expand-Braces([string]$s) {
    $m = [regex]::Match($s, '\{([^{}]+)\}')
    if (-not $m.Success) { return @($s) }
    $pre  = $s.Substring(0, $m.Index)
    $post = $s.Substring($m.Index + $m.Length)
    $out = @()
    foreach ($opt in ($m.Groups[1].Value -split ',')) {
        $out += Expand-Braces ($pre + $opt.Trim() + $post)
    }
    return $out
}

# Decide whether a raw token is a checkable local-file path; returns the cleaned
# path, or $null to skip (URL, anchor, ellipsis, templated, non-local ext).
# RequireSeparator: when set, the path must contain a / or \ -- this is how an
# inline-code REFERENCE (references/X.md, scripts/Y.ps1, ..\..\FILE.md) is told
# apart from a bare illustrative filename mentioned in prose (schema.xml,
# metro_population_piechart.jrxml, a lone .jrtx) that is not a link to a real
# file. Explicit markdown [text](path) links are always checked.
function Get-CheckablePath([string]$tok, [bool]$RequireSeparator) {
    if ([string]::IsNullOrWhiteSpace($tok)) { return $null }
    $t = $tok.Trim().Trim('"').Trim("'").Trim()
    if ($t -match '^(https?:|mailto:)' -or $t -match '://') { return $null }
    # drop a trailing anchor (#section); anchor-only links become empty
    $t = ($t -split '#', 2)[0]
    if ($t -eq '') { return $null }
    if ($t.StartsWith('./') -or $t.StartsWith('.\')) { $t = $t.Substring(2) }
    # ellipsis abbreviations like .../rest_v2/... are doc shorthand, not files
    if ($t.StartsWith('...') -or $t -match '\.\.\.[\\/]') { return $null }
    # templated / command-ish tokens (whitespace, $var, {id}, globs, pipes)
    if ($t -match '[\s\$\*<>\|"{}]') { return $null }
    if ($t -notmatch $ExtPattern) { return $null }
    if ($RequireSeparator -and $t -notmatch '[\\/]') { return $null }
    return $t
}

# Resolve a cleaned path to candidate absolute locations; valid if any exists.
function Test-LinkExists([string]$path) {
    $cands = @()
    if ($path -match '^(\.\.[\\/])+') {
        # ..\..\X -> resolve the remainder against the repo root
        $rest = $path -replace '^(\.\.[\\/])+', ''
        $cands += (Join-Path $repoRoot $rest)
        $cands += (Join-Path $repoRoot $path)
    } else {
        foreach ($base in @($SkillDir, $referencesDir, $scriptsDir, $repoRoot)) {
            $cands += (Join-Path $base $path)
        }
    }
    foreach ($c in $cands) {
        try { if (Test-Path -LiteralPath $c -PathType Leaf) { return $true } } catch { }
    }
    return $false
}

# Pull candidate tokens from one line, tagged by source. Markdown link targets
# are explicit links (checked even when bare); inline-code spans must contain a
# path separator to count (RequireSeparator) so prose filenames are not flagged.
function Get-LineTokens([string]$line) {
    $toks = @()
    foreach ($m in [regex]::Matches($line, '\[[^\]]*\]\(([^)]+)\)')) {
        # strip optional <...> wrapper and a "title" suffix
        $tgt = $m.Groups[1].Value.Trim().TrimStart('<').TrimEnd('>')
        $tgt = ($tgt -split '\s+', 2)[0]
        $toks += [pscustomobject]@{ Token = $tgt; RequireSeparator = $false }
    }
    foreach ($m in [regex]::Matches($line, '`([^`]+)`')) {
        $toks += [pscustomobject]@{ Token = $m.Groups[1].Value; RequireSeparator = $true }
    }
    return $toks
}

# --- gather doc files ---------------------------------------------------------
$docFiles = @($skillMd)
if (Test-Path $referencesDir -PathType Container) {
    $docFiles += Get-ChildItem -Path $referencesDir -Filter '*.md' -File | ForEach-Object FullName
}

$broken  = @()   # broken file links
$missing = @()   # capability-map scripts not in scripts\
$stale   = @()   # stale step-count prose
$linksChecked = 0

# --- check 1: broken file links ----------------------------------------------
foreach ($file in $docFiles) {
    $lines = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($tok in (Get-LineTokens $lines[$i])) {
            foreach ($expanded in (Expand-Braces $tok.Token)) {
                $path = Get-CheckablePath $expanded $tok.RequireSeparator
                if (-not $path) { continue }
                $linksChecked++
                if (-not (Test-LinkExists $path)) {
                    $broken += [pscustomobject]@{ File = $file; Line = ($i + 1); Link = $path }
                }
            }
        }
    }
}

# --- check 2: capability-map scripts exist -----------------------------------
$skillLines = Get-Content -LiteralPath $skillMd
$capStart = -1
for ($i = 0; $i -lt $skillLines.Count; $i++) {
    if ($skillLines[$i] -match '^##\s+Capability map') { $capStart = $i; break }
}
$capScriptsChecked = 0
if ($capStart -ge 0) {
    $inTable = $false
    for ($i = $capStart + 1; $i -lt $skillLines.Count; $i++) {
        $line = $skillLines[$i]
        if ($line -match '^\s*\|') {
            $inTable = $true
            $cells = $line.Split('|')
            if ($cells.Count -lt 3) { continue }
            $scriptCell = $cells[2]
            if ($scriptCell -match '^[\s\-:]+$') { continue }   # separator row
            if ($scriptCell -match 'Script') { continue }       # header row
            foreach ($bm in [regex]::Matches($scriptCell, '`([^`]+)`')) {
                $t = ($bm.Groups[1].Value.Trim() -split '\s+')[0]   # drop flags
                if ($t -match '(?i)\.(ps1|py)$') {
                    $capScriptsChecked++
                    if (-not (Test-Path (Join-Path $scriptsDir $t) -PathType Leaf)) {
                        $missing += [pscustomobject]@{ File = $skillMd; Line = ($i + 1); Script = $t }
                    }
                }
            }
        } elseif ($inTable) { break }
    }
}

# --- check 3: stale step counts ----------------------------------------------
foreach ($file in $docFiles) {
    $lines = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '(?i)(18|19|21)-step|(18|19|21) steps|each of the (18|19|21)') {
            $stale += [pscustomobject]@{ File = $file; Line = ($i + 1); Text = $lines[$i].Trim() }
        }
    }
}

# --- check 4: every script is indexed in SKILL.md -----------------------------
# SKILL.md is the discoverability surface: a script that exists in scripts\ but
# is never mentioned there cannot be found by a skill user. Simple substring
# match on the file NAME anywhere in SKILL.md (map row or prose) counts.
$unindexed = @()
$scriptsChecked = 0
$skillText = (Get-Content -LiteralPath $skillMd -Raw)
if (Test-Path $scriptsDir -PathType Container) {
    foreach ($sf in (Get-ChildItem -Path $scriptsDir -File | Where-Object { $_.Name -match '(?i)\.(ps1|py)$' })) {
        $scriptsChecked++
        if ($skillText.IndexOf($sf.Name, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $unindexed += $sf.Name
        }
    }
}

# --- check 5: junction / duplication guard -----------------------------------
# a) nothing under .claude/skills/jasper-deploy may be tracked in git (the
#    junction let `git add -A` re-add the moved skill at its old path, f2184cf);
# b) if that path is a real directory rather than a junction/symlink, it must be
#    byte-identical to the plugin skill dir. Skipped (with a note) outside git.
$junctionTracked = @()   # tracked paths under .claude/skills/jasper-deploy
$junctionDiverged = @()  # relative paths that differ between the two copies
$junctionNote = ''
if (-not $SkipJunctionCheck) {
    if (-not $ClaudeSkillDir) { $ClaudeSkillDir = Join-Path $repoRoot '.claude/skills/jasper-deploy' }
    $git = Get-Command git -ErrorAction SilentlyContinue
    $inRepo = $false
    if ($git) {
        try {
            $null = & git -C $repoRoot rev-parse --is-inside-work-tree 2>$null
            $inRepo = ($LASTEXITCODE -eq 0)
        } catch { $inRepo = $false }
    }
    if ($inRepo) {
        try {
            $relClaude = '.claude/skills/jasper-deploy'
            $tracked = & git -C $repoRoot ls-files -- $relClaude 2>$null
            if ($LASTEXITCODE -eq 0 -and $tracked) { $junctionTracked = @($tracked | Where-Object { $_ }) }
        } catch { }
    } else {
        $junctionNote = 'git unavailable or not a git checkout; tracked-duplicate check skipped'
    }

    if (Test-Path -LiteralPath $ClaudeSkillDir -PathType Container) {
        $item = Get-Item -LiteralPath $ClaudeSkillDir -Force
        # ReparsePoint covers NTFS junctions, Windows symlinks and POSIX symlinks (pwsh)
        $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if (-not $isLink -and $item.PSObject.Properties.Name -contains 'LinkType' -and $item.LinkType) { $isLink = $true }
        if (-not $isLink) {
            # real directory: compare every file both ways
            $src = (Resolve-Path -LiteralPath $SkillDir).Path
            $dst = (Resolve-Path -LiteralPath $ClaudeSkillDir).Path
            function Get-RelFiles([string]$base) {
                Get-ChildItem -LiteralPath $base -Recurse -File -Force |
                    Where-Object { $_.FullName -notmatch '[\\/](__pycache__|out|\.git)[\\/]' } |
                    ForEach-Object { $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/' }
            }
            $a = @(Get-RelFiles $src); $b = @(Get-RelFiles $dst)
            $union = @($a + $b | Sort-Object -Unique)
            foreach ($rel in $union) {
                $pa = Join-Path $src $rel; $pb = Join-Path $dst $rel
                if (-not (Test-Path -LiteralPath $pa -PathType Leaf) -or -not (Test-Path -LiteralPath $pb -PathType Leaf)) {
                    $junctionDiverged += $rel; continue
                }
                $ha = (Get-FileHash -LiteralPath $pa -Algorithm SHA256).Hash
                $hb = (Get-FileHash -LiteralPath $pb -Algorithm SHA256).Hash
                if ($ha -ne $hb) { $junctionDiverged += $rel }
            }
            if ($junctionNote) { $junctionNote += '; ' }
            $junctionNote += "$ClaudeSkillDir is a real directory (not a junction/symlink); byte-compared $($union.Count) file(s)"
        } else {
            if ($junctionNote) { $junctionNote += '; ' }
            $junctionNote += "$ClaudeSkillDir is a junction/symlink (ok)"
        }
    } else {
        if ($junctionNote) { $junctionNote += '; ' }
        $junctionNote += '.claude/skills/jasper-deploy absent (nothing to compare)'
    }
}

# --- report -------------------------------------------------------------------
function Rel([string]$p) {
    if ($p.StartsWith($SkillDir)) { return $p.Substring($SkillDir.Length).TrimStart('\', '/') }
    return $p
}

Write-Host ("check_docs: " + $SkillDir)

if ($broken) {
    Write-Host ""
    Write-Host "Broken file links:" -ForegroundColor Red
    foreach ($b in $broken) {
        Write-Host ("  {0}:{1}  ->  {2}" -f (Rel $b.File), $b.Line, $b.Link) -ForegroundColor Red
    }
}
if ($missing) {
    Write-Host ""
    Write-Host "Capability-map scripts not found in scripts\:" -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host ("  {0}:{1}  ->  {2}" -f (Rel $m.File), $m.Line, $m.Script) -ForegroundColor Red
    }
}
if ($stale) {
    Write-Host ""
    Write-Host "Stale step-count prose (smoke gate is now 24 steps):" -ForegroundColor Red
    foreach ($s in $stale) {
        Write-Host ("  {0}:{1}  {2}" -f (Rel $s.File), $s.Line, $s.Text) -ForegroundColor Red
    }
}
if ($unindexed) {
    Write-Host ""
    Write-Host "Scripts in scripts\ never mentioned in SKILL.md (add a capability-map row):" -ForegroundColor Red
    foreach ($u in $unindexed) {
        Write-Host ("  scripts/{0}" -f $u) -ForegroundColor Red
    }
}

if ($junctionTracked) {
    Write-Host ""
    Write-Host "Files tracked in git under .claude/skills/jasper-deploy (duplicates of the plugin skill; run: git rm -r --cached .claude/skills/jasper-deploy):" -ForegroundColor Red
    foreach ($t in $junctionTracked) { Write-Host ("  {0}" -f $t) -ForegroundColor Red }
}
if ($junctionDiverged) {
    Write-Host ""
    Write-Host ".claude/skills/jasper-deploy is a real directory that DIVERGES from plugins/jasper-deploy/skills/jasper-deploy (replace it with a junction/symlink):" -ForegroundColor Red
    foreach ($dv in $junctionDiverged) { Write-Host ("  {0}" -f $dv) -ForegroundColor Red }
}

$junctionBad = $junctionTracked.Count + $junctionDiverged.Count
$totalBad = $broken.Count + $missing.Count + $stale.Count + $unindexed.Count + $junctionBad

Write-Host ""
Write-Host ("Scanned {0} doc file(s); checked {1} link(s) + {2} capability-map script(s) + {3} scripts-dir file(s)." -f `
    $docFiles.Count, $linksChecked, $capScriptsChecked, $scriptsChecked)
if ($SkipJunctionCheck) { Write-Host "Junction guard: skipped (-SkipJunctionCheck)." }
elseif ($junctionNote) { Write-Host ("Junction guard: {0}." -f $junctionNote) }

if ($totalBad -eq 0) {
    Write-Host ("PASS: 0 broken link(s), 0 missing script(s), 0 stale count(s), 0 unindexed script(s), 0 junction duplicate(s).") -ForegroundColor Green
    exit 0
}
Write-Host ("FAIL: {0} broken link(s), {1} missing script(s), {2} stale count(s), {3} unindexed script(s), {4} junction duplicate(s)." -f `
    $broken.Count, $missing.Count, $stale.Count, $unindexed.Count, $junctionBad) -ForegroundColor Red
exit 1
