-- build_customer_ipt_stats.sql -- DROP-and-rebuild of customer_ipt_stats,
-- the inter-purchase-time (IPT) profile and churn-lite score, one row per
-- customer (3.18M). Everything here is REAL and derived from pos_sales_txn.
-- A purchase day is a calendar day with at least one Regular Sale, so two
-- baskets on the same day count as one purchase occasion. Gaps are the days
-- between consecutive purchase days. The as-of date is the last day in
-- date_dim (2020-12-31), matching recency_days on the customers dimension.
-- churn_horizon_days is the adaptive horizon used by churn_training_set --
-- max(90, 3 x median gap) capped at 180 -- so lifecycle_status here and the
-- churn_adaptive label there agree by construction.
-- overdue_ratio = days silent divided by the median gap. Above 1.5 is
-- Lapsing, at or beyond the horizon is Churned. One purchase day only means
-- One-time: no retention signal, routed to the activation model instead.
-- Requires: pos_sales_txn (build_pos_sales_txn.sql), date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS ipt_days;

CREATE TABLE ipt_days AS
SELECT customer_id, jdn,
       COUNT(*) AS baskets,
       SUM(basket_value) AS day_value
FROM pos_sales_txn
WHERE txn_type = 'Regular Sale'
GROUP BY customer_id, jdn
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- As-of date materialised into a one-row table: X100 rejects aggregates that
-- reference a scalar subquery, so the value is carried as a plain column

DROP TABLE IF EXISTS ipt_asof;

CREATE TABLE ipt_asof AS
SELECT MAX(jdn) AS as_of_jdn FROM date_dim;

DROP TABLE IF EXISTS ipt_gaps;

CREATE TABLE ipt_gaps AS
SELECT d.customer_id, d.jdn, d.baskets, d.day_value, a.as_of_jdn,
       d.jdn - LAG(d.jdn) OVER (PARTITION BY d.customer_id ORDER BY d.jdn) AS gap,
       ROW_NUMBER() OVER (PARTITION BY d.customer_id ORDER BY d.jdn DESC) AS rk_desc
FROM ipt_days d
CROSS JOIN ipt_asof a
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS ipt_agg;

CREATE TABLE ipt_agg AS
SELECT g.customer_id,
       COUNT(*) AS purchase_days,
       SUM(g.baskets) AS baskets,
       MIN(g.jdn) AS first_jdn,
       MAX(g.jdn) AS last_jdn,
       MEDIAN(g.gap) AS ipt_median_days,
       AVG(g.gap) AS ipt_mean_days,
       AVG(g.gap * g.gap) AS ipt_gap_sq,
       MIN(g.gap) AS ipt_min_days,
       MAX(g.gap) AS ipt_max_days,
       MAX(CASE WHEN g.rk_desc = 1 THEN g.gap END) AS ipt_last_days,
       SUM(CASE WHEN g.jdn > g.as_of_jdn - 90 THEN 1 ELSE 0 END) AS purchases_l90,
       SUM(CASE WHEN g.jdn > g.as_of_jdn - 180 AND g.jdn <= g.as_of_jdn - 90 THEN 1 ELSE 0 END) AS purchases_prior90,
       SUM(CASE WHEN g.jdn > g.as_of_jdn - 180 THEN 1 ELSE 0 END) AS purchases_l180,
       SUM(CASE WHEN g.jdn > g.as_of_jdn - 90 THEN g.day_value ELSE 0 END) AS value_l90,
       SUM(CASE WHEN g.jdn > g.as_of_jdn - 180 AND g.jdn <= g.as_of_jdn - 90 THEN g.day_value ELSE 0 END) AS value_prior90,
       MAX(g.as_of_jdn) AS as_of_jdn
FROM ipt_gaps g
GROUP BY g.customer_id;

DROP TABLE IF EXISTS customer_ipt_stats;

CREATE TABLE customer_ipt_stats AS
WITH s AS (
  SELECT a.*,
         a.as_of_jdn - a.last_jdn AS days_silent,
         a.as_of_jdn - a.first_jdn AS tenure_days,
         CASE WHEN a.purchase_days >= 2
              THEN LEAST(180, GREATEST(90, INT4(3 * a.ipt_median_days))) END AS churn_horizon_days
  FROM ipt_agg a
)
SELECT customer_id, purchase_days, baskets,
       d1.calendar_date AS first_purchase_date,
       d2.calendar_date AS last_purchase_date,
       first_jdn, last_jdn, tenure_days, days_silent,
       DECIMAL(ipt_median_days, 8, 1) AS ipt_median_days,
       DECIMAL(ipt_mean_days, 8, 1) AS ipt_mean_days,
       DECIMAL(SQRT(GREATEST(0, ipt_gap_sq - ipt_mean_days * ipt_mean_days)), 8, 1) AS ipt_stddev_days,
       ipt_min_days, ipt_max_days, ipt_last_days,
       CASE WHEN purchase_days >= 2 THEN d2.calendar_date + INT4(ipt_median_days) END AS expected_next_purchase,
       CASE WHEN purchase_days >= 2
            THEN DECIMAL(1.0 * days_silent / GREATEST(1, ipt_median_days), 8, 2) END AS overdue_ratio,
       churn_horizon_days,
       purchases_l90, purchases_prior90, purchases_l180,
       DECIMAL(value_l90, 12, 2) AS value_l90,
       DECIMAL(value_prior90, 12, 2) AS value_prior90,
       CASE WHEN purchases_prior90 > 0
            THEN DECIMAL(1.0 * purchases_l90 / purchases_prior90, 8, 2) END AS trend_ratio_l90_vs_prior,
       CASE WHEN purchase_days = 1 THEN 'One-time'
            WHEN tenure_days < 90 THEN 'New'
            WHEN days_silent >= churn_horizon_days THEN 'Churned'
            WHEN days_silent >= churn_horizon_days / 2
                 AND 1.0 * days_silent / GREATEST(1, ipt_median_days) >= 1.5 THEN 'Lapsing'
            ELSE 'Active' END AS lifecycle_status
FROM s
JOIN date_dim d1 ON d1.jdn = s.first_jdn
JOIN date_dim d2 ON d2.jdn = s.last_jdn;

DROP TABLE IF EXISTS ipt_agg;

DROP TABLE IF EXISTS ipt_gaps;

DROP TABLE IF EXISTS ipt_days;

DROP TABLE IF EXISTS ipt_asof;

CREATE STATISTICS FOR customer_ipt_stats;
