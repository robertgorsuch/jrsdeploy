"""wobby_add_gl_models.py -- register chart_of_accounts and gl_monthly in the
Wobby POS Sales Analyst semantic layer.

Adds
  models        accounts (chart_of_accounts), gl (gl_monthly)
  relationships gl -> accounts, gl -> stores, gl -> franchisees
  metrics       gl_amount, gl_budget_original, gl_variance_vs_original
  glossary      Chart of Accounts, Favourable Variance
  instructions  model reference, metric rows, the signed-amount convention

Usage:  python scripts/pos_perf/wobby_add_gl_models.py [--put]
Starts from a fresh environment GET so concurrent edits are preserved.
Rate limit 2 requests per 5 seconds: one GET, one PUT, one GET.
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

GRAINS = ["month", "quarter", "year"]


def build(env):
    models = {m["name"]: m for m in env["models"]}
    analyst = env["ai_analysts"][0]
    access = analyst["semantic_layer_access"]
    changes = []

    def key(model, dimension):
        return next(d["id"] for d in models[model]["dimensions"] if d["name"] == dimension)

    A, G = "accounts", "gl"
    if A not in models:
        model = {
            "id": gen_id("model", A), "name": A,
            "description": "Chart of accounts: the 13 P&L accounts behind gl_monthly, with account group (Revenue, COGS, Labour, Occupancy, Store Opex, Franchise Fees), normal balance, a basis note saying whether the line is real or modeled, and a sort order for rendering statements.",
            "agent_guidance": "Dimension table. Join gl.account_code to accounts.account_code. Render P&L statements ordered by sort_order. basis says which lines are real (sales, COGS, shrink, fees, labour wages) vs modeled (occupancy, utilities, card fees, other opex).",
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "chart_of_accounts"]},
            "dimensions": [
                dim(A, "account_code", "account_code", "string", "Account code, e.g. 4000", pk=True),
                dim(A, "account_name", "account_name", "string", "Account name"),
                dim(A, "account_group", "account_group", "enum", "Revenue, COGS, Labour, Occupancy, Store Opex, Franchise Fees"),
                dim(A, "statement", "statement", "enum", "P&L (balance sheet accounts arrive with the working-capital tables)"),
                dim(A, "normal_balance", "normal_balance", "enum", "Credit or Debit"),
                dim(A, "basis", "basis", "string", "Real, Modeled, or a mixed note"),
                dim(A, "sort_order", "sort_order", "number", "Statement rendering order"),
            ],
            "measures": [meas(A, "account_count", "COUNT(*)", "Number of accounts", "accounts", 0)],
            "filters": [],
        }
        env["models"].append(model)
        models[A] = model
        access["models"].append({"name": A})
        changes.append("model accounts")

    if G not in models:
        model = {
            "id": gen_id("model", G), "name": G,
            "description": ("Account-level P&L ledger: one row per store x month x account (102,583 rows, 13 accounts x 7,891 store-months), the long form of "
                            "store_pnl and store_budget. Amounts are SIGNED (revenue positive, costs negative) so any sum of rows is a profit figure and "
                            "variance vs budget is favourable whenever it is positive. budget_original is the Original plan for every month; budget_reforecast "
                            "is the Q2 2020 re-plan (NULL before 2020-04). Sales Returns (4010) carries no budget."),
            "agent_guidance": ("THE model for 'show me the P&L' questions: group by account_name (order by accounts.sort_order) or account_group, SUM(amount). "
                               "Because amounts are signed, SUM over all accounts = store contribution (plus sales returns) -- never flip signs or take ABS. "
                               "variance_vs_original = amount - budget_original: positive is ALWAYS favourable (more revenue or less cost). "
                               "Subtotals: Revenue + COGS groups = gross margin; everything except Franchise Fees = four-wall EBITDA. "
                               "Filter trading_status = 'Trading' for rankings. Join account_code to accounts, store_number to stores, franchisee_id to franchisees. "
                               "For single-line totals in original sign conventions (costs positive) use store_pnl instead."),
            "source": {"data_source_name": "POS Data", "type": "TABLE", "path": ["robert.gorsuch", "gl_monthly"]},
            "dimensions": [
                dim(G, "store_number", "storenumber", "number", "Store number, joins stores"),
                dim(G, "store_name", "storename", "string", "Store name"),
                dim(G, "franchisee_id", "franchisee_id", "number", "Franchisee, joins franchisees"),
                dim(G, "province", "province", "enum", "Store province"),
                dim(G, "region", "region", "enum", "Store region"),
                dim(G, "store_format", "store_format", "enum", "Store format"),
                dim(G, "year_month", "yyyymm", "number", "Calendar month as yyyymm"),
                dim(G, "month_date", "month_start", "date", "First day of the month, for time grains", grains=GRAINS),
                dim(G, "year", "yr", "number", "Calendar year"),
                dim(G, "month", "mo", "number", "Calendar month 1-12"),
                dim(G, "pandemic_period", "pandemic_period", "enum", "Pre-pandemic or Pandemic"),
                dim(G, "trading_status", "trading_status", "enum", "Trading, Closed, No sales"),
                dim(G, "account_code", "account_code", "string", "Account code, joins accounts"),
                dim(G, "account_name", "account_name", "string", "Account name (denormalised)"),
                dim(G, "account_group", "account_group", "enum", "Revenue, COGS, Labour, Occupancy, Store Opex, Franchise Fees"),
                dim(G, "basis", "basis", "string", "Real or modeled line"),
                dim(G, "favourable_vs_original", "favourable_vs_original", "enum", "Y when the line beat the Original budget"),
            ],
            "measures": [
                meas(G, "gl_rows", "COUNT(*)", "Ledger rows", "rows", 0),
                meas(G, "gl_amount", "SUM(amount)", "Signed amount: revenue positive, costs negative -- any sum is a profit figure", "CAD", 2),
                meas(G, "gl_budget_original", "SUM(budget_original)", "Signed Original budget", "CAD", 2),
                meas(G, "gl_budget_reforecast", "SUM(budget_reforecast)", "Signed Reforecast Q2 2020 budget (2020-04 onward)", "CAD", 2),
                meas(G, "gl_variance_vs_original", "SUM(variance_vs_original)", "Amount minus Original budget: positive is favourable", "CAD", 2),
                meas(G, "gl_variance_vs_reforecast", "SUM(variance_vs_reforecast)", "Amount minus Reforecast budget: positive is favourable", "CAD", 2),
                meas(G, "favourable_lines", "SUM(CASE WHEN favourable_vs_original = 'Y' THEN 1 ELSE 0 END)", "Lines at or better than Original budget", "rows", 0),
                meas(G, "unfavourable_lines", "SUM(CASE WHEN favourable_vs_original = 'N' THEN 1 ELSE 0 END)", "Lines worse than Original budget", "rows", 0),
            ],
            "filters": [
                filt(G, "trading_only", "trading_status = 'Trading'", "Months in which the store traded"),
                filt(G, "revenue_lines", "account_group = 'Revenue'", "Revenue accounts only"),
                filt(G, "opex_lines", "account_group IN ('Labour', 'Occupancy', 'Store Opex')", "Store operating cost accounts"),
                filt(G, "franchise_fee_lines", "account_group = 'Franchise Fees'", "Royalty and marketing fee accounts"),
            ],
        }
        env["models"].append(model)
        models[G] = model
        access["models"].append({"name": G})
        for name, desc, to_model, fk, tk in [
            ("gl_to_account", "Each ledger row posts to one account", A, "account_code", "account_code"),
            ("gl_to_store", "Each ledger row belongs to one store", "stores", "store_number", "storenumber"),
            ("gl_to_franchisee", "Each ledger row belongs to the store owner", "franchisees", "franchisee_id", "franchisee_id"),
        ]:
            env["relationships"].append({"id": gen_id("rel", name), "name": name, "description": desc, "from_model": G,
                                         "from_key": key(G, fk), "to_model": to_model, "to_key": key(to_model, tk),
                                         "type": "many_to_one", "join_type": "left"})
        changes.append("model gl + 3 relationships")

    # metrics
    existing = {m["name"] for m in env["metrics"]}
    gb = [{"model": G, "dimension": d} for d in ("account_name", "account_group", "region", "province", "store_format",
                                                  "store_name", "pandemic_period", "basis", "trading_status")]
    trading = [{"name": "trading_only", "expression": "trading_status = 'Trading'", "apply_default": False}]
    new_metrics = []
    for name, expr, desc, guide in [
        ("gl_amount", f"{G}.gl_amount",
         "Signed P&L amount by account (revenue positive, costs negative). Group by account_name for a full P&L statement, by account_group for subtotals.",
         "The P&L statement metric. SUM over all accounts = store contribution (plus sales returns). Order accounts by accounts.sort_order when rendering. Never flip signs.\n"),
        ("gl_budget_original", f"{G}.gl_budget_original",
         "Signed Original-plan budget by account. Same sign convention as gl_amount.",
         "Original covers every month; the 2020 plan was set in late 2019 and is blind to the pandemic. Sales Returns has no budget.\n"),
        ("gl_variance_vs_original", f"{G}.gl_variance_vs_original",
         "Actual minus Original budget by account. Positive is ALWAYS favourable (more revenue or less cost).",
         "Because amounts are signed, no per-account sign logic is needed: rank accounts by this metric to find the biggest favourable and unfavourable lines. "
         "2020 headline: sales +47.9M favourable vs the blind Original plan; COGS, card fees and royalty unfavourable because volume beat plan. "
         "gl_variance_vs_reforecast on the gl model compares to the April 2020 re-plan instead.\n"),
    ]:
        if name not in existing:
            new_metrics.append({"id": gen_id("metric", name), "name": name, "description": desc, "agent_guidance": guide,
                                "expression": expr, "anchor_model": G, "unit": "CAD", "precision": 2,
                                "time_dimension": {"model": G, "dimension": "month_date"}, "time_grains": GRAINS,
                                "group_by_dimensions": gb, "filters": trading})
    for mt in new_metrics:
        env["metrics"].append(mt)
        access["metrics"].append(mt["name"])
    changes.append(f"{len(new_metrics)} gl metrics")

    # glossary
    terms = {g["term"] for g in env["glossary"]}
    for term, definition, syn in [
        ("Chart of Accounts", "The 13 P&L accounts used by the gl model: Revenue (Net Sales, Sales Returns, Promotion Subsidy Income), COGS, Labour (loaded), Occupancy, Utilities, Shrinkage, Delivery Partner Cost, Card Processing Fees, Other Operating Expense, Royalty Fee, Marketing Fee. Amounts are signed: revenue positive, costs negative.", ["accounts", "account codes", "COA"]),
        ("Favourable Variance", "Actual minus budget on signed amounts. Positive is always favourable: revenue above plan or cost below plan. gl.favourable_vs_original flags each ledger line.", ["favorable variance", "budget variance"]),
    ]:
        if term not in terms:
            env["glossary"].append({"id": gen_id("term", term), "term": term, "definition": definition, "synonyms": syn, "tags": ["finance"], "mappings": []})
    changes.append("2 glossary terms")

    # instructions
    ins = analyst["instructions"]
    row = "| `contribution_variance_vs_budget` | Actual - budget contribution |"
    if row in ins and "`gl_amount`" not in ins:
        ins = ins.replace(row, row + "\n| `gl_amount` | Signed P&L by account (revenue +, costs -) — group by account for a statement |\n"
                          "| `gl_budget_original` | Signed Original budget by account |\n"
                          "| `gl_variance_vs_original` | Actual - Original budget by account; positive always favourable |")
        changes.append("gl metric reference")
    mref = "**store_pnl:**"
    if mref in ins and "**gl / accounts:**" not in ins:
        ins = ins.replace(mref, "**gl / accounts:**\n- Account-level P&L ledger (102,583 rows): store x month x account, SIGNED amounts (revenue +, costs -), so any sum is a profit figure and positive variance is always favourable\n"
                          "- Use for 'show me the P&L' (group by account_name, order by accounts.sort_order) and account-level budget variance. Sales Returns has no budget\n\n" + mref)
        changes.append("gl model reference")
    n = len(env["metrics"])
    ins = re.sub(r"All \d+ metrics available to you", f"All {n} metrics available to you", ins)
    analyst["instructions"] = ins

    # Round-trip guard: the PUT validator requires every model to have at least
    # one dimension, but the UI allows dimension-less single-row models (e.g.
    # dash_kpi). Give such models one constant label dimension so the sync
    # validates without changing their analytical design.
    for m in env["models"]:
        if not m.get("dimensions"):
            m["dimensions"] = [dim(m["name"], "period_label", "'Jan 2019 - Dec 2020'", "string",
                                   "Constant label for the single-row model (added so the environment sync validates; intentionally not an analytical dimension)")]
            changes.append(f"placeholder dimension on {m['name']} (had none; PUT validator requires one)")
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
    (OUT / "wobby_env_before_gl.json").write_text(json.dumps(env, ensure_ascii=False, indent=1), encoding="utf-8")
    body, changes = build(env)
    out = OUT / "wobby_env_gl_body.json"
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
    (OUT / "wobby_env_after_gl.json").write_text(json.dumps(after, ensure_ascii=False, indent=1), encoding="utf-8")
    names = {m["name"] for m in after["models"]}
    rels = {r["name"] for r in after["relationships"]}
    mets = {m["name"] for m in after["metrics"]}
    print("verify: gl", "gl" in names, "| accounts", "accounts" in names,
          "| rels", all(x in rels for x in ("gl_to_account", "gl_to_store", "gl_to_franchisee")),
          "| metrics", all(x in mets for x in ("gl_amount", "gl_variance_vs_original")),
          "| counts", len(after["models"]), len(after["relationships"]), len(after["metrics"]), len(after["glossary"]))


if __name__ == "__main__":
    sys.exit(main())
