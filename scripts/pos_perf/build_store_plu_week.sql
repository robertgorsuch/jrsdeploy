-- build_store_plu_week.sql -- DROP-and-rebuild of the store x PLU x week
-- demand spine behind the replenishment forecast.
--
-- Grain: one row per (storenumber, plu, week_seq) for every week inside the
-- carried life of that pair, INCLUDING weeks with no sales. Those zeros are
-- the demand signal -- a spine of only weeks that happened to sell would teach
-- the model that demand is never zero.
--
-- Week definition: consecutive 7-day blocks anchored on the first day of data
-- (2019-01-01), not ISO weeks. Anchoring on the data start avoids a partial
-- week at the left edge. The final partial block is dropped, leaving 104 whole
-- weeks. week_seq 0 is 2019-01-01 to 2019-01-07.
--
-- Dates come from pos_sales_txn, NOT from pos_sales_detail.saledate: that
-- column is a VARCHAR holding DD-Mon-YYYY text, so it neither sorts nor
-- compares as a date.
--
-- Transaction types. Regular Sale and Regular Return both count -- a return is
-- real negative demand and quantity is already signed. Post Void TX is
-- excluded: a void is a cancelled transaction, not a movement of stock.
--
-- LEAKAGE NOTE. This table carries the target and contemporaneous weekly
-- aggregates only. Product, store and inventory attributes are NOT joined in
-- here -- they are merged in pandas at training time, where the whole-period
-- rollups on inventory (avg_daily_units, units_90d, days_of_supply,
-- annual_turns, gmroi, units_sold_total, sales_total, reorder_point,
-- safety_stock) can be held out of the feature set. Every one of those is
-- computed from the full sales history and would leak the future.
-- reorder_point and safety_stock are kept aside deliberately: they are the
-- INCUMBENT policy this model has to beat, not inputs to it.
--
-- Requires: pos_sales_detail, pos_sales_txn, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS spw_weeks;

CREATE TABLE spw_weeks AS
SELECT (d.jdn - a.base_jdn) / 7                   AS week_seq,
       MIN(d.calendar_date)                       AS week_start,
       MAX(d.calendar_date)                       AS week_end,
       COUNT(*)                                   AS days_in_week,
       MAX(d.yr)                                  AS yr,
       MAX(d.mo)                                  AS mo,
       MAX(d.week_of_year)                        AS week_of_year,
       SUM(CASE WHEN d.is_holiday = 'Y' THEN 1 ELSE 0 END) AS holidays_in_week,
       AVG(FLOAT8(d.promos_active))               AS promos_active_avg,
       MAX(d.pandemic_period)                     AS pandemic_period
FROM date_dim d
CROSS JOIN (SELECT MIN(jdn) AS base_jdn FROM date_dim) a
GROUP BY (d.jdn - a.base_jdn) / 7;

DELETE FROM spw_weeks WHERE days_in_week < 7;

-- Weekly actuals, sparse: only pair-weeks that actually moved stock.

DROP TABLE IF EXISTS spw_actual;

-- week_seq is derived arithmetically from the julian day rather than by a
-- range join against spw_weeks: a BETWEEN join would put a 104-row range
-- lookup on the inside of a 63M-row scan.

CREATE TABLE spw_actual AS
SELECT dt.storenumber,
       dt.plu,
       (t.jdn - a.base_jdn) / 7                          AS week_seq,
       SUM(dt.quantity)                                  AS units,
       SUM(dt.quantity * dt.sellingprice)                AS sales,
       SUM(dt.quantity * (dt.sellingprice - dt.cost))    AS margin,
       SUM(CASE WHEN dt.promotiontype IS NOT NULL AND TRIM(dt.promotiontype) <> ''
                THEN dt.quantity ELSE 0 END)             AS promo_units,
       COUNT(*)                                          AS line_count
FROM pos_sales_detail dt
JOIN pos_sales_txn t
  ON dt.transactionuniqueid = t.transactionuniqueid
CROSS JOIN (SELECT MIN(jdn) AS base_jdn FROM date_dim) a
WHERE TRIM(dt.transactiontype) IN ('Regular Sale', 'Regular Return')
GROUP BY dt.storenumber, dt.plu, (t.jdn - a.base_jdn) / 7;

-- Carried life of each store-PLU pair: first through last selling week.

DROP TABLE IF EXISTS spw_pairs;

CREATE TABLE spw_pairs AS
SELECT storenumber, plu,
       MIN(week_seq) AS first_week,
       MAX(week_seq) AS last_week,
       SUM(units)    AS lifetime_units
FROM spw_actual
GROUP BY storenumber, plu;

-- Dense spine: every week inside each pair carried life, zeros included.

DROP TABLE IF EXISTS store_plu_week;

CREATE TABLE store_plu_week AS
SELECT p.storenumber,
       p.plu,
       w.week_seq,
       w.week_start,
       w.yr,
       w.mo,
       w.week_of_year,
       w.holidays_in_week,
       w.promos_active_avg,
       w.pandemic_period,
       COALESCE(a.units, 0)       AS units,
       COALESCE(a.sales, 0)       AS sales,
       COALESCE(a.margin, 0)      AS margin,
       COALESCE(a.promo_units, 0) AS promo_units,
       COALESCE(a.line_count, 0)  AS line_count
FROM spw_pairs p
JOIN spw_weeks w
  ON w.week_seq BETWEEN p.first_week AND p.last_week
LEFT JOIN spw_actual a
  ON a.storenumber = p.storenumber
 AND a.plu = p.plu
 AND a.week_seq = w.week_seq;

-- Shape check. Expect 104 whole weeks, 215,009 pairs, and a dense row count
-- well above the sparse actual count -- the difference IS the zero weeks.

SELECT (SELECT COUNT(*) FROM spw_weeks)                     AS weeks,
       (SELECT COUNT(*) FROM spw_pairs)                     AS pairs,
       (SELECT COUNT(*) FROM spw_actual)                    AS sparse_rows,
       COUNT(*)                                             AS dense_rows,
       SUM(CASE WHEN units = 0 THEN 1 ELSE 0 END)           AS zero_weeks,
       SUM(CASE WHEN units < 0 THEN 1 ELSE 0 END)           AS negative_weeks,
       DECIMAL(AVG(FLOAT8(units)), 12, 4)                   AS mean_units
FROM store_plu_week;
