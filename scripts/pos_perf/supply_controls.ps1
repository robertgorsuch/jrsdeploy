# scripts/pos_perf/supply_controls.ps1 -- create the shared supply input
# controls once under /reports/pos_perf/controls and attach the fixed supply
# filter set to a sup_* report unit.
#
# Usage:
#   $env:JRS_ENV = "stage"
#   . .\scripts\pos_perf\supply_controls.ps1
#   New-SupplyControls                       # rerun-safe: creates what's
#                                             # missing; warns loudly (never
#                                             # silently) on anything already
#                                             # referenced that it could not
#                                             # update in place.
#   New-SupplyControls -Force                # also replaces content a plain
#                                             # rerun could not touch.
#   Attach-SupplyControls -ReportUri /reports/pos_perf/sup_kpi
#
# This file deliberately does NOT reimplement any of jrs_controls.ps1's
# idempotency/update machinery: it dot-sources jrs_controls.ps1 (same
# directory) and reuses its Test-JrsExists, Put-Json, Try-PutJson,
# Update-FinanceControl, and Attach-Controls as-is, plus the $script:jrs /
# $script:ctl ("/reports/pos_perf/controls") / $script:ds
# ("/datasources/pos_data_avalanche") those set up. Only the SQL/label/URI
# and column-mapping specifics differ here.
#
# Column mapping: jrs_controls.ps1's New-QueryControl assumes a single query
# column that is both the value AND the visible/display column (e.g.
# p_store's storenumber). The supply LOV queries instead select two aliased
# columns per the task brief -- a display-label alias and a distinct
# "...v"-suffixed value alias (sv/svv, sc/scv, ss/ssv) -- so this file adds
# one small local wrapper, New-SupplyQueryControl, that builds that
# two-column query/inputControl JSON (valueColumn = the value alias,
# visibleColumns = [the label alias]) and hands off to the SHARED
# Update-FinanceControl for the actual idempotent-create / -Force-replace PUT
# sequence, identically to how New-QueryControl itself calls
# Update-FinanceControl. This is the same shape churn_controls.ps1 uses for
# its New-ChurnQueryControl wrapper.
#
# sup_store note: its value alias (svv) is the plain store number cast to a
# string, NOT the combined "1234 - Store Name" display string used for svv's
# sibling display alias (sv). A report's WHERE clause filtering on this
# control must compare storenumber = INT4($X{IN, ...}) against svv --
# matching how p_store was handled in Phase 1's pnl_worst_stores drill --
# rather than trying to match sv's combined display text.
#
# The existing /reports/pos_perf/controls/p_regions control (Phase 0 Ops
# Console; Ontario|Western|Quebec|Atlantic vocabulary, type 7 multiSelectQuery
# same as the controls created here) is reused AS-IS -- this file never
# creates, updates, or deletes it; Attach-SupplyControls only references its
# uri in the fixed attach list.
param([string]$Env = $env:JRS_ENV)
. (Join-Path $PSScriptRoot "jrs_controls.ps1") -Env $Env

function New-SupplyQueryControl([string]$Name, [string]$Label, [string]$LabelCol, [string]$ValueCol, [string]$Sql, [int]$Type, [switch]$Force) {
    $queryJson = ("{`"label`":`"$Name query`",`"language`":`"sql`",`"value`":`"$($Sql -replace '"','\"')`"," +
        "`"dataSource`":{`"dataSourceReference`":{`"uri`":`"$script:ds`",`"version`":0}}}")
    $icJson = ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":$Type," +
        "`"valueColumn`":`"$ValueCol`",`"visibleColumns`":[`"$LabelCol`"]," +
        "`"query`":{`"queryReference`":{`"uri`":`"$script:ctl/${Name}_query`",`"version`":0}}}")
    Update-FinanceControl -Name $Name -SubName "${Name}_query" -SubContentType "application/repository.query+json" -SubJson $queryJson `
        -IcContentType "application/repository.inputControl+json" -IcJson $icJson -Force:$Force
}

function New-SupplyControls([switch]$Force) {
    # Type 7 = multiSelectQuery ("Collection"), matching the existing
    # p_regions control it sits alongside in the filter strip.
    New-SupplyQueryControl -Name "sup_store" -Label "Store" -LabelCol "sv" -ValueCol "svv" -Type 7 -Force:$Force `
        -Sql "SELECT DISTINCT VARCHAR(storenumber) || ' - ' || storename AS sv, VARCHAR(storenumber) AS svv FROM inventory ORDER BY 1"
    New-SupplyQueryControl -Name "sup_category" -Label "Category" -LabelCol "sc" -ValueCol "scv" -Type 7 -Force:$Force `
        -Sql "SELECT DISTINCT category AS sc, category AS scv FROM inventory ORDER BY 1"
    New-SupplyQueryControl -Name "sup_supplier" -Label "Supplier" -LabelCol "ss" -ValueCol "ssv" -Type 7 -Force:$Force `
        -Sql "SELECT DISTINCT supplier_name AS ss, supplier_name AS ssv FROM inventory ORDER BY 1"
}

function Attach-SupplyControls([string]$ReportUri) {
    Attach-Controls -ReportUri $ReportUri -ControlUris @(
        "/reports/pos_perf/controls/p_regions",
        "/reports/pos_perf/controls/sup_store",
        "/reports/pos_perf/controls/sup_category",
        "/reports/pos_perf/controls/sup_supplier"
    )
}
