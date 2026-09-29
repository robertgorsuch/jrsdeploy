"""basket_reco_model.py -- item-item market-basket recommender over the POS
line detail, evaluated out-of-time against a popularity baseline, then loaded
as plu_recommendations in the pos_data warehouse.

THE COMPARISON THAT MATTERS
  Recommenders are easy to build and easy to fool yourself about. The honest
  test is whether the model beats simply recommending the most popular items to
  everyone -- in grocery, popularity is a very strong baseline, because most
  baskets contain staples. Every metric below is reported beside that baseline,
  and if the model does not beat it the run says so plainly.

SCORERS COMPARED
  popularity  rank by training basket count, identical for every basket
  cosine      c_ab / sqrt(c_a * c_b) -- co-occurrence normalised by how common
              each item is, so a staple that appears with everything does not
              dominate
  lift        P(a,b) / (P(a) * P(b)) -- how much more often the pair occurs
              than independence predicts. Sharper than cosine on genuinely
              associated pairs, noisier on rare ones, so pairs below
              MIN_PAIR_SUPPORT are dropped

EVALUATION
  Leave-one-out on HELD-OUT baskets. For each test basket one item is hidden at
  random, the rest are used to score all candidates, and we ask where the hidden
  item ranked. hit@k is the share of baskets where it made the top k; MRR is the
  mean reciprocal rank, which rewards getting it near the top rather than merely
  inside the window. Items already in the visible basket are excluded from the
  ranking -- recommending something already in the cart is not a recommendation.

  The split is out of time: co-occurrence comes only from baskets before
  2020-11-01, and every evaluated basket is later than that.

Usage
  python scripts/pos_perf/basket_reco_model.py
  python scripts/pos_perf/basket_reco_model.py --no-load --no-mlflow

Requires: rec_pair_counts, rec_item_counts, rec_basket_item, rec_test_basket
          (see build_reco_pairs.sql), products.
Outputs
  warehouse table plu_recommendations
  MLflow experiment pos-basket-reco
  scripts/pos_perf/basket_reco_metrics.json / _report.md
"""

import argparse
import json
import sys
import time
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pos_ml_common import connect, f, q, recreate_and_load, safe_track  # noqa: E402

HERE = Path(__file__).resolve().parent
REPORT = HERE / "basket_reco_report.md"
METRICS = HERE / "basket_reco_metrics.json"

MODEL_VERSION = "basket-reco-v1"
EXPERIMENT = "pos-basket-reco"

TOP_N = 10                 # recommendations stored per PLU
MIN_PAIR_SUPPORT = 30      # baskets a pair needs before lift is trusted
EVAL_BASKETS = 300000      # sampled held-out baskets
BATCH = 20000
KS = (1, 5, 10)

DDL = """
CREATE TABLE plu_recommendations (
    plu               VARCHAR(24) NOT NULL,
    product_name      VARCHAR(200),
    category          VARCHAR(60),
    rank              INTEGER     NOT NULL,
    rec_plu           VARCHAR(24) NOT NULL,
    rec_product_name  VARCHAR(200),
    rec_category      VARCHAR(60),
    cosine            DECIMAL(12,6),
    lift              DECIMAL(12,4),
    pair_baskets      INTEGER,
    support_pct       DECIMAL(10,6),
    same_category     VARCHAR(4),
    model_version     VARCHAR(40)
)
"""


def s_(v, n):
    return None if v is None else str(v)[:n]


def build_matrices(pairs, items):
    idx = {p: i for i, p in enumerate(items.plu)}
    n = len(items)
    cnt = items.baskets.values.astype(np.float64)
    total = float(items.baskets.sum())

    co = np.zeros((n, n), dtype=np.float64)
    a = pairs.plu_a.map(idx).values
    b = pairs.plu_b.map(idx).values
    v = pairs.pair_baskets.values.astype(np.float64)
    ok = ~(pd.isna(a) | pd.isna(b))
    a, b, v = a[ok].astype(int), b[ok].astype(int), v[ok]
    co[a, b] = v
    co[b, a] = v

    denom = np.sqrt(np.outer(cnt, cnt))
    cosine = np.divide(co, denom, out=np.zeros_like(co), where=denom > 0)

    # lift = P(a,b) / (P(a)P(b)); only trusted above MIN_PAIR_SUPPORT
    exp = np.outer(cnt, cnt) / max(total, 1.0)
    lift = np.divide(co, exp, out=np.zeros_like(co), where=exp > 0)
    lift[co < MIN_PAIR_SUPPORT] = 0.0

    np.fill_diagonal(cosine, 0.0)
    np.fill_diagonal(lift, 0.0)
    return idx, cnt, co, cosine, lift


def evaluate(baskets, idx, sims, pop, ks=KS, seed=0):
    """Leave-one-out hit@k and MRR per scorer. baskets is a list of index lists."""
    rng = np.random.default_rng(seed)
    n_items = len(pop)
    res = {name: {f"hit@{k}": 0 for k in ks} | {"mrr": 0.0, "n": 0} for name in sims}
    res["popularity"] = {f"hit@{k}": 0 for k in ks} | {"mrr": 0.0, "n": 0}
    pop_rank_order = np.argsort(-pop)

    for start in range(0, len(baskets), BATCH):
        chunk = baskets[start:start + BATCH]
        m = len(chunk)
        vis = np.zeros((m, n_items), dtype=np.float32)
        target = np.empty(m, dtype=np.int64)
        for r, items in enumerate(chunk):
            hide = rng.integers(len(items))
            target[r] = items[hide]
            for j, it in enumerate(items):
                if j != hide:
                    vis[r, it] = 1.0

        for name, S in sims.items():
            sc = vis @ S.astype(np.float32)
            sc[vis > 0] = -np.inf                      # never re-recommend what is visible
            order = np.argsort(-sc, axis=1)
            rank = (order == target[:, None]).argmax(axis=1) + 1
            for k in ks:
                res[name][f"hit@{k}"] += int((rank <= k).sum())
            res[name]["mrr"] += float((1.0 / rank).sum())
            res[name]["n"] += m

        # popularity: identical ranking for everyone, minus what is visible
        for r in range(m):
            seen = vis[r] > 0
            order = pop_rank_order[~seen[pop_rank_order]]
            pos = np.nonzero(order == target[r])[0]
            rank = int(pos[0]) + 1 if len(pos) else n_items
            for k in ks:
                res["popularity"][f"hit@{k}"] += int(rank <= k)
            res["popularity"]["mrr"] += 1.0 / rank
        res["popularity"]["n"] += m

    out = {}
    for name, d in res.items():
        n = max(d["n"], 1)
        out[name] = {f"hit@{k}": d[f"hit@{k}"] / n for k in ks}
        out[name]["mrr"] = d["mrr"] / n
        out[name]["n"] = d["n"]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print("market-basket recommender", flush=True)

    cn = connect()
    items = q(cn, "SELECT plu, baskets FROM rec_item_counts ORDER BY plu")
    pairs = q(cn, "SELECT plu_a, plu_b, pair_baskets FROM rec_pair_counts")
    prod = q(cn, "SELECT plu, product_name, category FROM products")
    prod["category"] = prod["category"].replace({"None": "Uncategorised", "": "Uncategorised"})
    items["baskets"] = items["baskets"].astype(float)
    pairs["pair_baskets"] = pairs["pair_baskets"].astype(float)
    print(f"  {len(items)} items, {len(pairs):,} pairs", flush=True)

    idx, cnt, co, cosine, lift = build_matrices(pairs, items)
    inv = {v: k for k, v in idx.items()}

    print("  pulling held-out baskets ...", flush=True)
    tb = q(cn, """SELECT b.basket, b.plu
                  FROM rec_basket_item b
                  JOIN rec_test_basket t ON t.basket = b.basket
                  WHERE b.sale_date >= DATE '2020-11-01' AND MOD(b.jdn, 3) = 0""")
    tb["ix"] = tb.plu.map(idx)
    tb = tb[tb.ix.notna()]
    grouped = tb.groupby("basket")["ix"].apply(lambda s: [int(x) for x in s])
    baskets = [b for b in grouped if len(b) >= 2][:EVAL_BASKETS]
    print(f"  evaluating on {len(baskets):,} held-out multi-item baskets", flush=True)

    ev = evaluate(baskets, idx, {"cosine": cosine, "lift": lift}, cnt)
    best = max(("cosine", "lift"), key=lambda k: ev[k]["mrr"])
    beats = ev[best]["mrr"] > ev["popularity"]["mrr"]
    for name in ("popularity", "cosine", "lift"):
        d = ev[name]
        print(f"  [{name:10}] hit@1 {d['hit@1']:.4f}  hit@5 {d['hit@5']:.4f}  "
              f"hit@10 {d['hit@10']:.4f}  MRR {d['mrr']:.4f}", flush=True)
    print(f"  best scorer: {best}; beats popularity: {beats}", flush=True)

    # ---- top-N table ------------------------------------------------------
    S = cosine if best == "cosine" else lift
    rows = []
    total = float(items.baskets.sum())
    for i in range(len(items)):
        order = np.argsort(-S[i])[:TOP_N]
        for r, j in enumerate(order, 1):
            if S[i, j] <= 0:
                continue
            rows.append({"plu": inv[i], "rank": r, "rec_plu": inv[j],
                         "cosine": cosine[i, j], "lift": lift[i, j],
                         "pair_baskets": co[i, j],
                         "support_pct": co[i, j] / total * 100.0})
    rec = pd.DataFrame(rows)
    rec = (rec.merge(prod, on="plu", how="left")
              .merge(prod.rename(columns={"plu": "rec_plu", "product_name": "rec_product_name",
                                          "category": "rec_category"}), on="rec_plu", how="left"))
    rec["same_category"] = np.where(rec.category == rec.rec_category, "Y", "N")
    print(f"  {len(rec):,} recommendations across {rec.plu.nunique()} PLUs "
          f"({rec.same_category.eq('Y').mean():.1%} within the same category)", flush=True)

    metrics = {
        "model_version": MODEL_VERSION, "run_date": str(date.today()),
        "items": int(len(items)), "pairs": int(len(pairs)),
        "train_baskets": int(items.baskets.sum() / max(1, 1)),
        "eval_baskets": int(len(baskets)), "top_n": TOP_N,
        "min_pair_support": MIN_PAIR_SUPPORT,
        "best_scorer": best, "beats_popularity": bool(beats),
        "scorers": ev,
        "same_category_share": float(rec.same_category.eq("Y").mean()),
        "uplift_vs_popularity_mrr": float(ev[best]["mrr"] / ev["popularity"]["mrr"])
        if ev["popularity"]["mrr"] > 0 else float("nan"),
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    print(f"  wrote {METRICS.name} and {REPORT.name}", flush=True)

    if not a.no_mlflow:
        safe_track(
            EXPERIMENT, f"reco-{MODEL_VERSION}",
            params={"scorers": "popularity, cosine, lift", "top_n": TOP_N,
                    "min_pair_support": MIN_PAIR_SUPPORT, "eval": "leave-one-out",
                    "split": "out-of-time, train before 2020-11-01"},
            metrics={k: v for k, v in metrics.items() if isinstance(v, (int, float))}
            | {"scorer": ev},
            tags={"model_version": MODEL_VERSION, "grain": "item-item",
                  "output_table": "plu_recommendations",
                  "baseline": "popularity, which is strong in grocery",
                  "source_script": "scripts/pos_perf/basket_reco_model.py"},
            dicts={"scorers.json": ev},
        )

    if not a.no_load:
        recs = [(
            s_(r.plu, 24), s_(r.product_name, 200), s_(r.category, 60), int(r.rank),
            s_(r.rec_plu, 24), s_(r.rec_product_name, 200), s_(r.rec_category, 60),
            f(r.cosine, 6), f(r.lift, 4), int(r.pair_baskets), f(r.support_pct, 6),
            s_(r.same_category, 4), MODEL_VERSION,
        ) for r in rec.itertuples(index=False)]
        recreate_and_load(cn, "plu_recommendations", DDL, recs)

    print(f"done in {time.time() - t0:.0f}s", flush=True)
    return 0


def write_report(m):
    L = []
    A = L.append
    A("# Market-basket recommender report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}. {m['items']} items, "
      f"{m['pairs']:,} co-occurring pairs.\n")
    A("Split is out of time: co-occurrence is built only from baskets before 2020-11-01, "
      f"and all {m['eval_baskets']:,} evaluated baskets fall after it.\n")
    A("## Leave-one-out accuracy against the popularity baseline\n")
    A("One item is hidden from each held-out basket, the rest are used to rank candidates, "
      "and we record where the hidden item landed. Items already visible in the basket are "
      "excluded from the ranking.\n")
    A("| Scorer | hit@1 | hit@5 | hit@10 | MRR |")
    A("|---|---|---|---|---|")
    for name in ("popularity", "cosine", "lift"):
        d = m["scorers"][name]
        A(f"| {name} | {d['hit@1']:.4f} | {d['hit@5']:.4f} | {d['hit@10']:.4f} | {d['mrr']:.4f} |")
    verdict = ("beats" if m["beats_popularity"] else "DOES NOT BEAT")
    A(f"\nBest scorer: **{m['best_scorer']}**, which {verdict} the popularity baseline "
      f"({m['uplift_vs_popularity_mrr']:.2f}x on MRR).\n")
    A("Popularity is the baseline that matters. Most grocery baskets contain staples, so "
      "recommending the chain bestsellers to everyone is already a decent strategy. A "
      "co-occurrence model only earns its place by beating it.\n")
    A("## What the recommendations look like\n")
    A(f"{m['same_category_share']:.1%} of the stored recommendations sit in the same category "
      "as their anchor product. A very high share would mean the model has learned little "
      "beyond the category tree and a category rule would do the same job for free; a very "
      "low share on a grocery assortment would be equally suspicious.\n")
    A("## Output\n")
    A(f"plu_recommendations holds the top {m['top_n']} companions per PLU with both scores, "
      "the raw pair basket count and its support, so a caller can apply its own confidence "
      "floor. Pairs seen in fewer than "
      f"{m['min_pair_support']} baskets are excluded from lift, which is unstable on thin "
      "support.\n")
    A("The table is the serving artefact -- a lookup joined in SQL or read by a dashboard. "
      "There is no fitted estimator to register, because the model IS the pair table.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
