"""supplier_reliability_model.py -- predict purchase-order lead time and
on-time delivery, and load supplier_reliability_forecast into pos_data.

WHY THIS EXISTS
  The PLU replenishment model assumes stock arrives on the nominal lead time.
  It does not. Across 92,472 purchase orders the actual lead time varies around
  the expectation, and a late delivery turns an accurate demand forecast into a
  stockout anyway. This model predicts, for a PO about to be raised, how long
  it will actually take and how likely it is to arrive on time -- which is what
  a safety-stock calculation needs and what the static lead_time_days column
  cannot give.

TWO HEADS
  regression   actual_lead_days, so replenishment can plan on the expected wait
  classifier   P(on time), so the safety buffer can be sized by risk rather
               than by a flat rule

CAREFUL WITH THE FEATURES
  suppliers carries whole-period rollups -- on_time_pct, avg_fill_rate_pct,
  purchase_orders, total_spend -- computed across every PO including the ones
  being predicted. Those are excluded. What a buyer genuinely knows before
  raising a PO is used instead: which supplier, which store, order size, the
  calendar, and the supplier expectation recorded on the order itself.
  expected_lead_days IS known at order time and is kept.

  fill_rate_pct, received_units and backordered_units are OUTCOMES of the same
  delivery and are excluded from the features -- they are not known when the
  order is placed.

VALIDATION
  Out of time. Orders are split on order_date, training on everything before
  TRAIN_END and evaluating after, so a supplier that degraded late in the
  period cannot be predicted using its own later behaviour.

BASELINES
  The regression is compared against expected_lead_days itself -- the number
  already printed on the PO. If the model cannot beat the supplier stated
  expectation there is no reason to run it. The classifier is compared against
  predicting the base rate for everyone.

Usage
  python scripts/pos_perf/supplier_reliability_model.py
  python scripts/pos_perf/supplier_reliability_model.py --no-load --no-mlflow

Requires: purchase_orders, stores, suppliers (for category_focus only).
Outputs
  warehouse table supplier_reliability_forecast
  MLflow experiment pos-supplier-reliability
  registered models supplier-lead-time and supplier-on-time
  scripts/pos_perf/supplier_reliability_metrics.json / _report.md
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
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pos_ml_common import (clf_score, connect, encode, f, permutation_importance,  # noqa: E402
                           predict_nn, q, recreate_and_load, safe_track, score)

HERE = Path(__file__).resolve().parent
REPORT = HERE / "supplier_reliability_report.md"
METRICS = HERE / "supplier_reliability_metrics.json"

MODEL_VERSION = "supplier-reliability-v1"
EXPERIMENT = "pos-supplier-reliability"
REG_LEAD = "supplier-lead-time"
REG_ONTIME = "supplier-on-time"

TRAIN_END = date(2020, 6, 30)

CATEGORICAL = ["supplier_name", "po_status", "province", "region", "store_format",
               "category_focus", "payment_terms", "order_dow"]
NUMERIC = ["expected_lead_days", "line_count", "ordered_units", "po_value_cost",
           "order_month", "order_year", "square_feet", "staff_count",
           "supplier_nominal_lead"]

DDL = """
CREATE TABLE supplier_reliability_forecast (
    po_number             VARCHAR(40) NOT NULL,
    storenumber           INTEGER,
    supplier_name         VARCHAR(80),
    order_date            ANSIDATE,
    expected_lead_days    INTEGER,
    predicted_lead_days   DECIMAL(10,3),
    actual_lead_days      INTEGER,
    lead_abs_error        DECIMAL(10,3),
    expected_abs_error    DECIMAL(10,3),
    p_on_time             DECIMAL(10,6),
    actual_on_time        VARCHAR(4),
    risk_band             VARCHAR(16),
    recommended_buffer_days DECIMAL(10,3),
    split_role            VARCHAR(16) NOT NULL,
    model_version         VARCHAR(40)
)
"""


def s_(v, n):
    return None if v is None else str(v)[:n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print("supplier reliability -- lead time and on-time delivery", flush=True)

    cn = connect()
    po = q(cn, """SELECT po_number, storenumber, supplier_name, order_date, order_year,
                         order_month, expected_lead_days, actual_lead_days, on_time,
                         line_count, ordered_units, po_value_cost, po_status
                  FROM purchase_orders""")
    st = q(cn, "SELECT storenumber, province, region, store_format, square_feet, staff_count FROM stores")
    sup = q(cn, "SELECT supplier_name, category_focus, payment_terms, lead_time_days AS supplier_nominal_lead FROM suppliers")
    po["order_date"] = pd.to_datetime(po["order_date"])
    print(f"  {len(po):,} purchase orders, {po.supplier_name.nunique()} suppliers, "
          f"{po.order_date.min().date()} .. {po.order_date.max().date()}", flush=True)

    df = po.merge(st, on="storenumber", how="left").merge(sup, on="supplier_name", how="left")
    df = df[df.actual_lead_days.notna() & df.expected_lead_days.notna()].copy()
    df["order_dow"] = df.order_date.dt.dayofweek.astype(str)
    df["on_time_flag"] = (df.on_time.astype(str).str.upper().str[0] == "Y").astype(int)
    print(f"  usable {len(df):,} | on-time rate {df.on_time_flag.mean():.3f} | "
          f"mean actual lead {df.actual_lead_days.mean():.2f}d vs expected "
          f"{df.expected_lead_days.mean():.2f}d", flush=True)

    enc, mapping = encode(df, CATEGORICAL)
    tr = enc[enc.order_date <= pd.Timestamp(TRAIN_END)]
    te = enc[enc.order_date > pd.Timestamp(TRAIN_END)]
    print(f"  train {len(tr):,} (to {TRAIN_END}) | holdout {len(te):,}", flush=True)

    feats, cats = NUMERIC, CATEGORICAL
    cmask = [c in cats for c in (feats + cats)]

    reg = HistGradientBoostingRegressor(
        loss="absolute_error", max_iter=350, learning_rate=0.06, max_leaf_nodes=31,
        min_samples_leaf=40, l2_regularization=1.0, early_stopping=True,
        n_iter_no_change=25, validation_fraction=0.1,
        categorical_features=cmask, random_state=42)
    clf = HistGradientBoostingClassifier(
        max_iter=350, learning_rate=0.06, max_leaf_nodes=31, min_samples_leaf=40,
        l2_regularization=1.0, early_stopping=True, n_iter_no_change=25,
        validation_fraction=0.1, categorical_features=cmask, random_state=42)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        print("  fitting lead-time regressor ...", flush=True)
        reg.fit(tr[feats + cats], tr["actual_lead_days"])
        print("  fitting on-time classifier ...", flush=True)
        clf.fit(tr[feats + cats], tr["on_time_flag"])

    pl = predict_nn(reg, te[feats + cats])
    pt = clf.predict_proba(te[feats + cats])[:, 1]
    y_lead = te["actual_lead_days"].values
    y_ot = te["on_time_flag"].values

    m_lead = score(y_lead, pl)
    b_lead = score(y_lead, te["expected_lead_days"].values)      # the number on the PO
    b_naive = score(y_lead, np.full(len(te), tr["actual_lead_days"].mean()))
    m_ot = clf_score(y_ot, pt)
    b_ot = clf_score(y_ot, np.full(len(te), tr["on_time_flag"].mean()))

    print(f"  [lead time] MAE {m_lead['mae']:.3f}d  R2 {m_lead['r2']:.3f} | "
          f"PO expectation MAE {b_lead['mae']:.3f}d | train-mean MAE {b_naive['mae']:.3f}d", flush=True)
    print(f"  [on time]   AUC {m_ot['auc_roc']:.4f}  PR {m_ot['auc_pr']:.4f}  "
          f"Brier {m_ot['brier']:.4f} | base rate {b_ot['positive_rate']:.3f}", flush=True)

    beats_po = m_lead["mae"] < b_lead["mae"]
    if not beats_po:
        print("  WARNING: the model does not beat the expected_lead_days already on the PO", flush=True)

    imp_lead = permutation_importance(reg, te, feats, cats, "actual_lead_days")
    imp_ot = permutation_importance(clf, te, feats, cats, "on_time_flag",
                                    predict=lambda m, X: m.predict_proba(X)[:, 1])

    # recommended buffer: how many extra days cover this order at the target
    # service level, from the model residual spread rather than a flat rule
    resid = y_lead - pl
    buf_q = float(np.quantile(resid, 0.90))
    te = te.copy()
    te["predicted_lead_days"] = pl
    te["p_on_time"] = pt
    te["recommended_buffer_days"] = np.clip(buf_q * (1.0 - pt) / max(1e-6, 1.0 - pt.mean()), 0, 14)
    te["risk_band"] = pd.cut(pt, [-0.01, 0.5, 0.8, 1.01], labels=["high risk", "watch", "reliable"])

    metrics = {
        "model_version": MODEL_VERSION, "run_date": str(date.today()),
        "orders": int(len(df)), "suppliers": int(df.supplier_name.nunique()),
        "train_rows": int(len(tr)), "holdout_rows": int(len(te)),
        "train_end": str(TRAIN_END),
        "on_time_base_rate": float(df.on_time_flag.mean()),
        "lead_time": {"model": m_lead, "baseline_po_expectation": b_lead,
                      "baseline_train_mean": b_naive, "beats_po_expectation": bool(beats_po)},
        "on_time": {"model": m_ot, "baseline_base_rate": b_ot},
        "buffer_q90_residual_days": buf_q,
        "importance_lead": imp_lead, "importance_on_time": imp_ot,
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    print(f"  wrote {METRICS.name} and {REPORT.name}", flush=True)

    if not a.no_mlflow:
        sample = tr[feats + cats].head(200)
        safe_track(
            EXPERIMENT, f"lead-time-{MODEL_VERSION}",
            params={"loss": "absolute_error", "max_iter": 350, "learning_rate": 0.06,
                    "train_end": str(TRAIN_END), "n_features": len(feats) + len(cats),
                    "excluded": "supplier rollups on_time_pct/avg_fill_rate_pct and delivery outcomes"},
            metrics={"lead_time": metrics["lead_time"], "on_time": metrics["on_time"],
                     "orders": metrics["orders"], "buffer_q90": buf_q},
            model=reg, model_name=REG_LEAD, sample_X=sample,
            extra_models={"on_time_classifier": clf},
            tags={"model_version": MODEL_VERSION, "grain": "purchase order",
                  "output_table": "supplier_reliability_forecast",
                  "baseline": "expected_lead_days already printed on the PO",
                  "source_script": "scripts/pos_perf/supplier_reliability_model.py"},
            dicts={"importance_lead.json": {"rows": imp_lead},
                   "importance_on_time.json": {"rows": imp_ot}},
        )

    if not a.no_load:
        recs = [(
            s_(r.po_number, 40), int(r.storenumber), s_(r.supplier_name, 80),
            r.order_date.date() if pd.notna(r.order_date) else None,
            int(r.expected_lead_days), f(r.predicted_lead_days, 3),
            int(r.actual_lead_days), f(abs(r.predicted_lead_days - r.actual_lead_days), 3),
            f(abs(r.expected_lead_days - r.actual_lead_days), 3), f(r.p_on_time, 6),
            "Y" if r.on_time_flag == 1 else "N", s_(r.risk_band, 16),
            f(r.recommended_buffer_days, 3), "holdout", MODEL_VERSION,
        ) for r in te.itertuples(index=False)]
        recreate_and_load(cn, "supplier_reliability_forecast", DDL, recs)

    print(f"done in {time.time() - t0:.0f}s", flush=True)
    return 0


def write_report(m):
    L = []
    A = L.append
    A("# Supplier reliability report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}. {m['orders']:,} purchase "
      f"orders across {m['suppliers']} suppliers. Trained on orders to {m['train_end']}, "
      f"evaluated on the {m['holdout_rows']:,} that follow.\n")
    A("Two heads: expected lead time for planning, and probability of on-time arrival for "
      "sizing the safety buffer by risk instead of by a flat rule.\n")
    lt = m["lead_time"]
    A("## Lead time, against the number already on the PO\n")
    A("| Predictor | MAE (days) | RMSE | R2 | Bias |")
    A("|---|---|---|---|---|")
    A(f"| model | {lt['model']['mae']:.3f} | {lt['model']['rmse']:.3f} | "
      f"{lt['model']['r2']:.3f} | {lt['model']['bias']:+.3f} |")
    A(f"| expected_lead_days on the PO | {lt['baseline_po_expectation']['mae']:.3f} | "
      f"{lt['baseline_po_expectation']['rmse']:.3f} | {lt['baseline_po_expectation']['r2']:.3f} | "
      f"{lt['baseline_po_expectation']['bias']:+.3f} |")
    A(f"| training mean | {lt['baseline_train_mean']['mae']:.3f} | "
      f"{lt['baseline_train_mean']['rmse']:.3f} | {lt['baseline_train_mean']['r2']:.3f} | "
      f"{lt['baseline_train_mean']['bias']:+.3f} |")
    A(f"\nBeats the PO expectation: **{'yes' if lt['beats_po_expectation'] else 'NO'}**. "
      "That is the baseline that decides whether this model is worth running -- the supplier "
      "already tells you how long it expects to take, for free.\n")
    ot = m["on_time"]
    A("## On-time delivery\n")
    A("| Predictor | AUC-ROC | AUC-PR | Brier | Top-decile lift |")
    A("|---|---|---|---|---|")
    A(f"| model | {ot['model']['auc_roc']:.4f} | {ot['model']['auc_pr']:.4f} | "
      f"{ot['model']['brier']:.4f} | {ot['model']['top_decile_lift']:.3f} |")
    A(f"| base rate ({ot['baseline_base_rate']['positive_rate']:.3f}) | "
      f"{ot['baseline_base_rate']['auc_roc']:.4f} | {ot['baseline_base_rate']['auc_pr']:.4f} | "
      f"{ot['baseline_base_rate']['brier']:.4f} | - |")
    A("\n## What was deliberately left out\n")
    A("suppliers carries on_time_pct, avg_fill_rate_pct, purchase_orders and total_spend, all "
      "computed over every order including the ones being predicted. Feeding a supplier its own "
      "future on-time rate would produce a spectacular and meaningless AUC. Delivery outcomes on "
      "the order itself -- fill_rate_pct, received_units, backordered_units -- are excluded for "
      "the same reason: they are not known when the order is raised.\n")
    A("## Feature importance, lead time (MAE rise when shuffled)\n")
    A("| Feature | MAE rise |")
    A("|---|---|")
    for r in m["importance_lead"][:10]:
        A(f"| {r['feature']} | {r['mae_rise']:.4f} |")
    A(f"\n## Output\n")
    A("supplier_reliability_forecast holds the holdout orders with predicted and actual lead "
      "time, the error of both the model and the PO expectation side by side, the on-time "
      "probability, a risk band and a recommended buffer in days. The buffer comes from the "
      f"90th percentile of the model residual ({m['buffer_q90_residual_days']:.2f} days) scaled "
      "by the predicted risk, so an order from a reliable supplier carries less padding than one "
      "from a shaky one -- which is the point of predicting risk at all.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
