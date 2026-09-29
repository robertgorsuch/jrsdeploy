"""wobby_fix_defects.py -- build the PUT body that fixes the five semantic-layer
defects found in the 2026-08-23 export of the Wobby POS Sales Analyst
(agent_ak2os72a8), and optionally send it.

  1. total_labour_cost: new measure SUM(labour_cost) on shift_schedules
     (column added by alter_shift_schedules_labour_cost.sql); metric repointed
     from scheduled hours to dollars.
  2. Relationships for customer_demographics (1:1), customer_diet_profile
     (1:1) and customer_month (N:1) to customers.
  3. Churn risk-band thresholds in the instructions corrected to the values
     in customer_churn_scores (Watch >= 0.25, High >= 0.45, Critical >= 0.70).
  4. The four unlisted metrics added to the instructions reference, count
     corrected.
  5. New model `transactions` on pos_sales_txn (19.5M rows, one per
     transaction); total_transactions, avg_basket_size and
     avg_items_per_basket repointed to it; new metric
     transactions_by_product keeps category-level transaction counts on the
     line-item fact.

Usage
  python scripts/pos_perf/wobby_fix_defects.py            # write body only
  python scripts/pos_perf/wobby_fix_defects.py --put      # write body and PUT
Input : the full environment export (wobby_env.json, from one GET)
Output: out/pos_perf/wobby_env_put_body.json (gitignored)
Rate limit is 2 requests per 5 seconds per IP; this script makes at most one
PUT and one verification GET, 6 seconds apart.
"""

import argparse
import copy
import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CFG = ROOT / ".claude" / "skills" / "wobby" / "wobby.config.json"
OUT = ROOT / "out" / "pos_perf"


def gen_id(prefix, seed):
    h = hashlib.sha1(seed.encode()).hexdigest()
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    return prefix + "_" + "".join(alphabet[int(h[i:i + 2], 16) % 36] for i in range(0, 18, 2))


def dim(model, name, expr, typ, desc, pk=False, grains=None):
    d = {"id": gen_id("dimension", f"{model}.{name}"), "name": name, "expression": expr, "type": typ,
         "description": desc, "primary_key": pk}
    if grains:
        d["time_grains"] = grains
    return d


def meas(model, name, expr, desc, unit, precision):
    return {"id": gen_id("measure", f"{model}.{name}"), "name": name, "expression": expr,
            "description": desc, "unit": unit, "precision": precision}


def filt(model, name, expr, desc):
    return {"id": gen_id("filter", f"{model}.{name}"), "name": name, "expression": expr,
            "description": desc, "apply_default": False}


def build(env):
    env = copy.deepcopy(env)
    models = {m["name"]: m for m in env["models"]}
    metrics = {m["name"]: m for m in env["metrics"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    access_models = {m["name"]: m for m in access["models"]}
    changes = []

    def key(model, dimension):
        return next(d["id"] for d in models[model]["dimensions"] if d["name"] == dimension)

    # ---- 1. labour cost ------------------------------------------------------
    ss = models["shift_schedules"]
    if not any(m["name"] == "total_labour_cost" for m in ss["measures"]):
        ss["measures"].append(meas("shift_schedules", "total_labour_cost", "SUM(labour_cost)",
                                   "Total labour cost in CAD: scheduled_hours x the hourly wage of the employee on the shift (labour_cost column)",
                                   "CAD", 2))
        access_models["shift_schedules"]["measures"].append("total_labour_cost")
    ss["agent_guidance"] = ("482,460 rows. Join store_number to stores, employee_id to employees, calendar_date to date_dim. "
                            "labour_cost is REAL dollars per shift (scheduled_hours x the employee hourly wage, no burden or overtime uplift) -- "
                            "use total_labour_cost for cost and total_scheduled_hours for hours, no multiplication needed.")
    m = metrics["total_labour_cost"]
    m["expression"] = "shift_schedules.total_labour_cost"
    m["description"] = ("Total labour cost in CAD across all scheduled shifts: scheduled hours multiplied by the hourly wage of the "
                        "employee on each shift. Maps to SCOR CO.1.1 Labour Cost component.")
    m["agent_guidance"] = ("Real dollars, not hours: each shift row carries labour_cost = scheduled_hours x the assigned employee's hourly_wage. "
                           "Full-dataset total is 70.2M CAD on 3.38M hours (about 9.2 percent of net sales). No employer burden or overtime premium is included.\n"
                           "Break down by is_weekend (Y) and is_holiday (Y) to isolate premium-rate labour days.\n"
                           "Use alongside total_labour_hours for cost per hour, and with total_net_sales (join via stores) for labour as a percent of sales.\n"
                           "Maps to SCOR CO.1.1 Total Supply Chain Management Cost (Labour component).\n")
    changes.append("total_labour_cost -> SUM(labour_cost) in CAD")

    # ---- 2. relationships -----------------------------------------------------
    cust_key = key("customers", "customer_id")
    new_rels = [
        ("demographics_to_customer", "One demographic profile per customer", "customer_demographics", "customer_id", "one_to_one"),
        ("diet_profile_to_customer", "One diet profile per customer", "customer_diet_profile", "customer_id", "one_to_one"),
        ("customer_month_to_customer", "Monthly activity rows roll up to one customer", "customer_month", "customer_id", "many_to_one"),
    ]
    existing = {(r["from_model"], r["to_model"]) for r in env["relationships"]}
    for name, desc, frm, fk, typ in new_rels:
        if (frm, "customers") in existing:
            continue
        env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc,
                                     "from_model": frm, "from_key": key(frm, fk), "to_model": "customers",
                                     "to_key": cust_key, "type": typ, "join_type": "left"})
        changes.append(f"relationship {name}")

    # ---- 5. transactions model ----------------------------------------------
    T = "transactions"
    if T not in models:
        grains = ["day", "week", "month", "quarter", "year"]
        model = {
            "id": gen_id("model", T), "name": T,
            "description": ("One row per POS transaction (19.5M rows) rolled up from pos_sales_detail: basket value, cost, margin, items, "
                            "discount, promotion and ecommerce flags, with store, customer and a typed sale_date. Covers January 2019 to December 2020. "
                            "Use this model for transaction counts, basket size and items per basket -- it is 3x smaller than the line-item fact and needs no COUNT DISTINCT."),
            "agent_guidance": ("Transaction grain, REAL, reconciles to pos_sales_detail to the cent. Filter transaction_type = 'Regular Sale' for sales analysis "
                               "(Regular Return and Post Void TX are also present). Join customer_id to customers, store_number to stores, sale_date to date_dim. "
                               "No product columns here: for anything by category, PLU or dietary flag use pos_sales_detail (transactions_by_product metric). "
                               "promo_flag = Y when any line in the basket carried a promotion; ecommerce_flag = Y when the basket is an ecommerce order."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "pos_sales_txn"]},
            "dimensions": [
                dim(T, "transaction_unique_id", "transactionuniqueid", "string", "Transaction id, joins pos_sales_detail line items", pk=True),
                dim(T, "customer_id", "customer_id", "string", "Customer id, joins customers"),
                dim(T, "store_number", "storenumber", "number", "Store number, joins stores"),
                dim(T, "store_province", "storeprovince", "enum", "Store province"),
                dim(T, "store_region", "storeregion", "enum", "Store region: Western, Ontario, Quebec, Atlantic"),
                dim(T, "sale_date", "sale_date", "date", "Sale date (typed), joins date_dim.calendar_date", grains=grains),
                dim(T, "year_month", "yyyymm", "number", "Calendar month as yyyymm"),
                dim(T, "sale_hour", "sale_hour", "number", "Hour of day 0-23"),
                dim(T, "day_of_week", "dow_num", "number", "Day of week number from date_dim"),
                dim(T, "is_weekend", "is_weekend", "enum", "Y on Saturday and Sunday"),
                dim(T, "is_holiday", "is_holiday", "enum", "Y on Canadian statutory holidays"),
                dim(T, "pandemic_period", "pandemic_period", "enum", "Pre-pandemic (before 2020-03-01) or Pandemic"),
                dim(T, "transaction_type", "txn_type", "enum", "Regular Sale, Regular Return, Post Void TX"),
                dim(T, "promo_flag", "promo_flag", "enum", "Y when any line carried a promotion"),
                dim(T, "promo_id", "promo_id", "string", "Promotion event id when promoted, joins promotions.promo_id"),
                dim(T, "ecommerce_flag", "ecommerce_flag", "enum", "Y when the basket is an ecommerce order"),
                dim(T, "customer_fsa", "fsa", "string", "Customer forward sortation area"),
                dim(T, "line_items", "line_items", "number", "Number of line items in the basket"),
                dim(T, "basket_items", "basket_items", "number", "Units in the basket"),
                dim(T, "distinct_categories", "distinct_categories", "number", "Distinct product categories in the basket (catalogued PLUs only)"),
            ],
            "measures": [
                meas(T, "total_transactions", "COUNT(*)", "Number of transactions", "transactions", 0),
                meas(T, "total_sales", "SUM(basket_value)", "Net sales at selling price", "CAD", 2),
                meas(T, "total_cost", "SUM(basket_cost)", "Cost of goods", "CAD", 2),
                meas(T, "gross_margin", "SUM(basket_margin)", "Sales minus cost", "CAD", 2),
                meas(T, "gross_margin_pct", "SUM(basket_margin) / NULLIF(SUM(basket_value), 0) * 100", "Gross margin as percent of sales", "%", 2),
                meas(T, "avg_basket_value", "AVG(basket_value)", "Average transaction value", "CAD", 2),
                meas(T, "avg_items_per_transaction", "AVG(line_items)", "Average line items per transaction", "items", 2),
                meas(T, "avg_units_per_transaction", "AVG(basket_items)", "Average units per transaction", "units", 2),
                meas(T, "avg_categories_per_basket", "AVG(distinct_categories)", "Average distinct categories per basket", "categories", 2),
                meas(T, "total_units", "SUM(basket_items)", "Units sold", "units", 0),
                meas(T, "total_line_items", "SUM(line_items)", "Line items", "items", 0),
                meas(T, "total_discount", "SUM(discount_total)", "Item, transaction and override discounts", "CAD", 2),
                meas(T, "promo_sales", "SUM(promo_value)", "Sales on promoted lines", "CAD", 2),
                meas(T, "promo_transactions", "SUM(CASE WHEN promo_flag = 'Y' THEN 1 ELSE 0 END)", "Transactions with at least one promoted line", "transactions", 0),
                meas(T, "ecommerce_transactions", "SUM(CASE WHEN ecommerce_flag = 'Y' THEN 1 ELSE 0 END)", "Ecommerce transactions", "transactions", 0),
                meas(T, "distinct_customers", "COUNT(DISTINCT customer_id)", "Distinct customers transacting", "customers", 0),
            ],
            "filters": [
                filt(T, "regular_sales", "transaction_type = 'Regular Sale'", "Regular Sale transactions only (default for sales analysis)"),
                filt(T, "returns_only", "transaction_type = 'Regular Return'", "Return transactions only"),
                filt(T, "ecommerce_only", "ecommerce_flag = 'Y'", "Ecommerce baskets only"),
                filt(T, "promoted_only", "promo_flag = 'Y'", "Baskets with at least one promoted line"),
            ],
        }
        env["models"].append(model)
        models[T] = model
        access["models"].append({"name": T, "dimensions": [d["name"] for d in model["dimensions"]],
                                 "measures": [m["name"] for m in model["measures"]],
                                 "filters": [f["name"] for f in model["filters"]]})
        for name, desc, to_model, fk, tk, typ in [
            ("transactions_to_customer", "Each transaction belongs to one customer", "customers", "customer_id", "customer_id", "many_to_one"),
            ("transactions_to_store", "Each transaction happened in one store", "stores", "store_number", "storenumber", "many_to_one"),
            ("transactions_to_date", "Transaction sale date on the calendar", "date_dim", "sale_date", "calendar_date", "many_to_one"),
        ]:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc,
                                         "from_model": T, "from_key": key(T, fk), "to_model": to_model,
                                         "to_key": key(to_model, tk), "type": typ, "join_type": "left"})
        changes.append("model transactions + 3 relationships")

    # repoint the three basket metrics
    gb = [{"model": T, "dimension": d} for d in ("store_region", "store_province", "pandemic_period", "is_weekend",
                                                  "is_holiday", "promo_flag", "ecommerce_flag", "transaction_type", "sale_hour")]
    gb += [{"model": "stores", "dimension": d} for d in ("store_name", "store_format")]
    gb += [{"model": "customers", "dimension": d} for d in ("loyalty_tier", "rfm_segment")]
    rs = [{"name": "regular_sales", "expression": "transaction_type = 'Regular Sale'", "apply_default": False}]
    repoint = {
        "total_transactions": ("transactions.total_transactions", "transactions", 0,
                               "Count of POS transactions (baskets). Regular Sale transactions by default -- apply the regular_sales filter. Reads the transaction-grain model, no COUNT DISTINCT needed.",
                               "Counts baskets, not line items. Apply the regular_sales filter for sales analysis (returns and voids are separate transaction_type values).\n"
                               "Group by store_region, store_province, pandemic_period, is_weekend, promo_flag or ecommerce_flag. For transactions by product category or dietary flag use transactions_by_product instead (line-item fact).\n"
                               "Use time_grain (day/week/month/quarter/year) for trends. Use alongside avg_basket_size and avg_items_per_basket to separate visit growth from spend-per-visit growth.\n"),
        "avg_basket_size": ("transactions.avg_basket_value", "CAD", 2,
                            "Average revenue per transaction (Average Transaction Value). Mean of basket value over Regular Sale transactions on the transaction-grain model.",
                            "Also called Average Transaction Value (ATV). Apply the regular_sales filter. Compare across regions, store formats, pandemic_period and promo_flag. "
                            "For ATV by product category use total_net_sales / transactions_by_product on pos_sales_detail.\n"),
        "avg_items_per_basket": ("transactions.avg_items_per_transaction", "items", 2,
                                 "Average line items per transaction -- basket complexity and cross-sell depth, on the transaction-grain model.",
                                 "Apply the regular_sales filter. Compare alongside avg_basket_size to distinguish revenue growth from more items vs higher prices. "
                                 "avg_units_per_transaction on the transactions model gives units rather than lines.\n"),
    }
    for name, (expr, unit, prec, desc, guide) in repoint.items():
        mt = metrics[name]
        mt.update({"expression": expr, "anchor_model": T, "unit": unit, "precision": prec, "description": desc, "agent_guidance": guide,
                   "time_dimension": {"model": T, "dimension": "sale_date"}, "time_grains": ["day", "week", "month", "quarter", "year"],
                   "group_by_dimensions": gb, "filters": rs})
        mt.pop("joins", None)
    changes.append("total_transactions, avg_basket_size, avg_items_per_basket -> transactions model")

    if "transactions_by_product" not in metrics:
        src = next(m for m in env["metrics"] if m["id"] == "metric_4dwhu1xdx")  # original total_transactions shape from the export
        new = {"id": gen_id("metric", "transactions_by_product"), "name": "transactions_by_product",
               "description": "Count of unique Regular Sale transactions on the line-item fact, for breakdowns by product category, sub-category, product or dietary flag (transactions containing at least one matching line).",
               "agent_guidance": "Slower than total_transactions (COUNT DISTINCT over 63.6M lines) -- use only when the breakdown is by a products dimension. A transaction containing two categories counts once in each. Only 21 percent of PLUs carry category data; caveat accordingly. Apply the regular_sales filter.\n",
               "expression": "pos_sales_detail.total_transactions", "anchor_model": "pos_sales_detail", "unit": "transactions", "precision": 0,
               "time_dimension": {"model": "pos_sales_detail", "dimension": "sale_date"}, "time_grains": ["day", "week", "month", "quarter", "year"],
               "group_by_dimensions": [{"model": "pos_sales_detail", "dimension": "store_region"}, {"model": "pos_sales_detail", "dimension": "store_province"},
                                       {"model": "products", "dimension": "category"}, {"model": "products", "dimension": "sub_category"},
                                       {"model": "products", "dimension": "product_name"}, {"model": "products", "dimension": "vegetarian"},
                                       {"model": "products", "dimension": "vegan"}, {"model": "products", "dimension": "gluten_free"},
                                       {"model": "products", "dimension": "single_serve"}],
               "joins": [{"alias": "prod", "from_key": "pos_sales_detail.plu", "to_model": "products", "to_key": "products.plu", "join_type": "left"}],
               "filters": [{"name": "regular_sales", "expression": "transaction_type = 'Regular Sale'", "apply_default": False}]}
        env["metrics"].append(new)
        access["metrics"].append("transactions_by_product")
        changes.append("metric transactions_by_product")

    # ---- 3 + 4. instructions ---------------------------------------------------
    ins = analyst["instructions"]
    old_bands = "Risk bands: Low (<0.3), Watch (0.3–0.5), High (0.5–0.75), Critical (>0.75)"
    if old_bands in ins:
        ins = ins.replace(old_bands, "Risk bands: Low (<0.25), Watch (0.25–0.45), High (0.45–0.70), Critical (>=0.70)")
        changes.append("risk bands corrected")
    else:
        print("WARN: risk band sentence not found verbatim", file=sys.stderr)
    n_metrics = len(env["metrics"])
    if "All 52 metrics available to you" in ins:
        ins = ins.replace("All 52 metrics available to you", f"All {n_metrics} metrics available to you")
    churn_block = "| `total_ltv_at_risk` | Total CAD revenue at risk if at-risk customers churn |"
    if churn_block in ins and "avg_overdue_ratio" not in ins:
        ins = ins.replace(churn_block, churn_block + "\n"
                          "| `avg_overdue_ratio` | Average days-silent / median inter-purchase gap; >1 = overdue, >2 = lapsing |\n"
                          "| `pct_customers_overdue` | % of repeat customers whose overdue ratio exceeds 1 |\n"
                          "| `avg_days_to_expected_next_purchase` | Average days from last purchase to the expected next one (median gap) |\n"
                          "| `total_ltv_at_risk_by_overdue` | LTV at risk segmentable by overdue ratio band |")
        changes.append("4 unlisted metrics added to reference")
    sales_block = "| `total_transactions` | Count of unique Regular Sale transactions (not line items) |"
    if sales_block in ins and "transactions_by_product" not in ins:
        ins = ins.replace(sales_block, "| `total_transactions` | Count of Regular Sale transactions (baskets) on the `transactions` model -- fast, apply `regular_sales` |\n"
                          "| `transactions_by_product` | Unique transactions on the line-item fact, for breakdowns by category / product / dietary flag (slower) |")
    labour_line = "| `total_labour_cost` | Total estimated labour cost (scheduled hours × wage proxy) — SCOR CO.1.1 |"
    if labour_line in ins:
        ins = ins.replace(labour_line, "| `total_labour_cost` | Total labour cost in CAD (scheduled hours × the shift employee's hourly wage, real) — SCOR CO.1.1 |")
    rule = "- Always qualify `transaction_type` as `pos_sales_detail.transaction_type` in `where` clauses"
    if rule in ins and "transactions.transaction_type" not in ins:
        ins = ins.replace(rule, rule + " (or `transactions.transaction_type` on the transactions model)")
    model_ref = "**products:**\n- 942 products by PLU."
    if model_ref in ins and "**transactions:**" not in ins:
        ins = ins.replace(model_ref, "**transactions:**\n- One row per POS transaction (19.5M rows), rolled up from pos_sales_detail and reconciled to it. Basket value, cost, margin, items, promo_flag, ecommerce_flag, typed sale_date\n"
                          "- Use for transaction counts, basket size, items per basket. Filter `transaction_type = 'Regular Sale'`. No product columns: category questions stay on pos_sales_detail\n\n" + model_ref)
        changes.append("transactions model documented in instructions")
    ctx = "- **Currency**: All monetary values are in **CAD**"
    if ctx in ins and "**Labour cost**" not in ins:
        ins = ins.replace(ctx, ctx + "\n- **Labour cost**: `shift_schedules.labour_cost` is real CAD per shift (scheduled hours x the shift employee's hourly wage); `total_labour_cost` sums it. No burden or overtime uplift is included")
        changes.append("labour cost note in Business Context")
    analyst["instructions"] = ins
    return env, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=None, help="path to the environment export JSON (default: out/pos_perf/wobby_env_backup_20260823.json)")
    ap.add_argument("--put", action="store_true", help="send the body to PUT /api/public/v1/environment")
    args = ap.parse_args()
    src = Path(args.env) if args.env else OUT / "wobby_env_backup_20260823.json"
    env = json.loads(src.read_text(encoding="utf-8"))
    body, changes = build(env)
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "wobby_env_put_body.json"
    out.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    print("changes:"); [print("  -", c) for c in changes]
    print(f"models {len(body['models'])} relationships {len(body['relationships'])} metrics {len(body['metrics'])} glossary {len(body['glossary'])}")
    print("body ->", out)
    if not args.put:
        return
    cfg = json.loads(CFG.read_text())
    hdr = {"Authorization": "Bearer " + cfg["apiKey"], "Content-Type": "application/json"}
    req = urllib.request.Request(cfg["baseUrl"] + "/api/public/v1/environment", data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                 headers=hdr, method="PUT")
    try:
        r = urllib.request.urlopen(req, timeout=180)
        print("PUT", r.status, r.read()[:600].decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        print("PUT FAILED", e.code, e.read()[:2000].decode("utf-8", "replace"))
        return 1
    time.sleep(6)
    r = urllib.request.urlopen(urllib.request.Request(cfg["baseUrl"] + "/api/public/v1/environment", headers=hdr), timeout=120)
    data = r.read()
    (OUT / "wobby_env_after_fix.json").write_bytes(data)
    after = json.loads(data)
    names = {m["name"] for m in after["models"]}
    rels = {r["name"] for r in after["relationships"]}
    mets = {m["name"]: m for m in after["metrics"]}
    print("verify: transactions model", "transactions" in names,
          "| rels", all(x in rels for x in ("demographics_to_customer", "diet_profile_to_customer", "customer_month_to_customer", "transactions_to_store")),
          "| labour expr", mets["total_labour_cost"]["expression"],
          "| total_transactions expr", mets["total_transactions"]["expression"],
          "| bands ok", "Critical (>=0.70)" in after["ai_analysts"][0]["instructions"])


if __name__ == "__main__":
    sys.exit(main())
