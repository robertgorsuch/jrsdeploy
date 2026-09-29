"""clv_model.py -- predict forward 6-month gross margin per customer, and load
customer_clv_scores into the pos_data warehouse.

WHY SQUARED ERROR HERE, WHEN THE DEMAND MODELS USE ABSOLUTE ERROR
  This is the mirror image of the replenishment decision, and getting it
  backwards would quietly wreck the model. An absolute-error objective predicts
  the conditional MEDIAN. For customer value the median is zero or near it --
  40 percent of customers spend nothing in the next six months -- so a median
  model would predict almost nobody is worth anything and the portfolio total
  would collapse. A value model has to predict the conditional MEAN, because
  the only useful property of a CLV number is that summing it across customers
  reproduces expected margin. So: squared error here, absolute error there,
  quantile for ordering. The objective follows the decision.

VALIDATION IS OUT OF TIME, ACROSS TWO COHORTS
  train  as-of 2019-12, target margin over 2020-01 .. 2020-06
  valid  as-of 2020-06, target margin over 2020-07 .. 2020-12
  The cohorts genuinely differ -- forward activity falls from 71.4 to 60.2
  percent between them -- so this is a real test of transfer, not a reshuffle.
  That drift is expected to cost calibration, and the report measures it rather
  than hiding it.

BASELINE
  margin_l6: assume the next six months look like the last six. Free, obvious,
  and hard to beat on customers with stable habits. The model earns its place
  only by beating it.

WHAT IS ACTUALLY MEASURED
  Point accuracy alone is the wrong lens for CLV. Three things matter:
    portfolio calibration   sum(predicted) / sum(actual). A model that ranks
                            well but predicts half the money is unusable for
                            budgeting.
    decile separation       do the top-decile customers actually turn out most
                            valuable. This is how CLV gets used.
    top-decile capture      what share of all future margin sits in the top
                            predicted decile. This is the number a targeting
                            budget is sized from.

Usage
  python scripts/pos_perf/clv_model.py
  python scripts/pos_perf/clv_model.py --no-load --no-mlflow

Requires: clv_training_set (see build_clv_training_set.sql).
Outputs
  warehouse table customer_clv_scores
  MLflow experiment pos-customer-clv, registered model customer-clv
  scripts/pos_perf/clv_metrics.json / clv_report.md
"""

import argparse
import json
import sys
import time
import warnings
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pos_ml_common import (connect, encode, f, permutation_importance,  # noqa: E402
                           predict_nn, q, recreate_and_load, safe_track, score)

HERE = Path(__file__).resolve().parent
REPORT = HERE / "clv_report.md"
METRICS = HERE / "clv_metrics.json"

MODEL_VERSION = "customer-clv-v1"
EXPERIMENT = "pos-customer-clv"
REGISTERED_NAME = "customer-clv"

TRAIN_ASOF, VALID_ASOF = 11, 17
HORIZON_MONTHS = 6

# Sentinel accounts, not people. 74 customer_ids shop at more than 20 of the
# 330 stores -- customer_id 0 alone covers all 330 with 1,003,697 transactions
# and 24.1M of sales, which is the unidentified walk-in bucket rather than a
# shopper. Together they hold 29.4M, or 3.9 percent of all chain sales, and one
# of them carries a six-month margin of 2.5M. Left in, they dominate a squared
# error objective completely: the model spends its capacity chasing two rows
# and scores R2 0.02, while a persistence baseline that simply tracks them
# scores 0.9987. Excluding them is not outlier-trimming for convenience, it is
# removing records that are not the unit of analysis.
MAX_DISTINCT_STORES = 20

CATEGORICAL = ["province", "home_region", "loyalty_tier", "favorite_category",
               "email_opt_in", "rfm_segment", "lifecycle_status", "age_band",
               "gender", "household_income_band", "life_stage", "children_flag",
               "dwelling_type", "acquisition_channel", "diet_profile", "basket_profile"]

NUMERIC = ["months_observed", "months_since_first", "sales_life", "margin_life",
           "txns_life", "purchase_days_life", "sales_l3", "sales_l6", "sales_l12",
           "margin_l3", "margin_l6", "margin_l12", "txns_l6", "txns_l12",
           "purchase_days_l6", "returns_l6", "promo_sales_l6", "discount_l6",
           "ecom_l6", "points_earned_l6", "redemptions_l6", "emails_sent_l6",
           "emails_opened_l6", "emails_clicked_l6", "cases_l6", "giftcards_l6",
           "active_months_l6", "days_since_last", "distinct_stores_asof",
           "min_csat_l6", "household_size", "categories_bought",
           "ipt_median_days", "overdue_ratio", "tenure_days"]

DDL = """
CREATE TABLE customer_clv_scores (
    customer_id          VARCHAR(40) NOT NULL,
    as_of_seq            INTEGER     NOT NULL,
    horizon_months       INTEGER     NOT NULL,
    model_version        VARCHAR(40) NOT NULL,
    predicted_margin     DECIMAL(14,4),
    actual_margin        DECIMAL(14,4),
    baseline_margin_l6   DECIMAL(14,4),
    value_decile         INTEGER,
    value_band           VARCHAR(16),
    loyalty_tier         VARCHAR(24),
    lifecycle_status     VARCHAR(24),
    province             VARCHAR(40),
    split_role           VARCHAR(16) NOT NULL
)
"""


def s_(v, n):
    return None if v is None else str(v)[:n]


def decile_table(y, p, n=10):
    d = pd.DataFrame({"y": np.asarray(y, float), "p": np.asarray(p, float)})
    d["dec"] = pd.qcut(d.p.rank(method="first"), n, labels=False)
    g = (d.groupby("dec")
           .agg(n=("y", "size"), pred=("p", "mean"), actual=("y", "mean"),
                total_actual=("y", "sum"))
           .reset_index())
    tot = float(d.y.sum())
    g["share_of_total"] = g.total_actual / tot if tot else np.nan
    return g.to_dict(orient="records")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print(f"customer lifetime value -- forward {HORIZON_MONTHS} month margin", flush=True)

    cn = connect()
    cols = ["customer_id", "as_of_seq"] + NUMERIC + CATEGORICAL + ["future_margin"]
    df = q(cn, f"SELECT {', '.join(cols)} FROM clv_training_set")
    print(f"  {len(df):,} rows across cohorts {sorted(df.as_of_seq.unique())}", flush=True)

    excl = q(cn, f"SELECT customer_id FROM customers WHERE distinct_stores > {MAX_DISTINCT_STORES}")
    before = len(df)
    df = df[~df.customer_id.isin(set(excl.customer_id))].copy()
    print(f"  excluded {before - len(df):,} rows for {len(excl)} aggregate accounts "
          f"(more than {MAX_DISTINCT_STORES} distinct stores -- sentinel IDs, not shoppers)", flush=True)

    enc, mapping = encode(df, CATEGORICAL)
    tr = enc[enc.as_of_seq == TRAIN_ASOF]
    te = enc[enc.as_of_seq == VALID_ASOF]
    print(f"  train {len(tr):,} (as-of {TRAIN_ASOF}) | valid {len(te):,} (as-of {VALID_ASOF})", flush=True)
    print(f"  mean target: train {tr.future_margin.mean():.2f} | valid {te.future_margin.mean():.2f}", flush=True)

    feats, cats = NUMERIC, CATEGORICAL
    m = HistGradientBoostingRegressor(
        loss="squared_error",           # the MEAN, not the median -- see module docstring
        max_iter=400, learning_rate=0.06, max_leaf_nodes=63, min_samples_leaf=100,
        l2_regularization=1.0, early_stopping=True, n_iter_no_change=25,
        validation_fraction=0.1,
        categorical_features=[c in cats for c in (feats + cats)], random_state=42)
    print("  fitting ...", flush=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        m.fit(tr[feats + cats], tr["future_margin"])

    p = predict_nn(m, te[feats + cats])
    y = te["future_margin"].values
    base = np.clip(te["margin_l6"].fillna(0).values, 0, None)

    s_model = score(y, p)
    s_base = score(y, base)
    cal_model = float(p.sum() / y.sum()) if y.sum() else float("nan")
    cal_base = float(base.sum() / y.sum()) if y.sum() else float("nan")
    dt = decile_table(y, p)
    dt_base = decile_table(y, base)
    top_capture = float(dt[-1]["share_of_total"])
    top_capture_base = float(dt_base[-1]["share_of_total"])

    print(f"  [model]    MAE {s_model['mae']:.3f}  RMSE {s_model['rmse']:.2f}  R2 {s_model['r2']:.4f}  "
          f"portfolio calib {cal_model:.4f}  top-decile capture {top_capture:.3f}", flush=True)
    print(f"  [margin_l6] MAE {s_base['mae']:.3f}  RMSE {s_base['rmse']:.2f}  R2 {s_base['r2']:.4f}  "
          f"portfolio calib {cal_base:.4f}  top-decile capture {top_capture_base:.3f}", flush=True)
    beats = s_model["mae"] < s_base["mae"]
    print(f"  beats margin_l6 baseline on MAE: {beats}", flush=True)

    imp = permutation_importance(m, te, feats, cats, "future_margin", sample=150000)

    te = te.copy()
    te["predicted_margin"] = p
    te["actual_margin"] = y
    te["baseline_margin_l6"] = base
    te["value_decile"] = pd.qcut(pd.Series(p).rank(method="first"), 10, labels=False).values + 1
    te["value_band"] = pd.cut(te.value_decile, [0, 7, 9, 10],
                              labels=["standard", "high value", "top decile"])
    raw = df[df.as_of_seq == VALID_ASOF]
    for c in ("loyalty_tier", "lifecycle_status", "province"):
        te[c] = raw[c].values

    metrics = {
        "model_version": MODEL_VERSION, "run_date": str(date.today()),
        "horizon_months": HORIZON_MONTHS, "train_asof": TRAIN_ASOF, "valid_asof": VALID_ASOF,
        "train_rows": int(len(tr)), "valid_rows": int(len(te)),
        "train_mean_target": float(tr.future_margin.mean()),
        "valid_mean_target": float(te.actual_margin.mean()),
        "objective": "squared_error (conditional mean)",
        "excluded_aggregate_accounts": int(len(excl)),
        "max_distinct_stores": MAX_DISTINCT_STORES,
        "model": s_model, "baseline_margin_l6": s_base,
        "portfolio_calibration_model": cal_model,
        "portfolio_calibration_baseline": cal_base,
        "top_decile_capture_model": top_capture,
        "top_decile_capture_baseline": top_capture_base,
        "beats_baseline_mae": bool(beats),
        "deciles": dt, "importance": imp,
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    print(f"  wrote {METRICS.name} and {REPORT.name}", flush=True)

    if not a.no_mlflow:
        safe_track(
            EXPERIMENT, f"clv-{MODEL_VERSION}",
            params={"loss": "squared_error", "horizon_months": HORIZON_MONTHS,
                    "train_asof": TRAIN_ASOF, "valid_asof": VALID_ASOF,
                    "max_iter": 400, "learning_rate": 0.06,
                    "n_features": len(feats) + len(cats)},
            metrics={"model": s_model, "baseline": s_base,
                     "portfolio_calibration": cal_model,
                     "portfolio_calibration_baseline": cal_base,
                     "top_decile_capture": top_capture,
                     "top_decile_capture_baseline": top_capture_base},
            model=m, model_name=REGISTERED_NAME, sample_X=tr[feats + cats].head(200),
            tags={"model_version": MODEL_VERSION, "grain": "customer",
                  "objective_note": "conditional MEAN -- a median objective would predict zero for most customers",
                  "output_table": "customer_clv_scores",
                  "baseline": "margin_l6 persistence",
                  "source_script": "scripts/pos_perf/clv_model.py"},
            dicts={"deciles.json": {"rows": dt}, "importance.json": {"rows": imp}},
        )

    if not a.no_load:
        recs = [(
            s_(r.customer_id, 40), int(r.as_of_seq), HORIZON_MONTHS, MODEL_VERSION,
            f(r.predicted_margin), f(r.actual_margin), f(r.baseline_margin_l6),
            int(r.value_decile), s_(r.value_band, 16), s_(r.loyalty_tier, 24),
            s_(r.lifecycle_status, 24), s_(r.province, 40), "validation",
        ) for r in te.itertuples(index=False)]
        recreate_and_load(cn, "customer_clv_scores", DDL, recs)

    print(f"done in {time.time() - t0:.0f}s", flush=True)
    return 0


def write_report(m):
    L = []
    A = L.append
    A("# Customer lifetime value report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}. Forward "
      f"{m['horizon_months']}-month gross margin per customer.\n")
    A(f"Trained on the as-of {m['train_asof']} cohort ({m['train_rows']:,} customers, mean target "
      f"{m['train_mean_target']:.2f}) and validated out of time on as-of {m['valid_asof']} "
      f"({m['valid_rows']:,} customers, mean target {m['valid_mean_target']:.2f}). The cohorts "
      "genuinely differ -- forward activity falls from 71.4 to 60.2 percent between them -- so "
      "this measures transfer across a real distribution shift, not a reshuffle.\n")
    A("## Objective\n")
    A(f"{m['objective']}. This is deliberately the opposite choice from the demand models. An "
      "absolute-error objective predicts the conditional median, and roughly 40 percent of "
      "customers spend nothing in the next six months, so a median model would price almost "
      "everyone at zero and the portfolio total would collapse. A value model must predict the "
      "conditional mean, because the one property a CLV number has to have is that summing it "
      "across customers reproduces expected margin.\n")
    A("## Accuracy against the persistence baseline\n")
    A("| Predictor | MAE | RMSE | R2 | Portfolio calibration | Top-decile capture |")
    A("|---|---|---|---|---|---|")
    A(f"| model | {m['model']['mae']:.3f} | {m['model']['rmse']:.2f} | {m['model']['r2']:.4f} | "
      f"{m['portfolio_calibration_model']:.4f} | {m['top_decile_capture_model']:.3f} |")
    A(f"| margin_l6 persistence | {m['baseline_margin_l6']['mae']:.3f} | "
      f"{m['baseline_margin_l6']['rmse']:.2f} | {m['baseline_margin_l6']['r2']:.4f} | "
      f"{m['portfolio_calibration_baseline']:.4f} | {m['top_decile_capture_baseline']:.3f} |")
    A(f"\nBeats the baseline on MAE: **{'yes' if m['beats_baseline_mae'] else 'NO'}**.\n")
    A("Portfolio calibration is sum(predicted) / sum(actual). A value of 1.0 means the model "
      "prices the whole book correctly; below 1.0 it is systematically under-valuing customers. "
      "This matters more than point accuracy for any budgeting use, and a model can rank well "
      "while being badly calibrated.\n")
    A("Top-decile capture is the share of all future margin that sits in the top predicted "
      "decile. It is the number a targeting budget is sized from.\n")
    A("## Value deciles\n")
    A("| Decile | Customers | Mean predicted | Mean actual | Share of total future margin |")
    A("|---|---|---|---|---|")
    for r in m["deciles"]:
        A(f"| {int(r['dec']) + 1} | {int(r['n']):,} | {r['pred']:.2f} | {r['actual']:.2f} | "
          f"{r['share_of_total']:.3f} |")
    A("\nMonotonically rising actual value across deciles is the property that makes a CLV model "
      "usable for targeting. A break in that monotonicity matters more than a small MAE gap.\n")
    A("## Feature importance (MAE rise when shuffled)\n")
    A("| Feature | MAE rise |")
    A("|---|---|")
    for r in m["importance"][:12]:
        A(f"| {r['feature']} | {r['mae_rise']:.4f} |")
    A("\n## Output\n")
    A("customer_clv_scores carries the predicted and actual forward margin, the persistence "
      "baseline for comparison, a value decile and band, and the customer attributes needed to "
      "segment without another join.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
