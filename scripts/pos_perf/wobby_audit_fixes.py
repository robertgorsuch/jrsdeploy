"""wobby_audit_fixes.py -- apply the API-side fixes from the completeness
audit (WOBBY_ANALYST_REFINEMENT_REVIEW.md section 8) in one PUT.

  1  sales_targets: actual/attainment measures (columns added by
     alter_sales_targets_actuals.sql); sales_plan_attainment_pct repointed
     to a real attainment expression
  2  churn_rate_90 / activation_rate: Postgres ::numeric -> FLOAT8()
  3  promotional_sales: promoted_items filter apply_default = true;
     dietary_sales guidance hardened (attribute filter mandatory)
  4  glossary mappings for Breakage, Deferred Revenue, Margin Bridge,
     Pricebook
  5  fsa_demographics: 11 enrichment dimensions exposed
  6  customer_month: 9 additional measures (returns, purchase days, csat,
     late deliveries, redemptions, gift cards, discount, items, home-store
     share input)
  7  small exposure pass: promotions, loyalty_liability,
     gift_card_liability, franchise_fees, pricebook, payables
  8  (API half) relationships for re-granted models: dash_store -> stores,
     pos_sales_detail_v -> stores / products

Usage:  python scripts/pos_perf/wobby_audit_fixes.py [--put]
Fresh GET first; rate limit 2 req / 5 s; dimension-less-model guard applied.
"""

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wobby_fix_defects import CFG, OUT, dim, gen_id, meas  # noqa: E402


def build(env):
    models = {m["name"]: m for m in env["models"]}
    metrics = {m["name"]: m for m in env["metrics"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next((d["id"] for d in models[model]["dimensions"] if d["name"] == dimension), None)

    def grant_extras(model_name, dims=None, measures=None):
        e = next((x for x in access["models"] if x["name"] == model_name), None)
        if e is None:
            return
        for kind, names in (("dimensions", dims or []), ("measures", measures or [])):
            if isinstance(e.get(kind), list):
                for n in names:
                    if n not in e[kind]:
                        e[kind].append(n)

    def add_measures(model_name, specs):
        mdl = models[model_name]
        have = {x["name"] for x in mdl["measures"]}
        added = []
        for name, expr, desc, unit, prec in specs:
            if name not in have:
                mdl["measures"].append(meas(model_name, name, expr, desc, unit, prec))
                added.append(name)
        if added:
            grant_extras(model_name, measures=added)
            changes.append(f"{model_name}: +{len(added)} measures")
        return added

    def add_dims(model_name, specs):
        mdl = models[model_name]
        have = {x["name"] for x in mdl["dimensions"]}
        added = []
        for name, expr, typ, desc in specs:
            if name not in have:
                mdl["dimensions"].append(dim(model_name, name, expr, typ, desc))
                added.append(name)
        if added:
            grant_extras(model_name, dims=added)
            changes.append(f"{model_name}: +{len(added)} dimensions")
        return added

    # ---- 1. sales_targets attainment ----------------------------------------
    add_measures("sales_targets", [
        ("total_actual_sales", "SUM(actual_sales)", "Actual net sales for the target store-months (real, from the transaction grain)", "CAD", 2),
        ("total_actual_margin", "SUM(actual_margin)", "Actual gross margin for the target store-months", "CAD", 2),
        ("total_actual_transactions", "SUM(actual_transactions)", "Actual Regular Sale transactions", "transactions", 0),
        ("sales_attainment_pct", "SUM(actual_sales) * 100.0 / NULLIF(SUM(target_sales), 0)", "Actual sales as percent of target (network ~100.2)", "%", 2),
        ("margin_attainment_pct", "SUM(actual_margin) * 100.0 / NULLIF(SUM(target_margin), 0)", "Actual margin as percent of target", "%", 2),
    ])
    mt = metrics.get("sales_plan_attainment_pct")
    if mt is not None and mt.get("expression") != "sales_targets.sales_attainment_pct":
        mt["expression"] = "sales_targets.sales_attainment_pct"
        mt["unit"] = "%"
        mt["precision"] = 2
        mt["description"] = "Actual sales as a percent of the monthly operational target (actual / target x 100). Network full-dataset attainment is about 100.2 percent -- targets are calibrated 90-110 percent of actuals."
        mt["agent_guidance"] = ("FIXED 2026-08-23: previously returned the target itself. Now actual_sales (real, from the transaction grain) over target_sales, "
                                "sum-over-sum. Group by store or join stores for region. This is OPERATIONAL attainment; for the financial plan story use "
                                "sales_variance_vs_budget on store_budget.\n")
        changes.append("sales_plan_attainment_pct repointed to real attainment")

    # ---- 2. ::numeric casts ---------------------------------------------------
    for mn, msname in (("churn_training_set", "churn_rate_90"), ("activation_training_set", "activation_rate")):
        mdl = models.get(mn)
        if mdl is None:
            continue
        for ms in mdl["measures"]:
            if "::numeric" in ms.get("expression", ""):
                ms["expression"] = ms["expression"].replace("::numeric", "")
                ms["expression"] = ms["expression"].replace("AVG(churn_90)", "AVG(FLOAT8(churn_90))").replace("AVG(activated_90)", "AVG(FLOAT8(activated_90))")
                changes.append(f"{mn}.{ms['name']}: ::numeric removed (FLOAT8)")

    # ---- 3. promo/dietary defaults -------------------------------------------
    ps = metrics.get("promotional_sales")
    if ps is not None:
        for f in ps.get("filters") or []:
            if f["name"] == "promoted_items" and not f.get("apply_default"):
                f["apply_default"] = True
                changes.append("promotional_sales: promoted_items now default")
        if "applied by default" not in (ps.get("agent_guidance") or ""):
            ps["agent_guidance"] = ("The promoted_items filter is applied by default (2026-08-23) so this metric never silently equals total_net_sales. "
                                    "Add regular_sales for clean sales analysis.\n") + (ps.get("agent_guidance") or "")
    ds = metrics.get("dietary_sales")
    if ds is not None and "MANDATORY" not in (ds.get("agent_guidance") or ""):
        ds["agent_guidance"] = ("An attribute filter (vegan_products, vegetarian_products or gluten_free_products) is MANDATORY -- without one this metric "
                                "equals total_net_sales. Always apply exactly one, plus regular_sales.\n") + (ds.get("agent_guidance") or "")
        changes.append("dietary_sales guidance hardened")

    # ---- 4. glossary mappings -------------------------------------------------
    MAPS = {
        "Breakage": [{"type": "model", "name": "gift_card_liability"}, {"type": "model", "name": "loyalty_liability"},
                     {"type": "measure", "model": "gift_card_liability", "name": "cumulative_redemption_pct"},
                     {"type": "measure", "model": "loyalty_liability", "name": "points_redeemed"},
                     {"type": "metric", "name": "gift_card_liability_cad"}],
        "Deferred Revenue": [{"type": "model", "name": "gift_card_liability"}, {"type": "model", "name": "loyalty_liability"},
                             {"type": "metric", "name": "gift_card_liability_cad"}, {"type": "metric", "name": "loyalty_liability_cad"},
                             {"type": "measure", "model": "gift_card_liability", "name": "closing_liability"},
                             {"type": "measure", "model": "loyalty_liability", "name": "closing_liability_cad"}],
        "Margin Bridge": [{"type": "model", "name": "pricebook"},
                          {"type": "metric", "name": "avg_cost_change_pct"}, {"type": "metric", "name": "avg_price_change_pct"},
                          {"type": "metric", "name": "price_cost_spread"},
                          {"type": "measure", "model": "pricebook", "name": "margin_pct_realised"},
                          {"type": "dimension", "model": "pricebook", "name": "category"}],
        "Pricebook": [{"type": "model", "name": "pricebook"},
                      {"type": "measure", "model": "pricebook", "name": "avg_pricebook_cost"},
                      {"type": "measure", "model": "pricebook", "name": "avg_regular_price"},
                      {"type": "dimension", "model": "pricebook", "name": "plu"},
                      {"type": "dimension", "model": "pricebook", "name": "month_date"}],
    }
    for g in env["glossary"]:
        if g["term"] in MAPS and not g.get("mappings"):
            g["mappings"] = MAPS[g["term"]]
            changes.append(f"glossary mapped: {g['term']}")

    # ---- 5. fsa_demographics enrichment --------------------------------------
    add_dims("fsa_demographics", [
        ("median_age", "median_age", "number", "Median age in the FSA (modeled, urban younger)"),
        ("pct_families_with_children", "pct_families_with_children", "number", "Share of households with children (modeled)"),
        ("pct_seniors", "pct_seniors", "number", "Share of seniors (modeled, rural higher)"),
        ("pct_french_speaking", "pct_french_speaking", "number", "French-speaking share (anchored to the real FSA first letter: QC ~83, NB ~32)"),
        ("pct_owner_occupied", "pct_owner_occupied", "number", "Owner-occupied dwelling share (modeled)"),
        ("unemployment_rate_pct", "unemployment_rate_pct", "number", "Unemployment rate (modeled)"),
        ("pct_recent_movers", "pct_recent_movers", "number", "Share who moved in the last year (modeled, urban higher)"),
        ("stores_in_fsa", "stores_in_fsa", "number", "Network stores located in the FSA (real)"),
        ("competitor_count_5km", "competitor_count_5km", "number", "Competitor banners within 5 km of a store whose trade area is this FSA (real)"),
        ("home_store_number", "home_store_number", "number", "Modal store of the FSA shoppers (real), joins stores"),
        ("stores_shopped", "stores_shopped", "number", "Distinct network stores the FSA residents shopped (real)"),
    ])

    # ---- 6. customer_month measures ------------------------------------------
    add_measures("customer_month", [
        ("total_returns", "SUM(returns)", "Return transactions in the month", "transactions", 0),
        ("total_purchase_days", "SUM(purchase_days)", "Distinct purchase days", "days", 0),
        ("total_items", "SUM(items)", "Units bought", "units", 0),
        ("total_discount", "SUM(discount)", "Discounts received", "CAD", 2),
        ("total_ecommerce_late", "SUM(ecommerce_late)", "Late ecommerce deliveries", "orders", 0),
        ("avg_min_csat", "AVG(min_csat)", "Average of the worst CSAT per active service month", "score", 2),
        ("total_loyalty_redemptions", "SUM(loyalty_redemptions)", "Loyalty redemption events", "events", 0),
        ("total_gift_cards_bought", "SUM(gift_cards_bought)", "Gift cards purchased", "cards", 0),
        ("total_home_store_txns", "SUM(home_store_txns)", "Transactions at the customer home store (share = / total_transactions)", "transactions", 0),
    ])

    # ---- 7. small exposure pass ----------------------------------------------
    add_measures("promotions", [
        ("total_promo_transactions", "SUM(total_transactions)", "Transactions on promotion events (pre-aggregated per promo)", "transactions", 0),
        ("total_promo_customers", "SUM(distinct_customers)", "Distinct customers per promotion, summed across promos (a customer in two promos counts twice)", "customers", 0),
    ])
    add_measures("loyalty_liability", [
        ("redemption_rate_pct", "SUM(points_redeemed) * 100.0 / NULLIF(SUM(points_earned), 0)", "Points redeemed as percent of earned (programme health, ~3.6)", "%", 2),
        ("points_adjusted", "SUM(points_adjusted)", "Adjustment points (returns), negative", "points", 0),
        ("avg_active_members", "AVG(active_members)", "Average monthly active loyalty members", "customers", 0),
    ])
    add_measures("gift_card_liability", [
        ("opening_liability", "MAX(opening_liability)", "Month-opening liability (LEVEL -- single month only)", "CAD", 2),
    ])
    add_measures("franchise_fees", [
        ("avg_fee_pct_of_sales", "AVG(fee_pct_of_sales)", "Average fee burden as percent of that month's store sales (row-level average)", "%", 2),
    ])
    add_measures("pricebook", [
        ("avg_sale_price", "SUM(avg_sale_price * units) / NULLIF(SUM(units), 0)", "Units-weighted pricebook sale price", "CAD", 2),
        ("avg_selling_price_change_pct", "SUM(CASE WHEN ABS(selling_price_change_pct) < 50 THEN selling_price_change_pct * units END) / NULLIF(SUM(CASE WHEN ABS(selling_price_change_pct) < 50 THEN units END), 0)", "Units-weighted MoM realised price change, outliers excluded", "%", 2),
        ("avg_stores_selling", "AVG(stores_selling)", "Average stores ranging the PLU per month", "stores", 1),
    ])
    add_dims("payables", [("terms_days", "terms_days", "number", "Payment terms in days (30, 45, 60)")])

    # ---- 8 (API half). relationships for re-granted models -------------------
    rels = {(r["from_model"], r["to_model"]) for r in env["relationships"]}
    for name, desc, frm, fk, to_model, tk in [
        ("dash_store_to_store", "Store rollup joins the store directory", "dash_store", "store_number", "stores", "storenumber"),
        ("psdv_to_store", "Line view joins the store directory", "pos_sales_detail_v", "store_number", "stores", "storenumber"),
        ("psdv_to_product", "Line view joins the product catalogue", "pos_sales_detail_v", "plu", "products", "plu"),
    ]:
        if frm in models and (frm, to_model) not in rels:
            fkey, tkey = key(frm, fk), key(to_model, tk)
            if fkey and tkey:
                env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc,
                                             "from_model": frm, "from_key": fkey, "to_model": to_model, "to_key": tkey,
                                             "type": "many_to_one", "join_type": "left"})
                changes.append(f"relationship {name}")
            else:
                changes.append(f"SKIPPED relationship {name} (key not found)")

    # guard
    for m2 in env["models"]:
        if not m2.get("dimensions"):
            m2["dimensions"] = [dim(m2["name"], "period_label", "'Jan 2019 - Dec 2020'", "string",
                                    "Constant label for the single-row model (added so the environment sync validates)")]
            changes.append(f"placeholder dimension on {m2['name']}")
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
    (OUT / "wobby_env_before_auditfix.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_auditfix_body.json"
    out.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    print("changes:"); [print("  -", c) for c in changes]
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
    (OUT / "wobby_env_after_auditfix.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    models = {m["name"]: m for m in after["models"]}
    mets = {m["name"]: m for m in after["metrics"]}
    gl = {g["term"]: g for g in after["glossary"]}
    rels = {(r["from_model"], r["to_model"]) for r in after["relationships"]}
    print("verify:")
    print("  attainment expr:", mets["sales_plan_attainment_pct"]["expression"])
    print("  attainment measure present:", any(x["name"] == "sales_attainment_pct" for x in models["sales_targets"]["measures"]))
    print("  ::numeric remaining:", sum("::numeric" in x.get("expression", "") for mn in ("churn_training_set", "activation_training_set") if mn in models for x in models[mn]["measures"]))
    print("  promoted default:", [f.get("apply_default") for f in mets["promotional_sales"]["filters"] if f["name"] == "promoted_items"])
    print("  glossary mapped:", all(gl[t].get("mappings") for t in ("Breakage", "Deferred Revenue", "Margin Bridge", "Pricebook")))
    print("  fsa dims:", sum(1 for d in models["fsa_demographics"]["dimensions"] if d["name"] in ("median_age", "competitor_count_5km", "pct_french_speaking")))
    print("  customer_month measures:", sum(1 for x in models["customer_month"]["measures"] if x["name"] in ("total_returns", "avg_min_csat", "total_purchase_days")))
    print("  new rels:", [(a, b) for (a, b) in (("dash_store", "stores"), ("pos_sales_detail_v", "stores"), ("pos_sales_detail_v", "products")) if (a, b) in rels])
    print("  counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
