"""wobby_refinements.py -- apply the ten refinements from
WOBBY_ANALYST_REFINEMENT_REVIEW.md to the Wobby POS Sales Analyst in one PUT.

  1  Correct churn risk bands everywhere in the instructions (0.25/0.45/0.70)
  2  Fix churn/activation training-set model guidance (cutoff grain, never
     SUM across cutoffs) AND remove both from the analyst's access
  3  Grant avg_cost_change_pct, avg_price_change_pct, price_cost_spread
  4  Plan-arbitration rule (sales_targets = operational, store_budget =
     financial) in the Plan vs Actuals pattern
  5  Monthly fee ledger authoritative: repoint franchise_fee_burden_pct to
     store_pnl, mark franchisees estimate metrics as legacy
  6  Document the 15 finance metrics and 6 finance models in the reference
  7  Expose the 8 lifecycle columns on the customers model
  8  Retire dash_monthly/promo/province/region/store and pos_sales_detail_v
     from analyst access (dash_kpi stays); label them fast-path in guidance
  9  Relationship transactions.promo_id -> promotions.promo_id
 10  Register loyalty_liability_monthly and gift_card_liability_monthly
     (built by build_liability_monthly.sql) with metrics and glossary

Usage:  python scripts/pos_perf/wobby_refinements.py [--put]
Fresh GET first; rate limit 2 req / 5 s; dimension-less-model guard applied.
Known caveat: the server may ignore access-entry edits for existing entries;
the verify step reports which access changes stuck.
"""

import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wobby_fix_defects import CFG, OUT, dim, gen_id, meas  # noqa: E402

RETIRE = ["churn_training_set", "activation_training_set", "dash_monthly", "dash_promo",
          "dash_province", "dash_region", "dash_store", "pos_sales_detail_v"]

BANDS_NEW = "Low (<0.25), Watch (0.25–0.45), High (0.45–0.70), Critical (>=0.70)"

METRIC_DOC = """
### Working Capital (AP / AR)

| Metric | Description |
|--------|-------------|
| `ap_outstanding` | Unpaid supplier balance (Open + Overdue) as of 2020-12-31 -- most is Current year-end invoices |
| `avg_days_to_pay` | DPO on paid invoices: ~26 d on Net 30, ~40 on Net 45, ~53 on Net 60 (apply `paid_only`) |
| `ap_pct_paid_on_time` | Share of paid supplier invoices settled by due date (~80%) |
| `early_pay_discounts_taken` | Early-payment discounts captured (~794K lifetime) |
| `franchise_fees_invoiced` | Royalty + marketing fees invoiced by month (ties to store_pnl to the cent) |
| `franchise_fees_collected` | Fees collected as of 2020-12-31 |
| `ar_outstanding` | Uncollected fees; the 60+ days bucket (~1.27M) is the true delinquency |
| `ar_pct_paid_on_time` | Share of paid fee invoices settled within the 15-day term (~83%) |

### Pricing, Tax & Assets

| Metric | Description |
|--------|-------------|
| `avg_cost_change_pct` | Units-weighted MoM pricebook cost change (cost inflation; outliers beyond +-50% excluded) |
| `avg_price_change_pct` | Units-weighted MoM regular-price change (price pass-through) |
| `price_cost_spread` | Regular price minus pricebook cost per unit |
| `tax_collected` | GST + provincial sales tax collected -- remittance liability, never revenue, not in the P&L |
| `taxable_sales_share_pct` | Taxable share of net sales (~31%); MB RST cut 8->7% at 2019-07 is real |
| `total_depreciation` | Monthly straight-line depreciation on store assets -- not in the P&L |
| `total_net_book_value` | NBV of store assets as of 2020-12-31 (156.6M on 194.6M cost) |

### Balance-Sheet Liabilities

| Metric | Description |
|--------|-------------|
| `loyalty_liability_cad` | Loyalty points liability at 1,000 pts/CAD -- month-end balance, filter to one month (2020-12: ~7.37M) |
| `gift_card_liability_cad` | Gift card liability roll-forward month-end balance (2020-12: 1,694,634.25, ties to gift_cards) |
"""

MODEL_DOC = """
### Finance Models

**payables:**

*   One supplier invoice per PO (92,472; amount real, payment behaviour modeled). DPO, on-time rate, aging, early-pay discounts. Status as of 2020-12-31: the big Current balance is year-end invoices not yet due

**franchise\\_fees:**

*   One fee invoice per store-month (7,706; ties to store\\_pnl to the cent). AR aging and collections by owner\\_name; 60+ days is true delinquency

**pricebook:**

*   Monthly cost and price per PLU (real, 16,088 rows). Cost inflation, pass-through, margin bridge; exclude MoM changes beyond +-50% as assortment noise

**sales\\_tax / tax\\_rates:**

*   GST/HST/PST collected per store-month; taxable share ~31%; MB RST cut 8->7% at 2019-07 (real). Remittance liability -- never revenue, not in the P&L

**store\\_assets:**

*   Build cost, depreciation (not in the P&L), NBV, lease expiries (cluster 2024/2028), 50 stores refitted in 2020 for refit-ROI vs store\\_traffic

**loyalty\\_liability / gift\\_card\\_liability:**

*   Month-end balance-sheet roll-forwards (24 rows each). Balances are month-end levels -- NEVER SUM across months, filter to one month (latest = 2020-12). Flows (earned, redeemed, issued) may be summed

"""


def build(env):
    models = {m["name"]: m for m in env["models"]}
    metrics = {m["name"]: m for m in env["metrics"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next((d["id"] for d in models[model]["dimensions"] if d["name"] == dimension), None)

    ins = analyst["instructions"]

    # ---- 1. risk bands everywhere -------------------------------------------
    n = 0
    for old in set(re.findall(r"Low \(<0\.3\), Watch \(0\.3.0\.5\), High \(0\.5.0\.75\), Critical \(>0\.75\)", ins)):
        n += ins.count(old)
        ins = ins.replace(old, BANDS_NEW)
    changes.append(f"risk bands corrected in {n} places")

    # ---- 4. plan arbitration -------------------------------------------------
    anchor = "Attainment % = actual / target × 100"
    if anchor in ins and "OPERATIONAL targets" not in ins:
        ins = ins.replace(anchor, anchor + "\n    \n*   **Two plan systems -- pick by intent**: `sales_targets` = OPERATIONAL targets "
                          "(calibrated 90-110% of actuals; use for attainment and manager performance -- 2020 plan 415.2M vs actual 416.5M). "
                          "`store_budget` = FINANCIAL plan (Original is blind to the pandemic -- 2020 plan 368.6M, actual +13%; Reforecast Q2 2020 tracks within 1%). "
                          "Default \"did we hit plan\" to sales_targets unless the user says budget, variance, reforecast or P&L\n", 1)
        changes.append("plan arbitration rule")

    # ---- 5. fee authority ----------------------------------------------------
    fa = "### Franchisee Fee Analysis"
    if fa in ins and "authoritative" not in ins.split(fa)[1][:900]:
        ins = ins.replace(fa, fa + "\n\n*   **Authoritative source**: the monthly ledger (`total_royalty_revenue`, `franchise_fees_invoiced`, store_pnl fees -- real rates on real sales). "
                          "`total_royalty_cost` / `total_est_marketing_fee` on franchisees are legacy lifetime ESTIMATES about 0.14% lower -- do not mix the two in one answer\n", 1)
        changes.append("fee authority rule")
    m = metrics.get("franchise_fee_burden_pct")
    if m is not None and m.get("anchor_model") != "store_pnl":
        m.update({
            "expression": "store_pnl.total_franchise_fees * 100.0 / NULLIF(store_pnl.total_net_sales, 0)",
            "anchor_model": "store_pnl",
            "description": "Royalty plus marketing fees as a percent of net sales, from the real monthly fee lines in the store P&L (network about 6.3 percent).",
            "agent_guidance": "Repointed 2026-08-23 from the franchisees lifetime estimates to the real monthly ledger. Group by region, store_format, store_name or franchisees.owner_name; time grain via store_pnl month_date.\n",
            "time_dimension": {"model": "store_pnl", "dimension": "month_date"},
            "time_grains": ["month", "quarter", "year"],
            "group_by_dimensions": [{"model": "store_pnl", "dimension": d} for d in ("region", "province", "store_format", "store_name", "pandemic_period")],
        })
        changes.append("franchise_fee_burden_pct -> store_pnl (real monthly)")
    for name, note in [("total_royalty_cost", "LEGACY lifetime estimate on franchisees (0.14 pct below the real ledger). Prefer total_royalty_revenue (monthly, real)."),
                       ("total_est_marketing_fee", "LEGACY lifetime estimate on franchisees. Prefer total_marketing_fee_revenue or franchise_fees_invoiced (monthly, real).")]:
        mt = metrics.get(name)
        if mt is not None and "LEGACY" not in (mt.get("agent_guidance") or ""):
            mt["agent_guidance"] = note + "\n" + (mt.get("agent_guidance") or "")
            changes.append(f"{name} marked legacy")

    # ---- 2. training-set models: guidance + access removal ------------------
    cts = models.get("churn_training_set")
    if cts is not None:
        cts["description"] = ("ML FEATURE TABLE for churn model training -- NOT for business analytics (use customer_churn_scores, customer_ipt_stats or customer_month instead). "
                              "24.3M rows: one row per customer per CUTOFF -- 16 month-end cutoffs (2019-07-31 to 2020-09-30 plus the 2020-12-31 scoring snapshot), not every month.")
        cts["agent_guidance"] = ("The same customer appears up to 16 times (once per cutoff) -- NEVER SUM amounts across this table, totals inflate up to 16x. "
                                 "is_scoring_row = Y is the single 2020-12-31 snapshot (2,095,432 rows). churn_90 / churn_adaptive are NULL when the label horizon passes 2020-12-31 (right-censored). "
                                 "Redirect business questions to customer_churn_scores (risk today), customer_ipt_stats (cadence) or customer_month (time series).")
        changes.append("churn_training_set guidance corrected")
    ats = models.get("activation_training_set")
    if ats is not None:
        ats["description"] = ("ML FEATURE TABLE for the second-purchase activation model -- NOT for business analytics. One row per customer (3.18M) with first-basket features; "
                              "activated_90 is NULL when the 90-day window passes 2020-12-31.")
        ats["agent_guidance"] = ("For one-time-buyer questions use customer_churn_scores (model_version activation-gbm-v1) or customers.lifecycle_status = 'One-time'. "
                                 "This table exists to train the model, not to answer questions.")
        changes.append("activation_training_set guidance corrected")

    # ---- 8. fast-path labels + access retirement -----------------------------
    for name in ("dash_monthly", "dash_promo", "dash_province", "dash_region", "dash_store", "pos_sales_detail_v"):
        mm = models.get(name)
        if mm is not None and "FAST PATH" not in (mm.get("agent_guidance") or ""):
            mm["agent_guidance"] = ("FAST PATH ONLY, line-grain totals (sales_ext sums line items -- 102 CAD above the basket-grain transactions total). "
                                    "Prefer transactions / store_pnl / gl for anything beyond a quick headline. ") + (mm.get("agent_guidance") or "")
            changes.append(f"{name} labelled fast-path")
    before = len(access["models"])
    access["models"] = [m for m in access["models"] if m["name"] not in RETIRE]
    changes.append(f"access: removed {before - len(access['models'])} model grants ({', '.join(RETIRE)})")

    # ---- 3. metric grants ----------------------------------------------------
    for name in ("avg_cost_change_pct", "avg_price_change_pct", "price_cost_spread"):
        if name not in access["metrics"]:
            access["metrics"].append(name)
    changes.append("access: pricebook metrics granted")

    # ---- 7. customers lifecycle columns -------------------------------------
    cust = models["customers"]
    have = {d["name"] for d in cust["dimensions"]}
    addcols = [
        ("lifecycle_status", "lifecycle_status", "enum", "One-time, New, Active, Lapsing, Churned, Inactive -- adaptive cadence-based lifecycle as of 2020-12-31"),
        ("churn_risk_band", "churn_risk_band", "enum", "Low, Watch, High, Critical -- mirrors customer_churn_scores.risk_band"),
        ("overdue_ratio", "overdue_ratio", "number", "Days silent divided by the customer median purchase gap (>1 overdue, >2 lapsing)"),
        ("ipt_median_days", "ipt_median_days", "number", "Median days between purchases"),
        ("expected_next_purchase", "expected_next_purchase", "date", "Last purchase plus the median gap"),
        ("tenure_days", "tenure_days", "number", "Days from first purchase to 2020-12-31"),
        ("first_store_number", "first_store_number", "number", "Store of the first transaction"),
        ("churn_horizon_days", "churn_horizon_days", "number", "Adaptive churn horizon: max(90, 3 x median gap) capped at 180"),
    ]
    added = 0
    for nm, expr, typ, desc in addcols:
        if nm not in have:
            cust["dimensions"].append(dim("customers", nm, expr, typ, desc))
            added += 1
    if added:
        ce = next((x for x in access["models"] if x["name"] == "customers"), None)
        if ce is not None and isinstance(ce.get("dimensions"), list):
            for nm, *_ in addcols:
                if nm not in ce["dimensions"]:
                    ce["dimensions"].append(nm)
        changes.append(f"customers: {added} lifecycle dimensions added")
    guide = cust.get("agent_guidance") or ""
    if "lifecycle_status" not in guide:
        cust["agent_guidance"] = guide + " lifecycle_status and churn_risk_band are the preferred segmentation dimensions (cadence-adaptive, as of 2020-12-31); rfm_segment is the legacy static segmentation."
        changes.append("customers guidance updated")

    # ---- 9. transactions -> promotions --------------------------------------
    rels = {(r["from_model"], r["to_model"]) for r in env["relationships"]}
    if ("transactions", "promotions") not in rels:
        fk, tk = key("transactions", "promo_id"), key("promotions", "promo_id")
        if fk and tk:
            env["relationships"].append({"id": gen_id("rel", "transactions_to_promotion"), "name": "transactions_to_promotion",
                                         "description": "Promoted baskets link to the promotion event (promo_id NULL on unpromoted baskets)",
                                         "from_model": "transactions", "from_key": fk, "to_model": "promotions", "to_key": tk,
                                         "type": "many_to_one", "join_type": "left"})
            changes.append("relationship transactions_to_promotion")
        else:
            changes.append("SKIPPED transactions_to_promotion (key not found)")

    # ---- 10. liability models ------------------------------------------------
    LL, GC = "loyalty_liability", "gift_card_liability"
    if LL not in models:
        model = {
            "id": gen_id("model", LL), "name": LL,
            "description": ("Loyalty points liability roll-forward, one row per month (24 rows). Flows are REAL from the ledger (points earned, redeemed, adjustments); "
                            "point value convention 1,000 points per CAD (same as the Loyalty Points tender). Closing balance at 2020-12: 7,367,650,182 points = about 7.37M CAD, "
                            "tying to the ledger sum exactly. No expiry modeled inside the 24-month window."),
            "agent_guidance": ("Balances (opening/closing) are month-end LEVELS -- never SUM across months; filter to one month (latest = 2020-12) or show the trend. "
                               "Flows (earned, redeemed) may be summed. Deferred-revenue view of the programme; redemption_rate_pct is the health indicator (about 3.6 percent of points earned get redeemed)."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "loyalty_liability_monthly"]},
            "dimensions": [
                dim(LL, "year_month", "yyyymm", "number", "Month as yyyymm", pk=True),
                dim(LL, "month_date", "month_start", "date", "First day of the month", grains=["month", "quarter", "year"]),
                dim(LL, "year", "yr", "number", "Calendar year"),
            ],
            "measures": [
                meas(LL, "points_earned", "SUM(points_earned)", "Points earned in the month (flow)", "points", 0),
                meas(LL, "points_redeemed", "SUM(points_redeemed)", "Points redeemed in the month (flow)", "points", 0),
                meas(LL, "earned_value_cad", "SUM(earned_value_cad)", "CAD value of points earned (flow)", "CAD", 2),
                meas(LL, "redeemed_value_cad", "SUM(redeemed_value_cad)", "CAD value of points redeemed (flow)", "CAD", 2),
                meas(LL, "closing_liability_cad", "MAX(closing_liability_cad)", "Month-end liability (LEVEL -- single month only)", "CAD", 2),
                meas(LL, "closing_points_balance", "MAX(closing_points_balance)", "Month-end points outstanding (LEVEL)", "points", 0),
            ],
            "filters": [],
        }
        env["models"].append(model)
        models[LL] = model
        access["models"].append({"name": LL})
        fk, tk = key(LL, "month_date"), key("date_dim", "calendar_date")
        if fk and tk:
            env["relationships"].append({"id": gen_id("rel", "loyliab_to_date"), "name": "loyalty_liability_to_date",
                                         "description": "Liability month on the calendar", "from_model": LL, "from_key": fk,
                                         "to_model": "date_dim", "to_key": tk, "type": "many_to_one", "join_type": "left"})
        changes.append("model loyalty_liability")
    if GC not in models:
        model = {
            "id": gen_id("model", GC), "name": GC,
            "description": ("Gift card liability roll-forward, one row per month (24 rows). Issued value is REAL by purchase month; redemption timing is modeled "
                            "(each card's redeemed amount recognised 0-3 months after purchase, deterministic) so the closing balance at 2020-12 equals the real "
                            "outstanding balance to the cent (1,694,634.25)."),
            "agent_guidance": ("Balances are month-end LEVELS -- never SUM across months. issued_value and redeemed_value are flows and may be summed "
                               "(lifetime: 3.39M issued, 1.69M redeemed). Use gift_cards.outstanding_liability for the card-level view; this model adds the monthly movement."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "gift_card_liability_monthly"]},
            "dimensions": [
                dim(GC, "year_month", "yyyymm", "number", "Month as yyyymm", pk=True),
                dim(GC, "month_date", "month_start", "date", "First day of the month", grains=["month", "quarter", "year"]),
                dim(GC, "year", "yr", "number", "Calendar year"),
            ],
            "measures": [
                meas(GC, "issued_value", "SUM(issued_value)", "Gift card value issued (flow)", "CAD", 2),
                meas(GC, "issued_cards", "SUM(issued_cards)", "Cards issued (flow)", "cards", 0),
                meas(GC, "redeemed_value", "SUM(redeemed_value)", "Value redeemed (flow, timing modeled)", "CAD", 2),
                meas(GC, "closing_liability", "MAX(closing_liability)", "Month-end liability (LEVEL -- single month only)", "CAD", 2),
                meas(GC, "cumulative_redemption_pct", "MAX(cumulative_redemption_pct)", "Cumulative share of issued value redeemed (LEVEL)", "%", 2),
            ],
            "filters": [],
        }
        env["models"].append(model)
        models[GC] = model
        access["models"].append({"name": GC})
        fk, tk = key(GC, "month_date"), key("date_dim", "calendar_date")
        if fk and tk:
            env["relationships"].append({"id": gen_id("rel", "gcliab_to_date"), "name": "gift_card_liability_to_date",
                                         "description": "Liability month on the calendar", "from_model": GC, "from_key": fk,
                                         "to_model": "date_dim", "to_key": tk, "type": "many_to_one", "join_type": "left"})
        changes.append("model gift_card_liability")

    for name, expr, anchor_m, desc, guide in [
        ("loyalty_liability_cad", f"{LL}.closing_liability_cad", LL,
         "Loyalty points liability in CAD (1,000 points per CAD) at month end. A LEVEL: filter to one month; 2020-12 is about 7.37M.",
         "Never sum across months. Trend it monthly, or state the 2020-12 closing figure. About 1 percent of net sales -- the deferred-revenue cost of the programme.\n"),
        ("gift_card_liability_cad", f"{GC}.closing_liability", GC,
         "Gift card liability at month end (roll-forward). A LEVEL: filter to one month; 2020-12 is 1,694,634.25, tying to gift_cards.",
         "Never sum across months. Redemption timing is modeled (0-3 months after purchase); issued value and the closing balance are real.\n"),
    ]:
        if name not in metrics:
            mt = {"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
                  "expression": expr, "anchor_model": anchor_m, "unit": "CAD", "precision": 2,
                  "time_dimension": {"model": anchor_m, "dimension": "month_date"}, "time_grains": ["month", "quarter", "year"],
                  "group_by_dimensions": [{"model": anchor_m, "dimension": "year_month"}], "filters": []}
            env["metrics"].append(mt)
            metrics[name] = mt
            access["metrics"].append(name)
    changes.append("2 liability metrics")

    terms = {g["term"] for g in env["glossary"]}
    for term, definition, syn in [
        ("Deferred Revenue", "Value collected but not yet earned: outstanding gift card balances (1.69M at 2020-12) and the loyalty points liability (about 7.37M at 1,000 points per CAD). Tracked monthly in gift_card_liability and loyalty_liability.", ["unearned revenue", "liability roll-forward"]),
        ("Breakage", "The share of stored value never redeemed. Gift cards: about 50 percent of issued value is still outstanding at 2020-12. Loyalty: only about 3.6 percent of earned points are redeemed inside the window. No expiry is modeled, so breakage is a disclosure rather than recognised income.", ["unredeemed value"]),
    ]:
        if term not in terms:
            env["glossary"].append({"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": syn, "tags": ["finance"], "mappings": []})
    changes.append("2 glossary terms")

    # ---- 6. instruction reference sections ----------------------------------
    scor = "SCOR Framework Reference"
    if scor in ins and "### Working Capital (AP / AR)" not in ins:
        ins = ins.replace(scor, METRIC_DOC.strip() + "\n\n* * *\n\n" + scor, 1)
        changes.append("15+2 finance metrics documented")
    inv = "### Inventory & Supply Chain Models"
    if inv in ins and "### Finance Models" not in ins:
        ins = ins.replace(inv, MODEL_DOC.strip() + "\n\n" + inv, 1)
        changes.append("finance models documented")
    total = len(env["metrics"])
    ins = re.sub(r"has 95 well-documented metrics", f"has {total} well-documented metrics", ins)
    ins = re.sub(r"All \d+ metrics available to you", f"All {total} metrics available to you", ins)
    ins = re.sub(r"Total metrics: \d+\.", f"Total metrics: {total}.", ins)
    analyst["instructions"] = ins

    # dimension-less model guard (PUT validator)
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
    (OUT / "wobby_env_before_refine.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_refine_body.json"
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
    (OUT / "wobby_env_after_refine.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    a = after["ai_analysts"][0]
    ins2 = a["instructions"]
    accm = {m["name"] for m in a["semantic_layer_access"]["models"]}
    accmt = set(a["semantic_layer_access"]["metrics"])
    names = {m["name"] for m in after["models"]}
    rels = {(r["from_model"], r["to_model"]) for r in after["relationships"]}
    cust = next(m for m in after["models"] if m["name"] == "customers")
    ffb = next(m for m in after["metrics"] if m["name"] == "franchise_fee_burden_pct")
    print("verify:")
    print("  old bands remaining:", len(re.findall(r"Low \(<0\.3\), Watch", ins2)), "| new bands:", ins2.count("Low (<0.25)"))
    print("  plan rule:", "OPERATIONAL targets" in ins2, "| fee rule:", "Authoritative source" in ins2)
    print("  finance metric docs:", "### Working Capital (AP / AR)" in ins2, "| finance model docs:", "### Finance Models" in ins2)
    print("  training sets in access:", [n for n in RETIRE if n in accm] or "REMOVED")
    print("  pricebook metrics granted:", all(x in accmt for x in ("avg_cost_change_pct", "avg_price_change_pct", "price_cost_spread")))
    print("  customers lifecycle dims:", sum(1 for d in cust["dimensions"] if d["name"] in ("lifecycle_status", "churn_risk_band")))
    print("  txn->promo rel:", ("transactions", "promotions") in rels)
    print("  liability models:", "loyalty_liability" in names and "gift_card_liability" in names,
          "| metrics:", all(x in {m['name'] for m in after['metrics']} for x in ("loyalty_liability_cad", "gift_card_liability_cad")))
    print("  ffb anchor:", ffb["anchor_model"])
    print("  counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
