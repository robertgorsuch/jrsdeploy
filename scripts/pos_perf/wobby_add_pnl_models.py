"""wobby_add_pnl_models.py -- register store_pnl_monthly and
store_budget_vs_actual in the Wobby POS Sales Analyst semantic layer.

Adds
  models        store_pnl (store_pnl_monthly), store_budget (store_budget_vs_actual)
  relationships store_pnl -> stores, store_pnl -> franchisees,
                store_budget -> stores, store_budget -> franchisees
  metrics       total_opex, store_contribution, contribution_margin_pct,
                four_wall_ebitda, four_wall_margin_pct, loaded_labour_pct_of_sales,
                occupancy_pct_of_sales, total_royalty_revenue,
                total_marketing_fee_revenue, total_promo_subsidy_income,
                budget_net_sales, budget_store_contribution,
                sales_variance_vs_budget, opex_variance_vs_budget,
                contribution_variance_vs_budget
  glossary      Four-Wall EBITDA, Store Contribution, Occupancy Cost,
                Labour Burden, Royalty Fee, Marketing Fee, Budget Version,
                Reforecast
  instructions  Finance section, metric reference rows, model reference,
                SCOR Cost and Profitability rows

Usage
  python scripts/pos_perf/wobby_add_pnl_models.py          # body only
  python scripts/pos_perf/wobby_add_pnl_models.py --put    # body + PUT + verify
Starts from the latest environment GET (one call), so it layers on whatever
is live. Rate limit 2 requests per 5 seconds: one GET, one PUT, one GET.
"""

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wobby_fix_defects import CFG, OUT, dim, filt, gen_id, meas  # noqa: E402

GRAINS = ["month", "quarter", "year"]


def gloss(term, definition, synonyms, tags):
    return {"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": synonyms, "tags": tags, "mappings": []}


def metric(name, expr, anchor, unit, precision, desc, guide, gb, tdim="month_date", filters=None):
    return {"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
            "expression": expr, "anchor_model": anchor, "unit": unit, "precision": precision,
            "time_dimension": {"model": anchor, "dimension": tdim}, "time_grains": GRAINS,
            "group_by_dimensions": gb, "filters": filters or []}


def build(env):
    models = {m["name"]: m for m in env["models"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next(d["id"] for d in models[model]["dimensions"] if d["name"] == dimension)

    # ---------------------------------------------------------------- store_pnl
    P = "store_pnl"
    if P not in models:
        shared_dims = [
            dim(P, "store_number", "storenumber", "number", "Store number, joins stores"),
            dim(P, "store_name", "storename", "string", "Store name"),
            dim(P, "franchisee_id", "franchisee_id", "number", "Franchisee, joins franchisees"),
            dim(P, "province", "province", "enum", "Store province"),
            dim(P, "region", "region", "enum", "Store region: Western, Ontario, Quebec, Atlantic"),
            dim(P, "store_format", "store_format", "enum", "Standalone, Shopping Mall, Strip Plaza, Urban Storefront"),
            dim(P, "year_month", "yyyymm", "number", "Calendar month as yyyymm"),
            dim(P, "month_date", "month_start", "date", "First day of the month, for time grains", grains=GRAINS),
            dim(P, "year", "yr", "number", "Calendar year"),
            dim(P, "month", "mo", "number", "Calendar month 1-12"),
            dim(P, "pandemic_period", "pandemic_period", "enum", "Pre-pandemic or Pandemic"),
            dim(P, "trading_status", "trading_status", "enum", "Trading, Closed (after the store last sale), No sales"),
            dim(P, "opening_month", "opening_month", "enum", "Y in the month the store opened"),
        ]
        model = {
            "id": gen_id("model", P), "name": P,
            "description": ("Store x month contribution statement (7,891 rows, 330 stores, open month through 2020-12), franchisee view. "
                            "REAL: net sales, returns, COGS, gross margin, transactions, promo subsidy income, royalty and marketing fees at the real franchisee rates, "
                            "labour hours and cost from shifts, shrinkage, delivery orders and fees. MODELED and anchored: labour burden, occupancy (sqft x rate by format and province), "
                            "utilities (sqft, scaled by the real monthly temperature), delivery partner commission, card processing fees, other opex. "
                            "Sales, COGS and margin reconcile to pos_sales_detail to the cent."),
            "agent_guidance": ("One row per store per month -- SUM across rows for totals, never average the pct columns (recompute from sums). "
                               "four_wall_ebitda = gross margin + promo subsidy income - store operating costs (before franchise fees). "
                               "store_contribution = four_wall_ebitda - royalty - marketing fee. Filter trading_status = 'Trading' for performance rankings: "
                               "Closed months (13 stores closed before 2020-12) and No sales months still carry costs. Labour is the real shift schedule, which is flat "
                               "(about 8.8K CAD per store-month regardless of volume), so stores under ~70K monthly sales run negative contribution -- that is the data, not an error. "
                               "Join store_number to stores, franchisee_id to franchisees. For plan-vs-actual use store_budget."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "store_pnl_monthly"]},
            "dimensions": shared_dims,
            "measures": [
                meas(P, "store_months", "COUNT(*)", "Store-month rows", "rows", 0),
                meas(P, "total_net_sales", "SUM(net_sales)", "Net sales, Regular Sale", "CAD", 2),
                meas(P, "total_returns_value", "SUM(returns_value)", "Value of Regular Return transactions (negative)", "CAD", 2),
                meas(P, "total_cogs", "SUM(cogs)", "Cost of goods sold", "CAD", 2),
                meas(P, "total_gross_margin", "SUM(gross_margin)", "Sales minus COGS", "CAD", 2),
                meas(P, "gross_margin_pct", "SUM(gross_margin) / NULLIF(SUM(net_sales), 0) * 100", "Gross margin as percent of sales", "%", 2),
                meas(P, "total_transactions", "SUM(transactions)", "Regular Sale transactions", "transactions", 0),
                meas(P, "total_units", "SUM(units)", "Units sold", "units", 0),
                meas(P, "total_promo_subsidy_income", "SUM(promo_subsidy_income)", "Promotion subsidy credited to the store", "CAD", 2),
                meas(P, "total_vendor_coop_subsidy", "SUM(vendor_coop_subsidy)", "Vendor co-op component of the subsidy (informational, part of promo_subsidy_income)", "CAD", 2),
                meas(P, "total_labour_hours", "SUM(labour_hours)", "Scheduled labour hours", "hours", 1),
                meas(P, "total_labour_cost", "SUM(labour_cost)", "Labour cost before burden (real shift wages)", "CAD", 2),
                meas(P, "total_labour_burden", "SUM(labour_burden)", "Employer burden on labour (modeled 12-20 pct by province)", "CAD", 2),
                meas(P, "total_labour_loaded", "SUM(labour_cost + labour_burden)", "Labour cost including burden", "CAD", 2),
                meas(P, "total_occupancy_cost", "SUM(occupancy_cost)", "Rent and occupancy (modeled from sqft, format, province)", "CAD", 2),
                meas(P, "total_utilities_cost", "SUM(utilities_cost)", "Utilities (modeled from sqft and real monthly temperature)", "CAD", 2),
                meas(P, "total_shrinkage_cost", "SUM(shrinkage_cost)", "Inventory shrink at cost (real)", "CAD", 2),
                meas(P, "total_delivery_partner_cost", "SUM(delivery_partner_cost)", "Delivery partner commission net of fees collected", "CAD", 2),
                meas(P, "total_card_processing_fees", "SUM(card_processing_fees)", "Card processing fees (modeled rate on sales)", "CAD", 2),
                meas(P, "total_other_opex", "SUM(other_opex)", "Other operating expense (modeled 1.5-3 pct of sales)", "CAD", 2),
                meas(P, "total_store_opex", "SUM(total_store_opex)", "All store operating costs before franchise fees", "CAD", 2),
                meas(P, "total_royalty_fee", "SUM(royalty_fee)", "Royalty fee to the franchisor (royalty base x 4-6 pct)", "CAD", 2),
                meas(P, "total_marketing_fee", "SUM(marketing_fee)", "Marketing fee to the franchisor (net sales x 1-2 pct)", "CAD", 2),
                meas(P, "total_franchise_fees", "SUM(franchise_fees)", "Royalty plus marketing fee", "CAD", 2),
                meas(P, "total_opex", "SUM(total_opex)", "Store opex plus franchise fees", "CAD", 2),
                meas(P, "total_four_wall_ebitda", "SUM(four_wall_ebitda)", "Gross margin + subsidy income - store opex", "CAD", 2),
                meas(P, "four_wall_margin_pct", "SUM(four_wall_ebitda) / NULLIF(SUM(net_sales), 0) * 100", "Four-wall EBITDA as percent of sales", "%", 2),
                meas(P, "total_store_contribution", "SUM(store_contribution)", "Four-wall EBITDA minus franchise fees", "CAD", 2),
                meas(P, "contribution_margin_pct", "SUM(store_contribution) / NULLIF(SUM(net_sales), 0) * 100", "Store contribution as percent of sales", "%", 2),
                meas(P, "labour_pct_of_sales", "SUM(labour_cost + labour_burden) / NULLIF(SUM(net_sales), 0) * 100", "Loaded labour as percent of sales", "%", 2),
                meas(P, "occupancy_pct_of_sales", "SUM(occupancy_cost) / NULLIF(SUM(net_sales), 0) * 100", "Occupancy as percent of sales", "%", 2),
                meas(P, "store_opex_pct_of_sales", "SUM(total_store_opex) / NULLIF(SUM(net_sales), 0) * 100", "Store opex as percent of sales", "%", 2),
                meas(P, "avg_sales_per_sqft", "SUM(net_sales) / NULLIF(SUM(square_feet), 0)", "Monthly sales per square foot (sum of sales over sum of sqft-months)", "CAD", 2),
                meas(P, "loss_making_store_months", "SUM(CASE WHEN store_contribution < 0 THEN 1 ELSE 0 END)", "Store-months with negative contribution", "rows", 0),
                meas(P, "stores_count", "COUNT(DISTINCT storenumber)", "Distinct stores", "stores", 0),
            ],
            "filters": [
                filt(P, "trading_only", "trading_status = 'Trading'", "Months in which the store traded (default for rankings)"),
                filt(P, "loss_making_only", "store_contribution < 0", "Store-months with negative contribution"),
                filt(P, "pandemic_only", "pandemic_period = 'Pandemic'", "Months from 2020-03 onward"),
            ],
        }
        env["models"].append(model)
        models[P] = model
        access["models"].append({"name": P, "dimensions": [d["name"] for d in model["dimensions"]],
                                 "measures": [m["name"] for m in model["measures"]], "filters": [f["name"] for f in model["filters"]]})
        for name, desc, to_model, fk, tk in [
            ("pnl_to_store", "Each P&L row belongs to one store", "stores", "store_number", "storenumber"),
            ("pnl_to_franchisee", "Each P&L row belongs to the store owner", "franchisees", "franchisee_id", "franchisee_id"),
        ]:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc, "from_model": P,
                                         "from_key": key(P, fk), "to_model": to_model, "to_key": key(to_model, tk),
                                         "type": "many_to_one", "join_type": "left"})
        changes.append("model store_pnl + 2 relationships")

    # ---------------------------------------------------------------- store_budget
    B = "store_budget"
    if B not in models:
        model = {
            "id": gen_id("model", B), "name": B,
            "description": ("Budget next to actual for every store_pnl line at store x month x budget_version grain (10,854 rows) with variances. "
                            "Original: every month, 2019 = actual +-10 pct, 2020 = the 2019 same-month actual plus 3-8 pct growth (a plan set in late 2019 "
                            "that does not know about the pandemic). Reforecast Q2 2020: 2020-04 to 2020-12, actual +-8 pct, the April 2020 re-plan. Budget lines are "
                            "deterministic and anchored to the real actuals in store_pnl."),
            "agent_guidance": ("ALWAYS filter to one budget_version (default 'Original'), otherwise 2020-04 onward is double counted. "
                               "Variance = actual - budget, positive sales variance is good, positive opex variance is bad. "
                               "The 2020 Original plan misses the March-April stock-up (+40 pct sales vs plan): use it for 'how far did the pandemic move us off plan', "
                               "and Reforecast Q2 2020 for 'are we on the re-plan'. budget_basis says how each row was derived "
                               "(LY+growth, Actual+-10, Actual+-8). Filter trading_status = 'Trading' for rankings."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "store_budget_vs_actual"]},
            "dimensions": [
                dim(B, "store_number", "storenumber", "number", "Store number, joins stores"),
                dim(B, "store_name", "storename", "string", "Store name"),
                dim(B, "franchisee_id", "franchisee_id", "number", "Franchisee, joins franchisees"),
                dim(B, "province", "province", "enum", "Store province"),
                dim(B, "region", "region", "enum", "Store region"),
                dim(B, "store_format", "store_format", "enum", "Store format"),
                dim(B, "year_month", "yyyymm", "number", "Calendar month as yyyymm"),
                dim(B, "month_date", "month_start", "date", "First day of the month, for time grains", grains=GRAINS),
                dim(B, "year", "yr", "number", "Calendar year"),
                dim(B, "month", "mo", "number", "Calendar month 1-12"),
                dim(B, "pandemic_period", "pandemic_period", "enum", "Pre-pandemic or Pandemic"),
                dim(B, "trading_status", "trading_status", "enum", "Trading, Closed, No sales"),
                dim(B, "budget_version", "budget_version", "enum", "Original or Reforecast Q2 2020 -- always filter to one"),
                dim(B, "budget_basis", "budget_basis", "enum", "LY+growth, Actual+-10, Actual+-8"),
                dim(B, "budget_set_date", "budget_set_date", "date", "Date the budget version was set"),
                dim(B, "sales_on_plan", "sales_on_plan", "enum", "Y when actual sales met the budget"),
                dim(B, "opex_on_plan", "opex_on_plan", "enum", "Y when actual total opex was at or under budget"),
            ],
            "measures": [
                meas(B, "budget_rows", "COUNT(*)", "Store-month-version rows", "rows", 0),
                meas(B, "actual_net_sales", "SUM(actual_net_sales)", "Actual net sales", "CAD", 2),
                meas(B, "budget_net_sales", "SUM(budget_net_sales)", "Budgeted net sales", "CAD", 2),
                meas(B, "sales_variance", "SUM(sales_variance)", "Actual minus budget sales", "CAD", 2),
                meas(B, "sales_variance_pct", "SUM(sales_variance) / NULLIF(SUM(budget_net_sales), 0) * 100", "Sales variance as percent of budget", "%", 2),
                meas(B, "actual_transactions", "SUM(actual_transactions)", "Actual transactions", "transactions", 0),
                meas(B, "budget_transactions", "SUM(budget_transactions)", "Budgeted transactions", "transactions", 0),
                meas(B, "actual_gross_margin", "SUM(actual_gross_margin)", "Actual gross margin", "CAD", 2),
                meas(B, "budget_gross_margin", "SUM(budget_gross_margin)", "Budgeted gross margin", "CAD", 2),
                meas(B, "gross_margin_variance", "SUM(gross_margin_variance)", "Actual minus budget gross margin", "CAD", 2),
                meas(B, "actual_labour_cost", "SUM(actual_labour_cost)", "Actual loaded labour", "CAD", 2),
                meas(B, "budget_labour_cost", "SUM(budget_labour_cost)", "Budgeted loaded labour", "CAD", 2),
                meas(B, "labour_variance", "SUM(labour_variance)", "Actual minus budget labour (positive = over budget)", "CAD", 2),
                meas(B, "actual_total_store_opex", "SUM(actual_total_store_opex)", "Actual store opex", "CAD", 2),
                meas(B, "budget_total_store_opex", "SUM(budget_total_store_opex)", "Budgeted store opex", "CAD", 2),
                meas(B, "store_opex_variance", "SUM(store_opex_variance)", "Actual minus budget store opex", "CAD", 2),
                meas(B, "actual_total_opex", "SUM(actual_total_opex)", "Actual total opex incl. franchise fees", "CAD", 2),
                meas(B, "budget_total_opex", "SUM(budget_total_opex)", "Budgeted total opex", "CAD", 2),
                meas(B, "opex_variance", "SUM(opex_variance)", "Actual minus budget total opex (positive = over budget)", "CAD", 2),
                meas(B, "actual_four_wall_ebitda", "SUM(actual_four_wall_ebitda)", "Actual four-wall EBITDA", "CAD", 2),
                meas(B, "budget_four_wall_ebitda", "SUM(budget_four_wall_ebitda)", "Budgeted four-wall EBITDA", "CAD", 2),
                meas(B, "actual_store_contribution", "SUM(actual_store_contribution)", "Actual store contribution", "CAD", 2),
                meas(B, "budget_store_contribution", "SUM(budget_store_contribution)", "Budgeted store contribution", "CAD", 2),
                meas(B, "contribution_variance", "SUM(contribution_variance)", "Actual minus budget contribution", "CAD", 2),
                meas(B, "contribution_variance_pct", "SUM(contribution_variance) / NULLIF(ABS(SUM(budget_store_contribution)), 0) * 100", "Contribution variance as percent of budget", "%", 2),
                meas(B, "stores_on_sales_plan", "SUM(CASE WHEN sales_on_plan = 'Y' THEN 1 ELSE 0 END)", "Store-months at or above sales budget", "rows", 0),
                meas(B, "stores_on_opex_plan", "SUM(CASE WHEN opex_on_plan = 'Y' THEN 1 ELSE 0 END)", "Store-months at or under opex budget", "rows", 0),
            ],
            "filters": [
                filt(B, "original_budget", "budget_version = 'Original'", "Original plan (default)"),
                filt(B, "reforecast_q2_2020", "budget_version = 'Reforecast Q2 2020'", "April 2020 re-plan, 2020-04 onward"),
                filt(B, "trading_only", "trading_status = 'Trading'", "Months in which the store traded"),
            ],
        }
        env["models"].append(model)
        models[B] = model
        access["models"].append({"name": B, "dimensions": [d["name"] for d in model["dimensions"]],
                                 "measures": [m["name"] for m in model["measures"]], "filters": [f["name"] for f in model["filters"]]})
        for name, desc, to_model, fk, tk in [
            ("budget_to_store", "Each budget row belongs to one store", "stores", "store_number", "storenumber"),
            ("budget_to_franchisee", "Each budget row belongs to the store owner", "franchisees", "franchisee_id", "franchisee_id"),
        ]:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc, "from_model": B,
                                         "from_key": key(B, fk), "to_model": to_model, "to_key": key(to_model, tk),
                                         "type": "many_to_one", "join_type": "left"})
        changes.append("model store_budget + 2 relationships")

    # ---------------------------------------------------------------- metrics
    existing = {m["name"] for m in env["metrics"]}
    gb_p = [{"model": P, "dimension": d} for d in ("region", "province", "store_format", "store_name", "pandemic_period", "trading_status")] + \
           [{"model": "franchisees", "dimension": "owner_name"}]
    gb_b = [{"model": B, "dimension": d} for d in ("region", "province", "store_format", "store_name", "pandemic_period", "budget_version", "budget_basis")]
    trading = [{"name": "trading_only", "expression": "trading_status = 'Trading'", "apply_default": False}]
    orig = [{"name": "original_budget", "expression": "budget_version = 'Original'", "apply_default": True},
            {"name": "reforecast_q2_2020", "expression": "budget_version = 'Reforecast Q2 2020'", "apply_default": False}]
    new_metrics = [
        metric("total_opex", f"{P}.total_opex", P, "CAD", 2, "Total operating expense per store-month: labour incl. burden, occupancy, utilities, shrink, delivery partner cost, card fees, other opex, plus royalty and marketing fees. SCOR CO.1.1.",
               "Store-level costs plus franchise fees. Use total_store_opex on the store_pnl model to exclude franchise fees. Labour, shrink and fees are real; occupancy, utilities, card fees and other opex are modeled and anchored.\n", gb_p, filters=trading),
        metric("store_contribution", f"{P}.total_store_contribution", P, "CAD", 2, "Store contribution (franchisee profit before tax and depreciation): gross margin + promo subsidy income - store opex - royalty - marketing fee. SCOR PR.1.1.",
               "Apply trading_only for rankings. Negative in about a third of store-months: the shift schedule is flat, so stores under ~70K monthly sales cannot cover labour. Network contribution margin is about 6 percent of sales.\n", gb_p, filters=trading),
        metric("contribution_margin_pct", f"{P}.contribution_margin_pct", P, "%", 2, "Store contribution as a percent of net sales (sum over sum, never an average of row percentages).",
               "Network-wide about 6 percent. Compare by store_format (Shopping Mall carries the highest occupancy), region and pandemic_period (2020 is far stronger than 2019).\n", gb_p, filters=trading),
        metric("four_wall_ebitda", f"{P}.total_four_wall_ebitda", P, "CAD", 2, "Four-wall EBITDA: gross margin + promo subsidy income - store operating costs, before royalty and marketing fees.",
               "The store-level profit before anything paid to the franchisor. four_wall_margin_pct on store_pnl gives it as percent of sales (network about 12 percent).\n", gb_p, filters=trading),
        metric("four_wall_margin_pct", f"{P}.four_wall_margin_pct", P, "%", 2, "Four-wall EBITDA as a percent of net sales.",
               "Network about 12 percent; Standalone highest (lowest occupancy), Shopping Mall lowest.\n", gb_p, filters=trading),
        metric("loaded_labour_pct_of_sales", f"{P}.labour_pct_of_sales", P, "%", 2, "Loaded labour cost (wages plus burden) as a percent of net sales. SCOR CO.1.1.",
               "Network about 10 percent. Rises sharply in low-volume stores because the shift schedule is flat. Labour wages are real, burden is modeled 12-20 percent by province.\n", gb_p, filters=trading),
        metric("occupancy_pct_of_sales", f"{P}.occupancy_pct_of_sales", P, "%", 2, "Occupancy cost as a percent of net sales.",
               "Modeled: square feet x an annual rate by store_format and province. Shopping Mall about 7.7 percent, Standalone about 3.4 percent.\n", gb_p, filters=trading),
        metric("total_royalty_revenue", f"{P}.total_royalty_fee", P, "CAD", 2, "Royalty fees by month: royalty base sales x the franchisee royalty rate (4, 5 or 6 percent). Revenue for the franchisor, cost for the franchisee.",
               "Monthly time series of the fee that franchisees.est_royalty_paid only shows as a lifetime total. Group by franchisees.owner_name for the franchisor view.\n", gb_p),
        metric("total_marketing_fee_revenue", f"{P}.total_marketing_fee", P, "CAD", 2, "Marketing fees by month: net sales x the franchisee marketing rate (1 or 2 percent).",
               "Monthly time series; group by owner or region. Funds the marketing campaigns in marketing_campaigns.\n", gb_p),
        metric("total_promo_subsidy_income", f"{P}.total_promo_subsidy_income", P, "CAD", 2, "Promotion subsidy credited to stores by month (real, from the line fact).",
               "Counted as income in four_wall_ebitda. vendor_coop_subsidy on store_pnl is a component of it, never add them.\n", gb_p),
        metric("budget_net_sales", f"{B}.budget_net_sales", B, "CAD", 2, "Budgeted net sales per store-month for the selected budget version (Original by default).",
               "Always one budget_version. Compare with total_net_sales or use sales_variance_vs_budget directly.\n", gb_b, filters=orig),
        metric("budget_store_contribution", f"{B}.budget_store_contribution", B, "CAD", 2, "Budgeted store contribution for the selected budget version.",
               "Always one budget_version.\n", gb_b, filters=orig),
        metric("sales_variance_vs_budget", f"{B}.sales_variance", B, "CAD", 2, "Actual minus budgeted net sales (positive = ahead of plan).",
               "Default version Original. 2020 vs Original shows the pandemic: March +40 percent, April +42 percent. Switch to reforecast_q2_2020 to see performance against the April re-plan (within 1 percent). sales_variance_pct on store_budget gives the percent.\n", gb_b, filters=orig),
        metric("opex_variance_vs_budget", f"{B}.opex_variance", B, "CAD", 2, "Actual minus budgeted total opex (positive = over budget).",
               "Default version Original. labour_variance and store_opex_variance on store_budget split it.\n", gb_b, filters=orig),
        metric("contribution_variance_vs_budget", f"{B}.contribution_variance", B, "CAD", 2, "Actual minus budgeted store contribution.",
               "Default version Original. contribution_variance_pct on store_budget gives percent of budget.\n", gb_b, filters=orig),
    ]
    for mt in new_metrics:
        if mt["name"] not in existing:
            env["metrics"].append(mt)
            access["metrics"].append(mt["name"])
    changes.append(f"{len(new_metrics)} finance metrics")

    # ---------------------------------------------------------------- glossary
    terms = {g["term"] for g in env["glossary"]}
    for g in [
        gloss("Four-Wall EBITDA", "Store-level profit before anything paid to the franchisor: gross margin plus promotion subsidy income minus store operating costs (labour with burden, occupancy, utilities, shrink, delivery partner cost, card fees, other opex). Measured in store_pnl.four_wall_ebitda.", ["four wall margin", "store EBITDA", "4-wall"], ["finance"]),
        gloss("Store Contribution", "Four-wall EBITDA minus royalty and marketing fees: what the franchisee keeps before tax and depreciation. store_pnl.store_contribution; contribution_margin_pct is its share of net sales.", ["contribution", "store profit", "franchisee profit"], ["finance"]),
        gloss("Occupancy Cost", "Rent and occupancy per store-month, modeled as square feet x an annual rate by store format and province (Shopping Mall highest, Standalone lowest) with a per-store adjustment. Not a real lease figure.", ["rent", "occupancy"], ["finance", "modeled"]),
        gloss("Labour Burden", "Employer on-costs on top of wages (CPP, EI, vacation), modeled at 12 to 20 percent of labour cost by province. Wages themselves are real (shift hours x the employee hourly wage).", ["burden", "employer costs", "on-costs"], ["finance", "modeled"]),
        gloss("Royalty Fee", "Fee paid by the franchisee to the franchisor: royalty base sales x the franchisee royalty rate of 4, 5 or 6 percent. Monthly in store_pnl.royalty_fee, lifetime in franchisees.est_royalty_paid.", ["royalty", "royalties"], ["finance", "franchise"]),
        gloss("Marketing Fee", "Fee paid by the franchisee into the network marketing fund: net sales x the franchisee marketing rate of 1 or 2 percent. Monthly in store_pnl.marketing_fee.", ["marketing fund", "ad fund"], ["finance", "franchise"]),
        gloss("Budget Version", "Which plan a budget row belongs to. Original: set in late 2019 for every month (2019 rows are actual +-10 percent, 2020 rows are the 2019 same-month actual plus 3-8 percent growth, blind to the pandemic). Reforecast Q2 2020: the April 2020 re-plan for 2020-04 onward. Always filter to one version.", ["plan version", "budget_version"], ["finance", "budget"]),
        gloss("Reforecast", "A budget re-planned mid-year. Reforecast Q2 2020 was set on 2020-04-10 and covers 2020-04 to 2020-12 at actual +-8 percent, so actuals track it within about 1 percent.", ["re-plan", "reforecast Q2 2020"], ["finance", "budget"]),
    ]:
        if g["term"] not in terms:
            env["glossary"].append(g)
            access["glossary"].append(g["term"]) if isinstance(access.get("glossary"), list) and g["term"] not in access["glossary"] else None
    changes.append("8 glossary terms")

    # ---------------------------------------------------------------- instructions
    ins = analyst["instructions"]
    if "### Finance (store P&L and budget)" not in ins:
        anchor = "### Franchisee Fees"
        block = ("### Finance (store P&L and budget)\n"
                 "| Metric | Description |\n|--------|-------------|\n"
                 "| `total_opex` | Store opex + franchise fees per store-month — SCOR CO.1.1 |\n"
                 "| `store_contribution` | Gross margin + subsidy - store opex - royalty - marketing fee (franchisee profit) — SCOR PR.1.1 |\n"
                 "| `contribution_margin_pct` | Store contribution as % of net sales (network ~6%) |\n"
                 "| `four_wall_ebitda` | Store profit before franchise fees |\n"
                 "| `four_wall_margin_pct` | Four-wall EBITDA as % of sales (network ~12%) |\n"
                 "| `labour_pct_of_sales` | Loaded labour as % of sales (network ~10%) |\n"
                 "| `occupancy_pct_of_sales` | Occupancy as % of sales (modeled) |\n"
                 "| `total_royalty_revenue` | Royalty fees by month (real rates) |\n"
                 "| `total_marketing_fee_revenue` | Marketing fees by month (real rates) |\n"
                 "| `total_promo_subsidy_income` | Promotion subsidy credited to stores by month |\n"
                 "| `budget_net_sales` | Budgeted sales, Original version by default |\n"
                 "| `budget_store_contribution` | Budgeted contribution, Original version by default |\n"
                 "| `sales_variance_vs_budget` | Actual - budget sales (positive = ahead) |\n"
                 "| `opex_variance_vs_budget` | Actual - budget opex (positive = over) |\n"
                 "| `contribution_variance_vs_budget` | Actual - budget contribution |\n\n")
        if anchor in ins:
            ins = ins.replace(anchor, block + anchor)
            changes.append("finance metric reference")
        ctx = "- **Labour cost**:"
        if ctx in ins and "**Store P&L**" not in ins:
            ins = ins.replace(ctx, "- **Store P&L**: `store_pnl` is the store x month contribution statement (franchisee view). Sales, COGS, margin, subsidy, fees, labour wages, shrink and delivery orders are REAL; labour burden, occupancy, utilities, card fees and other opex are MODELED and anchored. Say which when asked about a cost line. `store_budget` holds Original and Reforecast Q2 2020 plans with variances — always filter to one `budget_version`\n" + ctx)
        scor = "| **Cost (CO)** | `total_cogs`, `total_procurement_spend`, `total_labour_hours`, `total_labour_cost`, `total_shrinkage_cost`, `gross_margin_rate` |"
        if scor in ins:
            ins = ins.replace(scor, "| **Cost (CO)** | `total_cogs`, `total_procurement_spend`, `total_labour_hours`, `total_labour_cost`, `loaded_labour_pct_of_sales`, `total_shrinkage_cost`, `total_opex`, `gross_margin_rate` |")
        prof = "| **Profitability (PR)** | `gross_margin_rate`, `total_royalty_cost`, `total_est_marketing_fee` |"
        if prof in ins:
            ins = ins.replace(prof, "| **Profitability (PR)** | `gross_margin_rate`, `four_wall_margin_pct`, `contribution_margin_pct`, `store_contribution`, `total_royalty_revenue`, `total_marketing_fee_revenue` |")
        mref = "**stores:**\n- 330 store master directory."
        if mref in ins:
            ins = ins.replace(mref, "**store_pnl:**\n- Store x month contribution statement, 7,891 rows from each store open month. One row per store-month: SUM rows, recompute percentages from sums\n"
                              "- Filter `trading_status = 'Trading'` for rankings (13 stores closed before 2020-12). About a third of store-months have negative contribution because the shift schedule is flat\n\n"
                              "**store_budget:**\n- Budget next to actual with variances, store x month x budget_version (10,854 rows). ALWAYS filter one `budget_version`: Original (all months, 2020 blind to the pandemic) or Reforecast Q2 2020 (2020-04 onward)\n\n" + mref)
        n = len(env["metrics"])
        import re
        ins = re.sub(r"All \d+ metrics available to you", f"All {n} metrics available to you", ins)
    analyst["instructions"] = ins
    return env, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--put", action="store_true")
    args = ap.parse_args()
    cfg = json.loads(CFG.read_text())
    hdr = {"Authorization": "Bearer " + cfg["apiKey"], "Content-Type": "application/json"}
    url = cfg["baseUrl"] + "/api/public/v1/environment"
    env = json.loads(urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=120).read())
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "wobby_env_before_pnl.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_pnl_body.json"
    out.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    print("changes:"); [print("  -", c) for c in changes]
    print(f"models {len(body['models'])} relationships {len(body['relationships'])} metrics {len(body['metrics'])} glossary {len(body['glossary'])} -> {out}")
    if not args.put:
        return
    time.sleep(6)
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"), headers=hdr, method="PUT"), timeout=180)
        print("PUT", r.status, r.read()[:400].decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        print("PUT FAILED", e.code, e.read()[:2000].decode("utf-8", "replace"))
        return 1
    time.sleep(6)
    after = json.loads(urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=120).read())
    (OUT / "wobby_env_after_pnl.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    names = {m["name"] for m in after["models"]}
    mets = {m["name"] for m in after["metrics"]}
    print("verify: store_pnl", "store_pnl" in names, "| store_budget", "store_budget" in names,
          "| metrics", all(x in mets for x in ("store_contribution", "four_wall_ebitda", "sales_variance_vs_budget")),
          "| glossary", any(g["term"] == "Four-Wall EBITDA" for g in after["glossary"]),
          "| counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
