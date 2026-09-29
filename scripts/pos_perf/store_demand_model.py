"""store_demand_model.py -- train, validate and score the store-day demand
forecast, track every run in the warehouse MLflow, then load
store_day_forecast back into the pos_data warehouse.

The problem
  Forecast daily sales (and optionally transactions or visitors) for each of
  the 330 stores at a 14-day horizon, so that labour scheduling and store
  ordering have a number to work against.

Why a 14-day gap on every lag
  A forecast is only useful if it can be produced before the day it predicts.
  Every lag and rolling feature here is offset by at least HORIZON days, so a
  row dated D uses nothing observed after D - HORIZON. That makes the model a
  direct 14-step-ahead forecaster: one model, no recursive error compounding,
  and forward scoring needs no imputed history.

Pandemic-aware validation
  2019 and 2020 are different regimes. March 2020 sales ran 49 percent above
  March 2019 on only 12 percent more transactions -- basket size, not footfall.
  April 2020 had FEWER transactions than April 2019 and 50 percent more
  revenue. A model fitted blindly across both learns a regime that ended.
  So three runs are logged, not one:
    main          train <= TRAIN_END, holdout the final HOLDOUT_DAYS.
                  pandemic_period is an explicit feature.
    pandemic_only train on the pandemic era only, same holdout. Tests whether
                  pre-COVID history helps or hurts.
    regime_shift  train pre-pandemic only, evaluate ON the pandemic era.
                  A diagnostic, never shipped -- it quantifies the damage of
                  ignoring the break.
  main and pandemic_only compete on holdout WAPE. The winner is retrained on
  all data and becomes the production model.

Baselines
  Every run is scored against two naive forecasters: lag-14 persistence and
  the same-weekday mean of the four prior same weekdays (also lagged 14).
  A learned model that cannot beat both is not worth deploying, and the run
  is flagged as such rather than quietly registered.

Gaps and closures
  store_traffic covers 229,595 of a possible 241,230 store-days. Two causes:
  scattered non-trading days inside a store's life, and roughly a dozen stores
  that opened or closed mid-window. Each store is reindexed onto a complete
  daily spine between ITS OWN first and last observed day. Filled days get
  target 0 for the sole purpose of computing lags -- they never become
  training or evaluation rows. Forward scoring covers only stores still
  trading on the last day of data.

Forward scoring assumptions
  Data ends 2020-12-31, so the forward window is 2021-01-01 to 2021-01-14 and
  has no actuals. Two inputs are unknown there and are stated as assumptions
  in the run tags:
    weather       per-province day-of-year climatology from the two years of
                  history. Production would swap in a forecast feed.
    promos_active per (month, day-of-week) mean from history. Production would
                  read the planned promo calendar.
  Calendar flags for the window are mapped from the same month-day in prior
  years, which resolves New Year's Day correctly.

Usage
  python scripts/pos_perf/store_demand_model.py                 # full run
  python scripts/pos_perf/store_demand_model.py --no-load       # no write-back
  python scripts/pos_perf/store_demand_model.py --no-mlflow     # skip tracking
  python scripts/pos_perf/store_demand_model.py --target target_transactions

Requires: store_day_features (see build_store_day_features.sql).
Outputs
  warehouse table store_day_forecast
  MLflow experiment pos-store-day-demand, registered model store-day-demand
  scripts/pos_perf/store_demand_metrics.json
  scripts/pos_perf/store_demand_report.md
"""

import argparse
import json
import os
import sys
import time
import warnings
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
import pyodbc
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

# mlflow writes emoji to stdout on run end and the Windows console is cp1252.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parents[1] / ".claude" / "skills" / "admiral" / "admiral.config.json"
REPORT = HERE / "store_demand_report.md"
METRICS = HERE / "store_demand_metrics.json"

MODEL_VERSION = "store-day-demand-v1"
EXPERIMENT = "pos-store-day-demand"
REGISTERED_NAME = "store-day-demand"
MLFLOW_PATH = "/mlflow/"

HORIZON = 14
HOLDOUT_DAYS = 57            # 2020-11-05 .. 2020-12-31
DATA_END = date(2020, 12, 31)
PANDEMIC_START = date(2020, 3, 1)

LAGS = [14, 21, 28, 35, 364]
ROLL_WINDOWS = [7, 28, 91]

CATEGORICAL = [
    "province", "region", "store_format", "wx_condition", "pandemic_period",
    "is_weekend", "is_holiday", "holiday_name", "fsa_urban_flag",
]

# Structural / calendar / exogenous columns carried straight from the table.
BASE_NUMERIC = [
    "mo", "day_of_month", "day_of_year", "quarter", "week_of_year", "dow_num",
    "promos_active", "square_feet", "staff_count", "latitude", "longitude",
    "temp_high_c", "temp_low_c", "rain_mm", "snow_cm",
    "fsa_population", "fsa_households", "fsa_median_income",
    "fsa_avg_household_size", "fsa_median_age", "fsa_pct_families",
    "fsa_pct_seniors", "fsa_pct_french", "fsa_pct_owner", "fsa_unemployment",
    "fsa_pct_movers", "stores_in_fsa", "competitor_count_5km",
]

FORECAST_DDL = """
CREATE TABLE store_day_forecast (
    storenumber        INTEGER      NOT NULL,
    forecast_date      ANSIDATE     NOT NULL,
    origin_date        ANSIDATE     NOT NULL,
    horizon_days       INTEGER      NOT NULL,
    model_version      VARCHAR(40)  NOT NULL,
    target_name        VARCHAR(30)  NOT NULL,
    predicted          DECIMAL(14,2),
    actual             DECIMAL(14,2),
    abs_error          DECIMAL(14,2),
    baseline_lag14     DECIMAL(14,2),
    split_role         VARCHAR(16)  NOT NULL,
    province           VARCHAR(40),
    region             VARCHAR(40),
    store_format       VARCHAR(40)
)
"""


# --------------------------------------------------------------------------
# connection + mlflow auth
# --------------------------------------------------------------------------

def _cfg():
    return json.load(open(CONFIG, encoding="utf-8-sig"))


def connect():
    p = _cfg()["db_pos_data"]
    enc = "Encryption Mechanism=ssl;" if str(p.get("encryption", "")).lower() in ("on", "wire", "true", "1") else ""
    cs = (f"Driver={{Actian AC}};Server=@{p['host']},tcp_ip,{p['port']};Database={p['database']};"
          f"UID={p['username']};PWD={p['password']};{enc}")
    return pyodbc.connect(cs, autocommit=True)


def admiral_token(attempts=3, timeout=90):
    """OAuth2 password grant against Admiral. Same JWT the ML apps accept.
    Stage login occasionally exceeds 30s, so retry rather than lose the run."""
    import requests
    c = _cfg()
    last = None
    for i in range(attempts):
        try:
            r = requests.post(f"{c['baseUrl']}/login",
                              data={"grant_type": "password", "username": c["username"],
                                    "password": c["password"]},
                              timeout=timeout)
            r.raise_for_status()
            return r.json()["access_token"]
        except Exception as e:
            last = e
            print(f"  admiral login attempt {i + 1}/{attempts} failed: {type(e).__name__}", flush=True)
            time.sleep(3 * (i + 1))
    raise last


def mlflow_uri():
    host = _cfg()["db_pos_data"]["host"]
    return f"https://{host}{MLFLOW_PATH}"


# --------------------------------------------------------------------------
# data
# --------------------------------------------------------------------------

def load_features(cn):
    print("  reading store_day_features ...", flush=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        df = pd.read_sql("SELECT * FROM store_day_features", cn)
    df.columns = [c.strip().lower() for c in df.columns]
    for c in ("calendar_date", "store_open_date"):
        df[c] = pd.to_datetime(df[c])
    for c in df.columns:
        if df[c].dtype == object:
            df[c] = df[c].astype(str).str.strip()
    print(f"  {len(df):,} rows, {df.storenumber.nunique()} stores, "
          f"{df.calendar_date.min().date()} .. {df.calendar_date.max().date()}", flush=True)
    return df


def build_spine(df, target):
    """Per-store daily spine between that store's own first and last observed
    day. Filled days carry observed=False and target 0 -- lags only."""
    out = []
    for sn, g in df.groupby("storenumber", sort=False):
        g = g.sort_values("calendar_date")
        idx = pd.date_range(g.calendar_date.min(), g.calendar_date.max(), freq="D")
        g = g.set_index("calendar_date").reindex(idx)
        g["observed"] = g["storenumber"].notna()
        g["storenumber"] = sn
        g[target] = g[target].fillna(0.0)
        g.index.name = "calendar_date"
        out.append(g.reset_index())
    s = pd.concat(out, ignore_index=True)
    filled = int((~s.observed).sum())
    print(f"  spine {len(s):,} rows ({filled:,} filled non-trading days, lags only)", flush=True)
    return s


def add_lag_features(df, target):
    """Every feature offset by >= HORIZON days. Groupby-shift on a complete
    daily spine, so shift(k) is exactly k calendar days."""
    df = df.sort_values(["storenumber", "calendar_date"]).reset_index(drop=True)
    g = df.groupby("storenumber", sort=False)[target]

    for L in LAGS:
        df[f"lag_{L}"] = g.shift(L)

    base = g.shift(HORIZON)
    for w in ROLL_WINDOWS:
        df[f"roll{w}_lag{HORIZON}"] = (
            base.groupby(df.storenumber, sort=False)
                .transform(lambda s, w=w: s.rolling(w, min_periods=max(2, w // 4)).mean())
        )
    df[f"rollstd28_lag{HORIZON}"] = (
        base.groupby(df.storenumber, sort=False)
            .transform(lambda s: s.rolling(28, min_periods=7).std())
    )

    # Same-weekday history: mean of the 4 prior same weekdays. 14/21/28/35 are
    # all multiples of 7, so each lands on the same weekday and each is >= HORIZON.
    dow_lags = [g.shift(k) for k in (14, 21, 28, 35)]
    df["samedow_mean4"] = pd.concat(dow_lags, axis=1).mean(axis=1)

    # Momentum: recent level against a longer level, both lagged.
    df["trend_ratio"] = df[f"roll7_lag{HORIZON}"] / df[f"roll28_lag{HORIZON}"].replace(0, np.nan)
    df["store_age_days"] = (df.calendar_date - df.store_open_date).dt.days
    return df


def feature_columns(df):
    lagcols = [c for c in df.columns if c.startswith(("lag_", "roll", "samedow", "trend_ratio"))]
    return BASE_NUMERIC + ["store_age_days"] + lagcols, CATEGORICAL


def encode(df, cats):
    """Ordinal codes for HistGradientBoosting native categorical support."""
    enc = df.copy()
    mapping = {}
    for c in cats:
        u = pd.Index(sorted(enc[c].astype(str).unique()))
        mapping[c] = {v: i for i, v in enumerate(u)}
        enc[c] = enc[c].astype(str).map(mapping[c]).astype("float64")
    return enc, mapping


# --------------------------------------------------------------------------
# metrics
# --------------------------------------------------------------------------

def predict_nn(m, X):
    """Sales, transactions and visitors are all non-negative. A quantile-style
    absolute_error objective can still emit small negatives for stores whose
    recent history sits near zero (reopening or barely trading). Clipping at
    zero is applied EVERYWHERE predictions are produced -- evaluation and
    scoring alike -- so the reported metrics describe the forecast that is
    actually written to the warehouse, not an unclipped one."""
    return np.clip(m.predict(X), 0.0, None)


def score(y, p):
    y = np.asarray(y, dtype=float)
    p = np.asarray(p, dtype=float)
    denom = np.abs(y).sum()
    nz = y != 0
    return {
        "n": int(len(y)),
        "mae": float(mean_absolute_error(y, p)),
        "rmse": float(np.sqrt(mean_squared_error(y, p))),
        "wape": float(np.abs(y - p).sum() / denom) if denom else float("nan"),
        "mape": float(np.mean(np.abs((y[nz] - p[nz]) / y[nz]))) if nz.any() else float("nan"),
        "r2": float(r2_score(y, p)) if len(y) > 1 else float("nan"),
        "bias": float(np.mean(p - y)),
    }


def fit_predict(tr, va, feats, cats, target, seed=42):
    Xtr, Xva = tr[feats + cats], va[feats + cats]
    cat_mask = [c in cats for c in (feats + cats)]
    m = HistGradientBoostingRegressor(
        loss="absolute_error", max_iter=500, learning_rate=0.06,
        max_leaf_nodes=63, min_samples_leaf=40, l2_regularization=1.0,
        early_stopping=True, n_iter_no_change=30, validation_fraction=0.1,
        categorical_features=cat_mask, random_state=seed,
    )
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        m.fit(Xtr, tr[target])
    return m, predict_nn(m, Xva)


def permutation_importance(m, va, feats, cats, target, n=12, seed=0):
    rng = np.random.default_rng(seed)
    X = va[feats + cats]
    base = mean_absolute_error(va[target], predict_nn(m, X))
    out = []
    for c in (feats + cats):
        Xp = X.copy()
        Xp[c] = rng.permutation(Xp[c].values)
        out.append({"feature": c, "mae_rise": float(mean_absolute_error(va[target], predict_nn(m, Xp)) - base)})
    return sorted(out, key=lambda r: -r["mae_rise"])[:n]


# --------------------------------------------------------------------------
# forward window
# --------------------------------------------------------------------------

def build_forward(hist, target):
    """Rows for DATA_END+1 .. DATA_END+HORIZON for stores still trading."""
    active = hist.groupby("storenumber").calendar_date.max()
    active = active[active == pd.Timestamp(DATA_END)].index
    dates = [DATA_END + timedelta(days=i) for i in range(1, HORIZON + 1)]

    stat_cols = ["province", "region", "store_format", "square_feet", "staff_count",
                 "latitude", "longitude", "store_open_date", "fsa_urban_flag",
                 "fsa_population", "fsa_households", "fsa_median_income",
                 "fsa_avg_household_size", "fsa_median_age", "fsa_pct_families",
                 "fsa_pct_seniors", "fsa_pct_french", "fsa_pct_owner",
                 "fsa_unemployment", "fsa_pct_movers", "stores_in_fsa",
                 "competitor_count_5km"]
    stat = (hist[hist.storenumber.isin(active)]
            .sort_values("calendar_date").groupby("storenumber")[stat_cols].last().reset_index())

    # weather climatology per province x day-of-year
    hist = hist.copy()
    hist["doy"] = hist.calendar_date.dt.dayofyear
    wx = (hist.groupby(["province", "doy"])[["temp_high_c", "temp_low_c", "rain_mm", "snow_cm"]]
          .mean().reset_index())
    wxmode = (hist.groupby(["province", "doy"])["wx_condition"]
              .agg(lambda s: s.mode().iat[0] if len(s.mode()) else "Clear").reset_index())
    # planned promo proxy: mean by month x weekday
    hist["dw"] = hist.calendar_date.dt.dayofweek
    promo = hist.groupby(["mo", "dw"])["promos_active"].mean().reset_index()
    # calendar flags mapped from the same month-day in prior years
    cal = (hist.assign(md=hist.calendar_date.dt.strftime("%m-%d"))
           .groupby("md")[["is_holiday", "holiday_name"]].agg(lambda s: s.mode().iat[0] if len(s.mode()) else s.iloc[0]))

    rows = []
    for d in dates:
        f = stat.copy()
        ts = pd.Timestamp(d)
        f["calendar_date"] = ts
        f["mo"], f["day_of_month"] = ts.month, ts.day
        f["day_of_year"], f["quarter"] = ts.dayofyear, ts.quarter
        f["week_of_year"] = int(ts.isocalendar().week)
        f["dow_num"] = ts.dayofweek + 1
        f["dw"] = ts.dayofweek
        f["doy"] = ts.dayofyear
        f["is_weekend"] = "Y" if ts.dayofweek >= 5 else "N"
        md = ts.strftime("%m-%d")
        f["is_holiday"] = cal.at[md, "is_holiday"] if md in cal.index else "N"
        f["holiday_name"] = cal.at[md, "holiday_name"] if md in cal.index else "None"
        f["pandemic_period"] = "Pandemic"
        f["observed"] = False
        f[target] = np.nan
        rows.append(f)
    fw = pd.concat(rows, ignore_index=True)
    fw = fw.merge(wx, on=["province", "doy"], how="left").merge(wxmode, on=["province", "doy"], how="left")
    fw = fw.merge(promo, on=["mo", "dw"], how="left")
    return fw.drop(columns=["doy", "dw"]), sorted(active.tolist())


# --------------------------------------------------------------------------
# write-back
# --------------------------------------------------------------------------

def load_forecast(cn, recs, batch=20000):
    cur = cn.cursor()
    cur.execute("DROP TABLE IF EXISTS store_day_forecast")
    cur.execute(FORECAST_DDL)
    cur.fast_executemany = True
    sql = "INSERT INTO store_day_forecast VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    t0 = 0
    for i in range(0, len(recs), batch):
        cur.executemany(sql, recs[i:i + batch])
        t0 += len(recs[i:i + batch])
    cur.execute("CREATE STATISTICS FOR store_day_forecast")
    print(f"  store_day_forecast: {t0:,} rows loaded", flush=True)
    return t0


def _f(v):
    if v is None:
        return None
    v = float(v)
    return None if np.isnan(v) else round(v, 2)


def to_records(df, target, split_role, origin):
    out = []
    for r in df.itertuples(index=False):
        pred, act = _f(getattr(r, "predicted")), _f(getattr(r, "actual", None))
        out.append((
            int(r.storenumber), r.calendar_date.date(), origin, HORIZON,
            MODEL_VERSION, target, pred, act,
            None if (pred is None or act is None) else round(abs(pred - act), 2),
            _f(getattr(r, "lag_14", None)), split_role,
            str(r.province), str(r.region), str(r.store_format),
        ))
    return out


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="target_sales",
                    choices=["target_sales", "target_transactions", "target_visitors"])
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    ap.add_argument("--no-register", action="store_true")
    a = ap.parse_args()
    target = a.target
    t_start = time.time()

    print(f"store-day demand forecast -- target {target}, horizon {HORIZON}d", flush=True)
    cn = connect()
    raw = load_features(cn)

    spine = build_spine(raw, target)
    spine = add_lag_features(spine, target)
    feats, cats = feature_columns(spine)
    spine[cats] = spine[cats].fillna("None")

    holdout_start = pd.Timestamp(DATA_END - timedelta(days=HOLDOUT_DAYS - 1))
    train_end = holdout_start - timedelta(days=1)
    pand_start = pd.Timestamp(PANDEMIC_START)

    model_rows = spine[spine.observed & spine[f"roll28_lag{HORIZON}"].notna()].copy()
    print(f"  modelling rows {len(model_rows):,} (observed, with lag history)", flush=True)

    enc, mapping = encode(model_rows, cats)
    holdout = enc[enc.calendar_date >= holdout_start]
    runs, models = {}, {}

    specs = {
        "main":          enc[enc.calendar_date <= train_end],
        "pandemic_only": enc[(enc.calendar_date <= train_end) & (enc.calendar_date >= pand_start)],
    }
    for name, tr in specs.items():
        print(f"  [{name}] train {len(tr):,} -> holdout {len(holdout):,}", flush=True)
        m, p = fit_predict(tr, holdout, feats, cats, target)
        s = score(holdout[target], p)
        s["baseline_lag14"] = score(holdout[target], holdout["lag_14"].fillna(holdout[target].mean()))
        s["baseline_samedow"] = score(holdout[target], holdout["samedow_mean4"].fillna(holdout[target].mean()))
        s["beats_baselines"] = bool(s["wape"] < s["baseline_lag14"]["wape"] and s["wape"] < s["baseline_samedow"]["wape"])
        s["importance"] = permutation_importance(m, holdout, feats, cats, target)
        runs[name], models[name] = s, m
        print(f"      WAPE {s['wape']:.4f}  MAE {s['mae']:,.0f}  R2 {s['r2']:.3f}  "
              f"| lag14 {s['baseline_lag14']['wape']:.4f}  samedow {s['baseline_samedow']['wape']:.4f}", flush=True)

    # regime-shift diagnostic: pre-pandemic training, pandemic evaluation
    pre = enc[enc.calendar_date < pand_start]
    pan = enc[enc.calendar_date >= pand_start]
    m_rs, p_rs = fit_predict(pre, pan, feats, cats, target)
    rs = score(pan[target], p_rs)
    rs["baseline_lag14"] = score(pan[target], pan["lag_14"].fillna(pan[target].mean()))
    runs["regime_shift"] = rs
    print(f"  [regime_shift] pre-pandemic model on pandemic era: WAPE {rs['wape']:.4f} "
          f"(lag14 {rs['baseline_lag14']['wape']:.4f})", flush=True)

    winner = min(("main", "pandemic_only"), key=lambda k: runs[k]["wape"])
    print(f"  winner: {winner}", flush=True)
    if not runs[winner]["beats_baselines"]:
        print("  WARNING: winning model does not beat both naive baselines", flush=True)

    # production model: winner's recipe retrained through the last day of data
    prod_tr = enc if winner == "main" else enc[enc.calendar_date >= pand_start]
    prod, _ = fit_predict(prod_tr, holdout.head(1), feats, cats, target)

    # forward window
    fw, active = build_forward(raw, target)
    hist_tail = spine[spine.calendar_date > pd.Timestamp(DATA_END) - timedelta(days=400)]
    comb = pd.concat([hist_tail, fw], ignore_index=True, sort=False)
    comb = add_lag_features(comb, target)
    comb[cats] = comb[cats].fillna("None")
    for c in cats:
        comb[c] = comb[c].astype(str).map(mapping[c]).astype("float64")
    fwe = comb[comb.calendar_date > pd.Timestamp(DATA_END)].copy()
    fwe["predicted"] = predict_nn(prod, fwe[feats + cats])
    fwe["actual"] = np.nan
    print(f"  forward: {len(fwe):,} rows, {len(active)} active stores, "
          f"{(DATA_END + timedelta(days=1))} .. {DATA_END + timedelta(days=HORIZON)}", flush=True)

    # holdout rows carry actuals so the table supports error reporting
    hv = model_rows[model_rows.calendar_date >= holdout_start].copy()
    hv["predicted"] = predict_nn(models[winner], holdout[feats + cats])
    hv["actual"] = hv[target]

    metrics = {
        "model_version": MODEL_VERSION, "target": target, "horizon_days": HORIZON,
        "run_date": str(date.today()), "winner": winner,
        "train_rows": int(len(specs[winner])), "holdout_rows": int(len(holdout)),
        "holdout_start": str(holdout_start.date()), "data_end": str(DATA_END),
        "active_stores": len(active), "runs": runs,
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics)
    try:
        import joblib
        joblib.dump({"prod": prod, "winner": winner, "feats": feats, "cats": cats,
                     "mapping": mapping}, HERE / "store_demand_model.joblib")
        print(f"  wrote {METRICS.name}, {REPORT.name}, store_demand_model.joblib", flush=True)
    except Exception as e:
        print(f"  wrote {METRICS.name} and {REPORT.name} (joblib skipped: {type(e).__name__})", flush=True)

    if not a.no_mlflow:
        try:
            track(metrics, models, winner, prod, enc, feats, cats, a.no_register)
        except Exception as e:
            print(f"  MLFLOW FAILED ({type(e).__name__}: {e}) -- continuing to load", flush=True)

    if not a.no_load:
        recs = (to_records(hv, target, "holdout", DATA_END)
                + to_records(fwe, target, "forward", DATA_END))
        load_forecast(cn, recs)

    print(f"done in {time.time() - t_start:.0f}s", flush=True)


def track(metrics, models, winner, prod, enc, feats, cats, no_register):
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
    uri = mlflow_uri()
    mlflow.set_tracking_uri(uri)
    print(f"  mlflow -> {uri}", flush=True)
    mlflow.set_experiment(EXPERIMENT)

    def put(k, v):
        """One metric at a time, guarded. A rejected batch insert takes the
        whole run with it, and no single value is worth that."""
        try:
            if isinstance(v, (int, float)) and np.isfinite(float(v)):
                mlflow.log_metric(k[:250], float(v))
        except Exception:
            pass

    for name, s in metrics["runs"].items():
        with mlflow.start_run(run_name=f"{metrics['target']}-{name}"):
            mlflow.set_tags({
                "split": name, "target": metrics["target"],
                "horizon_days": HORIZON, "model_version": MODEL_VERSION,
                "is_winner": str(name == winner),
                "diagnostic_only": str(name == "regime_shift"),
                "weather_source": "history" if name != "forward" else "climatology",
                "data_end": str(DATA_END),
            })
            mlflow.log_params({
                "horizon_days": HORIZON, "lags": str(LAGS), "roll_windows": str(ROLL_WINDOWS),
                "loss": "absolute_error", "max_iter": 500, "learning_rate": 0.06,
                "max_leaf_nodes": 63, "min_samples_leaf": 40, "l2_regularization": 1.0,
                "n_features": len(feats) + len(cats), "split": name,
            })

            # The model is logged BEFORE the metrics. Metrics are nice to have,
            # the registered artifact is the point, and a metric failure must
            # not take the registration with it.
            if name == winner:
                sig = infer_signature(enc[feats + cats].head(200),
                                      predict_nn(prod, enc[feats + cats].head(200)))
                # cloudpickle, not the mlflow 3 skops default: HistGradientBoosting
                # references functools.partial and sklearn.utils.validation.check_array,
                # which skops refuses to serialise as untrusted types.
                mlflow.sklearn.log_model(
                    prod, name="model", signature=sig,
                    serialization_format="cloudpickle",
                    registered_model_name=None if no_register else REGISTERED_NAME,
                )
                print("  model logged and registered", flush=True)

            for k, v in s.items():
                put(f"{k}", v)
            for b in ("baseline_lag14", "baseline_samedow"):
                if b in s:
                    for k, v in s[b].items():
                        put(f"{b}_{k}", v)
            if "importance" in s:
                try:
                    mlflow.log_dict({"importance": s["importance"]}, "importance.json")
                except Exception:
                    pass
    print("  mlflow runs logged", flush=True)


def write_report(m):
    L = []
    A = L.append
    A("# Store-day demand forecast report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}, target {m['target']}, "
      f"horizon {m['horizon_days']} days.\n")
    A(f"Training rows {m['train_rows']:,}. Holdout {m['holdout_rows']:,} rows from "
      f"{m['holdout_start']} to {m['data_end']} (out-of-time). Winner: **{m['winner']}**.\n")
    A("Every lag and rolling feature is offset by at least the horizon, so no row uses "
      "information from inside its own forecast window.\n")
    A("## Holdout accuracy against naive baselines\n")
    A("| Run | n | WAPE | MAE | RMSE | R2 | Bias | lag-14 WAPE | same-dow WAPE | Beats both |")
    A("|---|---|---|---|---|---|---|---|---|---|")
    for k in ("main", "pandemic_only"):
        s = m["runs"][k]
        A(f"| {k} | {s['n']:,} | {s['wape']:.4f} | {s['mae']:,.0f} | {s['rmse']:,.0f} | "
          f"{s['r2']:.3f} | {s['bias']:,.0f} | {s['baseline_lag14']['wape']:.4f} | "
          f"{s['baseline_samedow']['wape']:.4f} | {'yes' if s['beats_baselines'] else 'NO'} |")
    rs = m["runs"]["regime_shift"]
    A("\n## Regime-shift diagnostic\n")
    A("Trained on pre-pandemic days only, evaluated on the pandemic era. Never shipped -- "
      "it measures what ignoring the 2020 break would cost.\n")
    A(f"| n | WAPE | MAE | R2 | lag-14 WAPE |")
    A("|---|---|---|---|---|")
    A(f"| {rs['n']:,} | {rs['wape']:.4f} | {rs['mae']:,.0f} | {rs['r2']:.3f} | {rs['baseline_lag14']['wape']:.4f} |")
    A("\n## Permutation importance, winning run (MAE rise when shuffled)\n")
    A("| Feature | MAE rise |")
    A("|---|---|")
    for r in m["runs"][m["winner"]]["importance"]:
        A(f"| {r['feature']} | {r['mae_rise']:,.1f} |")
    A(f"\n## Forward window\n")
    A(f"{m['active_stores']} stores still trading on {m['data_end']} are scored for the "
      f"{m['horizon_days']} days that follow. Weather uses per-province day-of-year "
      "climatology and promos_active uses a month-by-weekday mean, because neither is "
      "known past the end of the data. Production would read a weather feed and the "
      "planned promo calendar instead.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
