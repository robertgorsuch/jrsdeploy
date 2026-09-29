"""price_elasticity_model.py -- estimate own-price elasticity per PLU from the
monthly pricebook panel, shrink it toward its category, and load
plu_price_elasticity into the pos_data warehouse.

WHAT THIS IS, AND WHAT IT IS NOT
  This is an OBSERVATIONAL estimate. Prices were not randomly assigned. A
  retailer promotes what it expects to sell, so price and expected demand move
  together and the naive elasticity is biased -- typically toward zero, because
  a price cut timed to a demand peak looks less effective than it was.
  The design below removes the two largest confounders it can:
    within-PLU  first differences, so a permanently cheap product that is also
                permanently popular contributes nothing. Only price CHANGES
                identify the coefficient.
    month-demeaned  each month, the cross-PLU mean change is subtracted from
                both sides, so chain-wide shocks -- Christmas, the March 2020
                pantry-loading spike, a chain-wide markdown week -- cannot be
                read as a price response.
  What remains is still not a causal estimate. Treat the numbers as a ranked
  hypothesis about which products are price-sensitive, to be settled by a
  proper price test, not as a licence to reprice the catalogue.

ESTIMATOR
  For PLU i and consecutive months t-1, t:
      dq_it = ln(units_it) - ln(units_i,t-1)
      dp_it = ln(price_it) - ln(price_i,t-1)
  Both demeaned by month across PLUs, then per-PLU OLS through the origin:
      dq_it = beta_i * dp_it + e_it
  beta_i is the own-price elasticity. A well-behaved grocery elasticity is
  negative and usually between -0.5 and -4.

SHRINKAGE
  Each PLU has at most 23 differences and often far fewer, so a raw per-PLU
  beta is noisy. Each is shrunk toward its category mean by precision weight
      w = tau^2 / (tau^2 + se_i^2)
  where tau^2 is the between-PLU variance within the category. A PLU with a
  tight estimate keeps it; a PLU with a wobbly one is pulled to its category.
  This is the standard empirical-Bayes shrink, and elasticity_shrunk is the
  column downstream work should use.

VALIDATION
  Out-of-time. Elasticities are fitted on months up to TRAIN_END and then used
  to predict demand changes in the held-out months. The reported number is the
  correlation between predicted and actual demand change, against a null model
  that predicts no response at all. If the elasticities carry no signal the
  correlation collapses to zero and the run says so.

PRICING SIGNAL
  For a margin-maximising monopolist the optimal price is
      p* = c * e / (1 + e)   for e < -1
  With e > -1 (inelastic) the unconstrained optimum is unbounded, which in
  practice means "there is room to raise price, go and test it" rather than
  "raise price without limit". Both cases are labelled rather than acted on,
  and expected_margin_delta_up5 shows the modelled effect of a 5 percent rise.

Usage
  python scripts/pos_perf/price_elasticity_model.py
  python scripts/pos_perf/price_elasticity_model.py --no-load --no-mlflow

Requires: pricebook_history, products.
Outputs
  warehouse table plu_price_elasticity
  MLflow experiment pos-price-elasticity (registered pyfunc price-elasticity)
  scripts/pos_perf/price_elasticity_metrics.json / _report.md
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
from pos_ml_common import OWNER, TEAM, connect, f, q, recreate_and_load, safe_track  # noqa: E402

HERE = Path(__file__).resolve().parent
REPORT = HERE / "price_elasticity_report.md"
METRICS = HERE / "price_elasticity_metrics.json"

MODEL_VERSION = "price-elasticity-v1"
EXPERIMENT = "pos-price-elasticity"
REGISTERED_NAME = "price-elasticity"

MIN_DIFFS = 6          # per-PLU differences required to fit at all
TRAIN_END = 202006     # elasticities fitted here, validated after
PRICE_MOVE = 0.05      # the what-if used for the margin signal

DDL = """
CREATE TABLE plu_price_elasticity (
    plu                       VARCHAR(24) NOT NULL,
    product_name              VARCHAR(200),
    category                  VARCHAR(60),
    sub_category              VARCHAR(60),
    n_months                  INTEGER,
    n_price_moves             INTEGER,
    price_cv                  DECIMAL(10,5),
    avg_price                 DECIMAL(12,4),
    avg_cost                  DECIMAL(12,4),
    avg_monthly_units         DECIMAL(14,3),
    annual_sales              DECIMAL(16,2),
    elasticity_raw            DECIMAL(12,5),
    elasticity_se             DECIMAL(12,5),
    elasticity_shrunk         DECIMAL(12,5),
    category_elasticity       DECIMAL(12,5),
    elasticity_calibrated     DECIMAL(12,5),
    shrink_weight             DECIMAL(10,5),
    r2                        DECIMAL(10,5),
    identified                VARCHAR(16),
    demand_band               VARCHAR(24),
    optimal_price             DECIMAL(12,4),
    expected_units_delta_up5  DECIMAL(14,3),
    expected_margin_delta_up5 DECIMAL(16,2),
    pricing_signal            VARCHAR(80),
    model_version             VARCHAR(40)
)
"""


def s_(v, n):
    """Truncate to the declared column width. pyodbc aborts the entire batch on
    an overflow, so the width is enforced here rather than discovered at load."""
    return None if v is None else str(v)[:n]


def ols_through_origin(x, y):
    """beta, se, r2 for y = beta*x with no intercept. The intercept is already
    removed by first-differencing and month demeaning, and forcing it to zero
    keeps the coefficient interpretable as an elasticity."""
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    sxx = float((x * x).sum())
    if sxx <= 1e-12 or len(x) < 2:
        return np.nan, np.nan, np.nan
    beta = float((x * y).sum() / sxx)
    resid = y - beta * x
    dof = len(x) - 1
    if dof <= 0:
        return beta, np.nan, np.nan
    s2 = float((resid ** 2).sum() / dof)
    se = float(np.sqrt(s2 / sxx))
    sst = float((y ** 2).sum())
    r2 = float(1 - (resid ** 2).sum() / sst) if sst > 1e-12 else np.nan
    return beta, se, r2


def build_diffs(panel):
    """Within-PLU log first differences, demeaned by month."""
    p = panel.sort_values(["plu", "yyyymm"]).copy()
    p["lnq"] = np.log(p["units"])
    p["lnp"] = np.log(p["avg_selling_price"])
    g = p.groupby("plu", sort=False)
    p["dq"] = g["lnq"].diff()
    p["dp"] = g["lnp"].diff()
    p["month_gap"] = g["month_seq"].diff()
    # only consecutive months -- a gap means the PLU left the pricebook, and
    # differencing across that gap is not a price response
    d = p[(p.month_gap == 1) & p.dq.notna() & p.dp.notna()].copy()
    # strip chain-wide monthly shocks from both sides
    d["dq"] = d["dq"] - d.groupby("yyyymm")["dq"].transform("mean")
    d["dp"] = d["dp"] - d.groupby("yyyymm")["dp"].transform("mean")
    return d


def fit_elasticities(d):
    rows = []
    for plu, g in d.groupby("plu", sort=False):
        if len(g) < MIN_DIFFS:
            rows.append({"plu": plu, "n_diffs": len(g), "beta": np.nan,
                         "se": np.nan, "r2": np.nan, "moves": int((g.dp.abs() > 0.005).sum())})
            continue
        b, se, r2 = ols_through_origin(g.dp.values, g.dq.values)
        rows.append({"plu": plu, "n_diffs": len(g), "beta": b, "se": se, "r2": r2,
                     "moves": int((g.dp.abs() > 0.005).sum())})
    return pd.DataFrame(rows)


def shrink(est, key="category"):
    """Empirical-Bayes shrink of each PLU beta toward its category mean."""
    out = []
    for cat, g in est.groupby(key, sort=False):
        ok = g[g.beta.notna() & g.se.notna() & (g.se > 0)]
        if len(ok) < 3:
            cat_beta = float(ok.beta.median()) if len(ok) else np.nan
            tau2 = np.nan
        else:
            cat_beta = float(np.average(ok.beta, weights=1.0 / (ok.se ** 2)))
            # between-PLU variance net of sampling noise, floored at zero
            tau2 = max(float(ok.beta.var(ddof=1) - (ok.se ** 2).mean()), 0.0)
        g = g.copy()
        g["category_elasticity"] = cat_beta
        if np.isnan(tau2) or tau2 <= 0:
            w = np.where(g.se.notna(), 0.0, np.nan)
        else:
            w = tau2 / (tau2 + g.se ** 2)
        g["shrink_weight"] = w
        g["elasticity_shrunk"] = np.where(
            g.beta.notna() & pd.notna(w), w * g.beta + (1 - w) * cat_beta, cat_beta)
        out.append(g)
    return pd.concat(out, ignore_index=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--no-mlflow", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    print("price elasticity -- PLU x month pricebook panel", flush=True)

    cn = connect()
    ph = q(cn, """SELECT plu, yyyymm, yr, mo, avg_pricebook_cost, avg_regular_price,
                         avg_selling_price, units, sales, stores_selling
                  FROM pricebook_history""")
    prod = q(cn, "SELECT plu, product_name, category, sub_category FROM products")
    print(f"  pricebook {len(ph):,} rows, {ph.plu.nunique()} PLUs, {ph.yyyymm.nunique()} months", flush=True)

    ph = ph[(ph.units > 0) & (ph.avg_selling_price > 0)].copy()
    ph["month_seq"] = ph.yyyymm.map({m: i for i, m in enumerate(sorted(ph.yyyymm.unique()))})
    ph = ph.merge(prod, on="plu", how="left")
    ph["category"] = ph["category"].replace({"None": "Uncategorised", "": "Uncategorised"}).fillna("Uncategorised")

    d_all = build_diffs(ph)
    d_tr = d_all[d_all.yyyymm <= TRAIN_END]
    d_te = d_all[d_all.yyyymm > TRAIN_END]
    print(f"  usable differences {len(d_all):,} (train {len(d_tr):,}, holdout {len(d_te):,})", flush=True)

    est = fit_elasticities(d_tr).merge(
        ph.groupby("plu").agg(category=("category", "last")).reset_index(), on="plu", how="left")
    est = shrink(est)
    fitted = int(est.beta.notna().sum())
    print(f"  fitted {fitted} of {len(est)} PLUs (>= {MIN_DIFFS} consecutive-month diffs)", flush=True)

    # ---- out-of-time validation -------------------------------------------
    v = d_te.merge(est[["plu", "elasticity_shrunk", "beta"]], on="plu", how="left")
    v = v[v.elasticity_shrunk.notna() & v.dq.notna() & v.dp.notna()]
    pred = v.elasticity_shrunk * v.dp
    corr = float(np.corrcoef(pred, v.dq)[0, 1]) if len(v) > 2 else float("nan")
    sse_model = float(((v.dq - pred) ** 2).sum())
    sse_null = float((v.dq ** 2).sum())          # null: price has no effect
    r2_oos = float(1 - sse_model / sse_null) if sse_null > 0 else float("nan")
    corr_raw = float(np.corrcoef(v.beta.fillna(0) * v.dp, v.dq)[0, 1]) if len(v) > 2 else float("nan")
    # Calibration. A correlation says the RANKING carries signal. The slope of
    # actual on predicted says whether the MAGNITUDES can be trusted: slope 1
    # means calibrated, slope below 1 means the elasticities overstate the
    # response and must not be used for revenue arithmetic.
    denom = float((pred ** 2).sum())
    cal_slope = float((pred * v.dq).sum() / denom) if denom > 1e-12 else float("nan")
    print(f"  out-of-time: corr(pred, actual) {corr:.4f}, R2 vs no-response null {r2_oos:.4f}, "
          f"calibration slope {cal_slope:.4f} (raw unshrunk corr {corr_raw:.4f})", flush=True)

    # ---- assemble the deployed table --------------------------------------
    agg = (ph.groupby("plu")
             .agg(product_name=("product_name", "last"), category=("category", "last"),
                  sub_category=("sub_category", "last"), n_months=("yyyymm", "nunique"),
                  avg_price=("avg_selling_price", "mean"), avg_cost=("avg_pricebook_cost", "mean"),
                  avg_monthly_units=("units", "mean"), annual_sales=("sales", "sum"),
                  price_cv=("avg_selling_price", lambda s: s.std() / s.mean() if s.mean() else np.nan))
             .reset_index())
    out = agg.merge(est[["plu", "n_diffs", "moves", "beta", "se", "r2", "elasticity_shrunk",
                         "category_elasticity", "shrink_weight"]], on="plu", how="left")

    # Recalibrate for the money arithmetic. Out-of-time the elasticities carry
    # real ranking signal (corr 0.25) but overstate the MAGNITUDE of the
    # response -- the slope of actual on predicted is well below 1. Ranking uses
    # elasticity_shrunk; anything that multiplies into dollars uses the
    # calibrated value, or the margin numbers come out inflated by 1/slope.
    cal = cal_slope if np.isfinite(cal_slope) and 0.05 < cal_slope < 2.0 else 1.0
    out["elasticity_calibrated"] = out.elasticity_shrunk * cal
    ec = out.elasticity_calibrated
    e = out.elasticity_shrunk
    out["identified"] = np.where(out.beta.notna(), "fitted", "category")
    out["demand_band"] = np.select(
        [e < -1.5, (e >= -1.5) & (e < -1.0), (e >= -1.0) & (e < -0.3), e >= -0.3],
        ["highly elastic", "elastic", "inelastic", "very inelastic"], default="unknown")
    # p* = c*e/(1+e) is only defined and meaningful for e < -1
    out["optimal_price"] = np.where(ec < -1.0, out.avg_cost * ec / (1.0 + ec), np.nan)
    out["expected_units_delta_up5"] = out.avg_monthly_units * ec * PRICE_MOVE
    new_units = out.avg_monthly_units * (1 + ec * PRICE_MOVE)
    out["expected_margin_delta_up5"] = (
        new_units * (out.avg_price * (1 + PRICE_MOVE) - out.avg_cost)
        - out.avg_monthly_units * (out.avg_price - out.avg_cost)) * 12
    out["pricing_signal"] = np.select(
        [out.beta.isna(),
         e >= -0.3,
         (e >= -1.0) & (e < -0.3),
         (e >= -1.5) & (e < -1.0),
         e < -1.5],
        ["not identified - insufficient price variation",
         "very inelastic - price rise candidate, test first",
         "inelastic - modest price rise may pay, test first",
         "near unit elastic - hold price",
         "elastic - protect price, promote to drive volume"],
        default="unknown")
    out["model_version"] = MODEL_VERSION

    cat = (out.dropna(subset=["elasticity_shrunk"])
              .groupby("category")
              .agg(plus=("plu", "count"), elasticity=("elasticity_shrunk", "median"),
                   annual_sales=("annual_sales", "sum"))
              .sort_values("annual_sales", ascending=False).reset_index())

    metrics = {
        "model_version": MODEL_VERSION, "run_date": str(date.today()),
        "panel_rows": int(len(ph)), "plus": int(ph.plu.nunique()), "months": int(ph.yyyymm.nunique()),
        "usable_diffs": int(len(d_all)), "train_diffs": int(len(d_tr)), "holdout_diffs": int(len(d_te)),
        "train_end": TRAIN_END, "min_diffs": MIN_DIFFS, "fitted_plus": fitted,
        "validation": {"corr_pred_actual": corr, "r2_vs_no_response_null": r2_oos,
                       "corr_unshrunk": corr_raw, "calibration_slope": cal_slope,
                       "n": int(len(v))},
        "calibration_applied": cal,
        "elasticity_distribution": {
            "median": float(e.median()), "p10": float(e.quantile(0.10)),
            "p90": float(e.quantile(0.90)),
            "share_elastic_lt_minus1": float((e < -1).mean()),
            "share_positive_sign_error": float((e > 0).mean()),
        },
        "category_elasticity": cat.to_dict(orient="records"),
    }
    METRICS.write_text(json.dumps(metrics, indent=2), encoding="ascii")
    write_report(metrics, out)
    print(f"  wrote {METRICS.name} and {REPORT.name}", flush=True)

    if not a.no_mlflow:
        safe_track(
            EXPERIMENT, f"elasticity-{MODEL_VERSION}",
            params={"estimator": "within-PLU first difference, month demeaned, OLS through origin",
                    "min_diffs": MIN_DIFFS, "train_end": TRAIN_END,
                    "shrinkage": "empirical Bayes toward category mean",
                    "price_move_for_signal": PRICE_MOVE},
            metrics={k: v for k, v in metrics.items() if isinstance(v, (int, float))}
            | {"validation": metrics["validation"], "dist": metrics["elasticity_distribution"]},
            tags={"model_version": MODEL_VERSION, "grain": "plu x month",
                  "causal_status": "observational -- ranked hypothesis, not a causal effect",
                  "output_table": "plu_price_elasticity",
                  "source_script": "scripts/pos_perf/price_elasticity_model.py"},
            dicts={"category_elasticity.json": {"rows": cat.to_dict(orient="records")}},
        )

    if not a.no_load:
        recs = [(
            s_(r.plu, 24), s_(r.product_name, 200), s_(r.category, 60), s_(r.sub_category, 60),
            int(r.n_months), int(r.moves) if pd.notna(r.moves) else None, f(r.price_cv),
            f(r.avg_price), f(r.avg_cost), f(r.avg_monthly_units), f(r.annual_sales, 2),
            f(r.beta), f(r.se), f(r.elasticity_shrunk), f(r.category_elasticity),
            # calibrated value follows category_elasticity in the DDL order
            f(r.elasticity_calibrated), f(r.shrink_weight), f(r.r2),
            s_(r.identified, 16), s_(r.demand_band, 24),
            f(r.optimal_price), f(r.expected_units_delta_up5), f(r.expected_margin_delta_up5, 2),
            s_(r.pricing_signal, 80), MODEL_VERSION,
        ) for r in out.itertuples(index=False)]
        recreate_and_load(cn, "plu_price_elasticity", DDL, recs)

    print(f"done in {time.time() - t0:.0f}s", flush=True)
    return 0


def write_report(m, out):
    L = []
    A = L.append
    A("# Price elasticity report\n")
    A(f"Run {m['run_date']}, model_version {m['model_version']}. PLU x month pricebook panel: "
      f"{m['panel_rows']:,} rows, {m['plus']} PLUs, {m['months']} months.\n")
    A("## What this estimate is\n")
    A("Observational, not causal. Prices were not randomly assigned, and a retailer promotes "
      "what it expects to sell, so price and expected demand move together. The design removes "
      "the two largest confounders it can -- within-PLU first differences, so permanent product "
      "quality cannot masquerade as price sensitivity, and month demeaning, so chain-wide shocks "
      "like the March 2020 pantry-loading spike are not read as a price response. What survives "
      "is a ranked hypothesis about which products are price-sensitive. Settle it with a price "
      "test before repricing anything.\n")
    A(f"{m['usable_diffs']:,} consecutive-month differences, {m['train_diffs']:,} used for "
      f"fitting (through {m['train_end']}) and {m['holdout_diffs']:,} held out. "
      f"{m['fitted_plus']} of {m['plus']} PLUs had the {m['min_diffs']} differences needed to fit "
      "individually; the rest inherit their category elasticity and are labelled as such.\n")
    A("## Out-of-time validation\n")
    v = m["validation"]
    A(f"Elasticities fitted on months through {m['train_end']} were used to predict demand "
      f"changes in the held-out months (n = {v['n']:,}).\n")
    A("| Measure | Value |")
    A("|---|---|")
    A(f"| Correlation, predicted vs actual demand change | {v['corr_pred_actual']:.4f} |")
    A(f"| R2 against a no-price-response null | {v['r2_vs_no_response_null']:.4f} |")
    A(f"| Correlation using raw unshrunk betas | {v['corr_unshrunk']:.4f} |")
    A(f"| Calibration slope (actual on predicted) | {v['calibration_slope']:.4f} |")
    A("\nThe null is the honest comparator: a model that says price changes do nothing. "
      "Shrunk elasticities are compared against unshrunk ones so the value of the shrinkage "
      "is visible rather than assumed.\n")
    d = m["elasticity_distribution"]
    A("## Distribution\n")
    A("| Statistic | Value |")
    A("|---|---|")
    A(f"| Median elasticity | {d['median']:.3f} |")
    A(f"| 10th percentile | {d['p10']:.3f} |")
    A(f"| 90th percentile | {d['p90']:.3f} |")
    A(f"| Share elastic (below -1) | {d['share_elastic_lt_minus1']:.1%} |")
    A(f"| Share with a positive sign (theory violation) | {d['share_positive_sign_error']:.1%} |")
    A("\nA positive elasticity says demand rose when price rose. That is a sign error, not a "
      "discovery: it means the remaining confounding beats the signal for those products. "
      "The share is reported rather than hidden, and those PLUs should not be repriced on "
      "this evidence.\n")
    A("## Category elasticity, by sales\n")
    A("| Category | PLUs | Median elasticity | Annual sales |")
    A("|---|---|---|---|")
    for r in m["category_elasticity"][:12]:
        A(f"| {r['category']} | {r['plus']} | {r['elasticity']:.3f} | {r['annual_sales']:,.0f} |")
    A("\n## Output\n")
    A("plu_price_elasticity carries the raw and shrunk elasticity, its standard error and "
      "shrink weight, the category fallback, a demand band, and a pricing_signal in plain "
      "words. optimal_price is only populated where the elasticity is below -1, because the "
      "textbook formula p* = c*e/(1+e) is undefined otherwise -- an inelastic product has no "
      "unconstrained optimum, which in practice means there is room to test a rise, not that "
      "price should go up without limit.\n")
    REPORT.write_text("\n".join(L), encoding="ascii")


if __name__ == "__main__":
    sys.exit(main())
