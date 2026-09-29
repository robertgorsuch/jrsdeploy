"""wobby_add_ap_models.py -- register ap_invoices and franchise_fee_ledger in
the Wobby POS Sales Analyst semantic layer.

Adds
  models        payables (ap_invoices), franchise_fees (franchise_fee_ledger)
  relationships payables -> suppliers / stores / purchase_orders,
                franchise_fees -> franchisees / stores
  metrics       ap_outstanding, avg_days_to_pay, ap_pct_paid_on_time,
                early_pay_discounts_taken, franchise_fees_invoiced,
                franchise_fees_collected, ar_outstanding, ar_pct_paid_on_time
  glossary      DPO, AP Aging, AR Aging, Early-Payment Discount
  instructions  model references (metric table is UI-managed, left alone)

Usage:  python scripts/pos_perf/wobby_add_ap_models.py [--put]
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

GRAINS = ["day", "week", "month", "quarter", "year"]


def build(env):
    models = {m["name"]: m for m in env["models"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next((d["id"] for d in models[model]["dimensions"] if d["name"] == dimension), None)

    def rel(name, desc, frm, fk, to_model, tk):
        fkey, tkey = key(frm, fk), key(to_model, tk)
        if fkey and tkey:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc,
                                         "from_model": frm, "from_key": fkey, "to_model": to_model, "to_key": tkey,
                                         "type": "many_to_one", "join_type": "left"})
            return 1
        changes.append(f"SKIPPED relationship {name}: key not found ({frm}.{fk} -> {to_model}.{tk})")
        return 0

    P = "payables"
    if P not in models:
        model = {
            "id": gen_id("model", P), "name": P,
            "description": ("Accounts payable to suppliers: one invoice per purchase order (92,472 rows, 524.2M CAD). REAL: PO, supplier, store, amount, "
                            "invoice date (goods receipt = order date + the real lead time), payment terms (Net 30/45/60). Modeled and deterministic: payment "
                            "behaviour -- 10 pct early payers taking the early-payment discount (2 pct on Net 30, 1 pct otherwise), 70 pct on time, 20 pct "
                            "1-20 days late. Status and aging are as of 2020-12-31."),
            "agent_guidance": ("DPO = AVG(days_to_pay) on Paid invoices (network: 26 days on Net 30, 40 on Net 45, 53 on Net 60). About 80 pct paid on or "
                               "before due. balance is non-zero only for Open and Overdue invoices; aging_bucket buckets the unpaid ones (as of 2020-12-31 -- "
                               "the 29M Current balance is simply year-end invoices not yet due, not a problem). Join supplier_name to suppliers, store_number "
                               "to stores, po_number to purchase_orders."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "ap_invoices"]},
            "dimensions": [
                dim(P, "invoice_number", "invoice_number", "string", "Invoice id (INV- + PO number)", pk=True),
                dim(P, "po_number", "po_number", "string", "Purchase order, joins purchase_orders"),
                dim(P, "supplier_name", "supplier_name", "string", "Supplier, joins suppliers"),
                dim(P, "store_number", "storenumber", "number", "Store, joins stores"),
                dim(P, "province", "province", "enum", "Store province"),
                dim(P, "region", "region", "enum", "Store region"),
                dim(P, "invoice_date", "invoice_date", "date", "Goods receipt / invoice date", grains=GRAINS),
                dim(P, "due_date", "due_date", "date", "Invoice date plus payment terms"),
                dim(P, "paid_date", "paid_date", "date", "Payment date, NULL while unpaid"),
                dim(P, "payment_terms", "payment_terms", "enum", "Net 30, Net 45, Net 60"),
                dim(P, "status", "status", "enum", "Paid, Open (not yet due), Overdue -- as of 2020-12-31"),
                dim(P, "aging_bucket", "aging_bucket", "enum", "Paid, Current, 1-30 days, 31-60 days, 60+ days"),
                dim(P, "payer_profile", "payer_profile", "enum", "Early, On time, Late"),
            ],
            "measures": [
                meas(P, "invoice_count", "COUNT(*)", "Invoices", "invoices", 0),
                meas(P, "total_invoiced", "SUM(amount)", "Invoiced amount", "CAD", 2),
                meas(P, "total_paid", "SUM(amount_paid)", "Amount paid (net of discounts)", "CAD", 2),
                meas(P, "discounts_taken", "SUM(discount_taken)", "Early-payment discounts captured", "CAD", 2),
                meas(P, "ap_balance", "SUM(balance)", "Unpaid balance (Open + Overdue)", "CAD", 2),
                meas(P, "overdue_balance", "SUM(CASE WHEN status = 'Overdue' THEN balance ELSE 0 END)", "Past-due balance", "CAD", 2),
                meas(P, "avg_days_to_pay", "AVG(days_to_pay)", "Days payable outstanding on paid invoices", "days", 1),
                meas(P, "pct_paid_on_time", "SUM(CASE WHEN status = 'Paid' AND days_paid_late = 0 THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN status = 'Paid' THEN 1 ELSE 0 END), 0)", "Share of paid invoices settled by the due date", "%", 1),
                meas(P, "avg_days_overdue", "AVG(CASE WHEN status = 'Overdue' THEN days_overdue END)", "Average age past due of overdue invoices", "days", 1),
            ],
            "filters": [
                filt(P, "unpaid_only", "status <> 'Paid'", "Open and Overdue invoices"),
                filt(P, "overdue_only", "status = 'Overdue'", "Past-due invoices"),
                filt(P, "paid_only", "status = 'Paid'", "Settled invoices (use for DPO)"),
            ],
        }
        env["models"].append(model)
        models[P] = model
        access["models"].append({"name": P})
        n = rel("payables_to_supplier", "Each invoice is owed to one supplier", P, "supplier_name", "suppliers", "supplier_name")
        n += rel("payables_to_store", "Each invoice belongs to one store", P, "store_number", "stores", "storenumber")
        n += rel("payables_to_po", "Each invoice settles one purchase order", P, "po_number", "purchase_orders", "po_number")
        changes.append(f"model payables + {n} relationships")

    F = "franchise_fees"
    if F not in models:
        model = {
            "id": gen_id("model", F), "name": F,
            "description": ("Accounts receivable from franchisees: one fee invoice per store-month (7,706 rows, 47.97M CAD -- royalty at the real 4-6 pct rates "
                            "plus marketing fee at 1-2 pct, tying to store_pnl to the cent). Invoiced at month end, due 15 days later. Modeled and deterministic "
                            "payment behaviour: 80 pct on time, 16 pct 1-45 days late, 4 pct unpaid. Status and aging as of 2020-12-31."),
            "agent_guidance": ("The franchisor collections view. ar_outstanding = SUM(balance); the Current bucket is December fees not yet due (normal), the "
                               "60+ bucket is the real delinquency (about 1.27M CAD). Group by owner_name for a collections list. days_paid_late on Paid rows "
                               "measures payment discipline. Join franchisee_id to franchisees, store_number to stores. Fee amounts are the same real numbers "
                               "as store_pnl.royalty_fee and marketing_fee."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "franchise_fee_ledger"]},
            "dimensions": [
                dim(F, "invoice_number", "invoice_number", "string", "Fee invoice id (FF-store-month)", pk=True),
                dim(F, "store_number", "storenumber", "number", "Store, joins stores"),
                dim(F, "store_name", "storename", "string", "Store name"),
                dim(F, "franchisee_id", "franchisee_id", "number", "Franchisee, joins franchisees"),
                dim(F, "owner_name", "owner_name", "string", "Franchisee owner"),
                dim(F, "province", "province", "enum", "Store province"),
                dim(F, "region", "region", "enum", "Store region"),
                dim(F, "year_month", "yyyymm", "number", "Fee month as yyyymm"),
                dim(F, "month_date", "month_start", "date", "First day of the fee month", grains=["month", "quarter", "year"]),
                dim(F, "invoice_date", "invoice_date", "date", "Month-end invoice date"),
                dim(F, "due_date", "due_date", "date", "Invoice date plus 15 days"),
                dim(F, "paid_date", "paid_date", "date", "Payment date, NULL while unpaid"),
                dim(F, "status", "status", "enum", "Paid, Open, Overdue -- as of 2020-12-31"),
                dim(F, "aging_bucket", "aging_bucket", "enum", "Paid, Current, 1-30 days, 31-60 days, 60+ days"),
            ],
            "measures": [
                meas(F, "fee_invoices", "COUNT(*)", "Fee invoices", "invoices", 0),
                meas(F, "fees_invoiced", "SUM(total_invoiced)", "Royalty plus marketing fees invoiced", "CAD", 2),
                meas(F, "royalty_invoiced", "SUM(royalty_fee)", "Royalty fees invoiced", "CAD", 2),
                meas(F, "marketing_invoiced", "SUM(marketing_fee)", "Marketing fees invoiced", "CAD", 2),
                meas(F, "fees_collected", "SUM(amount_paid)", "Fees collected", "CAD", 2),
                meas(F, "ar_balance", "SUM(balance)", "Uncollected balance (Open + Overdue)", "CAD", 2),
                meas(F, "overdue_balance", "SUM(CASE WHEN status = 'Overdue' THEN balance ELSE 0 END)", "Past-due balance", "CAD", 2),
                meas(F, "pct_paid_on_time", "SUM(CASE WHEN status = 'Paid' AND days_paid_late = 0 THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN status = 'Paid' THEN 1 ELSE 0 END), 0)", "Share of paid fee invoices settled by the due date", "%", 1),
                meas(F, "avg_days_paid_late", "AVG(CASE WHEN days_paid_late > 0 THEN days_paid_late END)", "Average lateness of late payments", "days", 1),
                meas(F, "avg_days_overdue", "AVG(CASE WHEN status = 'Overdue' THEN days_overdue END)", "Average age past due of unpaid invoices", "days", 1),
            ],
            "filters": [
                filt(F, "unpaid_only", "status <> 'Paid'", "Open and Overdue fee invoices"),
                filt(F, "overdue_only", "status = 'Overdue'", "Past-due fee invoices (the collections list)"),
            ],
        }
        env["models"].append(model)
        models[F] = model
        access["models"].append({"name": F})
        n = rel("fees_to_franchisee", "Each fee invoice is owed by one franchisee", F, "franchisee_id", "franchisees", "franchisee_id")
        n += rel("fees_to_store", "Each fee invoice belongs to one store", F, "store_number", "stores", "storenumber")
        changes.append(f"model franchise_fees + {n} relationships")

    # metrics
    existing = {m["name"] for m in env["metrics"]}
    gb_p = [{"model": P, "dimension": d} for d in ("supplier_name", "payment_terms", "status", "aging_bucket", "payer_profile", "region", "province")]
    gb_f = [{"model": F, "dimension": d} for d in ("owner_name", "store_name", "status", "aging_bucket", "region", "province")]
    new_metrics = []
    for name, expr, anchor, unit, prec, tdim, gb, desc, guide in [
        ("ap_outstanding", f"{P}.ap_balance", P, "CAD", 2, "invoice_date", gb_p,
         "Unpaid supplier balance (Open + Overdue) as of 2020-12-31.",
         "Most of it is Current (year-end invoices not yet due, ~29M). overdue_balance on payables isolates the real past-due (~1.1M). Group by supplier_name or aging_bucket.\n"),
        ("avg_days_to_pay", f"{P}.avg_days_to_pay", P, "days", 1, "invoice_date", gb_p,
         "Days payable outstanding: average days from invoice (goods receipt) to payment, on paid invoices.",
         "Apply the paid_only filter. Network: about 26 days on Net 30, 40 on Net 45, 53 on Net 60; early payers average 7.5 days to capture discounts.\n"),
        ("ap_pct_paid_on_time", f"{P}.pct_paid_on_time", P, "%", 1, "invoice_date", gb_p,
         "Share of paid supplier invoices settled on or before the due date (about 80 percent network-wide).",
         "Group by supplier_name or store to find late-paying stores.\n"),
        ("early_pay_discounts_taken", f"{P}.discounts_taken", P, "CAD", 2, "invoice_date", gb_p,
         "Early-payment discounts captured (2 percent on Net 30, 1 percent otherwise, taken by the 10 percent early-payer profile).",
         "Lifetime about 794K CAD on 9.2K invoices. The counterfactual (discounts NOT taken by on-time and late payers) is a working-capital talking point.\n"),
        ("franchise_fees_invoiced", f"{F}.fees_invoiced", F, "CAD", 2, "month_date", gb_f,
         "Royalty plus marketing fees invoiced to franchisees by month (the same real amounts as the store P&L).",
         "royalty_invoiced and marketing_invoiced on franchise_fees split it. This is the franchisor revenue view of the fees that are costs in store_pnl.\n"),
        ("franchise_fees_collected", f"{F}.fees_collected", F, "CAD", 2, "month_date", gb_f,
         "Fees actually collected as of 2020-12-31.",
         "fees_invoiced minus fees_collected = ar_outstanding. Collection rate is about 89 percent with the tail being December invoices not yet due.\n"),
        ("ar_outstanding", f"{F}.ar_balance", F, "CAD", 2, "month_date", gb_f,
         "Uncollected franchise fees (Open + Overdue) as of 2020-12-31.",
         "Current bucket (3.8M) is December fees not yet due; the 60+ bucket (1.27M) is the true delinquency. Group by owner_name and aging_bucket for the collections list.\n"),
        ("ar_pct_paid_on_time", f"{F}.pct_paid_on_time", F, "%", 1, "month_date", gb_f,
         "Share of paid fee invoices settled within the 15-day term (about 83 percent).",
         "Group by owner_name to rank franchisee payment discipline.\n"),
    ]:
        if name not in existing:
            new_metrics.append({"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
                                "expression": expr, "anchor_model": anchor, "unit": unit, "precision": prec,
                                "time_dimension": {"model": anchor, "dimension": tdim},
                                "time_grains": GRAINS if anchor == P else ["month", "quarter", "year"],
                                "group_by_dimensions": gb, "filters": []})
    for mt in new_metrics:
        env["metrics"].append(mt)
        access["metrics"].append(mt["name"])
    changes.append(f"{len(new_metrics)} AP/AR metrics")

    # glossary
    terms = {g["term"] for g in env["glossary"]}
    for term, definition, syn in [
        ("DPO", "Days Payable Outstanding: average days from supplier invoice (goods receipt) to payment. avg_days_to_pay on the payables model; about 26/40/53 days on Net 30/45/60 terms.", ["days payable outstanding", "days to pay"]),
        ("AP Aging", "Unpaid supplier invoices bucketed by how far past due they are as of 2020-12-31: Current (not yet due), 1-30, 31-60, 60+ days. payables.aging_bucket.", ["payables aging", "accounts payable aging"]),
        ("AR Aging", "Uncollected franchise fee invoices bucketed by how far past due as of 2020-12-31. The Current bucket is December fees inside the 15-day term; 60+ days is true delinquency. franchise_fees.aging_bucket.", ["receivables aging", "collections aging"]),
        ("Early-Payment Discount", "Discount for settling a supplier invoice early: 2 percent on Net 30 terms, 1 percent on Net 45/60, captured by the early-payer profile (about 10 percent of invoices, 794K CAD lifetime).", ["prompt payment discount", "2/10 net 30"]),
    ]:
        if term not in terms:
            env["glossary"].append({"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": syn, "tags": ["finance"], "mappings": []})
    changes.append("4 glossary terms")

    # instructions: model references only (the metric table is UI-managed now)
    ins = analyst["instructions"]
    mref = "**tenders:**"
    if mref in ins and "**payables / franchise_fees:**" not in ins:
        ins = ins.replace(mref, "**payables / franchise_fees:**\n- payables: one supplier invoice per PO (92,472; amount real, payment behaviour modeled). DPO, on-time rate, aging, early-pay discounts. Status is as of 2020-12-31: the big Current balance is year-end invoices not yet due\n"
                          "- franchise_fees: one fee invoice per store-month (7,706; amounts tie to store_pnl to the cent). AR aging and the collections list by owner_name; 60+ days is the true delinquency\n\n" + mref)
        changes.append("model references in instructions")
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
    (OUT / "wobby_env_before_ap.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_ap_body.json"
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
    (OUT / "wobby_env_after_ap.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    names = {m["name"] for m in after["models"]}
    mets = {m["name"] for m in after["metrics"]}
    print("verify: payables", "payables" in names, "| franchise_fees", "franchise_fees" in names,
          "| metrics", all(x in mets for x in ("ap_outstanding", "avg_days_to_pay", "ar_outstanding", "franchise_fees_invoiced")),
          "| counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
