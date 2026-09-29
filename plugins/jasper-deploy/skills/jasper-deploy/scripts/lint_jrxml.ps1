<#
.SYNOPSIS
  Static pre-deploy linter for JasperReports 7 artifacts (.jrxml / .jrtx / .jrdax).

.DESCRIPTION
  JR7 parses these files with a STRICT Jackson deserializer: an unknown element or
  attribute, or a JR6-era name, throws UnrecognizedPropertyException at fill time --
  surfaced by JasperReports Server as an opaque HTTP 400, NOT a clean compile error.
  A clean local compile_jrxml.ps1 does NOT catch most of these (the file is valid XML;
  the trap is the strict object mapper and the server-side SQL validator).

  This linter codifies the hard-won gotchas from the skill (see references\gotchas.md
  and references\jr7-valid-elements.md) as fast, offline checks so the failure is caught
  before deploy. It scans raw text so every finding carries a line number.

  Checks (ERROR = will fail at fill time; WARN = renders wrong / blank):
    [E] jrtx   : isDefault="true"      -> JR7 default-style attr is default="true"
    [E] jrdax  : <useConnection> and other non-CsvDataAdapterImpl elements
    [E] jrxml  : <seriesColors> wrapper -> JR7 uses repeated <seriesColor .../>
    [E] jrxml  : seriesOrder=           -> the index attribute is order=
    [E] jrxml  : <query> text begins with WITH (CTE) -> JRS SQL validator rejects it
    [E] jrxml  : showTickMarks/showTickLabels inside a <linePlot> -> line plots use
                 showLines/showShapes; tick props throw UnrecognizedPropertyException
    [W] jrxml  : a chart/component in the <title> band without evaluationTime="Report"
                 -> binds zero data, renders blank/uniform
    [W] jrxml  : resourceBundle="..." present (reminder: the .properties bundle must be
                 embedded via deploy_report.ps1 -ResourceFiles even with whenResourceMissingType)

  Manifest mode (a .json path, or -Manifest): lints a dashboard build manifest
  (references\manifest.schema.json) instead of a jrxml. Unknown keys are tolerated.
    [E] manifest-invalid-json     : file is not parseable JSON / not an object
    [E] manifest-missing-key      : a required key (folder, name, dashlets) is absent
    [W] manifest-filter-floating  : "filters" set but "filterFloating" omitted -- the
                 gen_dashboard default flipped to floating:false (commit a8503f2), so
                 STAGE and PROD composed at different times DIVERGE; pin it explicitly
    [E] manifest-dashlet-outside-folder : a report dashlet's resource/report URI is not
                 under the manifest "folder" (promote.ps1 moves the folder, not the tile)
    [E] manifest-duplicate-dashlet : two dashlets share a name (or label -> component id)

.PARAMETER Path
  One or more .jrxml/.jrtx/.jrdax files, or directories (scanned recursively).
  A .json file is linted as a dashboard manifest.

.PARAMETER Manifest
  One or more dashboard manifest .json files to lint (same as passing them via -Path).

.PARAMETER WarningsAsErrors
  Treat WARN findings as failures for the exit code.

.EXAMPLE
  & lint_jrxml.ps1 -Path report\foodmart\foodmart_yoy_sales.jrxml
.EXAMPLE
  & lint_jrxml.ps1 -Path report\ -WarningsAsErrors   # lint a whole tree
.EXAMPLE
  & lint_jrxml.ps1 -Manifest report\foodmart\dashboard.json -WarningsAsErrors
.NOTES
  Exit code 0 = clean; 1 = at least one ERROR (or WARN with -WarningsAsErrors).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string[]]$Path,
    [string[]]$Manifest,
    [switch]$WarningsAsErrors
)
if (-not $Path -and -not $Manifest) { throw "lint_jrxml.ps1: supply -Path and/or -Manifest" }

$ErrorActionPreference = 'Stop'

# CsvDataAdapterImpl is the only valid element set for a JR7 .jrdax CSV adapter
# (verified against the JR7 source; JR6 names like useConnection are rejected).
$CsvAdapterValid = @(
    'name','fileName','dataFile','fieldDelimiter','recordDelimiter','useFirstRowAsHeader',
    'columnNames','queryExecuterMode','datePattern','numberPattern','encoding','timeZone','locale'
)

function New-Finding($Sev, $Line, $Rule, $Msg) {
    [pscustomobject]@{ Severity = $Sev; Line = $Line; Rule = $Rule; Message = $Msg }
}

# Return 1-based line numbers where a regex matches (raw scan -> real line numbers).
function Find-Lines($lines, $pattern) {
    $hits = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $hits += ($i + 1) }
    }
    return $hits
}

function Lint-File($file) {
    $findings = @()
    $raw   = Get-Content -Raw -LiteralPath $file
    $lines = $raw -split "`r?`n"
    $ext   = [IO.Path]::GetExtension($file).ToLowerInvariant()

    if ($ext -eq '.jrtx') {
        foreach ($ln in (Find-Lines $lines 'isDefault\s*=')) {
            $findings += New-Finding 'ERROR' $ln 'jrtx-default-attr' `
                'isDefault="true" is the JR6 name; JR7 default style uses default="true".'
        }
    }

    if ($ext -eq '.jrdax') {
        # collect child element local-names and flag any outside the valid set
        $elemMatches = [regex]::Matches($raw, '<\s*([A-Za-z_][\w.\-]*)')
        $seen = @{}
        foreach ($m in $elemMatches) {
            $name = $m.Groups[1].Value
            if ($name -match 'DataAdapter') { continue }   # the root element
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            if ($CsvAdapterValid -notcontains $name) {
                $ln = (Find-Lines $lines ("<\s*" + [regex]::Escape($name) + "\b"))
                $where = if ($ln) { $ln[0] } else { 0 }
                $findings += New-Finding 'ERROR' $where 'jrdax-unknown-element' `
                    ("<$name> is not a valid CsvDataAdapterImpl element (JR6-era or typo). Valid: " + ($CsvAdapterValid -join ', ') + '.')
            }
        }
    }

    if ($ext -eq '.jrxml') {
        foreach ($ln in (Find-Lines $lines '<\s*seriesColors\b')) {
            $findings += New-Finding 'ERROR' $ln 'pie-seriescolors-wrapper' `
                'JR7 has no <seriesColors> wrapper; use repeated <seriesColor order="N" color="#hex"/>.'
        }
        foreach ($ln in (Find-Lines $lines 'seriesOrder\s*=')) {
            $findings += New-Finding 'ERROR' $ln 'pie-seriesorder-attr' `
                'The seriesColor index attribute is order=, not seriesOrder=.'
        }

        # <query ...> ... </query> body starting with WITH (CTE) -> SQL validator rejects
        foreach ($qm in [regex]::Matches($raw, '(?is)<queryString[^>]*>(.*?)</queryString>|<query\b[^>]*>(.*?)</query>')) {
            $body = ($qm.Groups[1].Value + $qm.Groups[2].Value)
            $body = [regex]::Replace($body, '<!\[CDATA\[|\]\]>', '')
            if ($body.Trim() -match '(?i)^\s*WITH\b') {
                # locate the line where the query opens
                $idx = $raw.Substring(0, $qm.Index)
                $ln  = ($idx -split "`r?`n").Count
                $findings += New-Finding 'ERROR' $ln 'sql-leading-with' `
                    'Query begins with WITH (CTE); the JRS SQL security validator rejects non-SELECT-leading SQL. Push CTEs into FROM subqueries.'
            }
        }

        # Wrong plot properties per chart type. JR7-native form is a generic
        # <plot> whose class is fixed by the enclosing element's chartType=,
        # so the rule keys on that type; the legacy 6.x <linePlot>/<areaPlot>
        # forms are caught separately below.
        foreach ($ce in [regex]::Matches($raw, '(?is)<element\b[^>]*\bchartType\s*=\s*"([^"]+)"[^>]*>.*?</element>')) {
            $ctype = $ce.Groups[1].Value.ToLowerInvariant()
            $inner = $ce.Value
            $idx = $raw.Substring(0, $ce.Index); $ln = ($idx -split "`r?`n").Count
            if ($ctype -eq 'line' -and $inner -match 'showTick(Marks|Labels)') {
                $findings += New-Finding 'ERROR' $ln 'lineplot-tick-props' `
                    'A line chart plot uses showLines/showShapes; showTickMarks/showTickLabels throw UnrecognizedPropertyException on JRDesignLinePlot.'
            }
            if ($ctype -eq 'area' -and $inner -match 'showTick(Marks|Labels)|showLines|showShapes') {
                $findings += New-Finding 'ERROR' $ln 'areaplot-plot-props' `
                    'JRDesignAreaPlot supports NEITHER showTickMarks/showTickLabels NOR showLines/showShapes; use a bare <plot/> (only categoryAxisTickLabelRotation is valid).'
            }
        }
        # legacy 6.x dedicated plot elements
        foreach ($lp in [regex]::Matches($raw, '(?is)<linePlot\b.*?</linePlot>')) {
            if ($lp.Value -match 'showTick(Marks|Labels)') {
                $idx = $raw.Substring(0, $lp.Index); $ln = ($idx -split "`r?`n").Count
                $findings += New-Finding 'ERROR' $ln 'lineplot-tick-props' `
                    'A line plot uses showLines/showShapes; showTickMarks/showTickLabels throw UnrecognizedPropertyException on a linePlot.'
            }
        }
        foreach ($ap in [regex]::Matches($raw, '(?is)<areaPlot\b.*?</areaPlot>')) {
            if ($ap.Value -match 'showTick(Marks|Labels)|showLines|showShapes') {
                $idx = $raw.Substring(0, $ap.Index); $ln = ($idx -split "`r?`n").Count
                $findings += New-Finding 'ERROR' $ln 'areaplot-plot-props' `
                    'JRDesignAreaPlot supports NEITHER showTickMarks/showTickLabels NOR showLines/showShapes; use a bare <plot/>.'
            }
        }

        # chart/component in the <title> band without evaluationTime="Report"
        foreach ($tb in [regex]::Matches($raw, '(?is)<title\b.*?</title>')) {
            if (($tb.Value -match '<(componentElement|chart)\b') -and ($tb.Value -notmatch 'evaluationTime\s*=\s*"Report"')) {
                $idx = $raw.Substring(0, $tb.Index)
                $ln  = ($idx -split "`r?`n").Count
                $findings += New-Finding 'WARN' $ln 'title-band-evaluationtime' `
                    'A chart/component in the title band fills before row iteration; set evaluationTime="Report" or move it to the summary band, or it renders blank.'
            }
        }

        foreach ($ln in (Find-Lines $lines 'resourceBundle\s*=')) {
            $findings += New-Finding 'WARN' $ln 'resourcebundle-embed' `
                'resourceBundle set: embed the .properties bundle (deploy_report.ps1 -ResourceFiles) -- whenResourceMissingType only covers missing keys, not a missing bundle.'
        }
    }

    return $findings
}

# ---- manifest lint (dashboard build manifest .json) ---------------------------------------------
# Line numbers are best-effort: the line of the first occurrence of the offending
# key/value in the raw text (0 when it cannot be located).
function Find-JsonLine($lines, [string]$needle) {
    $esc = [regex]::Escape($needle)
    $hits = Find-Lines $lines $esc
    if ($hits) { return $hits[0] }
    return 0
}

function Lint-Manifest($file) {
    $findings = @()
    $raw   = Get-Content -Raw -LiteralPath $file
    $lines = $raw -split "`r?`n"
    try { $m = $raw | ConvertFrom-Json } catch {
        return @(New-Finding 'ERROR' 1 'manifest-invalid-json' "not valid JSON: $($_.Exception.Message)")
    }
    if (-not ($m -is [System.Management.Automation.PSCustomObject])) {
        return @(New-Finding 'ERROR' 1 'manifest-invalid-json' 'top level must be a JSON object')
    }
    $keys = @($m.PSObject.Properties.Name)

    foreach ($k in @('folder', 'name', 'dashlets')) {
        if ($keys -notcontains $k) {
            $findings += New-Finding 'ERROR' 1 'manifest-missing-key' "required key `"$k`" is missing (see references/manifest.schema.json)."
        }
    }

    # filters present but filterFloating not pinned -> docked/floating depends on
    # which gen_dashboard.py revision composed it (default changed in a8503f2).
    $hasFilters = ($keys -contains 'filters') -and $null -ne $m.filters -and @($m.filters).Count -gt 0
    if ($hasFilters -and ($keys -notcontains 'filterFloating')) {
        # tolerate an object-form filters:{floating:..} if a future schema adds it
        $objFloating = ($m.filters -is [System.Management.Automation.PSCustomObject]) -and ($m.filters.PSObject.Properties.Name -contains 'floating')
        if (-not $objFloating) {
            $findings += New-Finding 'WARN' (Find-JsonLine $lines '"filters"') 'manifest-filter-floating' `
                '"filters" is set but "filterFloating" is omitted: gen_dashboard.py now defaults to floating:false (docked, commit a8503f2) where older builds floated it, so STAGE and PROD diverge. Add "filterFloating": false (or true) explicitly.'
        }
    }

    $folder = if ($keys -contains 'folder') { [string]$m.folder } else { $null }
    $seen = @{}
    if ($keys -contains 'dashlets' -and $m.dashlets) {
        foreach ($d in @($m.dashlets)) {
            if (-not ($d -is [System.Management.Automation.PSCustomObject])) { continue }
            $dk = @($d.PSObject.Properties.Name)
            $kind = if ($dk -contains 'kind' -and $d.kind) { [string]$d.kind } else { 'report' }
            $dname = if ($dk -contains 'name' -and $d.name) { [string]$d.name } elseif ($dk -contains 'label' -and $d.label) { [string]$d.label } else { $null }

            # duplicate dashlet names (name, else label -> component id collision)
            if ($dname) {
                $key = $dname.ToLowerInvariant()
                if ($seen.ContainsKey($key)) {
                    $findings += New-Finding 'ERROR' (Find-JsonLine $lines $dname) 'manifest-duplicate-dashlet' `
                        "dashlet name `"$dname`" appears more than once; component ids derive from it and collide."
                } else { $seen[$key] = $true }
            }

            # report dashlet resource/report URI must live under the manifest folder
            if ($kind -eq 'report' -and $folder) {
                $uri = $null
                foreach ($uk in @('resource', 'report', 'uri')) {
                    if ($dk -contains $uk -and $d.$uk) { $uri = [string]$d.$uk; break }
                }
                if ($uri) {
                    $f1 = $folder.TrimEnd('/') + '/'
                    if (-not $uri.StartsWith($f1, [StringComparison]::OrdinalIgnoreCase)) {
                        $findings += New-Finding 'ERROR' (Find-JsonLine $lines $uri) 'manifest-dashlet-outside-folder' `
                            "report dashlet `"$dname`" points at $uri which is not under folder $folder; promote.ps1/teardown move the folder only, so the tile breaks on the target."
                    }
                }
            }
        }
    }
    return $findings
}

# ---- gather files -----------------------------------------------------------------------------
$exts = @('.jrxml', '.jrtx', '.jrdax')
$files = @()
$manifests = @()
foreach ($p in @($Path)) {
    if (-not $p) { continue }
    if (Test-Path $p -PathType Container) {
        $files += Get-ChildItem -Path $p -Recurse -File | Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } | ForEach-Object FullName
    } elseif (Test-Path $p -PathType Leaf) {
        if ([IO.Path]::GetExtension($p).ToLowerInvariant() -eq '.json') { $manifests += (Resolve-Path $p).Path }
        else { $files += (Resolve-Path $p).Path }
    } else {
        Write-Warning "Not found: $p"
    }
}
foreach ($p in @($Manifest)) {
    if (-not $p) { continue }
    if (Test-Path $p -PathType Leaf) { $manifests += (Resolve-Path $p).Path } else { Write-Warning "Not found: $p" }
}
$files = @($files | Sort-Object -Unique)
$manifests = @($manifests | Sort-Object -Unique)
if (-not $files -and -not $manifests) { Write-Host "No .jrxml/.jrtx/.jrdax/manifest files to lint."; exit 0 }

# ---- run + report -----------------------------------------------------------------------------
$totalErr = 0; $totalWarn = 0
$all = @()
foreach ($f in $files)     { $all += [pscustomobject]@{ File = $f; Kind = 'artifact' } }
foreach ($f in $manifests) { $all += [pscustomobject]@{ File = $f; Kind = 'manifest' } }
foreach ($item in $all) {
    $f = $item.File
    $findings = if ($item.Kind -eq 'manifest') { Lint-Manifest $f } else { Lint-File $f }
    if (-not $findings) {
        Write-Host ("OK    " + $f) -ForegroundColor Green
        continue
    }
    Write-Host ("ISSUES " + $f) -ForegroundColor Yellow
    foreach ($fd in ($findings | Sort-Object Line)) {
        $color = if ($fd.Severity -eq 'ERROR') { 'Red' } else { 'DarkYellow' }
        Write-Host ("  [{0}] line {1}  {2}: {3}" -f $fd.Severity, $fd.Line, $fd.Rule, $fd.Message) -ForegroundColor $color
        if ($fd.Severity -eq 'ERROR') { $totalErr++ } else { $totalWarn++ }
    }
}
Write-Host ""
Write-Host ("Summary: {0} file(s), {1} error(s), {2} warning(s)." -f $all.Count, $totalErr, $totalWarn)

$fail = ($totalErr -gt 0) -or ($WarningsAsErrors -and $totalWarn -gt 0)
exit ([int]$fail)
