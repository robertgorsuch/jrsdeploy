# PLU weekly replenishment forecast report

Run 2026-08-26, model_version plu-weekly-demand-v1, horizon 2 weeks, grain store x PLU x week.

Dense panel 15,304,087 pair-weeks, 23.9% of them zero. Trained on 1,302,396 rows from 32 stores (storenumber mod 10 = 0), weeks 0 to 95. Holdout is the final 8 weeks.

Every lag and rolling feature is offset by at least the horizon. Max lag 26 weeks -- there is no 52-week lag, because 104 weeks of history gives each pair exactly one prior observation, and the store-day model showed single-year seasonality to be fragile. week_of_year carries seasonality instead.

## Accuracy against baselines

valid_unseen is the honest number -- those stores were never trained on.

| Split | n | WAPE | MAE | R2 | Bias | lag2 | ma4 | static(train) | incumbent(biased) | Beats ma4 | Beats static |
|---|---|---|---|---|---|---|---|---|---|---|---|
| valid_seen | 104,297 | 0.5010 | 3.698 | 0.527 | -1.869 | 0.5931 | 0.5226 | 0.5716 | 0.4720 | yes | yes |
| valid_unseen | 104,135 | 0.5064 | 3.740 | 0.536 | -1.886 | 0.6004 | 0.5294 | 0.6037 | 0.4766 | yes | yes |

The incumbent baseline is inventory.avg_daily_units x 7, the static parameter behind reorder_point today. It is optimistically biased: that average spans the whole period, holdout weeks included, so it has seen the future.

## By velocity band, valid_unseen

| Band | n | WAPE | MAE | Bias |
|---|---|---|---|---|
| fast | 12,498 | 0.4389 | 10.595 | -6.058 |
| medium | 57,657 | 0.5170 | 3.447 | -1.493 |
| slow | 33,980 | 0.7023 | 1.718 | -1.017 |

Bands come from mean weekly units in the TRAINING period only: fast >= 10, medium 2 to 10, slow < 2.

## Permutation importance, valid_unseen (MAE rise when shuffled)

| Feature | MAE rise |
|---|---|
| roll4 | 1.0692 |
| roll13 | 0.8261 |
| week_of_year | 0.2595 |
| sub_category | 0.2457 |
| lag_2 | 0.1776 |
| roll26 | 0.1705 |
| lag_6 | 0.0851 |
| package_size | 0.0489 |
| lag_3 | 0.0427 |
| promo_lag2 | 0.0385 |
| lag_26 | 0.0278 |
| lag_4 | 0.0257 |
| roll13_std | 0.0254 |
| unit_retail | 0.0242 |
| unit_cost | 0.0177 |

## Output

store_plu_forecast holds 265,155 backtest rows (the last 2 whole weeks, with actuals, so the table can be verified in SQL) and 256,520 forward rows (the 2 weeks after the data ends, no actuals). Each row carries both baselines, the velocity band, and suggested_order -- the prediction rounded up to a whole case using inventory.case_size, which is what an ordering system would actually send.
