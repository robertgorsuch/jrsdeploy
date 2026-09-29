# Supplier reliability report

Run 2026-08-26, model_version supplier-reliability-v1. 92,472 purchase orders across 12 suppliers. Trained on orders to 2020-06-30, evaluated on the 22,824 that follow.

Two heads: expected lead time for planning, and probability of on-time arrival for sizing the safety buffer by risk instead of by a flat rule.

## Lead time, against the number already on the PO

| Predictor | MAE (days) | RMSE | R2 | Bias |
|---|---|---|---|---|
| model | 1.215 | 1.422 | 0.582 | -0.009 |
| expected_lead_days on the PO | 1.205 | 1.419 | 0.583 | -0.003 |
| training mean | 1.797 | 2.199 | -0.000 | -0.005 |

Beats the PO expectation: **NO**. That is the baseline that decides whether this model is worth running -- the supplier already tells you how long it expects to take, for free.

## On-time delivery

| Predictor | AUC-ROC | AUC-PR | Brier | Top-decile lift |
|---|---|---|---|---|
| model | 0.5002 | 0.8465 | 0.1305 | 1.006 |
| base rate (0.846) | 0.5000 | 0.8459 | 0.1304 | - |

## What was deliberately left out

suppliers carries on_time_pct, avg_fill_rate_pct, purchase_orders and total_spend, all computed over every order including the ones being predicted. Feeding a supplier its own future on-time rate would produce a spectacular and meaningless AUC. Delivery outcomes on the order itself -- fill_rate_pct, received_units, backordered_units -- are excluded for the same reason: they are not known when the order is raised.

## Feature importance, lead time (MAE rise when shuffled)

| Feature | MAE rise |
|---|---|
| supplier_name | 0.9320 |
| expected_lead_days | 0.0106 |
| ordered_units | 0.0061 |
| po_value_cost | 0.0039 |
| line_count | 0.0023 |
| store_format | 0.0004 |
| order_dow | 0.0003 |
| province | 0.0002 |
| payment_terms | 0.0001 |
| staff_count | 0.0001 |

## Output

supplier_reliability_forecast holds the holdout orders with predicted and actual lead time, the error of both the model and the PO expectation side by side, the on-time probability, a risk band and a recommended buffer in days. The buffer comes from the 90th percentile of the model residual (2.00 days) scaled by the predicted risk, so an order from a reliable supplier carries less padding than one from a shaky one -- which is the point of predicting risk at all.
