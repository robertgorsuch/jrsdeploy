-- build_store_day_features.sql -- DROP-and-rebuild of store_day_features, the
-- store x calendar-day feature table behind the store-day demand forecast.
-- One row per (storenumber, calendar_date) for every store-day present in
-- store_traffic: 330 stores across 2019-01-01 to 2020-12-31, about 230k rows.
-- Targets are the three same-day observations from store_traffic: sales,
-- transactions and visitors. Everything else is either known in advance
-- (calendar, planned promo count, store structure, trade-area demographics)
-- or is a weather observation that a production run would take from a
-- forecast feed instead.
--
-- LEAKAGE NOTE. stores carries whole-period rollups computed from the full
-- sales history -- total_sales, gross_margin, margin_pct, avg_weekly_sales,
-- sales_per_sqft, royalty_base_sales, total_subsidy, total_transactions,
-- distinct_customers, last_sale_date. fsa_demographics carries the same shape
-- in fsa_sales, sales_per_shopper, penetration_pct, shoppers and
-- stores_shopped. NONE of those are selected here: each one encodes the
-- future of the very series being predicted. Only structural attributes
-- (format, floor area, staff, location, trade-area population and income)
-- cross into the feature table.
--
-- conversion_pct and avg_transaction_value are likewise excluded. They are
-- contemporaneous with the target and unknown at a 14-day forecast origin.
--
-- Lag and rolling features are NOT built here. X100 has no ordered aggregate
-- windows, and at 230k rows the lags are cheaper and clearer to derive in
-- pandas -- see store_demand_model.py, which owns that step.
--
-- Requires: store_traffic, date_dim, stores, weather_daily, fsa_demographics.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS store_day_features;

CREATE TABLE store_day_features AS
SELECT
    t.storenumber,
    t.traffic_date                  AS calendar_date,
    d.jdn,
    d.yr,
    d.mo,
    d.day_of_month,
    d.day_of_year,
    d.quarter,
    d.week_of_year,
    d.dow_num,
    d.yyyymm,
    d.is_weekend,
    d.is_holiday,
    d.holiday_name,
    d.pandemic_period,
    d.promos_active,
    s.province,
    s.region,
    s.store_format,
    s.square_feet,
    s.staff_count,
    s.latitude,
    s.longitude,
    s.open_date                     AS store_open_date,
    s.franchisee_id,
    w.temp_high_c,
    w.temp_low_c,
    w.rain_mm,
    w.snow_cm,
    w.condition                     AS wx_condition,
    f.urban_flag                    AS fsa_urban_flag,
    f.population                    AS fsa_population,
    f.households                    AS fsa_households,
    f.median_income                 AS fsa_median_income,
    f.avg_household_size            AS fsa_avg_household_size,
    f.median_age                    AS fsa_median_age,
    f.pct_families_with_children    AS fsa_pct_families,
    f.pct_seniors                   AS fsa_pct_seniors,
    f.pct_french_speaking           AS fsa_pct_french,
    f.pct_owner_occupied            AS fsa_pct_owner,
    f.unemployment_rate_pct         AS fsa_unemployment,
    f.pct_recent_movers             AS fsa_pct_movers,
    f.stores_in_fsa,
    f.competitor_count_5km,
    t.sales                         AS target_sales,
    t.transactions                  AS target_transactions,
    t.visitors                      AS target_visitors
FROM store_traffic t
JOIN date_dim d
  ON t.traffic_date = d.calendar_date
JOIN stores s
  ON t.storenumber = s.storenumber
LEFT JOIN weather_daily w
  ON w.province = s.province
 AND w.calendar_date = t.traffic_date
LEFT JOIN fsa_demographics f
  ON f.fsa = s.postal_fsa;

-- Shape check: row count, store count, day count, and the null counts on the
-- two LEFT joins. Weather and FSA should both be fully matched.

SELECT COUNT(*)                              AS rows_built,
       COUNT(DISTINCT storenumber)           AS stores,
       COUNT(DISTINCT calendar_date)         AS days,
       SUM(CASE WHEN wx_condition IS NULL THEN 1 ELSE 0 END)      AS null_weather,
       SUM(CASE WHEN fsa_median_income IS NULL THEN 1 ELSE 0 END) AS null_fsa,
       SUM(CASE WHEN target_sales IS NULL THEN 1 ELSE 0 END)      AS null_target
FROM store_day_features;
