# scripts/pos_perf/franchisee_control.ps1 -- create the single-select
# franchisee-id control that backs the Franchisee Fee Statement drill target
# (report unit /reports/pos_perf/rpt_franchisee_fee_statement).
#
# Usage:
#   $env:JRS_ENV = "stage"
#   . .\scripts\pos_perf\franchisee_control.ps1
#   New-FranchiseeControl                    # rerun-safe: creates if missing;
#                                             # warns loudly (never silently)
#                                             # on anything already referenced
#                                             # that it could not update in
#                                             # place.
#   New-FranchiseeControl -Force             # also replaces content a plain
#                                             # rerun could not touch.
#
# This file deliberately does NOT reimplement any of jrs_controls.ps1's
# idempotency/update machinery: it dot-sources jrs_controls.ps1 (same
# directory) and reuses its Test-JrsExists, Put-Json, Try-PutJson,
# Update-FinanceControl, and Attach-Controls as-is, plus the $script:jrs /
# $script:ctl ("/reports/pos_perf/controls") / $script:ds
# ("/datasources/pos_data_avalanche") those set up -- same shape as
# supply_controls.ps1's New-SupplyQueryControl wrapper.
#
# NOT the existing /reports/pos_perf/controls/p_franchisee control. That one
# is a multi-select (type 7, confirmed 2026-08-25 via GET) built for the
# Treasury console's filter strip and cannot back a single-entity Statement
# report. This file creates a SEPARATE control, p_franchisee_id, single-select
# (type 4, matching the /reports/pos_perf/controls/p_store precedent -- read
# via GET before writing this file).
#
# Column mapping: jrs_controls.ps1's New-QueryControl assumes a single query
# column that is both the value AND the visible/display column (e.g.
# p_store's storenumber). Here the value and label differ -- the query
# selects two aliased columns, fv (franchisee_id, cast to a string -- the
# submitted parameter value) and fl (owner_name -- what the picker displays)
# -- so this file adds one small local wrapper, New-FranchiseeQueryControl,
# that builds that two-column query/inputControl JSON (valueColumn = fv,
# visibleColumns = [fl]) and hands off to the SHARED Update-FinanceControl
# for the actual idempotent-create / -Force-replace PUT sequence.
param([string]$Env = $env:JRS_ENV)
. (Join-Path $PSScriptRoot "jrs_controls.ps1") -Env $Env

function New-FranchiseeQueryControl([string]$Name, [string]$Label, [string]$LabelCol, [string]$ValueCol, [string]$Sql, [int]$Type, [switch]$Force) {
    $queryJson = ("{`"label`":`"$Name query`",`"language`":`"sql`",`"value`":`"$($Sql -replace '"','\"')`"," +
        "`"dataSource`":{`"dataSourceReference`":{`"uri`":`"$script:ds`",`"version`":0}}}")
    $icJson = ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":$Type," +
        "`"valueColumn`":`"$ValueCol`",`"visibleColumns`":[`"$LabelCol`"]," +
        "`"query`":{`"queryReference`":{`"uri`":`"$script:ctl/${Name}_query`",`"version`":0}}}")
    Update-FinanceControl -Name $Name -SubName "${Name}_query" -SubContentType "application/repository.query+json" -SubJson $queryJson `
        -IcContentType "application/repository.inputControl+json" -IcJson $icJson -Force:$Force
}

function New-FranchiseeControl([switch]$Force) {
    # Type 4 = singleSelectQuery, matching the p_store precedent.
    New-FranchiseeQueryControl -Name "p_franchisee_id" -Label "Franchisee" -LabelCol "fl" -ValueCol "fv" -Type 4 -Force:$Force `
        -Sql "SELECT DISTINCT VARCHAR(franchisee_id) AS fv, owner_name AS fl FROM franchise_fee_ledger ORDER BY 2"
}
