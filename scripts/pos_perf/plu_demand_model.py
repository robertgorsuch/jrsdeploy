"""plu_demand_model.py -- train, validate and score the store x PLU weekly
replenishment forecast, track the run in the warehouse MLflow, then load
store_plu_forecast back into the pos_data warehouse.

The problem
  Forecast weekly unit demand for each store-PLU pair two weeks ahead, so that
  ordering has a number instead of a static parameter. Supplier lead times run
  3 to 9 days (mean 5.7), so a two-week horizon covers the order cycle.

Why this is harder than the store-day forecast
  24 percent of the 15.3M pair-weeks are ZERO. Intermittent demand breaks the
  usual measures: MAPE is undefined on a zero actual, and a model predicting the
  conditional median will correctly predict zero for slow movers yet score badly
  on any percentage measure. Accuracy is therefore reported as WAPE over units,
  segmented by velocity band, and the headline comparison is against the policy
  already in force rather than against a percentage.

Baselines, in order of how much they matter
  static(train)  the flat weekly average over TRAINING weeks only. This is the
                 fair stand-in for the incumbent policy: the same "one number
                 per pair" rule, set at the forecast origin. This is the
                 comparison that decides whether the model earns its place.
  ma4            four-week moving average at lag HORIZON. Classic rule of thumb.
  lag2           naive persistence.
  incumbent      inventory.avg_daily_units x 7, the parameter behind
                 reorder_point today. Reported for context ONLY. That average
                 spans the whole period including the holdout, so it has seen
                 the future and is not a forecast anyone could have made. It
                 will often win, and that win means nothing.

Validation is out-of-time AND out-of-store
  train        stores where storenumber mod 10 = 0, weeks <= TRAIN_END_WEEK
  valid_seen   the same stores, the final HOLDOUT_WEEKS weeks
  valid_unseen a disjoint store set (mod 10 = 1), same final weeks
  valid_unseen is the honest number: the model scores all 330 stores while
  training on 33, so generalisation across stores is the actual claim.

Why no 52-week lag
  Only 104 weeks exist, so a 52-week lag covers barely half the rows and carries
  exactly one prior observation per pair. The store-day model showed a
  single-year seasonal feature dominating and being fragile. Seasonality is
  carried by week_of_year instead, learned across all 215k pairs. Max lag 26.

Leakage
  Every lag and rolling feature is offset by at least HORIZON weeks. The
  whole-period rollups on inventory (avg_daily_units, units_90d, days_of_supply,
  annual_turns, gmroi, units_sold_total, sales_total, reorder_point,
  safety_stock, distinct_customers, premium_sales_pct) are read but never used
  as features. avg_daily_units serves only as the incumbent baseline, and
  reorder_point / safety_stock are the incumbent policy, not model inputs.

Scoring covers every store, in two roles
  backtest  the last HORIZON whole weeks, which have actuals, so the output
            table can be verified in SQL independently of this script.
  forward   the HORIZON weeks after the data ends, which have no actuals. Both
            are scoreable because every lag reaches at least HORIZON weeks back.

Usage
  python scripts/pos_perf/plu_demand_model.py                # full run
  python scripts/pos_perf/plu_demand_model.py --no-load      # no write-back
  python scripts/pos_perf/plu_demand_model.py --no-mlflow    # skip tracking

Requires: store_plu_week (see build_store_plu_week.sql), products, stores,
          inventory.
Outputs
  warehouse table store_plu_forecast
  MLflow experiment pos-plu-weekly-demand, registered model plu-weekly-demand
  scripts/pos_perf/plu_demand_metrics.json
  scripts/pos_perf/plu_demand_report.md
"""

import argparse
import json
import os
import sys
import time
import warnings
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import pyodbc
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parents[1] / ".claude" / "skills" / "admiral" / "admiral.config.json"
REPORT = HERE / "plu_demand_report.md"
METRICS = HERE / "plu_demand_metrics.json"

MODEL_VERSION = "plu-weekly-demand-v1"
EXPERIMENT = "pos-plu-weekly-demand"
REGISTERED_NAME = "plu-weekly-demand"

HORIZON = 2
LAST_WEEK = 103
HOLDOUT_WEEKS = 8
TRAIN_END_WEEK = LAST_WEEK - HOLDOUT_WEEKS
MAX_LAG = 26
TRAIN_MOD, VALID_MOD, MOD_BASE = 0, 1, 10

# Ordering service level. The median model answers "what will demand be"; an
# order placed at the median is short half the time. SERVICE_Q is the quantile
# the ORDER quantity is placed at, so the order covers demand that often.
SERVICE_Q = 0.85

LAGS = [2, 3, 4, 5, 6, 8, 13, 26]
ROLLS = [4, 13, 26]

CATEGORICAL = [
    "category", "sub_category", "package_size", "single_serve", "vegetarian",
    "vegan", "gluten_free", "province", "region", "store_format",
    "supplier_name", "pandemic_period",
]

BASE_NUMERIC = [
    "week_of_year", "mo", "holidays_in_week", "promos_active_avg",
    "size_g", "price_cad", "calories", "fat_g", "carbs_g", "sugars_g",
    "protein_g", "sodium_mg", "square_feet", "staff_count",
    "case_size", "lead_time_days", "unit_cost", "unit_retail",
]

INVENTORY_HELDOUT = [
    "avg_daily_units", "units_90d", "days_of_supply", "annual_turns", "gmroi",
    "units_sold_total", "sales_total", "reorder_point", "safety_stock",
    "distinct_customers", "premium_sales_pct",
]

FORECAST_DDL = """
CREATE TABLE store_plu_forecast (
    storenumber        INTEGER      NOT NULL,
    plu                VARCHAR(24)  NOT NULL,
    week_seq           INTEGER      NOT NULL,
    week_start         ANSIDATE,
    horizon_weeks      INTEGER      NOT NULL,
    model_version      VARCHAR(40)  NOT NULL,
    predicted_units    DECIMAL(12,3),
    actual_units       DECIMAL(12,3),
    abs_error          DECIMAL(12,3),
    baseline_ma4       DECIMAL(12,3),
    baseline_incumbent DECIMAL(12,3),
    baseline_static    DECIMAL(12,3),
    order_quantile     DECIMAL(12,3),
    velocity_band      VARCHAR(10),
    split_role         VARCHAR(16)  NOT NULL,
    category           VARCHAR(60),
    province           VARCHAR(40),
    suggested_order    INTEGER
)
"""


def _cfg():
    return json.load(open(CONFIG, encoding="utf-8-sig"))


def connect():
    p = _cfg()["db_pos_data"]
    enc = "Encryption Mechanism=ssl;" if str(p.get("encryption", "")).lower() in ("on", "wire", "true", "1") else ""
    cs = (f"Driver={{Actian AC}};Server=@{p['host']},tcp_ip,{p['port']};Database={p['database']};"
          f"UID={p['username']};PWD={p['password']};{enc}")
    return pyodbc.connect(cs, autocommit=True)


def admiral_token(attempts=3, timeout=90):
    import requests
    c = _cfg()
    last = None
    for i in range(attempts):
        try:
            r = requests.post(f"{c['baseUrl']}/login",
                              data={"grant_type": "password", "username": c["username"],
                                    "password": c["password"]}, timeout=timeout)
            r.raise_for_status()
            return r.json()["access_token"]
        except Exception as e:
            last = e
            print(f"  admiral login attempt {i + 1}/{attempts} failed: {type(e).__name__}", flush=True)
            time.sleep(3 * (i + 1))
    raise last


def q(cn, sql):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        df = pd.read_sql(sql, cn)
    df.columns = [c.strip().lower() for c in df.columns]
    for c in df.columns:
        if df[c].dtype == object:
            df[c] = df[c].astype(str).str.strip()
    return df


def load_dims(cn):
    prod = q(cn, """SELECT plu, category, sub_category, package_size, single_serve,
                           vegetarian, vegan, gluten_free, size_g, price_cad,
                           calories, fat_g, carbs_g, sugars_g, protein_g, sodium_mg
                    FROM products""")
    stores = q(cn, """SELECT storenumber, province, region, store_format,
                             square_feet, staff_count FROM stores""")
    inv = q(cn, f"""SELECT storenumber, plu, supplier_name, lead_time_days, case_size,
                           unit_cost, unit_retail, {', '.join(INVENTORY_HELDOUT)}
                    FROM inventory""")
    print(f"  dims: {len(prod)} products, {len(stores)} stores, {len(inv):,} inventory pairs", flush=True)
    return prod, stores, inv


def load_panel(cn, where, label):
    t0 = time.time()
    df = q(cn, f"""SELECT storenumber, plu, week_seq, week_start, yr, mo, week_of_year,
                          holidays_in_week, promos_active_avg, pandemic_period,
                          units, promo_units
                   FROM store_plu_week WHERE {where}""")
    df["week_start"] = pd.to_datetime(df["week_start"])
    print(f"  panel[{label}]: {len(df):,} rows in {time.time() - t0:.0f}s", flush=True)
    return df


def add_lags(df):
    """The panel is dense and week-contiguous per pair, so shift(k) is exactly k
    weeks. Every feature is offset by at least HORIZON."""
    df = df.sort_values(["storenumber", "plu", "week_seq"]).reset_index(drop=True)
    key = [df.storenumber, df.plu]
    g = df.groupby(["storenumber", "plu"], sort=False)["units"]
    for L in LAGS:
        df[f"lag_{L}"] = g.shift(L)
    base = g.shift(HORIZON)
    for w in ROLLS:
        df[f"roll{w}"] = base.groupby(key, sort=False).transform(
            lambda s, w=w: s.rolling(w, min_periods=max(2, w // 4)).mean())
    df["roll13_std"] = base.groupby(key, sort=False).transform(
        lambda s: s.rolling(13, min_periods=4).std())
    # Intermittency: share of zero weeks in the lagged 13-week window. This is
    # what separates a slow mover from a fast one having a bad week.
    isz = (df["units"] == 0).astype(float)
    zb = isz.groupby(key, sort=False).shift(HORIZON)
    df["zero_rate13"] = zb.groupby(key, sort=False).transform(
        lambda s: s.rolling(13, min_periods=4).mean())
    df["promo_lag2"] = df.groupby(["storenumber", "plu"], sort=False)["promo_units"].shift(HORIZON)
    df["trend_ratio"] = df["roll4"] / df["roll13"].replace(0, np.nan)
    return df


def train_period_mean(narrow):
    """Mean weekly units over the TRAINING period only. A velocity band built
    from holdout weeks would leak."""
    return (narrow[narrow.week_seq <= TRAIN_END_WEEK]
            .groupby(["storenumber", "plu"])["units"].mean()
            .rename("mean_units_train").reset_index())


def synth_forward(narrow):
    """Empty rows for the HORIZON weeks after the data ends. Only the target is
    unknown: every lag reaches at least HORIZON weeks into observed data.
    Calendar fields come from the dates themselves. promos_active_avg uses a
    month mean because the planned promo calendar stops with the data."""
    # ONLY pairs still carried in the final week. store_plu_week spans each
    # pair from its first to its last selling week, so a pair that was delisted
    # mid-window still appears earlier in this panel. Ordering stock for a
    # delisted line is worse than not forecasting it at all.
    pairs = narrow.loc[narrow.week_seq == LAST_WEEK, ["storenumber", "plu"]].drop_duplicates()
    anchor = narrow.loc[narrow.week_seq == LAST_WEEK, "week_start"].iloc[0]
    promo_by_mo = narrow.groupby("mo")["promos_active_avg"].mean()
    rows = []
    for h in range(1, HORIZON + 1):
        ws = anchor + pd.Timedelta(days=7 * h)
        f = pairs.copy()
        f["week_seq"] = LAST_WEEK + h
        f["week_start"] = ws
        f["yr"], f["mo"] = ws.year, ws.month
        f["week_of_year"] = int(ws.isocalendar().week)
        # New Year falls inside the first forward week
        f["holidays_in_week"] = 1 if h == 1 else 0
        f["promos_active_avg"] = float(promo_by_mo.get(ws.month, promo_by_mo.mean()))
        f["pandemic_period"] = "Pandemic"
        f["units"] = np.nan
        f["promo_units"] = np.nan
        rows.append(f)
    return pd.concat(rows, ignore_index=True)


def finish(df, vb, prod, stores, inv):
    """Merge dimensions and attach the velocity band, AFTER row filtering."""
    d = (df.merge(prod, on="plu", how="left")
           .merge(stores, on="storenumber", how="left")
           .merge(inv, on=["storenumber", "plu"], how="left")
           .merge(vb, on=["storenumber", "plu"], how="left"))
    d["velocity_band"] = velocity_band(d["mean_units_train"].fillna(0))
    return d


def feature_cols(df):
    lag = [c for c in df.columns if c.startswith(("lag_", "roll", "zero_rate", "promo_lag", "trend_ratio"))]
    return BASE_NUMERIC + lag, CATEGORICAL


def encode(df, cats, mapping=None):
    enc = df.copy()
    if mapping is None:
        mapping = {}
        for c in cats:
            u = pd.Index(sorted(enc[c].astype(str).fillna("None").unique()))
            mapping[c] = {v: i for i, v in enumerate(u)}
    for c in cats:
        enc[c] = enc[c].astype(str).fillna("None").map(mapping[c]).astype("float64")
    return enc, mapping


def velocity_band(mean_units):
    return pd.cut(mean_units, [-np.inf, 2, 10, np.inf], labels=["slow", "medium", "fast"])


def predict_nn(m, X):
    """Unit demand is non-negative -- clip everywhere, evaluation and scoring
    alike, so reported metrics describe the forecast actually written."""
    return np.clip(m.predict(X), 0.0, None)


def score(y, p):
    y = np.asarray(y, float)
    p = np.asarray(p, float)
    d = np.abs(y).sum()
    return {
        "n": int(len(y)),
        "mae": float(mean_absolute_error(y, p)),
        "rmse": float(np.sqrt(mean_squared_error(y, p))),
        "wape": float(np.abs(y - p).sum() / d) if d else float("nan"),
        "r2": float(r2_score(y, p)) if len(y) > 1 else float("nan"),
        "bias": float(np.mean(p - y)),
    }


def banded(y, p, band):
    out = {}
    for b in ("fast", "medium", "slow"):
        m = (band == b).values
        if m.sum():
            out[b] = score(y[m], p[m])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    ap.add_argument("--no-register", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print(f"PLU weekly replenishment forecast -- horizon {HORIZON}w", flush=True)

    cn = connect()
    prod, stores, inv = load_dims(cn)

    # Lags are computed on the NARROW panel and rows filtered BEFORE the
    # dimension merge. Merging 50 columns onto a 6M-row panel first would cost
    # gigabytes for rows that are then discarded.
    lag_floor = TRAIN_END_WEEK - MAX_LAG - 2
    tr_n = load_panel(cn, f"MOD(storenumber, {MOD_BASE}) = {TRAIN_MOD}", "train")
    va_n = load_panel(cn, f"MOD(storenumber, {MOD_BASE}) = {VALID_MOD} AND week_seq >= {lag_floor}",
                      "valid_unseen")

    print("  building features ...", flush=True)
    tr_n, va_n = add_lags(tr_n), add_lags(va_n)
    vb_tr, vb_va = train_period_mean(tr_n), train_period_mean(va_n)
    tr = finish(tr_n[tr_n.roll13.notna()], vb_tr, prod, stores, inv)
    va = finish(va_n[va_n.roll13.notna() & (va_n.week_seq > TRAIN_END_WEEK)], vb_va, prod, stores, inv)
    del tr_n, va_n

    feats, cats = feature_cols(tr)
    enc_tr, mapping = encode(tr, cats)
    enc_va, _ = encode(va, cats, mapping)
    train = enc_tr[enc_tr.week_seq <= TRAIN_END_WEEK]
    seen = enc_tr[enc_tr.week_seq > TRAIN_END_WEEK]
    unseen = enc_va
    print(f"  train {len(train):,} rows / {train.storenumber.nunique()} stores | "
          f"valid_seen {len(seen):,} | valid_unseen {len(unseen):,}", flush=True)

    m = HistGradientBoostingRegressor(
        loss="absolute_error", max_iter=400, learning_rate=0.07,
        max_leaf_nodes=63, min_samples_leaf=60, l2_regularization=1.0,
        early_stopping=True, n_iter_no_change=25, validation_fraction=0.1,
        categorical_features=[c in cats for c in (feats + cats)], random_state=42)
    print("  fitting median model ...", flush=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        m.fit(train[feats + cats], train["units"])

    mq = HistGradientBoostingRegressor(
        loss="quantile", quantile=SERVICE_Q, max_iter=400, learning_rate=0.07,
        max_leaf_nodes=63, min_samples_leaf=60, l2_regularization=1.0,
        early_stopping=True, n_iter_no_change=25, validation_fraction=0.1,
        categorical_features=[c in cats for c in (feats + cats)], random_state=42)
    print(f"  fitting q{SERVICE_Q} order model ...", flush=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        mq.fit(train[feats + cats], train["units"])

    runs = {}
    for name, d in (("valid_seen", seen), ("valid_unseen", unseen)):
        p = predict_nn(m, d[feats + cats])
        y = d["units"].values
        s = score(y, p)
        s["baseline_lag2"] = score(y, np.clip(d["lag_2"].fillna(0), 0, None))
        s["baseline_ma4"] = score(y, np.clip(d["roll4"].fillna(0), 0, None))
        s["baseline_incumbent"] = score(y, np.clip(d["avg_daily_units"].fillna(0) * 7.0, 0, None))
        # The honest static baseline: the same "flat average" policy, but with
        # the average computed ONLY from training weeks -- what the parameter
        # would have been if set at the forecast origin. This is the
        # apples-to-apples comparison the biased incumbent cannot give.
        s["baseline_static_train"] = score(y, np.clip(d["mean_units_train"].fillna(0), 0, None))
        s["beats_static_train"] = bool(s["wape"] < s["baseline_static_train"]["wape"])
        # Service level: how often an order at this quantity covers demand,
        # and how many units short when it does not. This is what a buyer
        # actually cares about -- WAPE does not distinguish over from under.
        pq = predict_nn(mq, d[feats + cats])
        s["order_quantile"] = float(SERVICE_Q)
        s["service_level_median_order"] = float(np.mean(p >= y))
        s["service_level_quantile_order"] = float(np.mean(pq >= y))
        s["units_short_median_order"] = float(np.clip(y - p, 0, None).sum())
        s["units_short_quantile_order"] = float(np.clip(y - pq, 0, None).sum())
        s["by_band"] = banded(y, p, d["velocity_band"])
        s["beats_incumbent"] = bool(s["wape"] < s["baseline_incumbent"]["wape"])
        s["beats_ma4"] = bool(s["wape"] < s["baseline_ma4"]["wape"])
        runs[name] = s
        print(f"  [{name}] WAPE {s['wape']:.4f} MAE {s['mae']:.3f} R2 {s['r2']:.3f} "
              f"| ma4 {s['baseline_ma4']['wape']:.4f} incumbent {s['baseline_incumbent']['wape']:.4f}",
              flush=True)

    sub = unseen.sample(min(120000, len(unseen)), random_state=0)
    basem = mean_absolute_error(sub["units"], predict_nn(m, sub[feats + cats]))
    rng = np.random.default_rng(0)
    imp = []
    for c in feats + cats:
        Xp = sub[feats + cats].copy()
        Xp[c] = rng.permutation(Xp[c].values)
        imp.append({"feature": c,
                    "mae_rise": float(mean_absolute_error(sub["units"], predict_nn(m, Xp)) - basem)})
    imp = sorted(imp, key=lambda r: -r["mae_rise"])[:15]
    del enc_tr, enc_va, tr, va

    # ---------------- score every store ----------------
    fw_n = load_panel(cn, f"week_seq >= {LAST_WEEK - MAX_LAG - 2}", "all_stores")
    vb_all = train_period_mean(fw_n)
    fw_n = pd.concat([fw_n, synth_forward(fw_n)], ignore_index=True)
    fw_n = add_lags(fw_n)
    bt_n = fw_n[(fw_n.week_seq > LAST_WEEK - HORIZON) & (fw_n.week_seq <= LAST_WEEK)]
    fw_only = fw_n[fw_n.week_seq > LAST_WEEK]
    bt = finish(bt_n, vb_all, prod, stores, inv)
    fwd = finish(fw_only, vb_all, prod, stores, inv)
    del fw_n

    for d in (bt, fwd):
        e, _ = encode(d, cats, mapping)
        d["predicted_units"] = predict_nn(m, e[feats + cats])
        # Floor the order quantile at the median forecast. Two independently
        # fitted models can cross, and an order below the point forecast is
        # incoherent regardless of which model produced it.
        d["order_quantile"] = np.maximum(predict_nn(mq, e[feats + cats]), d["predicted_units"])
    bt["actual_units"] = bt["units"]
    fwd["actual_units"] = np.nan
    print(f"  backtest {len(bt):,} pair-weeks | forward {len(fwd):,} pair-weeks "
          f"across {fwd.storenumber.nunique()} stores", flush=True)

    metrics = {
        "model_version": MODEL_VERSION, "horizon_weeks": HORIZON,
        "run_date": str(date.today()), "max_lag_weeks": MAX_LAG,
        "train_rows": int(len(train)), "train_stores": int(train.storenumber.nunique()),
        "holdout_weeks": HOLDOUT_WEEKS, "train_end_week": TRAIN_END_WEEK,
        "dense_panel_rows": 15304087, "zero_week_share": 0.2392,
        "backtest_rows": int(len(bt)), "forward_rows": int(len(fwd)),
        "runs": runs, "importance": imp,
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    try:
        import joblib
        joblib.dump({"median": m, "order": mq, "feats": feats, "cats": cats,
                     "mapping": mapping, "service_q": SERVICE_Q}, HERE / "plu_demand_models.joblib")
        print(f"  wrote {METRICS.name}, {REPORT.name}, plu_demand_models.joblib", flush=True)
    except Exception as e:
        print(f"  wrote {METRICS.name} and {REPORT.name} (joblib skipped: {type(e).__name__})", flush=True)

    if not a.no_mlflow:
        try:
            track(metrics, m, mq, encode(bt.head(500), cats, mapping)[0], feats, cats, a.no_register)
        except Exception as e:
            print(f"  MLFLOW FAILED ({type(e).__name__}: {e}) -- continuing to load", flush=True)

    if not a.no_load:
        load_forecast(cn, to_records(bt, "backtest") + to_records(fwd, "forward"))

    print(f"done in {time.time() - t0:.0f}s", flush=True)


def _f(v, nd=3):
    if v is None:
        return None
    v = float(v)
    return None if np.isnan(v) else round(v, nd)


def to_records(df, role):
    out = []
    for r in df.itertuples(index=False):
        pred = float(getattr(r, "predicted_units"))
        act = _f(getattr(r, "actual_units", None))
        ma4 = _f(getattr(r, "roll4", None))
        adu = getattr(r, "avg_daily_units", None)
        adu = None if adu is None or (isinstance(adu, float) and np.isnan(adu)) else round(float(adu) * 7.0, 3)
        stat = _f(getattr(r, "mean_units_train", None))
        oq = float(getattr(r, "order_quantile"))
        cs = getattr(r, "case_size", None)
        cs = 1 if cs is None or (isinstance(cs, float) and np.isnan(cs)) or int(cs) < 1 else int(cs)
        out.append((
            int(r.storenumber), str(r.plu), int(r.week_seq),
            r.week_start.date() if pd.notna(r.week_start) else None,
            HORIZON, MODEL_VERSION, round(pred, 3), act,
            None if act is None else round(abs(pred - act), 3),
            ma4, adu, stat, round(oq, 3), str(r.velocity_band), role,
            str(r.category), str(r.province),
            int(np.ceil(oq / cs) * cs),
        ))
    return out


def load_forecast(cn, recs, batch=20000):
    cur = cn.cursor()
    cur.execute("DROP TABLE IF EXISTS store_plu_forecast")
    cur.execute(FORECAST_DDL)
    cur.fast_executemany = True
    sql = "INSERT INTO store_plu_forecast VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    n, t0 = 0, time.time()
    for i in range(0, len(recs), batch):
        cur.executemany(sql, recs[i:i + batch])
        n += len(recs[i:i + batch])
        if n % 200000 < batch:
            print(f"    loaded {n:,} ({time.time() - t0:.0f}s)", flush=True)
    cur.execute("CREATE STATISTICS FOR store_plu_forecast")
    print(f"  store_plu_forecast: {n:,} rows loaded in {time.time() - t0:.0f}s", flush=True)


def track(metrics, model, order_model, enc_sample, feats, cats, no_register):
    # Async logging OFF. MLflow 3 queues metric writes and retries a batch on a
    # slow response, which double-inserts and trips the metric_pk unique
    # constraint server-side. The failure then surfaces at flush time rather
    # than at the log_metric call, so a per-call guard cannot catch it.
    os.environ["MLFLOW_ENABLE_ASYNC_LOGGING"] = "false"
    import mlflow
    from mlflow.models import infer_signature
    try:
        mlflow.config.enable_async_logging(False)
    except Exception:
        pass
    os.environ["MLFLOW_TRACKING_TOKEN"] = admiral_token()
    host = _cfg()["db_pos_data"]["host"]
    mlflow.set_tracking_uri(f"https://{host}/mlflow/")
    mlflow.set_experiment(EXPERIMENT)
    with mlflow.start_run(run_name=f"plu-weekly-h{HORIZON}"):
        mlflow.set_tags({"model_version": MODEL_VERSION, "horizon_weeks": HORIZON,
                         "target": "units", "grain": "store x plu x week",
                         "train_sampling": f"storenumber mod {MOD_BASE} = {TRAIN_MOD}",
                         "incumbent_baseline_biased": "avg_daily_units spans the holdout"})
        mlflow.log_params({"horizon_weeks": HORIZON, "lags": str(LAGS), "rolls": str(ROLLS),
                           "max_lag_weeks": MAX_LAG, "loss": "absolute_error", "max_iter": 400,
                           "learning_rate": 0.07, "max_leaf_nodes": 63, "min_samples_leaf": 60,
                           "n_features": len(feats) + len(cats),
                           "train_rows": metrics["train_rows"],
                           "train_stores": metrics["train_stores"]})
        # The model is logged BEFORE the metrics. Metrics are nice to have,
        # the registered artifact is the point, and a metric failure must not
        # take the registration with it.
        sig = infer_signature(enc_sample[feats + cats], predict_nn(model, enc_sample[feats + cats]))
        mlflow.sklearn.log_model(model, name="model", signature=sig,
                                 serialization_format="cloudpickle",
                                 registered_model_name=None if no_register else REGISTERED_NAME)
        if order_model is not None:
            mlflow.sklearn.log_model(order_model, name="order_model", signature=sig,
                                     serialization_format="cloudpickle")
        print("  model logged and registered", flush=True)

        # One metric at a time. A batch insert that the tracking server rejects
        # takes the whole run with it, and a single unloggable value is not
        # worth losing the model registration over.
        def put(k, v):
            try:
                if isinstance(v, (int, float)) and np.isfinite(float(v)):
                    mlflow.log_metric(k[:250], float(v))
            except Exception:
                pass
        for rn, s in metrics["runs"].items():
            for k, v in s.items():
                put(f"{rn}_{k}", v)
            for b in ("baseline_lag2", "baseline_ma4", "baseline_incumbent", "baseline_static_train"):
                for k, v in s[b].items():
                    put(f"{rn}_{b}_{k}", v)
            for band, bs in s["by_band"].items():
                for k, v in bs.items():
                    put(f"{rn}_{band}_{k}", v)
        try:
            mlflow.log_dict({"importance": metrics["importance"]}, "importance.json")
        except Exception:
            pass
    print("  mlflow run logged", flush=True)


def write_report(m):
    out = []
    A = out.append
    A("# PLU weekly replenishment forecast report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}, horizon {m['horizon_weeks']} weeks, "
      "grain store x PLU x week.\n")
    A(f"Dense panel {m['dense_panel_rows']:,} pair-weeks, {m['zero_week_share']:.1%} of them zero. "
      f"Trained on {m['train_rows']:,} rows from {m['train_stores']} stores "
      f"(storenumber mod {MOD_BASE} = {TRAIN_MOD}), weeks 0 to {m['train_end_week']}. "
      f"Holdout is the final {m['holdout_weeks']} weeks.\n")
    A("Every lag and rolling feature is offset by at least the horizon. Max lag "
      f"{m['max_lag_weeks']} weeks -- there is no 52-week lag, because 104 weeks of history "
      "gives each pair exactly one prior observation, and the store-day model showed "
      "single-year seasonality to be fragile. week_of_year carries seasonality instead.\n")
    A("## Accuracy against baselines\n")
    A("valid_unseen is the honest number -- those stores were never trained on.\n")
    A("| Split | n | WAPE | MAE | R2 | Bias | lag2 | ma4 | static(train) | incumbent(biased) | "
      "Beats ma4 | Beats static |")
    A("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k, s in m["runs"].items():
        A(f"| {k} | {s['n']:,} | {s['wape']:.4f} | {s['mae']:.3f} | {s['r2']:.3f} | {s['bias']:+.3f} | "
          f"{s['baseline_lag2']['wape']:.4f} | {s['baseline_ma4']['wape']:.4f} | "
          f"{s['baseline_static_train']['wape']:.4f} | {s['baseline_incumbent']['wape']:.4f} | "
          f"{'yes' if s['beats_ma4'] else 'NO'} | {'yes' if s['beats_static_train'] else 'NO'} |")
    A("\nThe incumbent baseline is inventory.avg_daily_units x 7, the static parameter behind "
      "reorder_point today. It is optimistically biased: that average spans the whole period, "
      "holdout weeks included, so it has seen the future.\n")
    A("## By velocity band, valid_unseen\n")
    A("| Band | n | WAPE | MAE | Bias |")
    A("|---|---|---|---|---|")
    for b, s in m["runs"]["valid_unseen"]["by_band"].items():
        A(f"| {b} | {s['n']:,} | {s['wape']:.4f} | {s['mae']:.3f} | {s['bias']:+.3f} |")
    A("\nBands come from mean weekly units in the TRAINING period only: "
      "fast >= 10, medium 2 to 10, slow < 2.\n")
    A("## Permutation importance, valid_unseen (MAE rise when shuffled)\n")
    A("| Feature | MAE rise |")
    A("|---|---|")
    for r in m["importance"]:
        A(f"| {r['feature']} | {r['mae_rise']:.4f} |")
    A("\n## Output\n")
    A(f"store_plu_forecast holds {m['backtest_rows']:,} backtest rows (the last "
      f"{m['horizon_weeks']} whole weeks, with actuals, so the table can be verified in SQL) "
      f"and {m['forward_rows']:,} forward rows (the {m['horizon_weeks']} weeks after the data "
      "ends, no actuals). Each row carries both baselines, the velocity band, and "
      "suggested_order -- the prediction rounded up to a whole case using inventory.case_size, "
      "which is what an ordering system would actually send.\n")
    REPORT.write_text("\n".join(out), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
