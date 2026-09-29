# Store-day demand forecast report

Run 2026-08-26, model_version store-day-demand-v1, target target_sales, horizon 14 days.

Training rows 205,439. Holdout 17,595 rows from 2020-11-05 to 2020-12-31 (out-of-time). Winner: **main**.

Every lag and rolling feature is offset by at least the horizon, so no row uses information from inside its own forecast window.

## Holdout accuracy against naive baselines

| Run | n | WAPE | MAE | RMSE | R2 | Bias | lag-14 WAPE | same-dow WAPE | Beats both |
|---|---|---|---|---|---|---|---|---|---|
| main | 17,595 | 0.2120 | 1,114 | 1,668 | 0.755 | -186 | 0.3326 | 0.3622 | yes |
| pandemic_only | 17,595 | 0.3309 | 1,738 | 2,948 | 0.235 | -1,418 | 0.3326 | 0.3622 | yes |

## Regime-shift diagnostic

Trained on pre-pandemic days only, evaluated on the pandemic era. Never shipped -- it measures what ignoring the 2020 break would cost.

| n | WAPE | MAE | R2 | lag-14 WAPE |
|---|---|---|---|---|
| 95,165 | 0.2189 | 839 | 0.632 | 0.2883 |

## Permutation importance, winning run (MAE rise when shuffled)

| Feature | MAE rise |
|---|---|
| day_of_year | 530.6 |
| day_of_month | 228.0 |
| samedow_mean4 | 211.7 |
| roll91_lag14 | 151.2 |
| dow_num | 85.4 |
| lag_14 | 51.1 |
| roll7_lag14 | 38.4 |
| week_of_year | 28.7 |
| roll28_lag14 | 23.5 |
| is_holiday | 23.4 |
| lag_21 | 22.9 |
| holiday_name | 17.8 |

## Forward window

317 stores still trading on 2020-12-31 are scored for the 14 days that follow. Weather uses per-province day-of-year climatology and promos_active uses a month-by-weekday mean, because neither is known past the end of the data. Production would read a weather feed and the planned promo calendar instead.
