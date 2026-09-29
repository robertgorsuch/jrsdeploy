"""pos_ml_common.py -- shared plumbing for the POS model family.

Everything here was learned the hard way building the store-day and PLU weekly
demand forecasts. It is factored out so the remaining models inherit the fixes
rather than rediscovering them.

MLflow gotchas encoded in track_run()
  async logging OFF   MLflow 3 queues metric writes and retries a batch on a
                      slow response, which double-inserts and trips the server
                      metric_pk unique constraint. The failure surfaces at
                      flush time, not at the log_metric call, so a per-call
                      guard cannot catch it.
  model logged FIRST  metrics are nice to have, the registered artifact is the
                      point, and a metric failure must not take it down.
  cloudpickle         the mlflow 3 skops default refuses sklearn estimators
                      that reference functools.partial or check_array.
  per-metric guard    one unloggable value must not abort a run.
  non-finite filter   NaN and inf are dropped rather than sent.

SQL gotchas
  The sql.ps1 run-file splitter has no comment awareness, so a semicolon or an
  unbalanced apostrophe inside a SQL comment silently breaks statement
  splitting. check_sql_comments() catches that before a file is ever run.
  The schema is "robert.gorsuch" -- a dot in the name, so it needs quoting when
  qualified, though unqualified names resolve as the connecting user.

Modelling conventions
  predict_nn   every target in this family is non-negative, so predictions are
               clipped at zero EVERYWHERE -- evaluation and scoring alike, so
               reported metrics describe the artefact that is actually written.
  score        WAPE is the headline, not MAPE: several of these targets are
               intermittent and MAPE is undefined on a zero actual.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

import numpy as np
import pyodbc
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parents[1] / ".claude" / "skills" / "admiral" / "admiral.config.json"

OWNER = "robert.gorsuch@actian.com"
TEAM = "Actian POS Analytics"
DATA_END_STR = "2020-12-31"


def cfg():
    return json.load(open(CONFIG, encoding="utf-8-sig"))


def connect():
    p = cfg()["db_pos_data"]
    enc = "Encryption Mechanism=ssl;" if str(p.get("encryption", "")).lower() in ("on", "wire", "true", "1") else ""
    cs = (f"Driver={{Actian AC}};Server=@{p['host']},tcp_ip,{p['port']};Database={p['database']};"
          f"UID={p['username']};PWD={p['password']};{enc}")
    return pyodbc.connect(cs, autocommit=True)


def admiral_token(attempts=3, timeout=90):
    """Stage login occasionally exceeds 30s, so retry rather than lose a run."""
    import requests
    c = cfg()
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
    """Query to a tidy DataFrame: lowercase columns, stripped strings."""
    import warnings

    import pandas as pd
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        df = pd.read_sql(sql, cn)
    df.columns = [c.strip().lower() for c in df.columns]
    for c in df.columns:
        if df[c].dtype == object:
            df[c] = df[c].astype(str).str.strip()
    return df


def check_sql_comments(path):
    """The run-file splitter treats an apostrophe in a comment as the start of a
    string literal and then swallows the next semicolons. Fail loudly here
    rather than debug a mangled DROP statement later."""
    bad = []
    for i, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        st = line.strip()
        if st.startswith("--"):
            if "'" in st:
                bad.append((i, "apostrophe", st[:70]))
            if ";" in st:
                bad.append((i, "semicolon", st[:70]))
    if bad:
        for i, kind, txt in bad:
            print(f"  SQL COMMENT {kind} at line {i}: {txt}", flush=True)
        raise SystemExit(f"{path}: {len(bad)} comment(s) would break the statement splitter")
    return True


# --------------------------------------------------------------------------
# modelling helpers
# --------------------------------------------------------------------------

def predict_nn(m, X):
    """Clip at zero. Every target in this family is non-negative, and an
    absolute-error or quantile objective can still emit small negatives."""
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


def clf_score(y, p):
    """Binary classification, reported the way a decision-maker reads it."""
    from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score
    y = np.asarray(y, int)
    p = np.asarray(p, float)
    out = {"n": int(len(y)), "positive_rate": float(y.mean())}
    try:
        out["auc_roc"] = float(roc_auc_score(y, p))
        out["auc_pr"] = float(average_precision_score(y, p))
        out["brier"] = float(brier_score_loss(y, p))
    except Exception:
        out["auc_roc"] = out["auc_pr"] = out["brier"] = float("nan")
    k = max(1, len(y) // 10)
    top = np.argsort(-p)[:k]
    out["top_decile_lift"] = float(y[top].mean() / y.mean()) if y.mean() > 0 else float("nan")
    return out


def encode(df, cats, mapping=None):
    """Ordinal codes for HistGradientBoosting native categorical support."""
    import pandas as pd
    enc = df.copy()
    if mapping is None:
        mapping = {}
        for c in cats:
            u = pd.Index(sorted(enc[c].astype(str).fillna("None").unique()))
            mapping[c] = {v: i for i, v in enumerate(u)}
    for c in cats:
        enc[c] = enc[c].astype(str).fillna("None").map(mapping[c]).astype("float64")
    return enc, mapping


def permutation_importance(model, df, feats, cats, target, predict=None, n=15, sample=100000, seed=0):
    predict = predict or (lambda m, X: predict_nn(m, X))
    sub = df.sample(min(sample, len(df)), random_state=seed) if len(df) > sample else df
    X = sub[feats + cats]
    base = mean_absolute_error(sub[target], predict(model, X))
    rng = np.random.default_rng(seed)
    out = []
    for c in feats + cats:
        Xp = X.copy()
        Xp[c] = rng.permutation(Xp[c].values)
        out.append({"feature": c, "mae_rise": float(mean_absolute_error(sub[target], predict(model, Xp)) - base)})
    return sorted(out, key=lambda r: -r["mae_rise"])[:n]


# --------------------------------------------------------------------------
# warehouse write-back
# --------------------------------------------------------------------------

def recreate_and_load(cn, table, ddl, records, batch=20000):
    cur = cn.cursor()
    cur.execute(f"DROP TABLE IF EXISTS {table}")
    cur.execute(ddl)
    cur.fast_executemany = True
    ncols = len(records[0]) if records else 0
    sql = f"INSERT INTO {table} VALUES ({','.join(['?'] * ncols)})"
    n, t0 = 0, time.time()
    for i in range(0, len(records), batch):
        cur.executemany(sql, records[i:i + batch])
        n += len(records[i:i + batch])
        if n % 200000 < batch and n > batch:
            print(f"    loaded {n:,} ({time.time() - t0:.0f}s)", flush=True)
    cur.execute(f"CREATE STATISTICS FOR {table}")
    print(f"  {table}: {n:,} rows loaded in {time.time() - t0:.0f}s", flush=True)
    return n


def f(v, nd=4):
    """Float for pyodbc binding: numpy scalars and NaN are not bindable."""
    if v is None:
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return None if not np.isfinite(v) else round(v, nd)


# --------------------------------------------------------------------------
# mlflow
# --------------------------------------------------------------------------

def track_run(experiment, run_name, params, metrics, model=None, model_name=None,
              sample_X=None, tags=None, dicts=None, extra_models=None, predict=None):
    """One tracked run with every MLflow gotcha handled. Returns the run id, or
    None if tracking failed -- callers continue to their write-back regardless."""
    os.environ["MLFLOW_ENABLE_ASYNC_LOGGING"] = "false"
    import mlflow
    from mlflow.models import infer_signature
    try:
        mlflow.config.enable_async_logging(False)
    except Exception:
        pass
    os.environ["MLFLOW_TRACKING_TOKEN"] = admiral_token()
    host = cfg()["db_pos_data"]["host"]
    mlflow.set_tracking_uri(f"https://{host}/mlflow/")
    mlflow.set_experiment(experiment)
    predict = predict or (lambda m, X: predict_nn(m, X))

    def put(k, v):
        try:
            if isinstance(v, (int, float)) and np.isfinite(float(v)):
                mlflow.log_metric(str(k)[:250], float(v))
        except Exception:
            pass

    def walk(prefix, obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                walk(f"{prefix}_{k}" if prefix else str(k), v)
        elif isinstance(obj, (int, float)):
            put(prefix, obj)

    with mlflow.start_run(run_name=run_name) as run:
        base_tags = {"owner": OWNER, "team": TEAM, "data_end": DATA_END_STR}
        mlflow.set_tags({**base_tags, **(tags or {})})
        try:
            mlflow.log_params({k: str(v)[:500] for k, v in params.items()})
        except Exception as e:
            print(f"    param logging failed: {type(e).__name__}", flush=True)

        # model first -- metric noise must not cost the registration
        if model is not None and sample_X is not None:
            try:
                sig = infer_signature(sample_X, predict(model, sample_X))
                mlflow.sklearn.log_model(model, name="model", signature=sig,
                                         serialization_format="cloudpickle",
                                         registered_model_name=model_name)
                for nm, em in (extra_models or {}).items():
                    mlflow.sklearn.log_model(em, name=nm, signature=sig,
                                             serialization_format="cloudpickle")
                print("    model logged and registered", flush=True)
            except Exception as e:
                print(f"    MODEL LOGGING FAILED: {type(e).__name__}: {e}", flush=True)

        walk("", metrics)
        for name, d in (dicts or {}).items():
            try:
                mlflow.log_dict(d, name)
            except Exception:
                pass
        return run.info.run_id


def safe_track(*a, **k):
    try:
        rid = track_run(*a, **k)
        print("  mlflow run logged", flush=True)
        return rid
    except Exception as e:
        print(f"  MLFLOW FAILED ({type(e).__name__}: {e}) -- continuing", flush=True)
        return None
