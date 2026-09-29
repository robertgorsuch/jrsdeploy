-- build_traffic_weather.sql -- DROP-and-rebuild of store_traffic and weather_daily.
-- store_traffic: one row per (store, sale date) with sales history. REAL:
-- transactions and sales for the day. FICTITIOUS but DETERMINISTIC: a
-- conversion rate between 25 and 45 percent per store-day, from which
-- visitor footfall is back-computed, so conversion analytics stay coherent
-- with the actual transaction counts.
-- weather_daily: one row per (province, day) across the full 731-day
-- calendar. Temperatures follow monthly seasonal normals per province with
-- hash jitter, precipitation and snowfall are hash events consistent with
-- temperature, and a condition label summarizes the day. Indicative
-- synthetic weather -- not historical observations.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS store_traffic;

CREATE TABLE store_traffic AS
WITH d AS (
  SELECT storenumber, DATE(saledate) AS traffic_date,
         COUNT(DISTINCT transactionuniqueid) AS transactions,
         SUM(sellingprice * quantity) AS sales
  FROM pos_sales_detail
  GROUP BY storenumber, DATE(saledate)
), c AS (
  SELECT d.*,
         25 + ABS(MOD(HASH(VARCHAR(d.storenumber) + '|' + VARCHAR(YEAR(d.traffic_date) * 10000 + MONTH(d.traffic_date) * 100 + DAY(d.traffic_date)) + 'cv'), 21)) AS conversion_pct
  FROM d
)
SELECT storenumber, traffic_date, transactions,
       DECIMAL(sales, 12, 2) AS sales,
       conversion_pct,
       INT4(transactions * 100.0 / conversion_pct) AS visitors,
       DECIMAL(sales / NULLIF(transactions, 0), 10, 2) AS avg_transaction_value
FROM c;

DROP TABLE IF EXISTS weather_daily;

CREATE TABLE weather_daily AS
WITH prov AS (
  SELECT DISTINCT province FROM stores
), g AS (
  SELECT p.province, d.calendar_date, d.jdn, d.mo,
         VARCHAR(d.jdn) + p.province AS hk,
         CASE d.mo WHEN 1 THEN -10 WHEN 2 THEN -8 WHEN 3 THEN -2 WHEN 4 THEN 6
              WHEN 5 THEN 13 WHEN 6 THEN 18 WHEN 7 THEN 21 WHEN 8 THEN 20
              WHEN 9 THEN 15 WHEN 10 THEN 8 WHEN 11 THEN 1 ELSE -6 END +
         CASE p.province WHEN 'BC' THEN 6 WHEN 'NS' THEN 2 WHEN 'NB' THEN 1
              WHEN 'PE' THEN 1 WHEN 'NL' THEN -1 WHEN 'QC' THEN -1 WHEN 'ON' THEN 0
              WHEN 'AB' THEN -3 WHEN 'SK' THEN -4 WHEN 'MB' THEN -4 ELSE -8 END AS base_temp
  FROM prov p, date_dim d
), t AS (
  SELECT g.*,
         g.base_temp + ABS(MOD(HASH(g.hk + 'tj'), 9)) - 4 AS temp_high_c,
         ABS(MOD(HASH(g.hk + 'pe'), 3)) AS precip_event,
         ABS(MOD(HASH(g.hk + 'pa'), 15)) AS precip_amt,
         ABS(MOD(HASH(g.hk + 'sa'), 20)) AS snow_amt
  FROM g
)
SELECT province, calendar_date, jdn,
       temp_high_c,
       temp_high_c - (6 + ABS(MOD(HASH(hk + 'tl'), 6))) AS temp_low_c,
       CASE WHEN precip_event = 0 AND temp_high_c > 1 THEN precip_amt ELSE 0 END AS rain_mm,
       CASE WHEN precip_event = 0 AND temp_high_c <= 1 THEN snow_amt ELSE 0 END AS snow_cm,
       CASE WHEN precip_event = 0 AND temp_high_c <= 1 AND snow_amt > 10 THEN 'Heavy Snow'
            WHEN precip_event = 0 AND temp_high_c <= 1 AND snow_amt > 0 THEN 'Snow'
            WHEN precip_event = 0 AND temp_high_c > 1 AND precip_amt > 8 THEN 'Rain'
            WHEN precip_event = 0 AND temp_high_c > 1 AND precip_amt > 0 THEN 'Showers'
            WHEN ABS(MOD(HASH(hk + 'cl'), 3)) = 0 THEN 'Cloudy'
            ELSE 'Clear' END AS condition
FROM t;
