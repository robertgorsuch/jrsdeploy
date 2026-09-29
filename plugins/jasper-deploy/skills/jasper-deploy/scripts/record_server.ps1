<#
.SYNOPSIS
  Record the sanitised GET exchanges a dashboard manifest's promote/compose/
  teardown plan needs, from a live server, into a replayable recording for
  tests/mock_jrs.py.

.DESCRIPTION
  Read-only. For each manifest it GETs: serverInfo, the manifest folder, the
  dashboard, every report tile (plain and ?expanded=true, which inlines the
  jrxml), every filter/tile control and the control folder. Extra URIs can be
  added with -Uri. Bodies are stored as returned minus creationDate/updateDate
  and any key that looks like a credential. Nothing is written to the server.

  Output: <Out>/mappings.json (list of {method, path, status, contentType, body})
  and <Out>/recording.json (provenance: version, edition, when, manifests,
  "recorded"). Default -Out is tests/recordings/<version>-<edition>.

  Ported from jrsctl's recorded-server harness (ADR-0011): the scripts under
  test stay real; only the server is replayed. tests/harness.Tests.ps1 runs
  promote/teardown/compose in plan mode against the recording and proves that
  no PUT/POST/DELETE was issued.

.EXAMPLE
  .\record_server.ps1 -Manifest ..\tests\fixtures\harness\harness_dashboard.json -Env stage
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,     # file | directory | glob
    [string[]]$Uri = @(),
    [string]$Out,
    [string]$ServerUrl,
    [string]$User,
    [string]$Password,
    [string]$Env
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_jrs_common.ps1")
$jrs = Resolve-JrsConfig -ServerUrl $ServerUrl -User $User -Password $Password -Env $Env

function Get-ManifestFiles([string]$Spec) {
    $paths = @()
    if (Test-Path $Spec -PathType Container) { $paths = @(Get-ChildItem -Path $Spec -Filter *.json -File | ForEach-Object { $_.FullName }) }
    elseif (Test-Path $Spec -PathType Leaf) { $paths = @((Resolve-Path $Spec).Path) }
    else { $paths = @(Get-ChildItem -Path $Spec -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    $out = @()
    foreach ($p in $paths) {
        try { $j = ((Get-Content $p -Raw) -replace "^\xEF\xBB\xBF", "") | ConvertFrom-Json } catch { continue }
        if (($j.PSObject.Properties.Name -contains "dashlets") -and ($j.PSObject.Properties.Name -contains "folder") -and ($j.PSObject.Properties.Name -contains "name")) { $out += $p }
    }
    if (-not $out) { throw "no dashboard manifest(s) found for '$Spec'" }
    return $out
}

function Remove-Sensitive($node) {
    # drop timestamps (noise between recordings) and anything credential-shaped
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($node.PSObject.Properties)) {
            if ($p.Name -match '^(creationDate|updateDate)$' -or $p.Name -match '(?i)password|secret|token') { $node.PSObject.Properties.Remove($p.Name); continue }
            Remove-Sensitive $p.Value | Out-Null
        }
    } elseif ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
        foreach ($i in $node) { Remove-Sensitive $i | Out-Null }
    }
    return $node
}

$targets = New-Object System.Collections.Generic.List[string]
$targets.Add("/rest_v2/serverInfo")
$names = @()
foreach ($mf in (Get-ManifestFiles $Manifest)) {
    $m = ((Get-Content $mf -Raw) -replace "^\xEF\xBB\xBF", "") | ConvertFrom-Json
    $names += (Split-Path -Leaf $mf)
    $folder = "$($m.folder)".TrimEnd("/")
    $ctlFolder = if (($m.PSObject.Properties.Name -contains "filterControlFolder") -and $m.filterControlFolder) { "$($m.filterControlFolder)".TrimEnd("/") } else { "$folder/controls" }
    $targets.Add("/rest_v2/resources$folder")
    $targets.Add("/rest_v2/resources$folder/$($m.name)")
    foreach ($d in @($m.dashlets)) {
        $kind = if (($d.PSObject.Properties.Name -contains "kind") -and $d.kind) { $d.kind } else { "report" }
        if ($kind -ne "report") { continue }
        $u = if (($d.PSObject.Properties.Name -contains "resource") -and $d.resource) { $d.resource } else { "$folder/$($d.name)" }
        $targets.Add("/rest_v2/resources$u")
        $targets.Add("/rest_v2/resources${u}?expanded=true")
        if ($d.PSObject.Properties.Name -contains "controls") { foreach ($c in @($d.controls)) { $cu = if ("$c".StartsWith("/")) { "$c" } else { "$ctlFolder/$c" }; $targets.Add("/rest_v2/resources$cu") } }
    }
    $hasCtl = $false
    if (($m.PSObject.Properties.Name -contains "filters") -and $m.filters) { foreach ($f in @($m.filters)) { $targets.Add("/rest_v2/resources$ctlFolder/$f"); $hasCtl = $true } }
    if (($m.PSObject.Properties.Name -contains "controls") -and $m.controls) { foreach ($c in @($m.controls)) { if ($c.name) { $targets.Add("/rest_v2/resources$ctlFolder/$($c.name)"); $hasCtl = $true } } }
    if ($hasCtl) { $targets.Add("/rest_v2/resources$ctlFolder") }
}
foreach ($u in $Uri) { $targets.Add("/rest_v2/resources$(if ($u.StartsWith('/')) { $u } else { "/$u" })") }

$mappings = @()
$seen = @{}
$info = $null
foreach ($t in $targets) {
    if ($seen[$t]) { continue }; $seen[$t] = $true
    $r = Invoke-JrsRest -Jrs $jrs -Method GET -Path $t
    $code = "$($r.Code)".Trim()
    $body = $null
    if ($r.Body) { try { $body = Remove-Sensitive ($r.Body | ConvertFrom-Json) } catch { $body = $r.Body } }
    if ($t -eq "/rest_v2/serverInfo" -and $code -eq "200") { $info = $body }
    $mappings += [ordered]@{ method = "GET"; path = $t; status = [int]$code; contentType = "application/json"; body = $body }
    Write-Host ("  {0,3}  GET {1}" -f $code, $t)
}
if (-not $info) { throw "serverInfo not readable from $($jrs.ServerUrl)" }

if (-not $Out) { $Out = Join-Path $PSScriptRoot ("../tests/recordings/" + "$($info.version)-$($info.edition)") }
New-Item -ItemType Directory -Force $Out | Out-Null
$enc = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Out "mappings.json"), ($mappings | ConvertTo-Json -Depth 30), $enc)
$prov = [ordered]@{
    provenance = "recorded"; version = "$($info.version)"; edition = "$($info.edition)"
    recordedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    env = $(if ($jrs.Env) { "$($jrs.Env)" } else { "(explicit url)" }); manifests = $names; mappings = $mappings.Count
    note = "GET exchanges only; creationDate/updateDate and credential-shaped keys removed; replay with tests/mock_jrs.py"
}
[IO.File]::WriteAllText((Join-Path $Out "recording.json"), ($prov | ConvertTo-Json -Depth 5), $enc)
Write-Host "OK: recorded $($mappings.Count) exchange(s) from $($jrs.ServerUrl) ($($info.version) $($info.edition)) -> $Out"
