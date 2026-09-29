#!/usr/bin/env python
"""Cross-check the POS finance dashboard tiles against the Wobby semantic layer.

Usage:
    python scripts/pos_perf/wobby_metric_crosscheck.py out/pos_perf/wobby_env_phase1.json
    python scripts/pos_perf/wobby_metric_crosscheck.py <env.json> --markdown

The env json comes from ONE GET of https://app.wobby.ai/api/public/v1/environment
(Bearer key from .claude/skills/wobby/wobby.config.json, which is gitignored;
the API rate limit is 2 requests per 5 seconds, so fetch once and re-run this
script against the saved file).

    $cfg = Get-Content ".claude\\skills\\wobby\\wobby.config.json" -Raw | ConvertFrom-Json
    $r = Invoke-WebRequest -Uri "$($cfg.baseUrl)/api/public/v1/environment" `
         -Headers @{Authorization="Bearer $($cfg.apiKey)"} -Method Get -UseBasicParsing
    [IO.File]::WriteAllText("out\\pos_perf\\wobby_env_phase1.json", $r.Content)

Why this shape:  Wobby metrics are expressions over models, not a query API, so
the check cannot be "ask Wobby for the number".  Instead, for every dashboard
KPI the script

  1. resolves the metric in the environment export:
     metric.expression is "<model>.<measure>", so it walks metric -> anchor
     model -> measure to recover the measure's SQL expression and the model's
     physical source table;
  2. compares that recovered expression against EXPECT_EXPR, the text this
     script's WOBBY_SQL was derived from, and shouts DRIFT if the semantic
     layer has been edited since;
  3. runs both the tile's SQL and the Wobby-derived SQL through sql.ps1 against
     the pos_data warehouse and reports the two numbers and their delta.

Every pair must agree within 0.5 pct or carry a one-line NOTE explaining the
difference in scope.
"""
import json
import re
import subprocess
import sys

RESOURCE_ID = "av-flm7ykoxlcvq"
SQL_PS1 = r".\.claude\skills\admiral\scripts\sql.ps1"

# (metric, tile, expect_expr, tile_sql, wobby_sql, note)
#
# expect_expr  -- the measure expression this script's WOBBY_SQL was written
#                 against; a mismatch means the semantic layer moved.
# tile_sql     -- the number the JasperReports tile puts on screen.
# wobby_sql    -- the same number expressed the way the Wobby measure defines
#                 it (its own source table, its own predicate), X100-adjusted
#                 (FLOAT8 around ratio operands, DECIMAL cast on the result).
CHECKS = [
    dict(
        metric="four_wall_ebitda",
        tile="pnl_kpi_strip.four_wall_ebitda (2020)",
        expect_expr="SUM(four_wall_ebitda)",
        tile_sql="SELECT DECIMAL(SUM(four_wall_ebitda),16,2) AS v "
                 "FROM store_pnl_monthly WHERE yr = 2020",
        wobby_sql="SELECT DECIMAL(SUM(four_wall_ebitda),16,2) AS v "
                  "FROM store_pnl_monthly WHERE yr = 2020",
        note="",
    ),
    dict(
        metric="contribution_margin_pct",
        tile="pnl_contribution_trend.actual_pct (202012)",
        expect_expr="SUM(store_contribution) / NULLIF(SUM(net_sales), 0) * 100",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(store_contribution))/FLOAT8(SUM(net_sales)),8,2) AS v "
                 "FROM store_pnl_monthly WHERE yyyymm = 202012 AND trading_status = 'Trading'",
        wobby_sql="SELECT DECIMAL(FLOAT8(SUM(store_contribution))/NULLIF(FLOAT8(SUM(net_sales)),0)*100.0,8,2) AS v "
                  "FROM store_pnl_monthly WHERE yyyymm = 202012 AND trading_status = 'Trading'",
        note="trading_only is a model filter, not a metric default; applied to both sides",
    ),
    dict(
        metric="sales_plan_attainment_pct",
        tile="pnl_kpi_strip.plan_attainment_pct (2020)",
        expect_expr="SUM(actual_sales) * 100.0 / NULLIF(SUM(target_sales), 0)",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(actual_sales))/FLOAT8(SUM(target_sales)),8,2) AS v "
                 "FROM sales_targets WHERE yr = 2020",
        wobby_sql="SELECT DECIMAL(FLOAT8(SUM(actual_sales))*100.0/NULLIF(FLOAT8(SUM(target_sales)),0),8,2) AS v "
                  "FROM sales_targets WHERE yr = 2020",
        note="",
    ),
    dict(
        metric="ar_outstanding",
        tile="trs_kpi.ar_balance",
        expect_expr="SUM(balance)",
        tile_sql="SELECT DECIMAL(SUM(balance),16,2) AS v "
                 "FROM franchise_fee_ledger WHERE status <> 'Paid'",
        wobby_sql="SELECT DECIMAL(SUM(balance),16,2) AS v "
                  "FROM franchise_fee_ledger WHERE status <> 'Paid'",
        note="metric carries no default filter; unpaid_only is a model filter the tile applies",
    ),
    dict(
        metric="ap_outstanding",
        tile="trs_kpi.ap_balance",
        expect_expr="SUM(balance)",
        tile_sql="SELECT DECIMAL(SUM(balance),16,2) AS v "
                 "FROM ap_invoices WHERE status <> 'Paid'",
        wobby_sql="SELECT DECIMAL(SUM(balance),16,2) AS v "
                  "FROM ap_invoices WHERE status <> 'Paid'",
        note="metric carries no default filter; unpaid_only is a model filter the tile applies",
    ),
    dict(
        metric="avg_days_to_pay",
        tile="trs_dpo (all terms classes)",
        expect_expr="AVG(days_to_pay)",
        tile_sql="SELECT DECIMAL(AVG(FLOAT8(days_to_pay)),8,1) AS v "
                 "FROM ap_invoices WHERE status = 'Paid'",
        wobby_sql="SELECT DECIMAL(AVG(FLOAT8(days_to_pay)),8,1) AS v "
                  "FROM ap_invoices WHERE status = 'Paid'",
        note="",
    ),
    dict(
        metric="cashless_share_pct",
        tile="trs_kpi.cashless_pct (202012)",
        expect_expr="SUM(CASE WHEN tender_type <> 'Cash' THEN amount ELSE 0 END) / NULLIF(SUM(amount), 0) * 100",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(CASE WHEN tender_group <> 'Cash' THEN amount ELSE 0 END))"
                 "/FLOAT8(SUM(amount)),8,1) AS v FROM dash_tender_monthly WHERE yyyymm = 202012",
        wobby_sql="SELECT DECIMAL(FLOAT8(SUM(CASE WHEN tender_type <> 'Cash' THEN amount ELSE 0 END))"
                  "/NULLIF(FLOAT8(SUM(amount)),0)*100.0,8,1) AS v "
                  "FROM tender_summary_daily WHERE yyyymm = 202012",
        note="different source (tile reads the dash_tender_monthly aggregate) and different "
             "column (tender_group vs tender_type); agreement proves the aggregate is faithful",
    ),
    dict(
        metric="tax_collected",
        tile="trs_tax_province (2020)",
        expect_expr="SUM(total_tax_collected)",
        tile_sql="SELECT DECIMAL(SUM(total_tax_collected),16,2) AS v "
                 "FROM tax_collected_monthly WHERE yr = 2020",
        wobby_sql="SELECT DECIMAL(SUM(total_tax_collected),16,2) AS v "
                  "FROM tax_collected_monthly WHERE yr = 2020",
        note="",
    ),
    dict(
        metric="gift_card_liability_cad",
        tile="trs_liability.gift (202012)",
        expect_expr="MAX(closing_liability)",
        tile_sql="SELECT DECIMAL(closing_liability,16,2) AS v "
                 "FROM gift_card_liability_monthly WHERE yyyymm = 202012",
        wobby_sql="SELECT DECIMAL(MAX(closing_liability),16,2) AS v "
                  "FROM gift_card_liability_monthly WHERE yyyymm = 202012",
        note="one row per month, so MAX and the row value are the same number",
    ),
    dict(
        metric="loyalty_liability_cad",
        tile="trs_liability.loyalty (202012)",
        expect_expr="MAX(closing_liability_cad)",
        tile_sql="SELECT DECIMAL(closing_liability_cad,16,2) AS v "
                 "FROM loyalty_liability_monthly WHERE yyyymm = 202012",
        wobby_sql="SELECT DECIMAL(MAX(closing_liability_cad),16,2) AS v "
                  "FROM loyalty_liability_monthly WHERE yyyymm = 202012",
        note="one row per month, so MAX and the row value are the same number",
    ),
    dict(
        metric="total_net_book_value",
        tile="(reference only, no Phase 1 tile)",
        expect_expr="SUM(net_book_value)",
        tile_sql="SELECT DECIMAL(SUM(net_book_value),16,2) AS v FROM store_assets",
        wobby_sql="SELECT DECIMAL(SUM(net_book_value),16,2) AS v FROM store_assets",
        note="asset register total; trs_lease_expiry counts leases, it does not sum NBV",
    ),

    # -- Phase 4 (growth: Store Network + Marketing and Digital) -----------------
    dict(
        metric="ecommerce_revenue_share_pct",
        tile="mkt_kpi.ecom_share_pct (lifetime)",
        expect_expr="ecommerce_orders.total_order_value / NULLIF(ecommerce_orders.total_order_value + pos.total_sales, 0) * 100",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8((SELECT SUM(order_value) FROM dash_ecom_monthly))"
                 "/FLOAT8(NULLIF((SELECT SUM(net_sales) FROM store_pnl_monthly),0)),8,2) AS v FROM (SELECT 1 AS x) dual",
        wobby_sql="SELECT DECIMAL(100.0*FLOAT8((SELECT SUM(order_value) FROM ecommerce_orders))"
                  "/FLOAT8(NULLIF((SELECT SUM(order_value) FROM ecommerce_orders)"
                  "+(SELECT SUM(sellingprice*quantity) FROM pos_sales_detail),0)),8,2) AS v FROM (SELECT 1 AS x) dual",
        note="different revenue base by construction: tile denominator is store_pnl_monthly.net_sales "
             "(store-month rollup); wobby denominator is ecommerce_orders.total_order_value + "
             "pos_sales_detail.total_sales (raw line-level gross extension) - agreement not expected exact",
    ),
    dict(
        metric="ecommerce_late_fulfillment_rate",
        tile="mkt_kpi.late_pct (lifetime)",
        expect_expr="COUNT(DISTINCT CASE WHEN ecommerce_orders.fulfilled_late = 'Y' THEN ecommerce_orders.order_id END)"
                    " * 100.0 / NULLIF(COUNT(DISTINCT ecommerce_orders.order_id), 0)",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(late_orders))/FLOAT8(NULLIF(SUM(orders),0)),8,2) AS v "
                 "FROM dash_ecom_monthly",
        wobby_sql="SELECT DECIMAL(100.0*FLOAT8(COUNT(DISTINCT CASE WHEN fulfilled_late='Y' THEN order_id END))"
                  "/FLOAT8(NULLIF(COUNT(DISTINCT order_id),0)),8,2) AS v FROM ecommerce_orders",
        note="",
    ),
    dict(
        metric="avg_ecommerce_satisfaction_score",
        tile="mkt_partners.avg_satisfaction (network-wide reference, all delivery_partner incl Pickup)",
        expect_expr="AVG(satisfaction_score)",
        tile_sql="SELECT DECIMAL(SUM(avg_satisfaction*orders)/NULLIF(SUM(orders),0),8,2) AS v FROM dash_ecom_monthly",
        wobby_sql="SELECT DECIMAL(AVG(FLOAT8(satisfaction_score)),8,2) AS v FROM ecommerce_orders",
        note="tile side is an order-weighted average of dash_ecom_monthly's monthly-partner means "
             "(two-level aggregation); wobby side is a plain AVG over every raw order row",
    ),
    dict(
        metric="email_open_rate",
        tile="mkt_kpi.open_pct (lifetime)",
        expect_expr="email_engagement.emails_opened * 100.0 / NULLIF(email_engagement.emails_sent, 0)",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(opened))/FLOAT8(NULLIF(SUM(sent),0)),8,2) AS v FROM dash_email",
        wobby_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(CASE WHEN opened_flag='Y' THEN 1 ELSE 0 END))"
                  "/FLOAT8(NULLIF(COUNT(*),0)),8,2) AS v FROM email_engagement",
        note="",
    ),
    dict(
        metric="email_click_rate",
        tile="mkt_kpi.click_pct (lifetime)",
        expect_expr="email_engagement.emails_clicked * 100.0 / NULLIF(email_engagement.emails_sent, 0)",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(clicked))/FLOAT8(NULLIF(SUM(sent),0)),8,2) AS v FROM dash_email",
        wobby_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(CASE WHEN clicked_flag='Y' THEN 1 ELSE 0 END))"
                  "/FLOAT8(NULLIF(COUNT(*),0)),8,2) AS v FROM email_engagement",
        note="",
    ),
    dict(
        metric="email_conversion_rate",
        tile="mkt_funnel.pct_of_sent (Converted stage)",
        expect_expr="email_engagement.conversions * 100.0 / NULLIF(email_engagement.emails_sent, 0)",
        tile_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(converted))/FLOAT8(NULLIF(SUM(sent),0)),8,2) AS v FROM dash_email",
        wobby_sql="SELECT DECIMAL(100.0*FLOAT8(SUM(CASE WHEN converted_flag='Y' THEN 1 ELSE 0 END))"
                  "/FLOAT8(NULLIF(COUNT(*),0)),8,2) AS v FROM email_engagement",
        note="",
    ),
    dict(
        metric="promotion_roi",
        tile="mkt_kpi.promo_roi (lifetime, whole promotions table, no subsidy floor)",
        expect_expr="promotions.total_promo_margin / NULLIF(promotions.total_marketing_subsidy, 0)",
        tile_sql="SELECT DECIMAL(FLOAT8(SUM(promo_margin))/FLOAT8(NULLIF(SUM(marketing_subsidy),0)),16,2) AS v "
                 "FROM promotions",
        wobby_sql="SELECT DECIMAL(FLOAT8(SUM(promo_margin))/FLOAT8(NULLIF(SUM(marketing_subsidy),0)),16,2) AS v "
                  "FROM promotions",
        note="mkt_kpi's promo_roi is the unfiltered lifetime ratio over the whole promotions table - the "
             "SAME source/expression Wobby's metric uses, so this is expected to MATCH exactly, unlike "
             "mkt_campaign_roi's chart which applies a $1,000 subsidy floor as a display-ranking choice",
    ),
    dict(
        metric="subsidy_cost_per_conversion",
        tile="(reference only, no Phase 4 tile computes this network aggregate)",
        expect_expr="marketing_campaigns.total_budget / NULLIF(marketing_campaigns.total_conversions, 0)",
        tile_sql="SELECT DECIMAL(FLOAT8(SUM(budget_subsidy))/FLOAT8(NULLIF(SUM(recipients_converted),0)),12,2) AS v "
                 "FROM marketing_campaigns",
        wobby_sql="SELECT DECIMAL(FLOAT8(SUM(budget_subsidy))/FLOAT8(NULLIF(SUM(recipients_converted),0)),12,2) AS v "
                  "FROM marketing_campaigns",
        note="mkt_campaign_roi's own per-row subsidy_per_conversion field uses promotions.total_transactions "
             "as its denominator (POS transaction count during the promo), a different concept from this "
             "metric's marketing_campaigns.recipients_converted (email-attributed conversions) - not comparable "
             "to the tile, this check validates the Wobby definition against its own source table only",
    ),
    dict(
        metric="total_campaign_conversions",
        tile="dash_email SUM(converted) (network total; Task 1 verified agg_sent = src_sent exactly)",
        expect_expr="SUM(recipients_converted)",
        tile_sql="SELECT DECIMAL(SUM(converted),12,0) AS v FROM dash_email",
        wobby_sql="SELECT DECIMAL(SUM(recipients_converted),12,0) AS v FROM marketing_campaigns",
        note="dash_email.converted sums email_engagement.converted_flag='Y' events per campaign x month; "
             "marketing_campaigns.recipients_converted is a separate precomputed column on the campaigns "
             "table - agreement confirms the two independently-computed conversion counts tie out",
    ),
]


_SIMPLE_MODEL_MEASURE = re.compile(r"^[A-Za-z_]\w*\.[A-Za-z_]\w*$")


def _table_for_model(env, model_name):
    model = next((m for m in env.get("models", []) if m.get("name") == model_name), None)
    if model is None:
        return None
    # source.path is ["schema", "table"]; Ingres pads CHAR columns, so strip.
    path = [str(p).strip() for p in (model.get("source", {}).get("path") or [])]
    return ".".join(path)


def resolve(env, metric_name):
    """metric -> (source table, measure expression, diagnostic).

    Two shapes of metric.expression show up in this environment export:
    (a) the simple Phase 1 finance shape, a literal "<model>.<measure>"
        reference that has to be walked to the measure's own expression to
        see the real SQL; (b) a Phase 4+ shape, a full compound SQL
        expression that already IS the thing to diff against expect_expr,
        with the model to source from named separately in anchor_model.
    Treating (b) as (a) - splitting on the first "." and looking for a
    "measure" by the resulting garbage substring - produced a false
    "measure ... missing" diagnostic for every Phase 4 metric even though
    the values matched; this branches on shape instead of assuming (a).
    """
    metric = next((m for m in env.get("metrics", []) if m.get("name") == metric_name), None)
    if metric is None:
        return None, None, "METRIC MISSING FROM ENVIRONMENT"
    expr = metric.get("expression") or metric.get("formula") or ""
    if not expr:
        return None, expr, "metric has no expression"

    if _SIMPLE_MODEL_MEASURE.match(expr):
        model_name, measure_name = expr.split(".", 1)
        table = _table_for_model(env, model_name)
        if table is None:
            return None, expr, "anchor model %s missing" % model_name
        model = next((m for m in env.get("models", []) if m.get("name") == model_name), None)
        members = list(model.get("measures") or []) + list(model.get("metrics") or [])
        measure = next((x for x in members if x.get("name") == measure_name), None)
        if measure is None:
            return table, expr, "measure %s missing on model %s" % (measure_name, model_name)
        return table, (measure.get("expression") or ""), ""

    # compound expression: anchor_model names the table directly, and expr
    # IS the thing to compare against expect_expr - no further drilling.
    anchor = metric.get("anchor_model") or ""
    table = _table_for_model(env, anchor) if anchor else None
    if table is None:
        return None, expr, "anchor model %s missing" % (anchor or "?")
    return table, expr, ""


def run_sql(sql):
    """Run one scalar SELECT through sql.ps1 and return the value as text."""
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
         '& "%s" -Action query -ResourceId %s -Sql "%s"' % (SQL_PS1, RESOURCE_ID, sql.replace('"', '""'))],
        capture_output=True, text=True)
    lines = [ln.rstrip() for ln in proc.stdout.splitlines()]
    for i, ln in enumerate(lines):
        if re.match(r"^-+(\s+-+)*\s*$", ln) and ln.strip():
            for candidate in lines[i + 1:]:
                if candidate.strip():
                    return candidate.strip()
            break
    return "ERROR: " + (proc.stderr.strip() or "no rows")[:120]


def as_float(text):
    try:
        return float(text.replace(",", ""))
    except (ValueError, AttributeError):
        return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    env = json.load(open(sys.argv[1], encoding="utf-8"))
    markdown = "--markdown" in sys.argv
    exported = env.get("exported_at", "?")
    print("Wobby environment export: %s  (%d models, %d metrics)"
          % (exported, len(env.get("models", [])), len(env.get("metrics", []))))
    print("")

    rows = []
    for chk in CHECKS:
        table, expr, diag = resolve(env, chk["metric"])
        drift = ""
        if diag:
            drift = diag
        elif expr.strip() != chk["expect_expr"].strip():
            drift = "DRIFT: env says %r, script derived from %r" % (expr, chk["expect_expr"])
        tile_val = run_sql(chk["tile_sql"])
        wob_val = run_sql(chk["wobby_sql"])
        a, b = as_float(tile_val), as_float(wob_val)
        if a is None or b is None:
            verdict = "NO VALUE"
        elif a == b:
            verdict = "MATCH"
        elif b != 0 and abs(a - b) / abs(b) <= 0.005:
            verdict = "MATCH (within 0.5 pct)"
        else:
            verdict = "DELTA %.4f pct" % (100.0 * (a - b) / b if b else float("nan"))
        rows.append(dict(metric=chk["metric"], tile=chk["tile"], table=table or "?",
                         expr=expr or "?", tile_val=tile_val, wob_val=wob_val,
                         verdict=verdict, drift=drift, note=chk["note"]))

    if markdown:
        print("| Wobby metric | Model source | Measure expression | Tile | Tile value | Wobby value | Verdict |")
        print("|---|---|---|---|---|---|---|")
        for r in rows:
            print("| `%s` | `%s` | `%s` | %s | %s | %s | %s |"
                  % (r["metric"], r["table"], r["expr"], r["tile"],
                     r["tile_val"], r["wob_val"], r["verdict"]))
        print("")
        for r in rows:
            if r["note"]:
                print("- `%s`: %s" % (r["metric"], r["note"]))
            if r["drift"]:
                print("- `%s`: **%s**" % (r["metric"], r["drift"]))
    else:
        for r in rows:
            print("%-26s | %-42s | %-14s" % (r["metric"], r["tile"], r["verdict"]))
            print("    model source : %s" % r["table"])
            print("    wobby expr   : %s" % r["expr"])
            print("    tile  value  : %s" % r["tile_val"])
            print("    wobby value  : %s" % r["wob_val"])
            if r["note"]:
                print("    note         : %s" % r["note"])
            if r["drift"]:
                print("    ** %s" % r["drift"])
            print("")

    bad = [r for r in rows if r["verdict"].startswith("DELTA") or r["verdict"] == "NO VALUE" or r["drift"]]
    print("")
    print("%d of %d checks clean; %d need a look." % (len(rows) - len(bad), len(rows), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
