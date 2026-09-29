"""churn_model.py -- train, validate and score the POS churn models, then load
customer_churn_scores back into the pos_data warehouse.

Pipeline
  1. Pull a customer-hash sample of churn_training_set over ODBC (Actian AC
     driver, connection from admiral.config.json "db_pos_data" -- never on
     the command line, never printed).
  2. Fit a BG/NBD model (Fader, Hardie and Lee 2005) by maximum likelihood on
     the BG/NBD inputs at one cutoff, and compute P(alive) for every row.
     This is the no-demographics baseline.
  3. Train a gradient-boosted classifier (sklearn HistGradientBoosting) on
     churn_adaptive with behavioural + demographic + context features and
     bgnbd_p_alive as an input. Validation is out-of-time AND out-of-customer:
     train = hash buckets 0-5, cutoffs <= 2020-06-30
     valid = hash buckets 6-7, cutoffs 2020-07-31 .. 2020-09-30.
     Reports AUC-ROC, AUC-PR, top-decile lift, Brier and a calibration table
     for three scorers: overdue_ratio heuristic, BG/NBD, GBM.
  4. Train the activation model (second purchase within 90 days of the first)
     on activation_training_set, validated out-of-time on first_jdn.
  5. Score the 2020-12-31 snapshot (is_scoring_row = Y) with the churn model
     and every current one-time buyer with the activation model. Attach risk
     band, revenue at risk, three driver codes and a recommended action.
  6. Recreate customer_churn_scores (HASH on customer_id, 16 partitions), load
     the scores in batches, and refresh customers.churn_risk_band.

Usage
  python scripts/pos_perf/churn_model.py            # full run
  python scripts/pos_perf/churn_model.py --no-load  # train + validate only
  python scripts/pos_perf/churn_model.py --sample-pct 4 --score-buckets 2

Outputs
  scripts/pos_perf/churn_model_report.md   metrics, feature importance
  scripts/pos_perf/churn_model_metrics.json
Driver codes are a transparent z-score x importance attribution, not SHAP:
the three features that pull this customer furthest toward churn relative
to the population, in the direction the model learned.
"""

import argparse
import json
import math
import sys
import time
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import pyodbc
from scipy.optimize import minimize
from scipy.special import gammaln
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parent.parent / ".claude" / "skills" / "admiral" / "admiral.config.json"
MODEL_VERSION = "churn-gbm-v1"
ACT_VERSION = "activation-gbm-v1"
SCORE_DATE = date(2020, 12, 31)

ID_COLS = ["as_of_date", "as_of_yyyymm", "customer_id", "is_scoring_row"]
LABEL_COLS = ["churn_90", "churn_adaptive", "next_purchase_days", "censored_after_days"]
# High-cardinality or leaky columns kept out of the model. loyalty_tier,
# categories_bought, distinct_plus and flagged_coverage_pct are LIFETIME
# quantities as of 2020-12-31 -- for an earlier cutoff they encode the future
# (a first run with loyalty_tier in scored 0.35 AUC-drop importance, the
# signature of a leak). favorite_category stays: categorical composition,
# mild. The diet shares (pct) are lifetime compositions, accepted as mild.
EXCLUDE = set(ID_COLS + LABEL_COLS + [
    "home_store_number", "churn_horizon_days", "as_of_jdn",
    "loyalty_tier", "categories_bought", "distinct_plus", "flagged_coverage_pct",
])
CATEGORICAL = [
    "pandemic_period", "province", "home_region", "email_opt_in", "loyalty_tier",
    "favorite_category", "age_band", "gender", "household_income_band", "life_stage",
    "children_flag", "dwelling_type", "tenure_type", "language_pref", "employment_status",
    "education_level", "acquisition_channel", "demographics_consent", "diet_profile",
    "basket_profile", "fsa_urban_flag", "store_format",
]
ACT_CATEGORICAL = [
    "is_weekend", "is_holiday", "pandemic_period", "first_promo_flag", "first_ecommerce_flag",
    "province", "home_region", "favorite_category", "age_band", "gender",
    "household_income_band", "life_stage", "dwelling_type", "language_pref",
    "acquisition_channel", "fsa_urban_flag", "store_format",
]
ACT_EXCLUDE = {"customer_id", "first_purchase_date", "first_jdn", "days_since_first",
               "first_store_number", "days_to_second", "activated_90", "is_one_time",
               "favorite_category"}  # favorite_category is lifetime-derived: leaks activation

DRIVER_LABELS = {
    "overdue_ratio": "Overdue vs own cadence",
    "days_since_last": "Days since last purchase",
    "trend_ratio_l90": "Visit frequency falling",
    "sales_trend_ratio_l90": "Spend falling",
    "purchase_days_l90": "Few visits last 90 days",
    "purchase_days_l30": "No recent visits",
    "bgnbd_p_alive": "Low P(alive) BG/NBD",
    "min_csat_l180": "Poor service experience",
    "cases_l180": "Service cases opened",
    "ecommerce_late_l180": "Late deliveries",
    "promo_share_l180": "Promo dependent",
    "redemption_rate_l180": "Loyalty redemption drop",
    "email_open_rate_l180": "Email disengaged",
    "competitor_count_5km": "Competitors nearby",
    "store_traffic_trend_l90": "Home store traffic falling",
    "home_store_share_l180": "Store loyalty eroding",
    "ipt_last_asof": "Last gap longer than usual",
    "tenure_days": "Short tenure",
    "sales_l90": "Low recent spend",
    "returns_l180": "Returns",
    "vegetarian_pct": "Plant-forward basket mix",
    "single_serve_pct": "Single-serve basket mix",
    "prepared_meals_pct": "Ready-meal basket mix",
    "vegan_pct": "Plant-based basket mix",
    "gluten_free_pct": "Gluten-free basket mix",
    "ipt_max_asof": "Longest gap on record",
    "ipt_median_asof": "Slow buying cadence",
    "ipt_mean_asof": "Slow buying cadence",
    "avg_categories_l180": "Narrow basket mix",
    "avg_items_l180": "Small baskets",
    "avg_basket_asof": "Small baskets",
    "sales_asof": "Low lifetime spend",
    "purchase_days_asof": "Few purchases to date",
    "purchase_days_l180": "Few visits last 180 days",
    "baskets_asof": "Few purchases to date",
    "bgnbd_recency": "Long since first purchase",
    "bgnbd_t": "Long since first purchase",
    "store_sales_per_sqft": "Low-traffic home store",
    "store_margin_pct": "Home store margin",
    "fsa_median_income": "Neighbourhood income",
    "distinct_stores_l180": "Shops around",
    "margin_l180": "Low recent margin",
    "margin_l90": "Low recent margin",
    "sales_l180": "Low recent spend",
    "sales_l30": "No spend last 30 days",
    "discount_l180": "Discount driven",
    "points_earned_l180": "Few loyalty points earned",
    "emails_sent_l180": "Low email reach",
    "weekend_txns_l180": "Weekend shopper",
    "household_size": "Household size",
    "fsa_penetration_pct": "Low-penetration area",
    "fsa_pct_families": "Neighbourhood family mix",
    "fsa_median_age": "Neighbourhood age",
    "stores_in_fsa": "Store density",
    "store_square_feet": "Home store size",
    "store_staff_count": "Home store staffing",
}


# ---------------------------------------------------------------- connection

def connect():
    cfg = json.load(open(CONFIG))
    p = cfg["db_pos_data"]
    enc = "Encryption Mechanism=ssl;" if str(p.get("encryption", "")).lower() in ("on", "wire", "true", "1") else ""
    cs = (f"Driver={{Actian AC}};Server=@{p['host']},tcp_ip,{p['port']};Database={p['database']};"
          f"UID={p['username']};PWD={p['password']};{enc}")
    return pyodbc.connect(cs, autocommit=True)


def column_types(cn, table):
    cur = cn.cursor()
    cur.execute("SELECT TRIM(column_name), TRIM(column_datatype) FROM iicolumns "
                "WHERE table_name = ? AND table_owner = 'robert.gorsuch' ORDER BY column_sequence", table)
    return [(c, t.upper()) for c, t in cur.fetchall()]


def select_list(cols):
    out = []
    for c, t in cols:
        if t in ("DECIMAL", "INTEGER", "FLOAT", "SMALLINT", "BIGINT"):
            out.append(f"FLOAT8({c}) AS {c}")
        else:
            out.append(c)
    return ", ".join(out)


def fetch_df(cn, sql, cols, log_label, chunk=100000):
    """Stream the result set in chunks and type each chunk immediately, so the
    peak memory is one chunk of Python objects plus the compact frame."""
    t0 = time.time()
    cur = cn.cursor()
    cur.execute(sql)
    names = [c for c, _ in cols]
    numeric = [c for c, t in cols if t in ("DECIMAL", "INTEGER", "FLOAT", "SMALLINT", "BIGINT")]
    dates = [c for c, t in cols if t == "ANSIDATE"]
    parts = []
    while True:
        rows = cur.fetchmany(chunk)
        if not rows:
            break
        part = pd.DataFrame.from_records([tuple(r) for r in rows], columns=names)
        for c in numeric:
            part[c] = pd.to_numeric(part[c], errors="coerce").astype("float32")
        for c in dates:
            part[c] = pd.to_datetime(part[c])
        parts.append(part)
        del rows
    df = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(columns=names)
    print(f"  {log_label}: {len(df):,} rows x {df.shape[1]} cols in {time.time() - t0:.0f}s", flush=True)
    return df


# ---------------------------------------------------------------- BG/NBD

def bgnbd_negll(params, x, t_x, T):
    r, alpha, a, b = np.exp(params)  # positivity via log-parametrisation
    A1 = gammaln(r + x) - gammaln(r) + r * np.log(alpha)
    A2 = gammaln(a + b) + gammaln(b + x) - gammaln(b) - gammaln(a + b + x)
    A3 = -(r + x) * np.log(alpha + T)
    with np.errstate(divide="ignore", invalid="ignore"):
        A4 = np.where(x > 0, np.log(a) - np.log(b + x - 1) - (r + x) * np.log(alpha + t_x), -np.inf)
    ll = A1 + A2 + np.logaddexp(A3, A4)
    return -np.sum(ll)


def bgnbd_fit(x, t_x, T):
    x0 = np.log([1.0, 10.0, 1.0, 3.0])
    res = minimize(bgnbd_negll, x0, args=(x, t_x, T), method="Nelder-Mead",
                   options={"maxiter": 4000, "xatol": 1e-6, "fatol": 1e-6})
    return dict(zip(["r", "alpha", "a", "b"], np.exp(res.x))), res.fun


def bgnbd_p_alive(params, x, t_x, T):
    r, alpha, a, b = params["r"], params["alpha"], params["a"], params["b"]
    with np.errstate(divide="ignore", invalid="ignore", over="ignore"):
        ratio = np.where(x > 0, (a / (b + x - 1)) * ((alpha + T) / (alpha + t_x)) ** (r + x), 0.0)
    return 1.0 / (1.0 + ratio)


# ---------------------------------------------------------------- metrics

def top_decile_lift(y, p):
    n = len(y)
    k = max(1, n // 10)
    idx = np.argsort(-p)[:k]
    return float(y[idx].mean() / max(y.mean(), 1e-9))


def calibration_table(y, p, bins=10):
    q = pd.qcut(pd.Series(p), bins, labels=False, duplicates="drop")
    g = pd.DataFrame({"y": y, "p": p, "q": q}).groupby("q").agg(n=("y", "size"), pred=("p", "mean"), actual=("y", "mean"))
    return g.reset_index()


def evaluate(name, y, p):
    y = np.asarray(y, dtype=float)
    p = np.asarray(p, dtype=float)
    m = {
        "scorer": name,
        "n": int(len(y)),
        "positive_rate": float(y.mean()),
        "auc_roc": float(roc_auc_score(y, p)),
        "auc_pr": float(average_precision_score(y, p)),
        "top_decile_lift": top_decile_lift(y, p),
        "brier": float(brier_score_loss(y, np.clip(p, 0, 1))),
    }
    print(f"  {name:<22} AUC-ROC {m['auc_roc']:.4f}  AUC-PR {m['auc_pr']:.4f}  "
          f"lift@10% {m['top_decile_lift']:.2f}  Brier {m['brier']:.4f}  (n={m['n']:,}, pos={m['positive_rate']:.3f})", flush=True)
    return m


# ---------------------------------------------------------------- feature prep

class Encoder:
    """Ordinal-encodes categorical columns with a mapping learned once, so the
    same integer codes are used at training and scoring time. Unseen values
    become NaN, which HistGradientBoosting treats as missing."""

    def __init__(self, categorical, exclude):
        self.categorical = set(categorical)
        self.exclude = set(exclude)
        self.feats = None
        self.maps = {}

    def fit(self, df):
        self.feats = [c for c in df.columns if c not in self.exclude]
        for c in self.feats:
            if c in self.categorical:
                vals = sorted(v for v in df[c].dropna().astype(str).unique())
                self.maps[c] = {v: i for i, v in enumerate(vals)}
        return self

    def transform(self, df):
        X = pd.DataFrame(index=df.index)
        for c in self.feats:
            if c in self.maps:
                X[c] = df[c].astype(str).map(self.maps[c]).astype("float32")
            else:
                X[c] = pd.to_numeric(df[c], errors="coerce").astype("float32")
        return X

    def cat_mask(self):
        return [c in self.maps for c in self.feats]


def train_gbm(X, y, cat_mask, seed=7):
    clf = HistGradientBoostingClassifier(
        learning_rate=0.06, max_iter=400, max_leaf_nodes=31, min_samples_leaf=200,
        l2_regularization=1.0, early_stopping=True, validation_fraction=0.1,
        n_iter_no_change=25, categorical_features=cat_mask, random_state=seed,
    )
    clf.fit(X, y)
    return clf


def importance(clf, X, y, enc, n=25000, seed=3):
    """Permutation importance on a subsample (AUC drop), plus direction (corr with label)."""
    rng = np.random.default_rng(seed)
    idx = rng.choice(len(X), size=min(n, len(X)), replace=False)
    Xs, ys = X.iloc[idx].reset_index(drop=True), np.asarray(y)[idx]
    base = roc_auc_score(ys, clf.predict_proba(Xs)[:, 1])
    rows = []
    for f in enc.feats:
        Xp = Xs.copy()
        Xp[f] = Xp[f].sample(frac=1.0, random_state=seed).values
        drop = base - roc_auc_score(ys, clf.predict_proba(Xp)[:, 1])
        if f in enc.maps:
            direction = 0.0
        else:
            v = Xs[f].astype(float).values
            if np.all(np.isnan(v)) or np.nanstd(v) == 0:
                direction = 0.0
            else:
                direction = float(np.nan_to_num(np.corrcoef(np.nan_to_num(v, nan=np.nanmedian(v)), ys)[0, 1]))
        rows.append({"feature": f, "auc_drop": float(drop), "direction": direction})
    return pd.DataFrame(rows).sort_values("auc_drop", ascending=False).reset_index(drop=True)


def driver_codes(X, imp, stats, k=3, top_features=18):
    """Per-row top-k drivers: z-score of numeric feature (population median/sd from
    the training sample) x importance, signed toward churn. Vectorised."""
    cand = imp[(imp.auc_drop > 0) & (imp.direction != 0)].head(top_features)
    names, mats = [], []
    for r in cand.itertuples():
        med, sd = stats[r.feature]
        v = X[r.feature].astype(float).values
        z = np.nan_to_num((v - med) / (sd if sd > 0 else 1.0), nan=0.0)
        mats.append(np.clip(z * np.sign(r.direction), -4, 4) * r.auc_drop)
        names.append(DRIVER_LABELS.get(r.feature, r.feature.replace("_", " ")))
    if not mats:
        return [["", "", ""]] * len(X)
    M = np.vstack(mats).T
    order = np.argsort(-M, axis=1)[:, :k]
    names_arr = np.array(names, dtype=object)
    picked = np.where(np.take_along_axis(M, order, axis=1) > 0, names_arr[order], "")
    return picked.tolist()


def feature_stats(X, imp, top_features=18):
    cand = imp[(imp.auc_drop > 0) & (imp.direction != 0)].head(top_features)
    return {r.feature: (float(np.nanmedian(X[r.feature])), float(np.nanstd(X[r.feature]))) for r in cand.itertuples()}


def risk_band(p):
    return np.select([p >= 0.70, p >= 0.45, p >= 0.25], ["Critical", "High", "Watch"], default="Low")


def recommended_action(df, p, band):
    cases = df.get("cases_l180", pd.Series(0, index=df.index)).fillna(0).values
    csat = df.get("min_csat_l180", pd.Series(np.nan, index=df.index)).values
    promo = df.get("promo_share_l180", pd.Series(0, index=df.index)).fillna(0).values
    earned = df.get("points_earned_l180", pd.Series(0, index=df.index)).fillna(0).values
    redeem = df.get("redemption_rate_l180", pd.Series(0, index=df.index)).fillna(0).values
    late = df.get("ecommerce_late_l180", pd.Series(0, index=df.index)).fillna(0).values
    hot = np.isin(band, ["High", "Critical"])
    return np.select(
        [hot & (cases > 0) & (np.nan_to_num(csat, nan=5) <= 2),
         hot & (late > 0),
         hot & (promo >= 50),
         hot & (earned > 0) & (redeem < 5),
         hot],
        ["Service follow-up", "Delivery recovery", "Win-back offer", "Loyalty bonus", "Win-back offer"],
        default="None")


# ---------------------------------------------------------------- load scores

SCORES_DDL = """
CREATE TABLE customer_churn_scores (
  customer_id VARCHAR(20) NOT NULL,
  score_date ANSIDATE NOT NULL,
  model_version VARCHAR(24) NOT NULL,
  churn_probability DECIMAL(6,4),
  risk_band VARCHAR(8),
  expected_ltv_at_risk DECIMAL(12,2),
  bgnbd_p_alive DECIMAL(6,4),
  overdue_ratio DECIMAL(8,2),
  lifecycle_status VARCHAR(8),
  driver_1 VARCHAR(32),
  driver_2 VARCHAR(32),
  driver_3 VARCHAR(32),
  recommended_action VARCHAR(24)
) WITH PARTITION = (HASH ON customer_id 16 PARTITIONS)
"""


def existing_scores(cn):
    cur = cn.cursor()
    try:
        cur.execute("SELECT model_version, COUNT(*) FROM customer_churn_scores GROUP BY model_version")
        return {m: int(n) for m, n in cur.fetchall()}
    except pyodbc.Error:
        return {}


def load_scores(cn, frames, batch=20000, append=False):
    cur = cn.cursor()
    if not append:
        cur.execute("DROP TABLE IF EXISTS customer_churn_scores")
        cur.execute(SCORES_DDL)
    cur.fast_executemany = True
    sql = "INSERT INTO customer_churn_scores VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
    total, t0 = 0, time.time()
    for recs in frames:
        for i in range(0, len(recs), batch):
            cur.executemany(sql, recs[i:i + batch])
            total += len(recs[i:i + batch])
            if total % 200000 < batch:
                print(f"    loaded {total:,} rows ({time.time() - t0:.0f}s)", flush=True)
    print(f"  customer_churn_scores: {total:,} rows loaded in {time.time() - t0:.0f}s", flush=True)
    cur.execute("UPDATE customer_churn_scores FROM customers c SET lifecycle_status = c.lifecycle_status "
                "WHERE customer_churn_scores.customer_id = c.customer_id")
    cur.execute("CREATE STATISTICS FOR customer_churn_scores")
    cur.execute("UPDATE customers SET churn_risk_band = NULL")
    cur.execute("UPDATE customers FROM customer_churn_scores s SET churn_risk_band = s.risk_band "
                "WHERE customers.customer_id = s.customer_id AND s.model_version = ?", MODEL_VERSION)
    cur.execute("UPDATE customers FROM customer_churn_scores s SET churn_risk_band = s.risk_band "
                "WHERE customers.customer_id = s.customer_id AND s.model_version = ? AND customers.churn_risk_band IS NULL", ACT_VERSION)
    print("  customers.churn_risk_band refreshed", flush=True)


def _num(v):
    return None if v is None or (isinstance(v, float) and math.isnan(v)) else float(v)


def to_records(df, model_version, p, band, ltv, palive, drivers, action):
    """Native-typed tuples for pyodbc (numpy scalars are not bindable)."""
    ids = df["customer_id"].astype(str).tolist()
    p = np.round(np.asarray(p, dtype=float), 4).tolist()
    ltv = np.round(np.asarray(ltv, dtype=float), 2).tolist()
    pal = [None] * len(ids) if palive is None else np.round(np.asarray(palive, dtype=float), 4).tolist()
    odr = df["overdue_ratio"].astype(float).tolist() if "overdue_ratio" in df else [None] * len(ids)
    lcs = df["lifecycle_status"].tolist() if "lifecycle_status" in df else [None] * len(ids)
    band = [str(b) for b in band]
    action = [str(a) for a in action]
    return [
        (ids[i], SCORE_DATE, model_version, _num(p[i]), band[i], _num(ltv[i]), _num(pal[i]),
         _num(odr[i]), (None if lcs[i] is None else str(lcs[i])),
         drivers[i][0] or None, drivers[i][1] or None, drivers[i][2] or None, action[i])
        for i in range(len(ids))
    ]


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample-pct", type=int, default=8, help="customer hash buckets (of 100) pulled for training+validation")
    ap.add_argument("--score-buckets", type=int, default=20, help="hash buckets (of 20) to score; 20 = everyone")
    ap.add_argument("--no-load", action="store_true", help="train and validate only, do not write scores")
    ap.add_argument("--resume", action="store_true",
                    help="keep customer_churn_scores rows already loaded; only (re)build the model versions that are missing")
    args = ap.parse_args()

    t_all = time.time()
    metrics = {"model_version": MODEL_VERSION, "run_date": str(date.today()), "sample_pct": args.sample_pct}
    cn = connect()
    cols = column_types(cn, "churn_training_set")
    sel = select_list(cols)
    train_buckets = int(args.sample_pct * 0.75)
    have = existing_scores(cn) if args.resume else {}
    skip_churn = args.resume and have.get(MODEL_VERSION, 0) > 0
    skip_act = args.resume and have.get(ACT_VERSION, 0) > 0
    if args.resume:
        print(f"[resume] existing score rows: {have}  skip_churn={skip_churn} skip_act={skip_act}", flush=True)
    if skip_churn:
        return resume_activation_only(cn, args, skip_act, t_all)

    # ---- 1. pull sample -------------------------------------------------
    print("[1] pulling training sample", flush=True)
    sql = (f"SELECT {sel}, MOD(ABS(HASH(customer_id + 'cv')), 100) AS bucket FROM churn_training_set "
           f"WHERE is_scoring_row = 'N' AND churn_adaptive IS NOT NULL "
           f"AND MOD(ABS(HASH(customer_id + 'cv')), 100) < {args.sample_pct}")
    df = fetch_df(cn, sql, cols + [("bucket", "INTEGER")], "sample")
    df["lifecycle_status"] = None

    # ---- 2. BG/NBD ----------------------------------------------------------
    print("[2] fitting BG/NBD on cutoff 2020-06-30 (weeks)", flush=True)
    fit_rows = df[(df.as_of_date == "2020-06-30") & (df.bucket < train_buckets)]
    x = fit_rows.bgnbd_frequency.values.astype(float)
    t_x = fit_rows.bgnbd_recency.values.astype(float) / 7.0
    T = fit_rows.bgnbd_t.values.astype(float) / 7.0
    params, nll = bgnbd_fit(x, t_x, T)
    print(f"  params r={params['r']:.3f} alpha={params['alpha']:.3f} a={params['a']:.3f} b={params['b']:.3f}  (n={len(x):,}, nll={nll:,.0f})", flush=True)
    metrics["bgnbd_params"] = params
    df["bgnbd_p_alive"] = bgnbd_p_alive(params, df.bgnbd_frequency.values.astype(float),
                                        df.bgnbd_recency.values.astype(float) / 7.0,
                                        df.bgnbd_t.values.astype(float) / 7.0).astype("float32")

    # ---- 3. GBM -------------------------------------------------------------
    print("[3] training churn GBM (label = churn_adaptive)", flush=True)
    exclude = EXCLUDE | {"bucket", "lifecycle_status"}
    enc = Encoder(CATEGORICAL, exclude).fit(df)
    X = enc.transform(df)
    feats = enc.feats
    y = df.churn_adaptive.values.astype(int)
    is_train = ((df.bucket < train_buckets) & (df.as_of_date <= "2020-06-30")).values
    is_valid = ((df.bucket >= train_buckets) & (df.as_of_date > "2020-06-30")).values
    print(f"  train rows {is_train.sum():,}  valid rows {is_valid.sum():,}  features {len(feats)}", flush=True)
    clf = train_gbm(X[is_train], y[is_train], enc.cat_mask())
    metrics["gbm_iterations"] = int(clf.n_iter_)
    pv = clf.predict_proba(X[is_valid])[:, 1]
    yv = y[is_valid]
    print("  validation (out-of-time, out-of-customer):", flush=True)
    res = [
        evaluate("overdue_ratio", yv, np.nan_to_num(df.loc[is_valid, "overdue_ratio"].values.astype(float), nan=0)),
        evaluate("bgnbd_1_minus_palive", yv, 1 - df.loc[is_valid, "bgnbd_p_alive"].values.astype(float)),
        evaluate("gbm", yv, pv),
    ]
    # churn_90 as a secondary check with the same model
    m90 = is_valid & df.churn_90.notna().values
    res.append(evaluate("gbm_vs_churn_90", df.loc[m90, "churn_90"].values.astype(int), clf.predict_proba(X[m90])[:, 1]))
    # by tier
    for tier in ["Platinum", "Gold", "Silver", "Bronze"]:
        mt = is_valid & (df.loyalty_tier.values == tier)
        if mt.sum() > 500 and 0 < y[mt].mean() < 1:
            res.append(evaluate(f"gbm_{tier}", y[mt], clf.predict_proba(X[mt])[:, 1]))
    metrics["validation"] = res
    metrics["calibration"] = calibration_table(yv, pv).to_dict(orient="records")
    print("[3b] permutation importance", flush=True)
    imp = importance(clf, X[is_valid].reset_index(drop=True), yv, enc)
    stats = feature_stats(X[is_train], imp)
    metrics["importance"] = imp.head(30).to_dict(orient="records")
    print("  top 12: " + ", ".join(f"{r.feature} ({r.auc_drop:.4f})" for r in imp.head(12).itertuples()), flush=True)

    # ---- 4. activation model -------------------------------------------------
    aclf, aenc, acols, asel, aimp = train_activation(cn, args, metrics)

    write_report(metrics, imp, aimp)
    if args.no_load:
        print(f"done (no load) in {time.time() - t_all:.0f}s")
        return

    # ---- 5. score + 6. load --------------------------------------------------
    print("[5] scoring 2020-12-31 snapshot", flush=True)
    frames = []
    for b in range(args.score_buckets):
        sdf = fetch_df(cn, f"SELECT {sel} FROM churn_training_set WHERE is_scoring_row = 'Y' "
                           f"AND MOD(ABS(HASH(customer_id + 'sc')), 20) = {b}", cols, f"score bucket {b}")
        if not len(sdf):
            continue
        sdf["bgnbd_p_alive"] = bgnbd_p_alive(params, sdf.bgnbd_frequency.values.astype(float),
                                             sdf.bgnbd_recency.values.astype(float) / 7.0,
                                             sdf.bgnbd_t.values.astype(float) / 7.0).astype("float32")
        sdf["bucket"] = np.nan
        sdf["lifecycle_status"] = None
        SX = enc.transform(sdf)
        p = clf.predict_proba(SX)[:, 1]
        band = risk_band(p)
        ltv = p * np.nan_to_num(sdf.margin_l180.values.astype(float), nan=0) * 2.0  # trailing-12-month margin proxy
        drivers = driver_codes(SX, imp, stats)
        action = recommended_action(sdf, p, band)
        frames.append(to_records(sdf, MODEL_VERSION, p, band, ltv, sdf.bgnbd_p_alive.values, drivers, action))
        del sdf, SX
    frames.extend(score_activation(cn, args, aclf, aenc, acols, asel))
    print("[6] loading customer_churn_scores", flush=True)
    load_scores(cn, frames)
    cn.close()
    print(f"done in {time.time() - t_all:.0f}s")


def train_activation(cn, args, metrics):
    print("[4] training activation GBM (label = activated_90)", flush=True)
    acols = column_types(cn, "activation_training_set")
    asel = select_list(acols)
    adf = fetch_df(cn, f"SELECT {asel} FROM activation_training_set WHERE activated_90 IS NOT NULL "
                       f"AND MOD(ABS(HASH(customer_id + 'av')), 100) < {args.sample_pct}", acols, "activation sample")
    aenc = Encoder(ACT_CATEGORICAL, ACT_EXCLUDE).fit(adf)
    AX = aenc.transform(adf)
    ay = adf.activated_90.values.astype(int)
    split_jdn = float(np.quantile(adf.first_jdn.values, 0.75))
    a_train = adf.first_jdn.values < split_jdn
    a_valid = ~a_train
    aclf = train_gbm(AX[a_train], ay[a_train], aenc.cat_mask())
    ares = evaluate("activation_gbm", ay[a_valid], aclf.predict_proba(AX[a_valid])[:, 1])
    ares["split_first_jdn"] = split_jdn
    metrics["activation"] = ares
    aimp = importance(aclf, AX[a_valid].reset_index(drop=True), ay[a_valid], aenc)
    metrics["activation_importance"] = aimp.head(20).to_dict(orient="records")
    print("  top 8: " + ", ".join(f"{r.feature} ({r.auc_drop:.4f})" for r in aimp.head(8).itertuples()), flush=True)
    return aclf, aenc, acols, asel, aimp


def score_activation(cn, args, aclf, aenc, acols, asel):
    print("[5b] scoring one-time buyers with the activation model", flush=True)
    frames = []
    for b in range(args.score_buckets):
        odf = fetch_df(cn, f"SELECT {asel} FROM activation_training_set WHERE is_one_time = 'Y' "
                           f"AND MOD(ABS(HASH(customer_id + 'sc')), 20) = {b}", acols, f"activation bucket {b}")
        if not len(odf):
            continue
        OX = aenc.transform(odf)
        p = 1.0 - aclf.predict_proba(OX)[:, 1]
        band = risk_band(p)
        ltv = p * np.nan_to_num(odf.first_basket_margin.values.astype(float), nan=0)
        drivers = [["Single purchase so far", "", ""]] * len(odf)
        action = np.where(odf.days_since_first.values <= 90, "Second-buy nudge", "None")
        odf["overdue_ratio"] = np.nan
        odf["lifecycle_status"] = "One-time"
        frames.append(to_records(odf, ACT_VERSION, p, band, ltv, None, drivers, action))
        del odf, OX
    return frames


def resume_activation_only(cn, args, skip_act, t_all):
    """Churn rows are already loaded: (re)train the activation model, score the
    one-time buyers, append, and run the post-load refresh."""
    metrics = {}
    frames = []
    if not skip_act:
        aclf, aenc, acols, asel, _ = train_activation(cn, args, metrics)
        frames = score_activation(cn, args, aclf, aenc, acols, asel)
    print("[6] appending to customer_churn_scores", flush=True)
    load_scores(cn, frames, append=True)
    cn.close()
    print(f"done (resume) in {time.time() - t_all:.0f}s")


def write_report(metrics, imp, aimp):
    (HERE / "churn_model_metrics.json").write_text(json.dumps(metrics, indent=2, default=str))
    v = metrics["validation"]
    lines = [
        "# Churn model report",
        "",
        f"Run {metrics['run_date']}, model_version {metrics['model_version']}, sample {metrics['sample_pct']} percent of customers.",
        "",
        "Validation is out-of-time (cutoffs 2020-07-31 to 2020-09-30) and out-of-customer",
        "(hash buckets never seen in training). Label = churn_adaptive: no Regular Sale within",
        "max(90, 3 x median gap) days, capped at 180.",
        "",
        "| Scorer | n | Positive rate | AUC-ROC | AUC-PR | Lift top decile | Brier |",
        "|---|---|---|---|---|---|---|",
    ]
    for m in v:
        lines.append(f"| {m['scorer']} | {m['n']:,} | {m['positive_rate']:.3f} | {m['auc_roc']:.4f} | {m['auc_pr']:.4f} | {m['top_decile_lift']:.2f} | {m['brier']:.4f} |")
    p = metrics["bgnbd_params"]
    lines += ["", f"BG/NBD parameters (weeks): r={p['r']:.3f}, alpha={p['alpha']:.3f}, a={p['a']:.3f}, b={p['b']:.3f}.",
              f"GBM iterations: {metrics['gbm_iterations']}.", "", "## Calibration (validation deciles)", "",
              "| Decile | n | Predicted | Actual |", "|---|---|---|---|"]
    for r in metrics["calibration"]:
        lines.append(f"| {int(r['q'])} | {int(r['n']):,} | {r['pred']:.3f} | {r['actual']:.3f} |")
    lines += ["", "## Permutation importance (AUC drop, validation subsample)", "", "| Feature | AUC drop | Direction |", "|---|---|---|"]
    for r in imp.head(25).itertuples():
        lines.append(f"| {r.feature} | {r.auc_drop:.4f} | {r.direction:+.2f} |")
    a = metrics["activation"]
    lines += ["", "## Activation model (second purchase within 90 days)", "",
              f"AUC-ROC {a['auc_roc']:.4f}, AUC-PR {a['auc_pr']:.4f}, lift top decile {a['top_decile_lift']:.2f}, "
              f"positive rate {a['positive_rate']:.3f}, n={a['n']:,} (out-of-time split on first purchase day).", "",
              "| Feature | AUC drop | Direction |", "|---|---|---|"]
    for r in aimp.head(12).itertuples():
        lines.append(f"| {r.feature} | {r.auc_drop:.4f} | {r.direction:+.2f} |")
    lines += ["", "Risk bands: Critical >= 0.70, High >= 0.45, Watch >= 0.25, else Low.",
              "Driver codes are z-score x importance attributions, not SHAP values.", ""]
    (HERE / "churn_model_report.md").write_text("\n".join(lines))
    print(f"  report -> {HERE / 'churn_model_report.md'}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
