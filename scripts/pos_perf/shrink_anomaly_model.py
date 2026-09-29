"""shrink_anomaly_model.py -- find store-category shrink that is abnormal
relative to peers, and load shrink_anomaly_scores into the pos_data warehouse.

THE FRAMING MATTERS MORE THAN THE ALGORITHM
  There is no shrink-fraud label in this data, so this cannot be a supervised
  detector and must not be sold as one. What it does is measure how far each
  store-category-month sits from what comparable stores did in the same
  category and month, and rank the outliers for a human to look at. That is a
  triage queue, not an accusation.

  Two normalisations do the real work:
    shrink RATE, not value  a big store shrinks more in absolute dollars simply
                            by selling more. Everything is measured as shrink
                            value over sales for the same cell.
    peer and period relative  the comparison is against the same category in
                            the same month across the chain, so a category that
                            is inherently wasteful (fresh) and a month when
                            everyone spoiled more do not generate false alarms.

TWO SCORES, DELIBERATELY DIFFERENT
  robust_z   median and MAD within category-month, so a handful of extreme
             stores cannot inflate the spread they are being judged against.
             Interpretable: 3.5 means far outside normal variation.
  iforest    IsolationForest over the full feature vector -- rate, trend,
             concentration by reason, event size. Catches shapes a single-axis
             z-score misses, such as normal total shrink made up entirely of
             one reason code.
  They are reported side by side rather than blended, because they disagree in
  informative ways and a combined number would hide that.

VALIDATION WITHOUT LABELS
  Anomaly detection with no ground truth cannot report precision. What it can
  report, and what this does:
    stability      do the same stores flag in the first half and the second
                   half of the period. A detector whose alerts are pure noise
                   will not repeat, so persistence is evidence of signal.
    separation     flagged cells are compared against unflagged ones on shrink
                   rate and dollar value, to confirm the flags are actually
                   finding costly cells and not just small noisy ones.
    concentration  what share of total shrink dollars the flagged cells hold.
                   That is the size of the prize if the queue gets worked.

Usage
  python scripts/pos_perf/shrink_anomaly_model.py
  python scripts/pos_perf/shrink_anomaly_model.py --no-load --no-mlflow

Requires: shrinkage_log, store_plu_week or pos_sales_detail for the sales
          denominator, stores, products.
Outputs
  warehouse table shrink_anomaly_scores
  MLflow experiment pos-shrink-anomaly, registered model shrink-anomaly
  scripts/pos_perf/shrink_anomaly_metrics.json / _report.md
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
from sklearn.ensemble import IsolationForest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pos_ml_common import connect, f, q, recreate_and_load, safe_track  # noqa: E402

HERE = Path(__file__).resolve().parent
REPORT = HERE / "shrink_anomaly_report.md"
METRICS = HERE / "shrink_anomaly_metrics.json"

MODEL_VERSION = "shrink-anomaly-v1"
EXPERIMENT = "pos-shrink-anomaly"
REGISTERED_NAME = "shrink-anomaly"

Z_FLAG = 3.5           # robust z above which a cell is queued for review
CONTAM = 0.02          # expected outlier share for IsolationForest
MIN_SALES = 250.0      # a cell needs real sales before a rate means anything

DDL = """
CREATE TABLE shrink_anomaly_scores (
    storenumber        INTEGER     NOT NULL,
    storename          VARCHAR(80),
    province           VARCHAR(40),
    category           VARCHAR(60),
    yyyymm             INTEGER     NOT NULL,
    shrink_value       DECIMAL(14,2),
    shrink_units       INTEGER,
    shrink_events      INTEGER,
    sales_value        DECIMAL(14,2),
    shrink_rate        DECIMAL(12,6),
    peer_median_rate   DECIMAL(12,6),
    robust_z           DECIMAL(12,4),
    iforest_score      DECIMAL(12,6),
    top_reason         VARCHAR(40),
    top_reason_share   DECIMAL(10,4),
    excess_shrink_value DECIMAL(14,2),
    flagged            VARCHAR(4),
    flag_source        VARCHAR(24),
    model_version      VARCHAR(40)
)
"""


def s_(v, n):
    return None if v is None else str(v)[:n]


def robust_z(g, col):
    """Median and MAD within the group. MAD is scaled by 1.4826 so that on
    normal data it estimates the standard deviation, which keeps the threshold
    interpretable in the usual units."""
    med = g[col].median()
    mad = (g[col] - med).abs().median() * 1.4826
    if not np.isfinite(mad) or mad <= 1e-9:
        mad = g[col].std(ddof=0)
    if not np.isfinite(mad) or mad <= 1e-9:
        return pd.Series(0.0, index=g.index), med
    return (g[col] - med) / mad, med


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print("shrink anomaly -- store x category x month", flush=True)

    cn = connect()
    sh = q(cn, """SELECT storenumber, category, event_year, event_month,
                         SUM(qty_lost) AS shrink_units, SUM(shrink_value) AS shrink_value,
                         COUNT(*) AS shrink_events
                  FROM shrinkage_log GROUP BY storenumber, category, event_year, event_month""")
    rs = q(cn, """SELECT storenumber, category, event_year, event_month, reason,
                         SUM(shrink_value) AS reason_value
                  FROM shrinkage_log GROUP BY storenumber, category, event_year, event_month, reason""")
    sales = q(cn, """SELECT d.storenumber, p.category, t.yyyymm,
                            SUM(d.quantity * d.sellingprice) AS sales_value
                     FROM pos_sales_detail d
                     JOIN pos_sales_txn t ON d.transactionuniqueid = t.transactionuniqueid
                     JOIN products p ON p.plu = d.plu
                     WHERE TRIM(d.transactiontype) = 'Regular Sale'
                     GROUP BY d.storenumber, p.category, t.yyyymm""")
    st = q(cn, "SELECT storenumber, storename, province FROM stores")

    sh["yyyymm"] = sh.event_year.astype(int) * 100 + sh.event_month.astype(int)
    rs["yyyymm"] = rs.event_year.astype(int) * 100 + rs.event_month.astype(int)
    for d in (sh, rs, sales):
        d["category"] = d["category"].replace({"None": "Uncategorised", "": "Uncategorised"}).fillna("Uncategorised")
    print(f"  shrink cells {len(sh):,} | sales cells {len(sales):,}", flush=True)

    # dominant reason per cell -- a normal total made of one reason is itself a signal
    rs = rs.sort_values("reason_value", ascending=False)
    top = (rs.groupby(["storenumber", "category", "yyyymm"])
             .agg(top_reason=("reason", "first"), top_value=("reason_value", "first"),
                  total_reason_value=("reason_value", "sum")).reset_index())
    top["top_reason_share"] = top.top_value / top.total_reason_value.replace(0, np.nan)

    df = (sh.merge(sales, on=["storenumber", "category", "yyyymm"], how="left")
            .merge(top[["storenumber", "category", "yyyymm", "top_reason", "top_reason_share"]],
                   on=["storenumber", "category", "yyyymm"], how="left")
            .merge(st, on="storenumber", how="left"))
    df["sales_value"] = df.sales_value.fillna(0.0)
    before = len(df)
    df = df[df.sales_value >= MIN_SALES].copy()
    print(f"  {len(df):,} cells with at least {MIN_SALES:.0f} of sales "
          f"({before - len(df):,} thin cells dropped -- a rate on tiny sales is noise)", flush=True)

    df["shrink_rate"] = df.shrink_value / df.sales_value

    # peer-relative within category and month
    zs, meds = [], []
    for (cat, ym), g in df.groupby(["category", "yyyymm"], sort=False):
        z, med = robust_z(g, "shrink_rate")
        zs.append(z)
        meds.append(pd.Series(med, index=g.index))
    df["robust_z"] = pd.concat(zs).reindex(df.index)
    df["peer_median_rate"] = pd.concat(meds).reindex(df.index)
    df["excess_shrink_value"] = np.clip(
        (df.shrink_rate - df.peer_median_rate) * df.sales_value, 0, None)

    # trend within store-category so a deteriorating cell is visible
    df = df.sort_values(["storenumber", "category", "yyyymm"])
    grp = df.groupby(["storenumber", "category"], sort=False)["shrink_rate"]
    df["rate_prev"] = grp.shift(1)
    df["rate_trend"] = df.shrink_rate - df.rate_prev

    feats = ["shrink_rate", "robust_z", "shrink_events", "shrink_units",
             "top_reason_share", "rate_trend", "excess_shrink_value"]
    X = df[feats].replace([np.inf, -np.inf], np.nan).fillna(0.0)
    iso = IsolationForest(n_estimators=300, contamination=CONTAM,
                          random_state=42, n_jobs=-1)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        iso.fit(X)
    df["iforest_score"] = -iso.score_samples(X)      # higher is more anomalous
    iso_cut = float(np.quantile(df.iforest_score, 1 - CONTAM))

    df["flag_z"] = df.robust_z >= Z_FLAG
    df["flag_iso"] = df.iforest_score >= iso_cut
    df["flagged"] = np.where(df.flag_z | df.flag_iso, "Y", "N")
    df["flag_source"] = np.select(
        [df.flag_z & df.flag_iso, df.flag_z, df.flag_iso],
        ["both", "robust_z", "isolation_forest"], default="none")

    # ---- validation without labels ----------------------------------------
    mid = int(np.median(df.yyyymm.unique()))
    h1 = df[df.yyyymm <= mid]
    h2 = df[df.yyyymm > mid]
    k1 = set(map(tuple, h1.loc[h1.flagged == "Y", ["storenumber", "category"]].values))
    k2 = set(map(tuple, h2.loc[h2.flagged == "Y", ["storenumber", "category"]].values))
    repeat = len(k1 & k2) / len(k1) if k1 else float("nan")
    # a null: if flags were random, what share would repeat by chance
    all2 = set(map(tuple, h2[["storenumber", "category"]].values))
    chance = (len(k2) / len(all2)) if all2 else float("nan")

    fl, un = df[df.flagged == "Y"], df[df.flagged == "N"]
    metrics = {
        "model_version": MODEL_VERSION, "run_date": str(date.today()),
        "cells": int(len(df)), "stores": int(df.storenumber.nunique()),
        "categories": int(df.category.nunique()), "months": int(df.yyyymm.nunique()),
        "z_threshold": Z_FLAG, "contamination": CONTAM, "min_sales": MIN_SALES,
        "flagged_cells": int(len(fl)), "flagged_share": float((df.flagged == "Y").mean()),
        "flag_source_counts": df.flag_source.value_counts().to_dict(),
        "agreement_both": int((df.flag_source == "both").sum()),
        "stability": {"repeat_rate": repeat, "chance_rate": chance,
                      "lift_over_chance": float(repeat / chance) if chance and chance > 0 else float("nan"),
                      "h1_flagged_pairs": len(k1), "h2_flagged_pairs": len(k2)},
        "separation": {
            "flagged_mean_rate": float(fl.shrink_rate.mean()),
            "unflagged_mean_rate": float(un.shrink_rate.mean()),
            "flagged_mean_value": float(fl.shrink_value.mean()),
            "unflagged_mean_value": float(un.shrink_value.mean()),
        },
        "concentration": {
            "flagged_share_of_shrink_dollars": float(fl.shrink_value.sum() / df.shrink_value.sum()),
            "flagged_share_of_cells": float(len(fl) / len(df)),
            "excess_shrink_in_flagged": float(fl.excess_shrink_value.sum()),
            "total_shrink": float(df.shrink_value.sum()),
        },
    }
    print(f"  flagged {len(fl):,} of {len(df):,} cells ({metrics['flagged_share']:.2%}), "
          f"holding {metrics['concentration']['flagged_share_of_shrink_dollars']:.1%} of shrink dollars", flush=True)
    print(f"  stability: {repeat:.3f} of flagged store-categories reflag in the second half "
          f"vs {chance:.3f} by chance ({metrics['stability']['lift_over_chance']:.2f}x)", flush=True)
    print(f"  separation: flagged mean rate {fl.shrink_rate.mean():.4f} vs "
          f"unflagged {un.shrink_rate.mean():.4f}", flush=True)

    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    print(f"  wrote {METRICS.name} and {REPORT.name}", flush=True)

    if not a.no_mlflow:
        safe_track(
            EXPERIMENT, f"shrink-{MODEL_VERSION}",
            params={"z_threshold": Z_FLAG, "contamination": CONTAM, "min_sales": MIN_SALES,
                    "features": ", ".join(feats), "peer_group": "category x month"},
            metrics={k: v for k, v in metrics.items() if isinstance(v, (int, float))}
            | {"stability": metrics["stability"], "separation": metrics["separation"],
               "concentration": metrics["concentration"]},
            model=iso, model_name=REGISTERED_NAME, sample_X=X.head(200),
            predict=lambda m, Z: -m.score_samples(Z),
            tags={"model_version": MODEL_VERSION, "grain": "store x category x month",
                  "supervision": "UNSUPERVISED -- no shrink-fraud label exists in this data",
                  "intended_use": "ranked triage queue for human review, not an accusation",
                  "output_table": "shrink_anomaly_scores",
                  "source_script": "scripts/pos_perf/shrink_anomaly_model.py"},
        )

    if not a.no_load:
        recs = [(
            int(r.storenumber), s_(r.storename, 80), s_(r.province, 40), s_(r.category, 60),
            int(r.yyyymm), f(r.shrink_value, 2), int(r.shrink_units), int(r.shrink_events),
            f(r.sales_value, 2), f(r.shrink_rate, 6), f(r.peer_median_rate, 6),
            f(r.robust_z, 4), f(r.iforest_score, 6), s_(r.top_reason, 40),
            f(r.top_reason_share, 4), f(r.excess_shrink_value, 2),
            s_(r.flagged, 4), s_(r.flag_source, 24), MODEL_VERSION,
        ) for r in df.itertuples(index=False)]
        recreate_and_load(cn, "shrink_anomaly_scores", DDL, recs)

    print(f"done in {time.time() - t0:.0f}s", flush=True)
    return 0


def write_report(m):
    L = []
    A = L.append
    A("# Shrink anomaly report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}. {m['cells']:,} store x category "
      f"x month cells across {m['stores']} stores, {m['categories']} categories and "
      f"{m['months']} months.\n")
    A("## This is unsupervised, and that shapes what it can claim\n")
    A("There is no shrink-fraud label in this data, so this is not a fraud detector and must not "
      "be described as one. It measures how far each cell sits from comparable stores in the same "
      "category and month, and ranks the outliers for a human to look at. The output is a triage "
      "queue.\n")
    A("Everything is a RATE against sales in the same cell, because a large store shrinks more in "
      "absolute dollars simply by selling more, and the comparison is within category and month, "
      "so an inherently wasteful category or a bad month for everyone does not generate alarms.\n")
    A(f"Cells with under {m['min_sales']:.0f} of sales are dropped: a shrink rate computed on "
      "a tiny denominator is noise, and it is the fastest way to fill a review queue with nothing.\n")
    A("## Flags\n")
    A(f"{m['flagged_cells']:,} of {m['cells']:,} cells flagged ({m['flagged_share']:.2%}).\n")
    A("| Source | Cells |")
    A("|---|---|")
    for k, v in m["flag_source_counts"].items():
        A(f"| {k} | {v:,} |")
    A(f"\nThe two detectors agree on {m['agreement_both']:,} cells. They are reported separately "
      "rather than blended, because where they disagree is informative: robust_z catches a cell "
      "whose overall rate is extreme, isolation forest catches odd shapes such as a normal total "
      "made up almost entirely of one reason code.\n")
    A("## Validation without labels\n")
    s = m["stability"]
    A("With no ground truth there is no precision to report. What can be tested is whether the "
      "flags are stable, whether they separate, and whether they concentrate value.\n")
    A("| Test | Result |")
    A("|---|---|")
    A(f"| Flagged store-categories that reflag in the second half | {s['repeat_rate']:.3f} |")
    A(f"| Same, expected by chance | {s['chance_rate']:.3f} |")
    A(f"| Lift over chance | {s['lift_over_chance']:.2f}x |")
    sep = m["separation"]
    A(f"| Flagged mean shrink rate | {sep['flagged_mean_rate']:.4f} |")
    A(f"| Unflagged mean shrink rate | {sep['unflagged_mean_rate']:.4f} |")
    A(f"| Flagged mean shrink value | {sep['flagged_mean_value']:,.2f} |")
    A(f"| Unflagged mean shrink value | {sep['unflagged_mean_value']:,.2f} |")
    A("\nStability is the closest thing to evidence available here. Alerts driven by pure noise "
      "do not repeat, so a repeat rate well above chance means the detector is finding something "
      "persistent about those store-categories rather than reacting to month-to-month randomness.\n")
    c = m["concentration"]
    A("## Size of the prize\n")
    A(f"The flagged cells are {c['flagged_share_of_cells']:.2%} of all cells but hold "
      f"{c['flagged_share_of_shrink_dollars']:.1%} of shrink dollars. Excess shrink in the flagged "
      f"cells -- the amount above what a median peer would have lost -- totals "
      f"{c['excess_shrink_in_flagged']:,.0f} against {c['total_shrink']:,.0f} of shrink overall.\n")
    A("Excess is the honest way to size this. Total shrink in a flagged cell is not recoverable; "
      "the part above peer performance is the only piece a store could plausibly claw back, and "
      "even that assumes the cause is addressable.\n")
    A("## Output\n")
    A("shrink_anomaly_scores carries both scores, the peer median it was judged against, the "
      "dominant reason code and its share, the excess shrink value, and which detector fired. "
      "Sort by excess_shrink_value to work the queue by money rather than by strangeness.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
