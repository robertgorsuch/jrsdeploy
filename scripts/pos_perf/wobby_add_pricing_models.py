"""wobby_add_pricing_models.py -- register pricebook_history,
provincial_tax_rates, tax_collected_monthly and store_assets in the Wobby
POS Sales Analyst semantic layer.

Adds
  models        pricebook, tax_rates, sales_tax, store_assets
  relationships pricebook -> products; sales_tax -> stores, tax_rates(province);
                store_assets -> stores, franchisees
  metrics       avg_pricebook_cost, cost_change_pct, price_change_pct,
                price_cost_spread, tax_collected, taxable_sales_share_pct,
                total_depreciation, total_net_book_value
  glossary      Pricebook, Margin Bridge, Zero-Rated, HST, Net Book Value
  instructions  model references (metric table is UI-managed, left alone)

Usage:  python scripts/pos_perf/wobby_add_pricing_models.py [--put]
Fresh GET first; rate limit 2 req / 5 s; dimension-less-model guard applied.
"""

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wobby_fix_defects import CFG, OUT, dim, filt, gen_id, meas  # noqa: E402

M_GRAINS = ["month", "quarter", "year"]


def build(env):
    models = {m["name"]: m for m in env["models"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next((d["id"] for d in models[model]["dimensions"] if d["name"] == dimension), None)

    def rel(name, desc, frm, fk, to_model, tk, typ="many_to_one"):
        fkey, tkey = key(frm, fk), key(to_model, tk)
        if fkey and tkey:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc,
                                         "from_model": frm, "from_key": fkey, "to_model": to_model, "to_key": tkey,
                                         "type": typ, "join_type": "left"})
            return 1
        changes.append(f"SKIPPED relationship {name} ({frm}.{fk} -> {to_model}.{tk})")
        return 0

    def add_model(model, rels):
        env["models"].append(model)
        models[model["name"]] = model
        access["models"].append({"name": model["name"]})
        n = sum(rel(*r) for r in rels)
        changes.append(f"model {model['name']} + {n} relationships")

    PB = "pricebook"
    if PB not in models:
        add_model({
            "id": gen_id("model", PB), "name": PB,
            "description": ("Monthly pricebook per PLU (16,088 rows, all 942 PLUs x months sold, fully REAL from the line fact): average pricebook cost, "
                            "regular price, sale price and realised selling price, units and sales, with month-over-month cost and price change and the "
                            "price-cost spread. Powers cost inflation, price pass-through and margin-bridge analysis."),
            "agent_guidance": ("cost_change_pct and price_change_pct are month-over-month per PLU (NULL in a PLU's first month). For network inflation, "
                               "average changes weighted by units, and exclude outliers beyond +-50 pct (assortment mix, e.g. Stuffed Turkey Breast +255 pct "
                               "cost in 2020-08 is a pack-size change, not inflation). catalogued = Y means the PLU has category metadata (26 pct of rows); "
                               "category is NULL otherwise -- caveat category analysis. Margin bridge: realised margin moves with (price change) - "
                               "(cost change) + mix. Join plu to products."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "pricebook_history"]},
            "dimensions": [
                dim(PB, "plu", "plu", "string", "Product PLU, joins products"),
                dim(PB, "product_name", "product_name", "string", "Product name (catalogue name or POS description)"),
                dim(PB, "category", "category", "enum", "Product category, NULL for uncatalogued PLUs"),
                dim(PB, "sub_category", "sub_category", "enum", "Sub-category"),
                dim(PB, "catalogued", "catalogued", "enum", "Y when the PLU has category metadata (26 pct of rows)"),
                dim(PB, "year_month", "yyyymm", "number", "Month as yyyymm"),
                dim(PB, "month_date", "month_start", "date", "First day of the month", grains=M_GRAINS),
                dim(PB, "year", "yr", "number", "Calendar year"),
                dim(PB, "month", "mo", "number", "Calendar month"),
            ],
            "measures": [
                meas(PB, "plu_months", "COUNT(*)", "PLU-month rows", "rows", 0),
                meas(PB, "avg_pricebook_cost", "SUM(avg_pricebook_cost * units) / NULLIF(SUM(units), 0)", "Units-weighted average pricebook cost", "CAD", 2),
                meas(PB, "avg_regular_price", "SUM(avg_regular_price * units) / NULLIF(SUM(units), 0)", "Units-weighted average regular price", "CAD", 2),
                meas(PB, "avg_selling_price", "SUM(avg_selling_price * units) / NULLIF(SUM(units), 0)", "Units-weighted average realised price", "CAD", 2),
                meas(PB, "avg_price_cost_spread", "SUM(price_cost_spread * units) / NULLIF(SUM(units), 0)", "Units-weighted regular price minus cost", "CAD", 2),
                meas(PB, "avg_cost_change_pct", "SUM(CASE WHEN ABS(cost_change_pct) < 50 THEN cost_change_pct * units END) / NULLIF(SUM(CASE WHEN ABS(cost_change_pct) < 50 THEN units END), 0)", "Units-weighted MoM cost change, outliers beyond 50 pct excluded", "%", 2),
                meas(PB, "avg_price_change_pct", "SUM(CASE WHEN ABS(price_change_pct) < 50 THEN price_change_pct * units END) / NULLIF(SUM(CASE WHEN ABS(price_change_pct) < 50 THEN units END), 0)", "Units-weighted MoM regular-price change, outliers excluded", "%", 2),
                meas(PB, "total_units", "SUM(units)", "Units sold", "units", 0),
                meas(PB, "total_sales", "SUM(sales)", "Sales", "CAD", 2),
                meas(PB, "margin_pct_realised", "SUM((avg_selling_price - avg_pricebook_cost) * units) / NULLIF(SUM(avg_selling_price * units), 0) * 100", "Realised margin percent at pricebook cost", "%", 2),
            ],
            "filters": [filt(PB, "catalogued_only", "catalogued = 'Y'", "PLUs with category metadata")],
        }, [("pricebook_to_product", "Each pricebook row describes one PLU", PB, "plu", "products", "plu")])

    TR = "tax_rates"
    if TR not in models:
        add_model({
            "id": gen_id("model", TR), "name": TR,
            "description": ("Real Canadian GST/HST/PST rates for 2019-2020 by province and effective date (13 rows), including the real Manitoba RST cut "
                            "from 8 to 7 percent on 2019-07-01. Basic groceries are zero-rated; taxable categories in this catalogue: Prepared meals, "
                            "Single serve, Appetizers, Desserts, Kitchen essentials."),
            "agent_guidance": "Dimension table. sales_tax already applies these rates; use this model to explain a rate or the MB change. combined_pct = GST plus the provincial component.",
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "provincial_tax_rates"]},
            "dimensions": [
                dim(TR, "province", "province", "enum", "Province code"),
                dim(TR, "province_name", "province_name", "string", "Province name"),
                dim(TR, "effective_from", "effective_from", "date", "Date the rate took effect"),
                dim(TR, "provincial_tax_name", "provincial_tax_name", "enum", "HST, QST, PST, RST or None"),
                dim(TR, "gst_pct", "gst_pct", "number", "Federal GST percent"),
                dim(TR, "provincial_pct", "provincial_pct", "number", "Provincial component percent"),
                dim(TR, "combined_pct", "combined_pct", "number", "Combined rate on taxable items"),
            ],
            "measures": [meas(TR, "rate_rows", "COUNT(*)", "Rate rows", "rows", 0)],
            "filters": [],
        }, [])

    SX = "sales_tax"
    if SX not in models:
        add_model({
            "id": gen_id("model", SX), "name": SX,
            "description": ("Sales tax collected per store per month (7,706 rows), derived from the line fact x product categories x provincial_tax_rates. "
                            "Taxable share of sales is 30.6 percent network-wide (Prepared meals, Single serve, Appetizers, Desserts, Kitchen essentials; "
                            "basic groceries and uncatalogued PLUs zero-rated). Lifetime: 11.7M GST plus 16.4M provincial = 28.1M CAD collected."),
            "agent_guidance": ("Tax is collected ON TOP of the selling price -- a remittance liability, never revenue, and it does not touch the store P&L. "
                               "The Manitoba RST cut (8 to 7 percent, 2019-07-01) is visible in provincial_pct. Group by province or provincial_tax_name for "
                               "remittance by jurisdiction. taxable_share_pct varies little by store; differences in tax collected are mostly rate and volume."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "tax_collected_monthly"]},
            "dimensions": [
                dim(SX, "store_number", "storenumber", "number", "Store, joins stores"),
                dim(SX, "province", "province", "enum", "Store province, joins tax_rates"),
                dim(SX, "region", "region", "enum", "Store region"),
                dim(SX, "year_month", "yyyymm", "number", "Month as yyyymm"),
                dim(SX, "month_date", "month_start", "date", "First day of the month", grains=M_GRAINS),
                dim(SX, "year", "yr", "number", "Calendar year"),
                dim(SX, "provincial_tax_name", "provincial_tax_name", "enum", "HST, QST, PST, RST or None"),
                dim(SX, "combined_pct", "combined_pct", "number", "Combined rate applied that month"),
            ],
            "measures": [
                meas(SX, "taxable_sales", "SUM(taxable_sales)", "Sales in taxable categories", "CAD", 2),
                meas(SX, "zero_rated_sales", "SUM(zero_rated_sales)", "Zero-rated basic grocery sales", "CAD", 2),
                meas(SX, "taxable_share_pct", "SUM(taxable_sales) / NULLIF(SUM(taxable_sales) + SUM(zero_rated_sales), 0) * 100", "Taxable share of net sales", "%", 2),
                meas(SX, "gst_collected", "SUM(gst_collected)", "Federal GST collected", "CAD", 2),
                meas(SX, "provincial_tax_collected", "SUM(provincial_tax_collected)", "Provincial HST/QST/PST/RST component collected", "CAD", 2),
                meas(SX, "total_tax_collected", "SUM(total_tax_collected)", "Total sales tax collected (remittance liability)", "CAD", 2),
            ],
            "filters": [],
        }, [("salestax_to_store", "Each tax row belongs to one store", SX, "store_number", "stores", "storenumber")])

    SA = "store_assets"
    if SA not in models:
        add_model({
            "id": gen_id("model", SA), "name": SA,
            "description": ("Fixed assets per store (330 rows): leasehold improvements and freezer-heavy equipment costs modeled from square feet and format "
                            "(194.6M CAD network build cost), straight-line depreciation (leasehold 10y, equipment 7y; 1.83M CAD per month network-wide), "
                            "net book value 156.6M as of 2020-12-31, lease expiry from the real open date (5 or 10 year terms -- expiries cluster in 2024 "
                            "and 2028), and a 2020 refit for 50 of the 2019-H1 stores."),
            "agent_guidance": ("All values modeled and deterministic, anchored to real square footage, format and open date. Depreciation is NOT in the store "
                               "P&L (contribution is before depreciation) -- subtract total_monthly_depreciation from four_wall_ebitda for an EBIT view. "
                               "Refit ROI: compare store_traffic or store_pnl before vs after refit_date for the 50 refitted stores. The 2024 lease cluster "
                               "(169 stores) is the renewal-risk story. Join store_number to stores, franchisee_id to franchisees."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "store_assets"]},
            "dimensions": [
                dim(SA, "store_number", "storenumber", "number", "Store, joins stores", pk=True),
                dim(SA, "store_name", "storename", "string", "Store name"),
                dim(SA, "province", "province", "enum", "Province"),
                dim(SA, "region", "region", "enum", "Region"),
                dim(SA, "store_format", "store_format", "enum", "Store format"),
                dim(SA, "franchisee_id", "franchisee_id", "number", "Franchisee, joins franchisees"),
                dim(SA, "open_date", "open_date", "date", "Real store open date"),
                dim(SA, "refit_date", "refit_date", "date", "2020 refit date, NULL for most stores"),
                dim(SA, "lease_expiry", "lease_expiry", "date", "Lease end (open date + 5 or 10 years)"),
                dim(SA, "lease_years", "lease_years", "number", "Lease term in years"),
                dim(SA, "renewal_option", "renewal_option", "enum", "Y when the lease carries a renewal option"),
            ],
            "measures": [
                meas(SA, "stores_count", "COUNT(*)", "Stores", "stores", 0),
                meas(SA, "total_build_cost", "SUM(total_build_cost)", "Leasehold improvements plus equipment at cost", "CAD", 2),
                meas(SA, "total_refit_cost", "SUM(refit_cost)", "2020 refit spend", "CAD", 2),
                meas(SA, "total_monthly_depreciation", "SUM(total_monthly_depreciation)", "Straight-line depreciation per month", "CAD", 2),
                meas(SA, "total_net_book_value", "SUM(net_book_value)", "Net book value as of 2020-12-31", "CAD", 2),
                meas(SA, "refitted_stores", "SUM(CASE WHEN refit_date IS NOT NULL THEN 1 ELSE 0 END)", "Stores refitted in 2020", "stores", 0),
                meas(SA, "leases_expiring", "COUNT(*)", "Lease count (group by YEAR(lease_expiry) via lease_expiry)", "leases", 0),
            ],
            "filters": [filt(SA, "refitted_only", "refit_date IS NOT NULL", "The 50 stores refitted in 2020")],
        }, [("assets_to_store", "One asset record per store", SA, "store_number", "stores", "storenumber", "one_to_one"),
            ("assets_to_franchisee", "Assets belong to the store owner", SA, "franchisee_id", "franchisees", "franchisee_id")])

    # metrics
    existing = {m["name"] for m in env["metrics"]}
    new_metrics = []
    for name, expr, anchor, unit, prec, tdim, gb_dims, desc, guide in [
        ("avg_cost_change_pct", f"{PB}.avg_cost_change_pct", PB, "%", 2, "month_date",
         [(PB, "category"), (PB, "sub_category"), (PB, "product_name"), (PB, "catalogued")],
         "Units-weighted month-over-month pricebook cost change (outliers beyond 50 percent excluded): the cost-inflation metric.",
         "Network runs 0.1-0.25 percent per month. Group by category (catalogued PLUs only) to find where cost pressure sits; compare with avg_price_change_pct for pass-through.\n"),
        ("avg_price_change_pct", f"{PB}.avg_price_change_pct", PB, "%", 2, "month_date",
         [(PB, "category"), (PB, "sub_category"), (PB, "product_name")],
         "Units-weighted month-over-month regular-price change: the price pass-through metric.",
         "Compare against avg_cost_change_pct: price rising slower than cost = margin compression on that category.\n"),
        ("price_cost_spread", f"{PB}.avg_price_cost_spread", PB, "CAD", 2, "month_date",
         [(PB, "category"), (PB, "product_name")],
         "Units-weighted regular price minus pricebook cost per unit.",
         "The dollar margin per unit at full price. margin_pct_realised on pricebook gives the realised percent after promotions.\n"),
        ("tax_collected", f"{SX}.total_tax_collected", SX, "CAD", 2, "month_date",
         [(SX, "province"), (SX, "region"), (SX, "provincial_tax_name"), (SX, "year")],
         "Total sales tax collected (GST plus provincial), a remittance liability on top of the selling price -- never revenue.",
         "Lifetime 28.1M (11.7M GST, 16.4M provincial). Group by province for remittance by jurisdiction; the Manitoba RST cut (8 to 7 pct) shows from 2019-07.\n"),
        ("taxable_sales_share_pct", f"{SX}.taxable_share_pct", SX, "%", 2, "month_date",
         [(SX, "province"), (SX, "region")],
         "Share of net sales in taxable categories (Prepared meals, Single serve, Appetizers, Desserts, Kitchen essentials); the rest is zero-rated basic groceries.",
         "About 30.6 percent network-wide. Uncatalogued PLUs (79 percent of the catalogue) are treated as zero-rated -- state that caveat.\n"),
        ("total_depreciation", f"{SA}.total_monthly_depreciation", SA, "CAD", 2, None,
         [(SA, "region"), (SA, "province"), (SA, "store_format"), (SA, "store_name")],
         "Straight-line monthly depreciation on store assets (leasehold 10y, equipment 7y). Not included in the store P&L.",
         "Network 1.83M per month. Subtract from four_wall_ebitda for an EBIT view. Not a time series -- one asset record per store.\n"),
        ("total_net_book_value", f"{SA}.total_net_book_value", SA, "CAD", 2, None,
         [(SA, "region"), (SA, "province"), (SA, "store_format")],
         "Net book value of store assets as of 2020-12-31 (156.6M network-wide on 194.6M build cost).",
         "Modeled, anchored to real square footage and open dates. Group by format or region; refitted_only filter isolates the 50 refit stores.\n"),
    ]:
        if name not in existing:
            mt = {"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
                  "expression": expr, "anchor_model": anchor, "unit": unit, "precision": prec,
                  "group_by_dimensions": [{"model": m, "dimension": d} for m, d in gb_dims], "filters": []}
            if tdim:
                mt["time_dimension"] = {"model": anchor, "dimension": tdim}
                mt["time_grains"] = M_GRAINS
            new_metrics.append(mt)
    for mt in new_metrics:
        env["metrics"].append(mt)
        access["metrics"].append(mt["name"])
    changes.append(f"{len(new_metrics)} pricing/tax/asset metrics")

    # glossary
    terms = {g["term"] for g in env["glossary"]}
    for term, definition, syn in [
        ("Pricebook", "The master cost and price list per PLU. pricebook_history tracks its monthly averages from the line fact: cost, regular price, sale price and realised selling price.", ["price book", "cost book"]),
        ("Margin Bridge", "Decomposition of a margin change into price, cost and mix effects. Build it from pricebook: avg_price_change_pct minus avg_cost_change_pct is the rate effect; the remainder vs margin_pct_realised movement is mix.", ["price cost mix", "margin walk"]),
        ("Zero-Rated", "Taxed at 0 percent GST/HST: basic groceries in Canada. In this catalogue everything except Prepared meals, Single serve, Appetizers, Desserts and Kitchen essentials is treated as zero-rated (uncatalogued PLUs included, conservatively).", ["zero rated", "GST exempt groceries"]),
        ("HST", "Harmonized Sales Tax: the combined federal-provincial sales tax in ON (13 pct) and NB/NL/NS/PE (15 pct). Other provinces charge GST 5 pct plus QST/PST/RST separately; AB and the territories charge GST only. Manitoba cut RST from 8 to 7 pct on 2019-07-01 (real).", ["harmonized sales tax", "GST", "PST", "QST", "RST"]),
        ("Net Book Value", "Asset cost minus accumulated straight-line depreciation (leasehold 10 years, equipment 7 years), as of 2020-12-31 in store_assets. Depreciation is not in the store P&L.", ["NBV", "book value"]),
    ]:
        if term not in terms:
            env["glossary"].append({"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": syn, "tags": ["finance"], "mappings": []})
    changes.append("5 glossary terms")

    # instructions: model references only
    ins = analyst["instructions"]
    mref = "**payables / franchise_fees:**"
    if mref in ins and "**pricebook / sales_tax / store_assets:**" not in ins:
        ins = ins.replace(mref, "**pricebook / sales_tax / store_assets:**\n- pricebook: monthly cost and price per PLU (real). Cost inflation, price pass-through, margin bridge; exclude MoM changes beyond +-50% as assortment noise\n"
                          "- sales_tax + tax_rates: GST/HST/PST collected per store-month (taxable share ~31%; MB RST cut 8->7% at 2019-07 is real). Tax is a remittance liability, never revenue, and is not in the P&L\n"
                          "- store_assets: build cost, depreciation (not in the P&L), NBV, lease expiries (cluster 2024/2028), 50 stores refitted in 2020 for refit-ROI stories\n\n" + mref)
        changes.append("model references in instructions")
    analyst["instructions"] = ins

    # dimension-less model guard
    for m in env["models"]:
        if not m.get("dimensions"):
            m["dimensions"] = [dim(m["name"], "period_label", "'Jan 2019 - Dec 2020'", "string",
                                   "Constant label for the single-row model (added so the environment sync validates)")]
            changes.append(f"placeholder dimension on {m['name']}")
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
    (OUT / "wobby_env_before_pricing.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_pricing_body.json"
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
    (OUT / "wobby_env_after_pricing.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    names = {m["name"] for m in after["models"]}
    mets = {m["name"] for m in after["metrics"]}
    print("verify:", all(x in names for x in ("pricebook", "tax_rates", "sales_tax", "store_assets")),
          "| metrics", all(x in mets for x in ("avg_cost_change_pct", "tax_collected", "total_net_book_value")),
          "| counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
