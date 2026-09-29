# Churn model report

Run 2026-08-23, model_version churn-gbm-v1, sample 8 percent of customers.

Validation is out-of-time (cutoffs 2020-07-31 to 2020-09-30) and out-of-customer
(hash buckets never seen in training). Label = churn_adaptive: no Regular Sale within
max(90, 3 x median gap) days, capped at 180.

| Scorer | n | Positive rate | AUC-ROC | AUC-PR | Lift top decile | Brier |
|---|---|---|---|---|---|---|
| overdue_ratio | 43,913 | 0.424 | 0.7946 | 0.7336 | 2.00 | 0.4214 |
| bgnbd_1_minus_palive | 43,913 | 0.424 | 0.8228 | 0.7494 | 2.01 | 0.2142 |
| gbm | 43,913 | 0.424 | 0.8524 | 0.8058 | 2.16 | 0.1555 |
| gbm_vs_churn_90 | 43,913 | 0.442 | 0.8477 | 0.8096 | 2.08 | 0.1581 |
| gbm_Platinum | 8,564 | 0.082 | 0.8031 | 0.3448 | 4.37 | 0.0698 |
| gbm_Gold | 15,668 | 0.260 | 0.7196 | 0.4788 | 2.18 | 0.1778 |
| gbm_Silver | 13,432 | 0.605 | 0.6877 | 0.7590 | 1.40 | 0.2161 |
| gbm_Bronze | 6,249 | 0.914 | 0.7037 | 0.9604 | 1.09 | 0.0866 |

BG/NBD parameters (weeks): r=1.845, alpha=16.185, a=0.107, b=0.869.
GBM iterations: 400.

## Calibration (validation deciles)

| Decile | n | Predicted | Actual |
|---|---|---|---|
| 0 | 4,392 | 0.039 | 0.027 |
| 1 | 4,391 | 0.107 | 0.079 |
| 2 | 4,391 | 0.182 | 0.142 |
| 3 | 4,391 | 0.269 | 0.230 |
| 4 | 4,392 | 0.375 | 0.315 |
| 5 | 4,391 | 0.498 | 0.454 |
| 6 | 4,391 | 0.622 | 0.573 |
| 7 | 4,391 | 0.728 | 0.690 |
| 8 | 4,391 | 0.813 | 0.813 |
| 9 | 4,392 | 0.897 | 0.915 |

## Permutation importance (AUC drop, validation subsample)

| Feature | AUC drop | Direction |
|---|---|---|
| bgnbd_p_alive | 0.1416 | -0.50 |
| single_serve_pct | 0.0119 | +0.03 |
| prepared_meals_pct | 0.0116 | -0.01 |
| vegetarian_pct | 0.0089 | +0.07 |
| ipt_max_asof | 0.0073 | -0.14 |
| sales_asof | 0.0040 | -0.35 |
| purchase_days_asof | 0.0022 | -0.39 |
| ipt_median_asof | 0.0018 | -0.07 |
| purchase_days_l180 | 0.0017 | -0.43 |
| ipt_last_asof | 0.0012 | +0.03 |
| avg_categories_l180 | 0.0012 | -0.06 |
| bgnbd_recency | 0.0011 | -0.50 |
| overdue_ratio | 0.0010 | +0.23 |
| store_sales_per_sqft | 0.0010 | -0.04 |
| diet_profile | 0.0009 | +0.00 |
| avg_basket_asof | 0.0008 | -0.06 |
| email_opt_in | 0.0007 | +0.00 |
| tenure_days | 0.0007 | -0.24 |
| favorite_category | 0.0005 | +0.00 |
| home_store_share_l180 | 0.0005 | +0.07 |
| ipt_mean_asof | 0.0004 | -0.03 |
| days_since_last | 0.0004 | +0.48 |
| avg_items_l180 | 0.0003 | -0.07 |
| baskets_asof | 0.0002 | -0.32 |
| purchase_days_l30 | 0.0002 | -0.34 |

## Activation model (second purchase within 90 days)

AUC-ROC 0.5611, AUC-PR 0.3242, lift top decile 1.38, positive rate 0.272, n=59,068 (out-of-time split on first purchase day).

| Feature | AUC drop | Direction |
|---|---|---|
| email_flag | 0.0385 | +0.10 |
| first_basket_items | 0.0273 | +0.09 |
| first_basket_value | 0.0061 | +0.08 |
| first_categories | 0.0046 | +0.09 |
| home_region | 0.0041 | +0.00 |
| first_promo_value | 0.0018 | +0.03 |
| province | 0.0011 | +0.00 |
| first_distinct_plus | 0.0010 | +0.10 |
| dow_num | 0.0006 | +0.00 |
| is_holiday | 0.0005 | +0.00 |
| age_band | 0.0003 | +0.00 |
| language_pref | 0.0002 | +0.00 |

Risk bands: Critical >= 0.70, High >= 0.45, Watch >= 0.25, else Low.
Driver codes are z-score x importance attributions, not SHAP values.
