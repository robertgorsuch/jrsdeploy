# scripts/pos_perf/churn_controls.ps1 -- create the shared churn input
# controls once under /reports/pos_perf/controls and attach the fixed churn
# filter set to a chn_* report unit.
#
# Usage:
#   $env:JRS_ENV = "stage"
#   . .\scripts\pos_perf\churn_controls.ps1
#   New-ChurnControls                        # rerun-safe: creates what's
#                                             # missing; warns loudly (never
#                                             # silently) on anything already
#                                             # referenced that it could not
#                                             # update in place.
#   New-ChurnControls -Force                 # also replaces content a plain
#                                             # rerun could not touch.
#   Attach-ChurnControls -ReportUri /reports/pos_perf/chn_kpi
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
# p_franchisee's franchisee_id). The churn LOV queries instead select two
# aliased columns per the task brief -- a display-label alias and a distinct
# "...v"-suffixed value alias (ds/dsv, lt/ltv, rb/rbv) -- so this file adds
# one small local wrapper, New-ChurnQueryControl, that builds that two-column
# query/inputControl JSON (valueColumn = the value alias, visibleColumns =
# [the label alias]) and hands off to the SHARED Update-FinanceControl for
# the actual idempotent-create / -Force-replace PUT sequence, identically to
# how New-QueryControl itself calls Update-FinanceControl.
#
# The existing /reports/pos_perf/controls/p_regions control (Phase 0 Ops
# Console; Ontario|Western|Quebec|Atlantic vocabulary, type 7 multiSelectQuery
# same as the controls created here) is reused AS-IS -- this file never
# creates, updates, or deletes it; Attach-ChurnControls only references its
# uri in the fixed attach list.
param([string]$Env = $env:JRS_ENV)
. (Join-Path $PSScriptRoot "jrs_controls.ps1") -Env $Env

function New-ChurnQueryControl([string]$Name, [string]$Label, [string]$LabelCol, [string]$ValueCol, [string]$Sql, [int]$Type, [switch]$Force) {
    $queryJson = ("{`"label`":`"$Name query`",`"language`":`"sql`",`"value`":`"$($Sql -replace '"','\"')`"," +
        "`"dataSource`":{`"dataSourceReference`":{`"uri`":`"$script:ds`",`"version`":0}}}")
    $icJson = ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":$Type," +
        "`"valueColumn`":`"$ValueCol`",`"visibleColumns`":[`"$LabelCol`"]," +
        "`"query`":{`"queryReference`":{`"uri`":`"$script:ctl/${Name}_query`",`"version`":0}}}")
    Update-FinanceControl -Name $Name -SubName "${Name}_query" -SubContentType "application/repository.query+json" -SubJson $queryJson `
        -IcContentType "application/repository.inputControl+json" -IcJson $icJson -Force:$Force
}

function New-ChurnControls([switch]$Force) {
    # Type 7 = multiSelectQuery ("Collection"), matching the existing
    # p_regions/p_franchisee controls it sits alongside in the filter strip.
    # dash_churn's score_date currently carries a single value (2020-12-31)
    # but the query is DISTINCT-over-the-live-table, so it keeps working
    # unchanged when the churn model is re-run with a later cutoff.
    New-ChurnQueryControl -Name "chn_score_date" -Label "Score date" -LabelCol "ds" -ValueCol "dsv" -Type 7 -Force:$Force `
        -Sql "SELECT DISTINCT VARCHAR(score_date) AS ds, VARCHAR(score_date) AS dsv FROM dash_churn ORDER BY 1"
    New-ChurnQueryControl -Name "chn_tier" -Label "Loyalty tier" -LabelCol "lt" -ValueCol "ltv" -Type 7 -Force:$Force `
        -Sql "SELECT DISTINCT loyalty_tier AS lt, loyalty_tier AS ltv FROM dash_churn ORDER BY 1"
    New-ChurnQueryControl -Name "chn_band" -Label "Risk band" -LabelCol "rb" -ValueCol "rbv" -Type 7 -Force:$Force `
        -Sql ("SELECT DISTINCT risk_band AS rb, risk_band AS rbv FROM dash_churn WHERE risk_band IN ('Critical','High','Watch','Low') " +
              "ORDER BY DECODE(risk_band, 'Critical', 1, 'High', 2, 'Watch', 3, 'Low', 4)")
}

function Attach-ChurnControls([string]$ReportUri) {
    Attach-Controls -ReportUri $ReportUri -ControlUris @(
        "/reports/pos_perf/controls/chn_score_date",
        "/reports/pos_perf/controls/p_regions",
        "/reports/pos_perf/controls/chn_tier",
        "/reports/pos_perf/controls/chn_band"
    )
}
