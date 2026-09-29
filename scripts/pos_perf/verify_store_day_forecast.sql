-- verify_store_day_forecast.sql -- shape and sanity checks on the store-day
-- demand forecast written by store_demand_model.py.
-- Expected: two split_role values. holdout rows carry actuals and errors,
-- forward rows carry predictions only. 317 active stores x 14 days forward.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

SELECT split_role,
       COUNT(*)                        AS rows_out,
       COUNT(DISTINCT storenumber)     AS stores,
       COUNT(DISTINCT forecast_date)   AS days,
       VARCHAR(MIN(forecast_date))     AS first_day,
       VARCHAR(MAX(forecast_date))     AS last_day,
       SUM(CASE WHEN predicted IS NULL THEN 1 ELSE 0 END) AS null_pred,
       SUM(CASE WHEN actual    IS NULL THEN 1 ELSE 0 END) AS null_actual
FROM store_day_forecast
GROUP BY split_role
ORDER BY split_role;

-- Holdout accuracy recomputed in SQL, independent of the Python metrics.
-- WAPE here must agree with store_demand_report.md.

SELECT COUNT(*)                                              AS n,
       DECIMAL(SUM(abs_error) / SUM(actual), 10, 6)          AS wape_model,
       DECIMAL(SUM(ABS(baseline_lag14 - actual)) / SUM(actual), 10, 6) AS wape_lag14,
       DECIMAL(AVG(abs_error), 12, 2)                        AS mae,
       DECIMAL(AVG(predicted - actual), 12, 2)               AS bias
FROM store_day_forecast
WHERE split_role = 'holdout' AND actual IS NOT NULL AND baseline_lag14 IS NOT NULL;

-- Error by store format: is any format systematically worse.

SELECT store_format,
       COUNT(*)                                     AS n,
       DECIMAL(SUM(abs_error) / SUM(actual), 10, 6) AS wape,
       DECIMAL(AVG(predicted - actual), 12, 2)      AS bias
FROM store_day_forecast
WHERE split_role = 'holdout' AND actual IS NOT NULL
GROUP BY store_format
ORDER BY 3 DESC;

-- Forward window totals by day. A sane 14-day forecast should show the
-- New Year dip then recover, and never go negative.

SELECT VARCHAR(forecast_date)          AS forecast_date,
       COUNT(*)                        AS stores,
       DECIMAL(SUM(predicted), 14, 2)  AS predicted_chain_sales,
       DECIMAL(MIN(predicted), 12, 2)  AS min_store,
       DECIMAL(MAX(predicted), 12, 2)  AS max_store
FROM store_day_forecast
WHERE split_role = 'forward'
GROUP BY forecast_date
ORDER BY 1;

-- Guardrail: any negative prediction is a modelling error, not a forecast.

SELECT COUNT(*) AS negative_predictions
FROM store_day_forecast
WHERE predicted < 0;
