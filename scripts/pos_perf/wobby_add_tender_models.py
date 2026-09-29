"""wobby_add_tender_models.py -- register tender_summary_daily in the Wobby
POS Sales Analyst semantic layer and update the store_pnl guidance now that
card processing fees are derived from the tender mix.

Adds
  model         tenders (tender_summary_daily)
  relationships tenders -> stores, tenders -> date_dim
  metrics       tender_amount, total_card_processing_fees, cashless_share_pct
  glossary      Tender, Interchange
  instructions  metric rows, model reference, business-context note
Updates        store_pnl model description/guidance (card fees now derived)

Usage:  python scripts/pos_perf/wobby_add_tender_models.py [--put]
Fresh GET first; rate limit 2 req / 5 s; dimension-less-model guard applied.
"""

import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wobby_fix_defects import CFG, OUT, dim, filt, gen_id, meas  # noqa: E402

GRAINS = ["day", "week", "month", "quarter", "year"]


def build(env):
    models = {m["name"]: m for m in env["models"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next(d["id"] for d in models[model]["dimensions"] if d["name"] == dimension)

    T = "tenders"
    if T not in models:
        model = {
            "id": gen_id("model", T), "name": T,
            "description": ("How each store-day of real sales was paid: one row per store x day x tender type (about 1.7M rows over 229,594 store-days). "
                            "Tender types: Cash, Debit, Credit Visa, Credit Mastercard, Credit Amex, Mobile Wallet, Gift Card, Loyalty Points. "
                            "REAL: the store-day totals, the Loyalty Points tender (ledger REDEEM events at 1,000 points per CAD) and the Gift Card tender in "
                            "aggregate (equals lifetime gift card redemptions to the cent). MODELED and anchored: the split across the six payment tenders, "
                            "shifting cashless after 2020-03 (cash 22 to 10 pct, mobile 6 to 15 pct). processing_fee: Debit 0.06 CAD per transaction, "
                            "Visa/MC 1.6 pct, Amex 2.4 pct, Mobile 1.8 pct."),
            "agent_guidance": ("Amounts per store-day sum to that day's Regular Sale total, so tender share = SUM(amount for the tender) / SUM(amount overall) -- "
                               "never average per-row percentages. The cashless shift at 2020-03 is the designed pandemic story. processing_fee feeds "
                               "store_pnl.card_processing_fees (network effective rate about 1.0-1.2 pct of sales). est_transactions is an estimate from the "
                               "amount split, not a POS count. Join store_number to stores, sale_date to date_dim."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "tender_summary_daily"]},
            "dimensions": [
                dim(T, "store_number", "storenumber", "number", "Store number, joins stores"),
                dim(T, "province", "province", "enum", "Store province"),
                dim(T, "region", "region", "enum", "Store region"),
                dim(T, "sale_date", "sale_date", "date", "Trading day, joins date_dim", grains=GRAINS),
                dim(T, "year_month", "yyyymm", "number", "Calendar month as yyyymm"),
                dim(T, "is_weekend", "is_weekend", "enum", "Y on weekends"),
                dim(T, "pandemic_period", "pandemic_period", "enum", "Pre-pandemic or Pandemic"),
                dim(T, "tender_type", "tender_type", "enum", "Cash, Debit, Credit Visa, Credit Mastercard, Credit Amex, Mobile Wallet, Gift Card, Loyalty Points"),
                dim(T, "tender_group", "tender_group", "enum", "Cash, Card, Stored Value"),
                dim(T, "fee_pct", "fee_pct", "number", "Ad valorem fee rate for the tender"),
            ],
            "measures": [
                meas(T, "tender_rows", "COUNT(*)", "Store-day-tender rows", "rows", 0),
                meas(T, "tender_amount", "SUM(amount)", "Amount settled through the tender", "CAD", 2),
                meas(T, "est_transactions", "SUM(est_transactions)", "Estimated transactions on the tender", "transactions", 0),
                meas(T, "total_processing_fees", "SUM(processing_fee)", "Card processing fees on the tender mix", "CAD", 2),
                meas(T, "cash_amount", "SUM(CASE WHEN tender_type = 'Cash' THEN amount ELSE 0 END)", "Cash settled", "CAD", 2),
                meas(T, "cashless_amount", "SUM(CASE WHEN tender_type <> 'Cash' THEN amount ELSE 0 END)", "Non-cash settled", "CAD", 2),
                meas(T, "cashless_share_pct", "SUM(CASE WHEN tender_type <> 'Cash' THEN amount ELSE 0 END) / NULLIF(SUM(amount), 0) * 100", "Non-cash share of settled amount", "%", 2),
                meas(T, "effective_fee_rate_pct", "SUM(processing_fee) / NULLIF(SUM(amount), 0) * 100", "Processing fees as percent of settled amount", "%", 3),
            ],
            "filters": [
                filt(T, "cards_only", "tender_group = 'Card'", "Card tenders only"),
                filt(T, "cash_only", "tender_type = 'Cash'", "Cash only"),
                filt(T, "stored_value_only", "tender_group = 'Stored Value'", "Gift cards and loyalty points"),
            ],
        }
        env["models"].append(model)
        models[T] = model
        access["models"].append({"name": T})
        for name, desc, to_model, fk, tk in [
            ("tenders_to_store", "Each tender row belongs to one store", "stores", "store_number", "storenumber"),
            ("tenders_to_date", "Tender day on the calendar", "date_dim", "sale_date", "calendar_date"),
        ]:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc, "from_model": T,
                                         "from_key": key(T, fk), "to_model": to_model, "to_key": key(to_model, tk),
                                         "type": "many_to_one", "join_type": "left"})
        changes.append("model tenders + 2 relationships")

    # metrics
    existing = {m["name"] for m in env["metrics"]}
    gb = [{"model": T, "dimension": d} for d in ("tender_type", "tender_group", "region", "province", "pandemic_period", "is_weekend")] + \
         [{"model": "stores", "dimension": "store_format"}, {"model": "stores", "dimension": "storename"}]
    new_metrics = []
    for name, expr, unit, prec, desc, guide in [
        ("tender_amount", f"{T}.tender_amount", "CAD", 2,
         "Amount settled by tender type. Group by tender_type for the payment mix; per store-day the tenders sum to that day's net sales.",
         "Share of a tender = its tender_amount / overall tender_amount, never an average of percentages. The pandemic shifts the mix: cash roughly 22 to 10 percent, mobile 6 to 15 percent from 2020-03.\n"),
        ("total_card_processing_fees", f"{T}.total_processing_fees", "CAD", 2,
         "Card processing fees from the tender mix: Debit 0.06 CAD per transaction, Visa/MC 1.6 percent, Amex 2.4 percent, Mobile Wallet 1.8 percent.",
         "This is the source of store_pnl.card_processing_fees. effective_fee_rate_pct on the tenders model gives fees as a percent of settled amount (network about 1.0-1.2 percent, higher in the pandemic as the mix goes cashless).\n"),
        ("cashless_share_pct", f"{T}.cashless_share_pct", "%", 2,
         "Non-cash share of settled sales. The cashless shift is the designed pandemic story: it jumps at 2020-03.",
         "Compare pre-pandemic vs pandemic, by region or store format. Cash share = 100 minus this.\n"),
    ]:
        if name not in existing:
            new_metrics.append({"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
                                "expression": expr, "anchor_model": T, "unit": unit, "precision": prec,
                                "time_dimension": {"model": T, "dimension": "sale_date"}, "time_grains": GRAINS,
                                "group_by_dimensions": gb, "filters": []})
    for mt in new_metrics:
        env["metrics"].append(mt)
        access["metrics"].append(mt["name"])
    changes.append(f"{len(new_metrics)} tender metrics")

    # glossary
    terms = {g["term"] for g in env["glossary"]}
    for term, definition, syn in [
        ("Tender", "The payment method that settled a sale: Cash, Debit, Credit Visa, Credit Mastercard, Credit Amex, Mobile Wallet, Gift Card or Loyalty Points. tender_summary_daily holds the settled amount per store per day per tender.", ["payment method", "payment type", "tender type"]),
        ("Interchange", "The per-transaction cost of accepting card payments, modeled as Debit 0.06 CAD per transaction, Visa and Mastercard 1.6 percent, Amex 2.4 percent, Mobile Wallet 1.8 percent. Feeds card_processing_fees in the store P&L.", ["card fees", "processing fees", "merchant fees"]),
    ]:
        if term not in terms:
            env["glossary"].append({"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": syn, "tags": ["finance"], "mappings": []})
    changes.append("2 glossary terms")

    # store_pnl guidance update: card fees are now derived
    sp = models.get("store_pnl")
    if sp and "derived from the tender mix" not in (sp.get("description") or ""):
        sp["description"] = sp["description"].replace("card processing fees and other opex are modeled and anchored",
                                                      "other opex is modeled and anchored; card processing fees are derived from the tender mix in tenders")
        sp["description"] = sp["description"].replace("occupancy (sqft x rate by format and province), utilities (sqft, scaled by the real monthly temperature), delivery partner commission, card processing fees, other opex.",
                                                      "occupancy (sqft x rate by format and province), utilities (sqft, scaled by the real monthly temperature), delivery partner commission, other opex. Card processing fees are derived from the tender mix in tenders.")
        for ms in sp["measures"]:
            if ms["name"] == "total_card_processing_fees":
                ms["description"] = "Card processing fees derived from the tender mix (see tenders model)"
        changes.append("store_pnl guidance: card fees now derived")

    # instructions
    ins = analyst["instructions"]
    row = "| `gl_variance_vs_original` | Actual - Original budget by account; positive always favourable |"
    if row in ins and "`tender_amount`" not in ins:
        ins = ins.replace(row, row + "\n| `tender_amount` | Amount settled by tender type (payment mix) |\n"
                          "| `total_card_processing_fees` | Card fees from the tender mix (source of the P&L line) |\n"
                          "| `cashless_share_pct` | Non-cash share of sales — jumps at 2020-03 |")
        changes.append("tender metric reference")
    mref = "**gl / accounts:**"
    if mref in ins and "**tenders:**" not in ins:
        ins = ins.replace(mref, "**tenders:**\n- Payment mix per store-day (1.7M rows): Cash, Debit, Visa, Mastercard, Amex, Mobile Wallet, Gift Card, Loyalty Points. Per store-day the tenders sum to net sales\n"
                          "- Loyalty Points tender is real (ledger redemptions at 1,000 points per CAD); Gift Card ties to lifetime redemptions; the payment split is modeled with the cashless shift at 2020-03\n\n" + mref)
        changes.append("tenders model reference")
    n = len(env["metrics"])
    ins = re.sub(r"All \d+ metrics available to you", f"All {n} metrics available to you", ins)
    analyst["instructions"] = ins

    # dimension-less model guard (PUT validator)
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
    (OUT / "wobby_env_before_tenders.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_tenders_body.json"
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
    (OUT / "wobby_env_after_tenders.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    names = {m["name"] for m in after["models"]}
    mets = {m["name"] for m in after["metrics"]}
    rels = {r["name"] for r in after["relationships"]}
    print("verify: tenders", "tenders" in names,
          "| rels", all(x in rels for x in ("tenders_to_store", "tenders_to_date")),
          "| metrics", all(x in mets for x in ("tender_amount", "total_card_processing_fees", "cashless_share_pct")),
          "| counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
