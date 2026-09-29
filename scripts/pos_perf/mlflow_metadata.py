"""mlflow_metadata.py -- set descriptions, tags, owners and aliases on the POS
demand-forecasting experiments and registered models in the warehouse MLflow.

MLflow has no first-class owner field. The conventions used here are the ones
the UI understands:
  description   the mlflow.note.content tag, which the UI renders as the
                Description panel on experiments, models and versions
  owner         a plain tag, plus mlflow.user where the server accepts it
  alias         champion marks the version a consumer should load, so a
                scoring job can pin models:/name@champion instead of a number

Everything here is idempotent -- rerun it after any retrain. It never creates
runs and never touches model artifacts, only metadata.

Identity note: the owner is the Actian work identity that provisioned the
warehouse (preferredUsername on the Admiral resource record), not a personal
address.

Usage
  python scripts/pos_perf/mlflow_metadata.py            # apply
  python scripts/pos_perf/mlflow_metadata.py --dry-run  # print, change nothing
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parents[1] / ".claude" / "skills" / "admiral" / "admiral.config.json"

OWNER = "robert.gorsuch@actian.com"
TEAM = "Actian POS Analytics"
WAREHOUSE = "av-flm7ykoxlcvq (pos_data)"
DATA_WINDOW = "2019-01-01..2020-12-31"

COMMON = {
    "owner": OWNER,
    "team": TEAM,
    "warehouse": WAREHOUSE,
    "data_window": DATA_WINDOW,
    "domain": "retail-demand-forecasting",
    "serving": "batch score to Avalanche table, read by Jaspersoft dashboards",
    "lifecycle": "validated-on-historical-data",
    "data_caveat": "source data ends 2020-12-31 -- scoring is historical, not live inference",
}

EXPERIMENTS = {
    "pos-store-day-demand": {
        "note": (
            "Daily sales forecast per store, 14 days ahead, for labour scheduling and "
            "store ordering across 330 Canadian franchise grocery stores.\n\n"
            "Grain: store x calendar day, 229,595 rows over 2019-01-01 to 2020-12-31. "
            "Direct 14-step-ahead HistGradientBoosting on absolute-error loss, so a row "
            "dated D uses nothing observed after D-14 and there is no recursive error "
            "compounding.\n\n"
            "Result on a 57-day out-of-time holdout: WAPE 0.2120, MAE 1,114, R2 0.755. "
            "That is 36 percent better than lag-14 persistence (0.3326) and 41 percent "
            "better than a same-weekday mean (0.3622).\n\n"
            "Three runs are logged per target. 'main' trains on all history with "
            "pandemic_period as an explicit feature and is the shipped model. "
            "'pandemic_only' tests dropping pre-COVID history and is much worse "
            "(WAPE 0.3309) -- losing training volume outweighs regime purity. "
            "'regime_shift' is a diagnostic, never shipped: a model trained only on "
            "pre-pandemic days still beats persistence on pandemic data (0.2189 vs "
            "0.2883), because the lag features absorb the level shift.\n\n"
            "Leakage is excluded deliberately. The whole-period rollups on stores and "
            "fsa_demographics (total_sales, sales_per_sqft, penetration_pct and the "
            "rest) are computed from the full sales history and are never used as "
            "features.\n\n"
            "Build: scripts/pos_perf/build_store_day_features.sql then "
            "scripts/pos_perf/store_demand_model.py. Verify independently in SQL with "
            "scripts/pos_perf/verify_store_day_forecast.sql."
        ),
        "tags": {
            "grain": "store x day",
            "horizon": "14 days",
            "target": "store_traffic.sales",
            "source_tables": "store_traffic, date_dim, stores, weather_daily, fsa_demographics",
            "feature_table": "store_day_features",
            "output_table": "store_day_forecast",
            "registered_model": "store-day-demand",
            "source_script": "scripts/pos_perf/store_demand_model.py",
            "headline_metric": "holdout WAPE 0.2120, R2 0.755",
            "beats_baseline": "36 percent better than lag-14 persistence",
            "forward_assumptions": "weather from day-of-year climatology, promos_active from month x weekday mean",
        },
    },
    "pos-price-elasticity": {
        "note": (
            "Own-price elasticity per PLU from the monthly pricebook panel, 942 products over "
            "24 months.\n\n"
            "OBSERVATIONAL, NOT CAUSAL. Prices were not randomly assigned, and a retailer "
            "promotes what it expects to sell, so price and expected demand move together. The "
            "design removes the two largest confounders it can: within-PLU first differences, so "
            "permanent product quality cannot masquerade as price sensitivity, and month "
            "demeaning, so chain-wide shocks like the March 2020 pantry-loading spike are not "
            "read as a price response. What survives is a ranked hypothesis, to be settled by a "
            "price test.\n\n"
            "700 of 803 eligible PLUs had the 6 consecutive-month differences needed to fit "
            "individually. The rest inherit a category elasticity and are labelled as such. "
            "Per-PLU estimates are shrunk toward their category by empirical Bayes, which "
            "measurably helps: out-of-time correlation with actual demand change rises from "
            "0.146 unshrunk to 0.250 shrunk.\n\n"
            "READ THE CALIBRATION BEFORE USING THE NUMBERS. The out-of-time slope of actual on "
            "predicted is 0.50, so these elasticities rank price sensitivity usefully but "
            "overstate how far demand actually moves, by about 2x. elasticity_shrunk is the "
            "ranking column; elasticity_calibrated is what optimal_price and the margin columns "
            "are computed from. R2 against a no-response null is near zero: direction is "
            "informative, magnitude is not."
        ),
        "tags": {"grain": "plu x month", "target": "log units",
                 "estimator": "within-PLU first difference, month demeaned, OLS through origin",
                 "shrinkage": "empirical Bayes toward category",
                 "causal_status": "observational -- ranked hypothesis, not a causal effect",
                 "calibration_slope": "0.50 -- magnitudes overstate response by about 2x",
                 "output_table": "plu_price_elasticity",
                 "source_tables": "pricebook_history, products",
                 "source_script": "scripts/pos_perf/price_elasticity_model.py"},
    },
    "pos-basket-reco": {
        "note": (
            "Item-item market-basket recommender over 62.1M basket-item rows and 915 "
            "products.\n\n"
            "Co-occurrence is built only from the 17.4M baskets before 2020-11-01 and evaluated "
            "on 300,000 held-out baskets after it, leave-one-out: hide one item, rank candidates "
            "from the rest, record where the hidden item landed. Items already visible in the "
            "basket are excluded from the ranking.\n\n"
            "The baseline that matters is POPULARITY. Most grocery baskets contain staples, so "
            "recommending the chain bestsellers to everyone is already decent, and plenty of "
            "recommenders never beat it. This one does: cosine reaches MRR 0.1538 and hit@10 "
            "0.3048 against popularity at 0.0628 and 0.1578, a 2.45x improvement on MRR.\n\n"
            "Cosine beats lift (MRR 0.0951). Lift is sharper on genuinely associated pairs but "
            "noisier on thin support, and the cosine normalisation handles staples better.\n\n"
            "66.4 percent of stored recommendations sit in the same category as their anchor: "
            "high enough to be sensible for grocery, low enough that the model is doing more "
            "than restating the category tree."
        ),
        "tags": {"grain": "item-item", "scorers": "popularity, cosine, lift",
                 "best_scorer": "cosine", "headline_metric": "MRR 0.1538, hit@10 0.3048",
                 "beats_baseline": "2.45x popularity on MRR",
                 "output_table": "plu_recommendations",
                 "serving": "the pair table IS the model -- a SQL lookup, no fitted estimator",
                 "source_script": "scripts/pos_perf/basket_reco_model.py"},
    },
    "pos-customer-clv": {
        "note": (
            "Forward 6-month gross margin per customer, over the 39.6M-row customer_month "
            "panel.\n\n"
            "THE OBJECTIVE CHOICE IS THE POINT. This uses squared error, the conditional MEAN, "
            "deliberately opposite to the demand models which use absolute error. Roughly 40 "
            "percent of customers spend nothing in the next six months, so a median objective "
            "would price almost everyone at zero and the portfolio total would collapse. The one "
            "property a CLV number must have is that summing it across customers reproduces "
            "expected margin.\n\n"
            "AGGREGATE ACCOUNTS ARE EXCLUDED. 74 customer_ids shop at more than 20 of the 330 "
            "stores. customer_id 0 alone covers all 330, with 1,003,697 transactions and 24.1M "
            "of sales: that is the unidentified walk-in bucket, not a shopper. The 74 hold 29.4M, "
            "3.9 percent of all chain sales. Left in they destroy the model, and the first run "
            "proved it -- R2 0.02 with RMSE 1790 while a persistence baseline that merely tracked "
            "those same accounts scored R2 0.9987. Note those 74 also appear in "
            "customer_churn_scores, so the pre-existing churn model scored them as people.\n\n"
            "Validation is out of time across two genuinely different cohorts: trained as-of "
            "2019-12 for 2020 H1, validated as-of 2020-06 for 2020 H2. Forward activity falls "
            "from 71.4 to 60.2 percent between them.\n\n"
            "Judge it on portfolio calibration and decile separation, not point accuracy."
        ),
        "tags": {"grain": "customer", "horizon": "6 months", "target": "forward gross margin",
                 "objective": "squared_error -- conditional mean, not median",
                 "baseline": "margin_l6 persistence",
                 "population_filter": "excludes 74 aggregate accounts with more than 20 distinct stores",
                 "output_table": "customer_clv_scores",
                 "source_tables": "customer_month, customers, customer_demographics, customer_diet_profile, customer_ipt_stats",
                 "source_script": "scripts/pos_perf/clv_model.py"},
    },
    "pos-shrink-anomaly": {
        "note": (
            "Peer-relative shrink outlier detection over store x category x month cells.\n\n"
            "UNSUPERVISED. There is no shrink-fraud label in this data, so this is not a fraud "
            "detector and must not be described as one. It measures how far each cell sits from "
            "comparable stores in the same category and month and ranks the outliers for human "
            "review. The output is a triage queue, not an accusation.\n\n"
            "Everything is a rate against sales in the same cell, because a large store shrinks "
            "more in absolute dollars simply by selling more, and comparisons are made within "
            "category and month so an inherently wasteful category does not generate alarms. "
            "Cells under 250 of sales are dropped: a rate on a tiny denominator is noise and is "
            "the fastest way to fill a review queue with nothing.\n\n"
            "Two detectors run side by side rather than blended: a robust z-score on the shrink "
            "rate using median and MAD within category-month, and an IsolationForest over rate, "
            "trend, reason concentration and event size. Where they disagree is informative.\n\n"
            "With no labels there is no precision to report. Stability is the evidence available: "
            "38.0 percent of flagged store-categories reflag in the second half against 27.6 "
            "percent by chance, a 1.38x lift. That is real but modest, and it is stated that way. "
            "Flagged cells are 5.46 percent of the population and hold 17.1 percent of shrink "
            "dollars."
        ),
        "tags": {"grain": "store x category x month",
                 "supervision": "UNSUPERVISED -- no shrink-fraud label exists",
                 "intended_use": "ranked triage queue for human review, not an accusation",
                 "detectors": "robust z-score and IsolationForest, reported separately",
                 "stability_lift": "1.38x over chance -- real but modest",
                 "concentration": "5.46 percent of cells hold 17.1 percent of shrink dollars",
                 "output_table": "shrink_anomaly_scores",
                 "source_script": "scripts/pos_perf/shrink_anomaly_model.py"},
    },
    "pos-supplier-reliability": {
        "note": (
            "Purchase-order lead time and on-time delivery across 92,472 orders and 12 "
            "suppliers.\n\n"
            "NEGATIVE RESULT -- DO NOT DEPLOY. Both heads fail against their baselines.\n"
            "Lead time: model MAE 1.215 days against 1.205 days for expected_lead_days, the "
            "number already printed on the PO. The model is slightly WORSE than the supplier "
            "stated expectation, which costs nothing.\n"
            "On time: AUC 0.5002, a coin flip. Whether a delivery arrives on time is not "
            "predictable from anything known when the order is raised.\n\n"
            "This is recorded rather than buried because the baselines were built specifically "
            "to catch it. The supplier rollups that would have made this look good -- "
            "on_time_pct, avg_fill_rate_pct -- were excluded because they are computed over every "
            "order including the ones being predicted. Feeding a supplier its own future on-time "
            "rate produces a spectacular and meaningless AUC.\n\n"
            "Honest conclusion: in this dataset, lead-time variation around the expectation is "
            "close to noise. Use expected_lead_days and size safety stock from the observed "
            "residual spread. Revisit only with data this schema does not contain, such as "
            "carrier, depot backlog at order time, or weather."
        ),
        "tags": {"grain": "purchase order", "target": "actual_lead_days and on_time",
                 "result": "NEGATIVE -- does not beat the PO expectation",
                 "lead_time_mae": "1.215 model vs 1.205 PO expectation",
                 "on_time_auc": "0.5002 -- coin flip",
                 "recommendation": "do not deploy; use expected_lead_days plus a residual-based buffer",
                 "output_table": "supplier_reliability_forecast",
                 "source_script": "scripts/pos_perf/supplier_reliability_model.py"},
    },
    "pos-plu-weekly-demand": {
        "note": (
            "Weekly unit demand per store-PLU pair, 2 weeks ahead, to replace the static "
            "reorder parameter driving replenishment. Supplier lead times run 3 to 9 days "
            "(mean 5.7), so a two-week horizon covers the order cycle.\n\n"
            "Grain: store x PLU x week, 15.3M dense pair-weeks over 214,998 pairs and 104 "
            "weeks. 23.9 percent of pair-weeks are ZERO and those zeros are kept -- a "
            "spine of only weeks that happened to sell would teach the model that demand "
            "is never zero.\n\n"
            "Validation is out-of-time AND out-of-store: trained on 32 stores "
            "(storenumber mod 10 = 0), evaluated on a disjoint store set. WAPE 0.5064 on "
            "stores never trained on.\n\n"
            "READ THE BASELINES CAREFULLY. inventory.avg_daily_units x 7 appears to beat "
            "the model (0.4766 vs 0.5064), but that average spans the holdout weeks and "
            "is therefore not a forecast anyone could have made at the origin. The fair "
            "comparison is static(train), the same flat-average policy computed only from "
            "training weeks: 0.6037. The model wins that by 16 percent, and beats a "
            "4-week moving average by 4.3 percent.\n\n"
            "Order quantity is NOT the point forecast. An absolute-error model predicts "
            "the conditional median, and weekly demand is right-skewed, so ordering at "
            "the median covers only 45.2 percent of pair-weeks. A separate q0.85 model "
            "supplies the order quantity: 79.6 percent coverage and 66 percent fewer "
            "units short. The quantile is floored at the median so the two models cannot "
            "cross.\n\n"
            "Known limit: 739 of 942 products carry no category in the source and 763 no "
            "size_g, so product features contribute far less than the schema suggests. "
            "Filling that catalogue is the cheapest available accuracy gain.\n\n"
            "Build: scripts/pos_perf/build_store_plu_week.sql then "
            "scripts/pos_perf/plu_demand_model.py. Verify with "
            "scripts/pos_perf/verify_store_plu_forecast.sql."
        ),
        "tags": {
            "grain": "store x plu x week",
            "horizon": "2 weeks",
            "target": "net units sold",
            "source_tables": "pos_sales_detail, pos_sales_txn, date_dim, products, stores, inventory",
            "feature_table": "store_plu_week",
            "output_table": "store_plu_forecast",
            "registered_model": "plu-weekly-demand",
            "source_script": "scripts/pos_perf/plu_demand_model.py",
            "headline_metric": "out-of-store WAPE 0.5064",
            "beats_baseline": "16 percent better than a training-period flat average",
            "fair_baseline_warning": "incumbent avg_daily_units spans the holdout and is optimistically biased",
            "intermittency": "23.9 percent of pair-weeks are zero",
            "service_level": "orders placed at q0.85, covering 79.6 percent of pair-weeks",
            "data_gap": "739 of 942 products have no category in the source",
        },
    },
}

MODELS = {
    "store-day-demand": {
        "experiment": "pos-store-day-demand",
        "note": (
            "Direct 14-day-ahead daily sales forecast per store. Input is the "
            "store_day_features row for the target date, with every lag and rolling "
            "feature already offset by at least 14 days. Output is predicted daily "
            "sales in CAD, and callers MUST clip at zero -- the absolute-error "
            "objective can emit small negatives for stores trading near zero.\n\n"
            "Consume via the champion alias rather than a version number.\n\n"
            "Retrain when store_day_features is rebuilt. Scoring is batch: "
            "store_demand_model.py writes store_day_forecast, which the Jaspersoft "
            "dashboards read. There is no online serving path."
        ),
        "tags": {
            "task": "regression / time-series demand forecast",
            "framework": "scikit-learn HistGradientBoostingRegressor",
            "loss": "absolute_error (predicts the conditional median)",
            "serialization": "cloudpickle (skops rejects HistGradientBoosting internals)",
            "output_units": "CAD daily sales per store",
            "postprocessing_required": "clip predictions at zero",
            "training_split": "all history to 2020-11-04, pandemic_period as a feature",
            "validation": "out-of-time, final 57 days",
        },
        "version_note": (
            "Winning 'main' configuration retrained on all data through 2020-12-31.\n"
            "Holdout WAPE 0.2120, MAE 1,114, RMSE 1,668, R2 0.755, bias -186.\n"
            "Baselines: lag-14 persistence 0.3326, same-weekday mean 0.3622.\n"
            "SQL reproduces the holdout WAPE at 0.212028 against store_day_forecast.\n"
            "Top features by permutation importance: day_of_year, day_of_month, "
            "samedow_mean4, roll91_lag14.\n"
            "Caveat: day_of_year dominates and the model has seen exactly one prior "
            "December, so the annual seasonal signal rests on a single observation "
            "per calendar day."
        ),
    },
    "customer-clv": {
        "experiment": "pos-customer-clv",
        "note": (
            "Forward 6-month gross margin per customer. Input is a clv_training_set row at an "
            "as-of month; output is expected margin in CAD over the following six months.\n\n"
            "Fitted on squared error, so the output is a conditional MEAN and sums across "
            "customers are meaningful. Do not swap this for a median objective without "
            "understanding that roughly 40 percent of customers have a true forward value of "
            "zero.\n\n"
            "Scored population EXCLUDES 74 aggregate accounts that shop at more than 20 stores "
            "-- walk-in and sentinel IDs, not people. Apply the same filter before scoring or "
            "the output will be dominated by them.\n\n"
            "Clip at zero. Consume via the champion alias. Scoring is batch into "
            "customer_clv_scores; there is no online serving path."
        ),
        "tags": {"task": "regression / customer value",
                 "framework": "scikit-learn HistGradientBoostingRegressor",
                 "loss": "squared_error (conditional mean)",
                 "output_units": "CAD gross margin over 6 months",
                 "postprocessing_required": "clip at zero; exclude aggregate accounts before scoring",
                 "validation": "out-of-time across two cohorts with a real activity shift",
                 "serialization": "cloudpickle"},
        "version_note": (
            "Trained on the as-of 2019-12 cohort, validated out of time on as-of 2020-06.\n"
            "valid MAE 16.164, RMSE 45.29, R2 0.4967.\n"
            "Baseline margin_l6 persistence: MAE 24.393, RMSE 50.04, R2 0.3856.\n"
            "Portfolio calibration 0.967 against the baseline 1.170 -- the model prices the "
            "whole book within 3.3 percent while persistence over-prices it by 17 percent.\n"
            "Top-decile capture 0.470 against 0.391.\n"
            "Population excludes 74 aggregate accounts holding 3.9 percent of chain sales. "
            "Apply the same filter before scoring or the output is dominated by them."
        ),
    },
    "shrink-anomaly": {
        "experiment": "pos-shrink-anomaly",
        "note": (
            "IsolationForest over store-category-month shrink features. Output is an anomaly "
            "score where HIGHER means more anomalous -- the negated sklearn score_samples.\n\n"
            "This is one of two detectors, not the whole system. The robust z-score is computed "
            "in the scoring script and both are written to shrink_anomaly_scores, so loading this "
            "artifact alone gives you half the model.\n\n"
            "Unsupervised: there is no fraud label. The output ranks cells for human review. Sort "
            "the queue by excess_shrink_value rather than by score, to work it by money rather "
            "than by strangeness."
        ),
        "tags": {"task": "unsupervised anomaly detection",
                 "framework": "scikit-learn IsolationForest",
                 "output_semantics": "higher score = more anomalous",
                 "partial_system": "the robust z-score detector lives in the scoring script",
                 "intended_use": "triage queue for human review",
                 "serialization": "cloudpickle"},
        "version_note": (
            "IsolationForest, 300 trees, contamination 0.02, fitted on 45,136 store x category "
            "x month cells with at least 250 of sales.\n"
            "Features: shrink rate, robust z, event count, units lost, dominant-reason share, "
            "rate trend, excess shrink value.\n"
            "No labels exist, so there is no precision to quote. Stability is the evidence: "
            "38.0 percent of flagged store-categories reflag in the second half against 27.6 "
            "percent by chance, a 1.38x lift -- real but modest.\n"
            "Flagged cells are 5.46 percent of the population and hold 17.1 percent of shrink "
            "dollars. Flagged mean rate 0.0149 against 0.0038 unflagged.\n"
            "This artifact is only the IsolationForest half; the robust z-score detector lives "
            "in the scoring script."
        ),
    },
    "supplier-lead-time": {
        "experiment": "pos-supplier-reliability",
        "note": (
            "DO NOT DEPLOY. Predicts actual purchase-order lead time and is slightly WORSE than "
            "expected_lead_days, the number already on the PO: MAE 1.215 days against 1.205.\n\n"
            "The companion on_time_classifier artifact on the same run scores AUC 0.5002, which "
            "is a coin flip.\n\n"
            "Registered for provenance, so the negative result is reproducible and nobody spends "
            "a second week rediscovering it. Use expected_lead_days and size safety stock from "
            "the observed residual spread instead."
        ),
        "tags": {"task": "regression / lead time",
                 "framework": "scikit-learn HistGradientBoostingRegressor",
                 "result": "NEGATIVE -- does not beat a baseline already available for free",
                 "deploy": "NO",
                 "kept_for": "provenance and reproducibility of the negative result",
                 "serialization": "cloudpickle"},
        "version_note": (
            "NEGATIVE RESULT. Retained for provenance, not for use.\n"
            "Trained on 69,648 orders to 2020-06-30, evaluated on the 22,824 that follow.\n"
            "Lead time MAE 1.215 days against 1.205 for expected_lead_days already on the PO, "
            "and 1.797 for a training-mean baseline. The model sits between the two and loses "
            "to the free one.\n"
            "Companion on_time_classifier AUC 0.5002, PR 0.8465 against a base rate of 0.846 "
            "-- the PR figure looks respectable only because 85 percent of orders arrive on "
            "time. AUC is the honest read and it is a coin flip.\n"
            "Supplier rollups were excluded on purpose: they span the orders being predicted."
        ),
    },
    "plu-weekly-demand": {
        "experiment": "pos-plu-weekly-demand",
        "note": (
            "Two-week-ahead weekly unit demand per store-PLU pair. This registered "
            "model is the MEDIAN point forecast, used for planning.\n\n"
            "It is NOT the ordering model. Ordering at this output covers only 45.2 "
            "percent of pair-weeks. The run that produced this version also logs an "
            "'order_model' artifact fitted at q0.85, which is what suggested_order in "
            "store_plu_forecast is built from, floored at this median and rounded up "
            "to a whole case using inventory.case_size.\n\n"
            "Callers must clip at zero. Do not order for a PLU that is no longer "
            "carried: the scoring script restricts the forward window to pairs still "
            "selling in the final week.\n\n"
            "Consume via the champion alias. Scoring is batch, no online serving path."
        ),
        "tags": {
            "task": "regression / intermittent demand forecast",
            "framework": "scikit-learn HistGradientBoostingRegressor",
            "loss": "absolute_error (predicts the conditional median)",
            "serialization": "cloudpickle (skops rejects HistGradientBoosting internals)",
            "output_units": "net units per store-PLU-week",
            "postprocessing_required": "clip at zero; use the q0.85 order_model artifact for order quantity",
            "companion_artifact": "order_model (quantile 0.85) logged on the same run",
            "training_split": "32 stores (mod 10 = 0), weeks 0-95",
            "validation": "out-of-time AND out-of-store, final 8 weeks on a disjoint store set",
        },
        "version_note": (
            "Trained on 1,302,396 pair-weeks from 32 stores, weeks 0 to 95.\n"
            "valid_unseen (stores never trained on): WAPE 0.5064, MAE 3.740, R2 0.536.\n"
            "valid_seen: WAPE 0.5010.\n"
            "Fair baseline static(train) 0.6037 -- model wins by 16 percent.\n"
            "ma4 0.5294, lag2 0.6004.\n"
            "The incumbent avg_daily_units x 7 reads 0.4766 but spans the holdout and "
            "is optimistically biased; it is not a like-for-like comparison.\n"
            "By velocity band: fast 0.4389, medium 0.5170, slow 0.7023 -- slow movers "
            "are hardest, as intermittency predicts.\n"
            "Top features: roll4, roll13, week_of_year, sub_category.\n"
            "Systematic under-forecast (bias -1.49 medium, -6.06 fast) is inherent to "
            "the median objective and is why ordering uses the q0.85 companion."
        ),
    },
}


# Superseded versions. An undocumented version in a registry is an invitation
# to load the wrong one, so every version that is not champion says why.
SUPERSEDED = {
    ("store-day-demand", "1"): (
        "SUPERSEDED -- do not use. Registered before predictions were clipped at "
        "zero, so this model's scoring path emitted 6 negative daily-sales values. "
        "Superseded by v2 and then v3. Use the champion alias."
    ),
    ("customer-clv", "1"): (
        "SUPERSEDED -- do not use. Registered from a run that still included the 74 aggregate "
        "accounts (customer_id 0 and other walk-in and sentinel IDs). Those 143 rows dominated "
        "the squared-error objective completely: that run scored R2 0.02 with RMSE 1790, against "
        "R2 0.4967 and RMSE 45.29 once they were excluded. Use the champion alias."
    ),
    ("store-day-demand", "2"): (
        "SUPERSEDED by v3. Functionally equivalent model, but registered on a run "
        "whose metric logging was cut short by the MLflow async double-insert bug, "
        "so its run carries incomplete metrics. v3 is the same recipe with a clean "
        "run. Use the champion alias."
    ),
}


def cfg():
    return json.load(open(CONFIG, encoding="utf-8-sig"))


def token(attempts=3, timeout=90):
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
            print(f"  login attempt {i + 1}/{attempts} failed: {type(e).__name__}", flush=True)
            time.sleep(3 * (i + 1))
    raise last


# Metrics worth putting in a run description, in the order a reader wants them.
HEADLINE = ["wape", "mae", "rmse", "r2", "auc_roc", "auc_pr", "brier", "mrr",
            "hit@10", "hit@5", "hit@1", "corr_pred_actual", "calibration_slope",
            "portfolio_calibration", "top_decile_capture", "beats_popularity",
            "stability_repeat_rate", "flagged_share"]


def _pick(metrics, limit=8):
    """Headline metrics first, in a fixed order, then anything else notable."""
    out = []
    for want in HEADLINE:
        for k, v in metrics.items():
            if k == want or k.endswith("_" + want):
                out.append((k, v))
                if len(out) >= limit:
                    return out
    return out


def describe_runs(c):
    """Give every run a description built from its own tags and metrics, and
    mark which runs are superseded by a later run of the same name. Runs are
    what a person actually browses in the UI, and an untitled wall of them is
    the reason nobody trusts a tracking server."""
    from mlflow.entities import ViewType
    for name in list(EXPERIMENTS) + ["Default"]:
        exp = c.get_experiment_by_name(name)
        if exp is None:
            continue
        runs = c.search_runs([exp.experiment_id], run_view_type=ViewType.ALL, max_results=200)
        if not runs:
            continue
        # Older runs predate per-run source_script tagging. Fall back to the
        # experiment tag so every run names the script that produced it.
        exp_script = (EXPERIMENTS.get(name, {}).get("tags", {}) or {}).get("source_script")
        # newest run of each run-name is current, the rest are earlier attempts
        seen = {}
        for r in sorted(runs, key=lambda r: r.info.start_time or 0, reverse=True):
            rn = r.data.tags.get("mlflow.runName", r.info.run_id[:8])
            seen.setdefault(rn, []).append(r)
        n_desc = 0
        for rn, group in seen.items():
            for i, r in enumerate(group):
                current = (i == 0)
                t, m = r.data.tags, r.data.metrics
                lines = [f"{rn} -- {name}."]
                if t.get("split"):
                    lines.append(f"Split: {t['split']}.")
                if t.get("diagnostic_only") == "True":
                    lines.append("DIAGNOSTIC ONLY -- never shipped. It measures what a modelling "
                                 "choice would have cost, not a candidate model.")
                if t.get("is_winner") == "True":
                    lines.append("This is the winning configuration for its experiment.")
                if t.get("result", "").startswith("NEGATIVE"):
                    lines.append("NEGATIVE RESULT -- the model does not beat its baseline. "
                                 "Recorded so the finding is reproducible.")
                picked = _pick(m)
                if picked:
                    lines.append("Key metrics: " + ", ".join(
                        f"{k} {v:.4f}" for k, v in picked) + ".")
                if not current:
                    lines.append(f"SUPERSEDED by a later run named {rn}. Kept for history; "
                                 "read the most recent one instead.")
                script = t.get("source_script") or exp_script
                lines.append(f"Produced by {script}." if script
                             else "Produced by the POS model family.")
                if script and "source_script" not in t:
                    try:
                        c.set_tag(r.info.run_id, "source_script", script)
                    except Exception:
                        pass
                try:
                    c.set_tag(r.info.run_id, "mlflow.note.content", "\n".join(lines))
                    c.set_tag(r.info.run_id, "run_status", "current" if current else "superseded")
                    if "owner" not in t:
                        c.set_tag(r.info.run_id, "owner", OWNER)
                        c.set_tag(r.info.run_id, "team", TEAM)
                    n_desc += 1
                except Exception:
                    pass
        print(f"  runs in {name}: {n_desc} described", flush=True)


def label_default(c):
    """The stock Default experiment. Left unlabelled it looks like a live home
    for stray runs, which is exactly how tracking servers turn into landfill."""
    exp = c.get_experiment_by_name("Default")
    if exp is None:
        return
    try:
        c.set_experiment_tag(exp.experiment_id, "mlflow.note.content",
                             "Unused. This is the stock MLflow default experiment, kept only "
                             "because it cannot be removed. Every POS model logs to a named "
                             "pos-* experiment. Do not log here -- a run landing in Default is "
                             "a misconfigured tracking URI or a missing set_experiment call.")
        for k, v in {"owner": OWNER, "team": TEAM, "lifecycle": "unused",
                     "do_not_use": "yes"}.items():
            c.set_experiment_tag(exp.experiment_id, k, v)
        print("  Default experiment: labelled unused", flush=True)
    except Exception as e:
        print(f"  SKIP Default: {type(e).__name__}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.dry_run:
        for name, spec in EXPERIMENTS.items():
            print(f"\n=== experiment {name} ===\n{spec['note'][:400]}...")
            print("tags:", json.dumps({**COMMON, **spec["tags"]}, indent=2)[:600])
        for name, spec in MODELS.items():
            print(f"\n=== model {name} ===\n{spec['note'][:400]}...")
        return 0

    os.environ["MLFLOW_ENABLE_ASYNC_LOGGING"] = "false"
    import mlflow
    from mlflow.tracking import MlflowClient
    try:
        mlflow.config.enable_async_logging(False)
    except Exception:
        pass
    os.environ["MLFLOW_TRACKING_TOKEN"] = token()
    host = cfg()["db_pos_data"]["host"]
    uri = f"https://{host}/mlflow/"
    mlflow.set_tracking_uri(uri)
    c = MlflowClient()
    print(f"mlflow -> {uri}", flush=True)

    for name, spec in EXPERIMENTS.items():
        exp = c.get_experiment_by_name(name)
        if exp is None:
            print(f"  SKIP experiment {name}: not found", flush=True)
            continue
        c.set_experiment_tag(exp.experiment_id, "mlflow.note.content", spec["note"])
        for k, v in {**COMMON, **spec["tags"]}.items():
            c.set_experiment_tag(exp.experiment_id, k, v)
        print(f"  experiment {name} (id {exp.experiment_id}): description + "
              f"{len(COMMON) + len(spec['tags'])} tags", flush=True)

    for name, spec in MODELS.items():
        try:
            rm = c.get_registered_model(name)
        except Exception as e:
            print(f"  SKIP model {name}: {type(e).__name__}", flush=True)
            continue
        c.update_registered_model(name, description=spec["note"])
        for k, v in {**COMMON, **spec["tags"], "experiment": spec["experiment"]}.items():
            c.set_registered_model_tag(name, k, v)

        versions = c.search_model_versions(f"name='{name}'")
        latest = max(versions, key=lambda v: int(v.version))
        c.update_model_version(name, latest.version, description=spec["version_note"])
        for k, v in {"owner": OWNER, "team": TEAM, "validation_status": "passed",
                     "verified_in_sql": "yes", "lifecycle": "champion",
                     "promoted_by": "scripts/pos_perf/mlflow_metadata.py"}.items():
            c.set_model_version_tag(name, latest.version, k, v)
        if spec["tags"].get("deploy") == "NO":
            c.set_model_version_tag(name, latest.version, "lifecycle", "not-for-deployment")
            print(f"  model {name}: NO champion alias -- negative result", flush=True)
            continue
        try:
            c.set_registered_model_alias(name, "champion", latest.version)
            alias = f", alias champion -> v{latest.version}"
        except Exception as e:
            alias = f" (alias not set: {type(e).__name__})"
        print(f"  model {name}: description + tags, v{latest.version} annotated{alias}", flush=True)

    for (mname, ver), note in SUPERSEDED.items():
        try:
            c.update_model_version(mname, ver, description=note)
            for k, v in {"lifecycle": "superseded", "owner": OWNER, "team": TEAM,
                         "validation_status": "superseded",
                         "do_not_use": "yes",
                         "promoted_by": "scripts/pos_perf/mlflow_metadata.py"}.items():
                c.set_model_version_tag(mname, ver, k, v)
            print(f"  {mname} v{ver}: marked superseded", flush=True)
        except Exception as e:
            print(f"  SKIP {mname} v{ver}: {type(e).__name__}", flush=True)

    describe_runs(c)
    label_default(c)

    print("done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
