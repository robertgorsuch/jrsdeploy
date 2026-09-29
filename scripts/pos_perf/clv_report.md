# Customer lifetime value report

Run 2026-08-26, model_version customer-clv-v1. Forward 6-month gross margin per customer.

Trained on the as-of 11 cohort (1,691,971 customers, mean target 31.80) and validated out of time on as-of 17 (2,003,764 customers, mean target 27.25). The cohorts genuinely differ -- forward activity falls from 71.4 to 60.2 percent between them -- so this measures transfer across a real distribution shift, not a reshuffle.

## Objective

squared_error (conditional mean). This is deliberately the opposite choice from the demand models. An absolute-error objective predicts the conditional median, and roughly 40 percent of customers spend nothing in the next six months, so a median model would price almost everyone at zero and the portfolio total would collapse. A value model must predict the conditional mean, because the one property a CLV number has to have is that summing it across customers reproduces expected margin.

## Accuracy against the persistence baseline

| Predictor | MAE | RMSE | R2 | Portfolio calibration | Top-decile capture |
|---|---|---|---|---|---|
| model | 16.164 | 45.29 | 0.4967 | 0.9672 | 0.470 |
| margin_l6 persistence | 24.393 | 50.04 | 0.3856 | 1.1703 | 0.391 |

Beats the baseline on MAE: **yes**.

Portfolio calibration is sum(predicted) / sum(actual). A value of 1.0 means the model prices the whole book correctly; below 1.0 it is systematically under-valuing customers. This matters more than point accuracy for any budgeting use, and a model can rank well while being badly calibrated.

Top-decile capture is the share of all future margin that sits in the top predicted decile. It is the number a targeting budget is sized from.

## Value deciles

| Decile | Customers | Mean predicted | Mean actual | Share of total future margin |
|---|---|---|---|---|
| 1 | 200,377 | 0.24 | 1.53 | 0.006 |
| 2 | 200,376 | 1.57 | 2.56 | 0.009 |
| 3 | 200,376 | 3.14 | 3.75 | 0.014 |
| 4 | 200,377 | 5.40 | 6.55 | 0.024 |
| 5 | 200,376 | 8.35 | 10.10 | 0.037 |
| 6 | 200,376 | 11.70 | 14.05 | 0.052 |
| 7 | 200,377 | 17.91 | 22.75 | 0.084 |
| 8 | 200,376 | 30.05 | 33.35 | 0.122 |
| 9 | 200,376 | 43.84 | 49.65 | 0.182 |
| 10 | 200,377 | 141.35 | 128.19 | 0.470 |

Monotonically rising actual value across deciles is the property that makes a CLV model usable for targeting. A break in that monotonicity matters more than a small MAE gap.

## Feature importance (MAE rise when shuffled)

| Feature | MAE rise |
|---|---|
| loyalty_tier | 20.7971 |
| txns_life | 4.8861 |
| purchase_days_life | 2.8413 |
| sales_life | 1.8156 |
| ipt_median_days | 1.3245 |
| categories_bought | 0.7919 |
| overdue_ratio | 0.7651 |
| txns_l6 | 0.4780 |
| rfm_segment | 0.4107 |
| tenure_days | 0.3955 |
| purchase_days_l6 | 0.2197 |
| discount_l6 | 0.0643 |

## Output

customer_clv_scores carries the predicted and actual forward margin, the persistence baseline for comparison, a value decile and band, and the customer attributes needed to segment without another join.
