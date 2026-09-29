-- verify_store_plu_forecast.sql -- shape and sanity checks on the PLU weekly
-- replenishment forecast written by plu_demand_model.py.
-- Expected: backtest rows carry actuals, forward rows do not. WAPE recomputed
-- here must agree with plu_demand_report.md.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

SELECT split_role,
       COUNT(*)                      AS rows_out,
       COUNT(DISTINCT storenumber)   AS stores,
       COUNT(DISTINCT plu)           AS plus,
       COUNT(DISTINCT week_seq)      AS weeks,
       VARCHAR(MIN(week_start))      AS first_week,
       VARCHAR(MAX(week_start))      AS last_week,
       SUM(CASE WHEN predicted_units IS NULL THEN 1 ELSE 0 END) AS null_pred,
       SUM(CASE WHEN actual_units    IS NULL THEN 1 ELSE 0 END) AS null_actual
FROM store_plu_forecast
GROUP BY split_role
ORDER BY split_role;

-- Backtest accuracy recomputed in SQL against all three baselines. The model
-- column must match the report. static is the fair like-for-like policy.

SELECT COUNT(*)                                                        AS n,
       DECIMAL(SUM(abs_error) / SUM(ABS(actual_units)), 10, 6)         AS wape_model,
       DECIMAL(SUM(ABS(baseline_static - actual_units))
               / SUM(ABS(actual_units)), 10, 6)                        AS wape_static,
       DECIMAL(SUM(ABS(baseline_ma4 - actual_units))
               / SUM(ABS(actual_units)), 10, 6)                        AS wape_ma4,
       DECIMAL(SUM(ABS(baseline_incumbent - actual_units))
               / SUM(ABS(actual_units)), 10, 6)                        AS wape_incumbent,
       DECIMAL(AVG(predicted_units - actual_units), 12, 4)             AS bias_units
FROM store_plu_forecast
WHERE split_role = 'backtest' AND actual_units IS NOT NULL
  AND baseline_static IS NOT NULL AND baseline_ma4 IS NOT NULL
  AND baseline_incumbent IS NOT NULL;

-- Bias by velocity band. A persistent negative bias means under-forecasting,
-- which in replenishment shows up as stockouts rather than as a metric.

SELECT velocity_band,
       COUNT(*)                                          AS n,
       DECIMAL(AVG(predicted_units), 12, 3)              AS avg_pred,
       DECIMAL(AVG(actual_units), 12, 3)                 AS avg_actual,
       DECIMAL(AVG(predicted_units - actual_units), 12, 3) AS bias_units,
       DECIMAL(SUM(abs_error) / SUM(ABS(actual_units)), 10, 6) AS wape
FROM store_plu_forecast
WHERE split_role = 'backtest' AND actual_units IS NOT NULL
GROUP BY velocity_band
ORDER BY 5;

-- Guardrails. suggested_order derives from the q0.85 ORDER model, not from
-- predicted_units, so it is checked against order_quantile. order_quantile is
-- floored at predicted_units in the model script, so quantile crossing between
-- the two independently fitted models should be zero here.

SELECT SUM(CASE WHEN predicted_units < 0 THEN 1 ELSE 0 END)          AS negative_preds,
       SUM(CASE WHEN suggested_order < 0 THEN 1 ELSE 0 END)          AS negative_orders,
       SUM(CASE WHEN suggested_order < order_quantile THEN 1 ELSE 0 END) AS order_below_quantile,
       SUM(CASE WHEN order_quantile < predicted_units THEN 1 ELSE 0 END) AS quantile_crossing
FROM store_plu_forecast;

-- Forward window: chain-wide suggested order by week and category, top 10.

SELECT VARCHAR(week_start) AS week_start,
       category,
       COUNT(*)                 AS pairs,
       SUM(suggested_order)     AS suggested_units,
       DECIMAL(SUM(predicted_units), 14, 1) AS forecast_units
FROM store_plu_forecast
WHERE split_role = 'forward'
GROUP BY week_start, category
ORDER BY 4 DESC
FETCH FIRST 10 ROWS ONLY;
