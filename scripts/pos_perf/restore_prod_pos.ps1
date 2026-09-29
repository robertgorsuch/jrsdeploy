<#
.SYNOPSIS
  Restore the POS suite on a target server after the 2026-08-28 promote.ps1
  -WhatIf incident: re-attach input controls (copied from a reference server)
  and recompose every dashboard manifest under report/pos_perf.

.DESCRIPTION
  Read-only unless -Apply is passed. Steps:
    1. For every report tile referenced by a manifest, compare inputControls on
       the reference server (-FromEnv, default stage) with the target (-ToEnv,
       default prod); with -Apply, PUT the target report unit back with the
       reference's list (in-place ?overwrite=true, controls only -- the jrxml
       is untouched).
    2. With -Apply, compose_dashboard.ps1 -Replace against the target for each
       manifest (delete of an absent dashboard is a 404 = no-op).
    3. Run verify_suite.ps1 against the target and print its summary.
  Requires jrs.config.json "environments" profiles for both names. Never
  writes to the reference server.

.EXAMPLE
  .\scripts\pos_perf\restore_prod_pos.ps1              # plan only (GET)
  .\scripts\pos_perf\restore_prod_pos.ps1 -Apply       # restore PROD
#>
[CmdletBinding()]
param(
    [string]$ManifestDir = "report/pos_perf",
    [string]$FromEnv = "stage",
    [string]$ToEnv = "prod",
    [switch]$Apply
)
$ErrorActionPreference = "Stop"
$skill = Join-Path $PSScriptRoot "../../plugins/jasper-deploy/skills/jasper-deploy/scripts"
. (Join-Path $skill "_jrs_common.ps1")
$from = Resolve-JrsConfig -Env $FromEnv
$to   = Resolve-JrsConfig -Env $ToEnv
if ($from.ServerUrl -eq $to.ServerUrl) { throw "from and to are the same server" }
$mode = if ($Apply) { "APPLY" } else { "PLAN (read-only; pass -Apply to write)" }
Write-Host "restore POS suite: $($from.ServerUrl) [$FromEnv] -> $($to.ServerUrl) [$ToEnv]  mode: $mode"

function Get-Controls($j, [string]$u) {
    $r = Invoke-JrsGet -Jrs $j -Uri $u
    if ("$($r.Code)" -ne "200") { return $null }
    $o = $r.Body | ConvertFrom-Json
    if ($o.PSObject.Properties.Name -contains "inputControls" -and $o.inputControls) {
        return ,@($o.inputControls | ForEach-Object { $_.inputControlReference.uri } | Sort-Object)
    }
    return ,@()   # leading comma: a bare "return @()" reaches the caller as $null
}

$manifests = Get-ChildItem (Join-Path $ManifestDir "*_dashboard.json") | Sort-Object Name
$tiles = @{}
foreach ($m in $manifests) {
    $d = Get-Content $m.FullName -Raw | ConvertFrom-Json
    foreach ($x in $d.dashlets) {
        if ($x.type -in @("text", "image")) { continue }
        $u = if ($x.PSObject.Properties.Name -contains "resource" -and $x.resource) { $x.resource }
             elseif ($x.name) { "$($d.folder)/$($x.name)" } else { $null }
        if ($u) { $tiles[$u] = $true }
    }
}

# --- 1. input-control attachments ---------------------------------------------
Write-Host ""; Write-Host "phase 1 - input-control attachments ($($tiles.Count) tiles)"
$fixed = 0; $missing = 0
foreach ($u in ($tiles.Keys | Sort-Object)) {
    $want = Get-Controls $from $u
    $have = Get-Controls $to $u
    if ($null -eq $have) { Write-Host ("  [MISSING on target] {0}" -f $u); $missing++; continue }
    if ($null -eq $want) { Write-Host ("  [no reference]      {0}" -f $u); continue }
    $same = ($want.Count -eq $have.Count) -and -not @($want | Where-Object { $have -notcontains $_ })
    if ($same) { continue }
    Write-Host ("  [{0}] {1}: {2} -> {3}" -f $(if ($Apply) { "attach" } else { "would attach" }), $u, $have.Count, $want.Count)
    if ($Apply) {
        $cur = Invoke-JrsGet -Jrs $to -Uri $u
        $ru = $cur.Body | ConvertFrom-Json
        if ($ru.PSObject.Properties.Name -contains "inputControls") { $ru.PSObject.Properties.Remove("inputControls") }
        if (-not ($ru.PSObject.Properties.Name -contains "controlsLayout")) { $ru | Add-Member -NotePropertyName controlsLayout -NotePropertyValue "popupScreen" -Force }
        # literal JSON for inputControls: PS 5.1 ConvertTo-Json unwraps a one-element array
        $json = $ru | ConvertTo-Json -Depth 12
        $ics = ($want | ForEach-Object { '{"inputControlReference":{"uri":"' + $_ + '"}}' }) -join ","
        $json = $json -replace '^\{', ('{"inputControls":[' + $ics + '],')
        $f = [IO.Path]::GetTempFileName(); $json | Set-Content $f -Encoding utf8
        try { $r = Invoke-JrsPut -Jrs $to -Uri $u -Overwrite -ContentType "application/repository.reportUnit+json" -JsonFile $f }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
        Assert-JrsOk -Response $r -Operation "PUT $u (controls)" | Out-Null
        $after = Get-Controls $to $u
        if ($after.Count -ne $want.Count) { throw "re-attach of $u did not stick (have $($after.Count), want $($want.Count))" }
        $fixed++
    }
}
Write-Host "  attachments fixed: $fixed  tiles missing on target: $missing"
if ($missing -gt 0) { throw "$missing tile(s) are missing on the target; deploy them first (deploy_report.ps1) -- not attempting dashboards" }

# --- 2. recompose dashboards ----------------------------------------------------
Write-Host ""; Write-Host "phase 2 - dashboards ($($manifests.Count) manifests)"
foreach ($m in $manifests) {
    $d = Get-Content $m.FullName -Raw | ConvertFrom-Json
    $u = "$($d.folder)/$($d.name)"
    $exists = Test-JrsResource -Jrs $to -Uri $u
    if (-not $Apply) { Write-Host ("  [would compose] {0} (exists on target: {1})" -f $u, $exists); continue }
    Write-Host "  composing $u"
    $wd = Join-Path "out/restore_$ToEnv" ("dash_" + $d.name)
    $cargs = @{ Manifest = $m.FullName; Replace = $true; Apply = $true; WorkDir = $wd; ServerUrl = $to.ServerUrl; User = $to.User; Password = $to.Password }
    if ($exists) { $cargs.Backup = $true }
    & (Join-Path $skill "compose_dashboard.ps1") @cargs | ForEach-Object { if ($_ -is [string]) { Write-Host "    $_" } }
    if (-not (Test-JrsResource -Jrs $to -Uri $u)) { throw "dashboard $u still absent after compose" }
}

# --- 3. verify ------------------------------------------------------------------
Write-Host ""; Write-Host "phase 3 - verify_suite -Env $ToEnv"
& (Join-Path $skill "verify_suite.ps1") -Manifest $ManifestDir -Env $ToEnv | Out-Null
