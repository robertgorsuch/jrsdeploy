-- build_churn_training_set.sql -- DROP-and-rebuild of churn_training_set and
-- activation_training_set, the point-in-time, leak-free model tables.
--
-- churn_training_set: stacked snapshots at 16 cutoffs -- every month end
-- from 2019-07-31 through 2020-09-30 (15 training cutoffs) plus 2020-12-31
-- (the scoring snapshot, is_scoring_row = Y, labels NULL). One row per
-- (as_of_date, customer) for every customer with two or more purchase days
-- on or before the cutoff. Every behavioural feature is computed ONLY from
-- rows dated on or before as_of_date. Labels look strictly after it:
--   churn_90        no Regular Sale in the 90 days after the cutoff
--   churn_adaptive  no Regular Sale within churn_horizon_days =
--                   max(90, 3 x median gap as of the cutoff) capped at 180
--   next_purchase_days  days to the next purchase (NULL = none observed)
-- A label is NULL when its horizon runs past 2020-12-31 (right-censored),
-- so later cutoffs carry churn_90 but may lack churn_adaptive for slow
-- buyers. Train on rows where the chosen label is NOT NULL.
-- Context blocks (demographics, diet profile, FSA, home store) are joined as
-- they stand today. The diet profile is a lifetime composition, not a
-- timing signal, so it is accepted as a mild simplification.
-- BG/NBD inputs: bgnbd_frequency = purchase_days_asof - 1,
-- bgnbd_recency = last_jdn - first_jdn, bgnbd_t = as_of_jdn - first_jdn.
--
-- activation_training_set: one row per customer, first-basket features only
-- (no tenure, so the same model scores every current one-time buyer).
-- Label activated_90 = a second purchase day within 90 days of the first,
-- NULL when the 90 days run past 2020-12-31.
--
-- Requires: pos_sales_txn, customers, customer_demographics,
-- customer_diet_profile, fsa_demographics, stores, store_traffic, date_dim,
-- loyalty_ledger, email_engagement, customer_service_cases,
-- ecommerce_orders, gift_cards.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

-- ---------------------------------------------------------------- cutoffs

DROP TABLE IF EXISTS ct_cutoffs;

CREATE TABLE ct_cutoffs AS
SELECT d.calendar_date AS as_of_date, d.jdn AS as_of_jdn, d.yyyymm AS as_of_yyyymm,
       d.pandemic_period,
       CASE WHEN d.yyyymm >= 202003 THEN (d.yyyymm / 100 - 2020) * 12 + MOD(d.yyyymm, 100) - 3 ELSE 0 END AS months_since_pandemic_start,
       CASE WHEN d.yyyymm = 202012 THEN 'Y' ELSE 'N' END AS is_scoring_row,
       x.max_jdn
FROM date_dim d
JOIN (SELECT yyyymm, MAX(jdn) AS month_end_jdn FROM date_dim GROUP BY yyyymm) me
  ON me.yyyymm = d.yyyymm AND me.month_end_jdn = d.jdn
CROSS JOIN (SELECT MAX(jdn) AS max_jdn FROM date_dim) x
WHERE d.yyyymm BETWEEN 201907 AND 202009 OR d.yyyymm = 202012;

-- ---------------------------------------------------------------- purchase days and gaps

DROP TABLE IF EXISTS ct_days;

CREATE TABLE ct_days AS
SELECT customer_id, jdn, COUNT(*) AS baskets, SUM(basket_value) AS day_value
FROM pos_sales_txn
WHERE txn_type = 'Regular Sale'
GROUP BY customer_id, jdn
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS ct_gaps;

CREATE TABLE ct_gaps AS
SELECT customer_id, jdn, baskets, day_value,
       jdn - LAG(jdn) OVER (PARTITION BY customer_id ORDER BY jdn) AS gap,
       ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY jdn) AS rk_asc
FROM ct_days
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- ---------------------------------------------------------------- as-of purchase profile

DROP TABLE IF EXISTS ct_base;

CREATE TABLE ct_base AS
SELECT c.as_of_jdn, g.customer_id,
       COUNT(*) AS purchase_days_asof,
       SUM(g.baskets) AS baskets_asof,
       SUM(g.day_value) AS sales_asof,
       MIN(g.jdn) AS first_jdn,
       MAX(g.jdn) AS last_jdn,
       MEDIAN(g.gap) AS ipt_median_asof,
       AVG(g.gap) AS ipt_mean_asof,
       MAX(g.gap) AS ipt_max_asof,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 30 THEN 1 ELSE 0 END) AS purchase_days_l30,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 90 THEN 1 ELSE 0 END) AS purchase_days_l90,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 180 THEN 1 ELSE 0 END) AS purchase_days_l180,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 180 AND g.jdn <= c.as_of_jdn - 90 THEN 1 ELSE 0 END) AS purchase_days_prior90,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 30 THEN g.day_value ELSE 0 END) AS sales_l30,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 90 THEN g.day_value ELSE 0 END) AS sales_l90,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 180 THEN g.day_value ELSE 0 END) AS sales_l180,
       SUM(CASE WHEN g.jdn > c.as_of_jdn - 180 AND g.jdn <= c.as_of_jdn - 90 THEN g.day_value ELSE 0 END) AS sales_prior90
FROM ct_gaps g
JOIN ct_cutoffs c ON g.jdn <= c.as_of_jdn
GROUP BY c.as_of_jdn, g.customer_id
HAVING COUNT(*) >= 2
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- Gap that ended on the last purchase day before the cutoff

DROP TABLE IF EXISTS ct_lastgap;

CREATE TABLE ct_lastgap AS
SELECT b.as_of_jdn, b.customer_id, g.gap AS ipt_last_asof
FROM ct_base b
JOIN ct_gaps g ON g.customer_id = b.customer_id AND g.jdn = b.last_jdn
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- ---------------------------------------------------------------- 180-day basket behaviour

DROP TABLE IF EXISTS ct_txn;

CREATE TABLE ct_txn AS
SELECT c.as_of_jdn, t.customer_id,
       SUM(CASE WHEN t.txn_type = 'Regular Return' THEN 1 ELSE 0 END) AS returns_l180,
       SUM(t.basket_margin) AS margin_l180,
       SUM(CASE WHEN t.jdn > c.as_of_jdn - 90 THEN t.basket_margin ELSE 0 END) AS margin_l90,
       SUM(t.promo_value) AS promo_sales_l180,
       SUM(t.discount_total) AS discount_l180,
       COUNT(DISTINCT t.storenumber) AS distinct_stores_l180,
       SUM(CASE WHEN t.storenumber = cu.home_store_number THEN 1 ELSE 0 END) AS home_store_txns_l180,
       COUNT(*) AS txns_l180,
       SUM(CASE WHEN t.ecommerce_flag = 'Y' THEN 1 ELSE 0 END) AS ecommerce_l180,
       AVG(1.0 * t.distinct_categories) AS avg_categories_l180,
       AVG(1.0 * t.basket_items) AS avg_items_l180,
       SUM(CASE WHEN t.is_weekend = 'Y' THEN 1 ELSE 0 END) AS weekend_txns_l180
FROM pos_sales_txn t
JOIN customers cu ON cu.customer_id = t.customer_id
JOIN ct_cutoffs c ON t.jdn <= c.as_of_jdn AND t.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, t.customer_id
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- ---------------------------------------------------------------- 180-day engagement events

DROP TABLE IF EXISTS ct_loy;

CREATE TABLE ct_loy AS
SELECT c.as_of_jdn, l.customer_id,
       SUM(CASE WHEN l.entry_type = 'EARN' THEN l.points ELSE 0 END) AS points_earned_l180,
       SUM(CASE WHEN l.entry_type = 'REDEEM' THEN -l.points ELSE 0 END) AS points_redeemed_l180,
       SUM(CASE WHEN l.entry_type = 'REDEEM' THEN 1 ELSE 0 END) AS redemptions_l180
FROM loyalty_ledger l
JOIN date_dim d ON d.calendar_date = l.entry_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, l.customer_id
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS ct_email;

CREATE TABLE ct_email AS
SELECT c.as_of_jdn, e.customer_id,
       COUNT(*) AS emails_sent_l180,
       SUM(CASE WHEN e.opened_flag = 'Y' THEN 1 ELSE 0 END) AS emails_opened_l180,
       SUM(CASE WHEN e.clicked_flag = 'Y' THEN 1 ELSE 0 END) AS emails_clicked_l180
FROM email_engagement e
JOIN date_dim d ON d.calendar_date = e.send_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, e.customer_id;

DROP TABLE IF EXISTS ct_cases;

CREATE TABLE ct_cases AS
SELECT c.as_of_jdn, k.customer_id,
       COUNT(*) AS cases_l180,
       MIN(k.csat_score) AS min_csat_l180,
       SUM(CASE WHEN k.status <> 'Closed' THEN 1 ELSE 0 END) AS open_cases_l180
FROM customer_service_cases k
JOIN date_dim d ON d.calendar_date = k.open_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, k.customer_id;

DROP TABLE IF EXISTS ct_ecom;

CREATE TABLE ct_ecom AS
SELECT c.as_of_jdn, o.customer_id,
       SUM(CASE WHEN o.fulfilled_late = 'Y' THEN 1 ELSE 0 END) AS ecommerce_late_l180,
       MIN(o.satisfaction_score) AS min_ecom_satisfaction_l180
FROM ecommerce_orders o
JOIN date_dim d ON d.calendar_date = o.order_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, o.customer_id;

DROP TABLE IF EXISTS ct_gift;

CREATE TABLE ct_gift AS
SELECT c.as_of_jdn, g.purchased_by AS customer_id,
       COUNT(*) AS gift_cards_l180
FROM gift_cards g
JOIN date_dim d ON d.calendar_date = g.purchase_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, g.purchased_by;

-- ---------------------------------------------------------------- home-store traffic trend at cutoff

DROP TABLE IF EXISTS ct_store;

CREATE TABLE ct_store AS
SELECT c.as_of_jdn, s.storenumber,
       SUM(CASE WHEN d.jdn > c.as_of_jdn - 90 THEN s.transactions ELSE 0 END) AS store_txns_l90,
       SUM(CASE WHEN d.jdn <= c.as_of_jdn - 90 THEN s.transactions ELSE 0 END) AS store_txns_prior90
FROM store_traffic s
JOIN date_dim d ON d.calendar_date = s.traffic_date
JOIN ct_cutoffs c ON d.jdn <= c.as_of_jdn AND d.jdn > c.as_of_jdn - 180
GROUP BY c.as_of_jdn, s.storenumber;

-- ---------------------------------------------------------------- labels

DROP TABLE IF EXISTS ct_next;

CREATE TABLE ct_next AS
SELECT c.as_of_jdn, g.customer_id, MIN(g.jdn) - c.as_of_jdn AS next_purchase_days
FROM ct_days g
JOIN ct_cutoffs c ON g.jdn > c.as_of_jdn
GROUP BY c.as_of_jdn, g.customer_id
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- ---------------------------------------------------------------- assemble

DROP TABLE IF EXISTS churn_training_set;

CREATE TABLE churn_training_set AS
WITH h AS (
  SELECT b.*, c.as_of_date, c.as_of_yyyymm, c.pandemic_period, c.months_since_pandemic_start,
         c.is_scoring_row, c.max_jdn,
         LEAST(180, GREATEST(90, INT4(3 * b.ipt_median_asof))) AS churn_horizon_days,
         c.as_of_jdn - b.last_jdn AS days_since_last,
         c.as_of_jdn - b.first_jdn AS tenure_days
  FROM ct_base b
  JOIN ct_cutoffs c ON c.as_of_jdn = b.as_of_jdn
)
SELECT h.as_of_date, h.as_of_yyyymm, h.customer_id, h.is_scoring_row,
       h.pandemic_period, h.months_since_pandemic_start,
       -- purchase profile as of cutoff
       h.purchase_days_asof, h.baskets_asof,
       DECIMAL(h.sales_asof, 12, 2) AS sales_asof,
       h.tenure_days, h.days_since_last,
       DECIMAL(h.ipt_median_asof, 8, 1) AS ipt_median_asof,
       DECIMAL(h.ipt_mean_asof, 8, 1) AS ipt_mean_asof,
       h.ipt_max_asof, lg.ipt_last_asof,
       DECIMAL(1.0 * h.days_since_last / GREATEST(1, h.ipt_median_asof), 8, 2) AS overdue_ratio,
       h.churn_horizon_days,
       h.purchase_days_l30, h.purchase_days_l90, h.purchase_days_l180, h.purchase_days_prior90,
       DECIMAL(h.sales_l30, 12, 2) AS sales_l30,
       DECIMAL(h.sales_l90, 12, 2) AS sales_l90,
       DECIMAL(h.sales_l180, 12, 2) AS sales_l180,
       DECIMAL(h.sales_prior90, 12, 2) AS sales_prior90,
       CASE WHEN h.purchase_days_prior90 > 0 THEN DECIMAL(1.0 * h.purchase_days_l90 / h.purchase_days_prior90, 8, 2) END AS trend_ratio_l90,
       CASE WHEN h.sales_prior90 > 0 THEN DECIMAL(h.sales_l90 / h.sales_prior90, 8, 2) END AS sales_trend_ratio_l90,
       DECIMAL(h.sales_asof / NULLIF(h.baskets_asof, 0), 10, 2) AS avg_basket_asof,
       -- BG/NBD inputs
       h.purchase_days_asof - 1 AS bgnbd_frequency,
       h.last_jdn - h.first_jdn AS bgnbd_recency,
       h.as_of_jdn - h.first_jdn AS bgnbd_t,
       -- 180-day basket behaviour
       COALESCE(t.txns_l180, 0) AS txns_l180,
       COALESCE(t.returns_l180, 0) AS returns_l180,
       DECIMAL(COALESCE(t.margin_l180, 0), 12, 2) AS margin_l180,
       DECIMAL(COALESCE(t.margin_l90, 0), 12, 2) AS margin_l90,
       DECIMAL(COALESCE(t.promo_sales_l180, 0), 12, 2) AS promo_sales_l180,
       DECIMAL(100.0 * COALESCE(t.promo_sales_l180, 0) / NULLIF(h.sales_l180, 0), 8, 2) AS promo_share_l180,
       DECIMAL(COALESCE(t.discount_l180, 0), 12, 2) AS discount_l180,
       COALESCE(t.distinct_stores_l180, 0) AS distinct_stores_l180,
       DECIMAL(100.0 * COALESCE(t.home_store_txns_l180, 0) / NULLIF(t.txns_l180, 0), 8, 2) AS home_store_share_l180,
       COALESCE(t.ecommerce_l180, 0) AS ecommerce_l180,
       DECIMAL(t.avg_categories_l180, 6, 2) AS avg_categories_l180,
       DECIMAL(t.avg_items_l180, 8, 2) AS avg_items_l180,
       COALESCE(t.weekend_txns_l180, 0) AS weekend_txns_l180,
       -- 180-day engagement
       COALESCE(l.points_earned_l180, 0) AS points_earned_l180,
       COALESCE(l.points_redeemed_l180, 0) AS points_redeemed_l180,
       COALESCE(l.redemptions_l180, 0) AS redemptions_l180,
       DECIMAL(100.0 * COALESCE(l.points_redeemed_l180, 0) / NULLIF(l.points_earned_l180, 0), 8, 2) AS redemption_rate_l180,
       COALESCE(e.emails_sent_l180, 0) AS emails_sent_l180,
       COALESCE(e.emails_opened_l180, 0) AS emails_opened_l180,
       COALESCE(e.emails_clicked_l180, 0) AS emails_clicked_l180,
       DECIMAL(100.0 * COALESCE(e.emails_opened_l180, 0) / NULLIF(e.emails_sent_l180, 0), 8, 2) AS email_open_rate_l180,
       COALESCE(k.cases_l180, 0) AS cases_l180,
       k.min_csat_l180,
       COALESCE(k.open_cases_l180, 0) AS open_cases_l180,
       COALESCE(o.ecommerce_late_l180, 0) AS ecommerce_late_l180,
       o.min_ecom_satisfaction_l180,
       COALESCE(gc.gift_cards_l180, 0) AS gift_cards_l180,
       -- customer context
       cu.home_store_number, cu.province, cu.home_region, cu.email_opt_in, cu.loyalty_tier,
       cu.favorite_category,
       dm.age_band, dm.gender, dm.household_size, dm.household_income_band, dm.life_stage,
       dm.children_flag, dm.dwelling_type, dm.tenure_type, dm.language_pref,
       dm.employment_status, dm.education_level, dm.acquisition_channel, dm.demographics_consent,
       dp.diet_profile, dp.basket_profile, dp.flagged_coverage_pct, dp.vegetarian_pct,
       dp.single_serve_pct, dp.prepared_meals_pct, dp.categories_bought,
       f.median_income AS fsa_median_income, f.urban_flag AS fsa_urban_flag,
       f.competitor_count_5km, f.stores_in_fsa, f.penetration_pct AS fsa_penetration_pct,
       f.pct_families_with_children AS fsa_pct_families, f.median_age AS fsa_median_age,
       st.store_format, st.square_feet AS store_square_feet, st.staff_count AS store_staff_count,
       st.sales_per_sqft AS store_sales_per_sqft, st.margin_pct AS store_margin_pct,
       CASE WHEN sx.store_txns_prior90 > 0 THEN DECIMAL(1.0 * sx.store_txns_l90 / sx.store_txns_prior90, 8, 2) END AS store_traffic_trend_l90,
       -- labels (NULL when censored or scoring row)
       n.next_purchase_days,
       CASE WHEN h.is_scoring_row = 'Y' OR h.as_of_jdn + 90 > h.max_jdn THEN NULL
            WHEN n.next_purchase_days IS NULL OR n.next_purchase_days > 90 THEN 1 ELSE 0 END AS churn_90,
       CASE WHEN h.is_scoring_row = 'Y' OR h.as_of_jdn + h.churn_horizon_days > h.max_jdn THEN NULL
            WHEN n.next_purchase_days IS NULL OR n.next_purchase_days > h.churn_horizon_days THEN 1 ELSE 0 END AS churn_adaptive,
       CASE WHEN n.next_purchase_days IS NULL THEN h.max_jdn - h.as_of_jdn END AS censored_after_days
FROM h
LEFT JOIN ct_lastgap lg ON lg.as_of_jdn = h.as_of_jdn AND lg.customer_id = h.customer_id
LEFT JOIN ct_txn t      ON t.as_of_jdn = h.as_of_jdn AND t.customer_id = h.customer_id
LEFT JOIN ct_loy l      ON l.as_of_jdn = h.as_of_jdn AND l.customer_id = h.customer_id
LEFT JOIN ct_email e    ON e.as_of_jdn = h.as_of_jdn AND e.customer_id = h.customer_id
LEFT JOIN ct_cases k    ON k.as_of_jdn = h.as_of_jdn AND k.customer_id = h.customer_id
LEFT JOIN ct_ecom o     ON o.as_of_jdn = h.as_of_jdn AND o.customer_id = h.customer_id
LEFT JOIN ct_gift gc    ON gc.as_of_jdn = h.as_of_jdn AND gc.customer_id = h.customer_id
LEFT JOIN ct_next n     ON n.as_of_jdn = h.as_of_jdn AND n.customer_id = h.customer_id
JOIN customers cu       ON cu.customer_id = h.customer_id
LEFT JOIN customer_demographics dm ON dm.customer_id = h.customer_id
LEFT JOIN customer_diet_profile dp ON dp.customer_id = h.customer_id
LEFT JOIN fsa_demographics f ON f.fsa = LEFT(cu.postal_code, 3)
LEFT JOIN stores st     ON st.storenumber = cu.home_store_number
LEFT JOIN ct_store sx   ON sx.as_of_jdn = h.as_of_jdn AND sx.storenumber = cu.home_store_number
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- ---------------------------------------------------------------- activation set (one-time buyers)

DROP TABLE IF EXISTS act_first;

CREATE TABLE act_first AS
SELECT customer_id, transactionuniqueid, jdn, storenumber, sale_hour, dow_num, is_weekend, is_holiday,
       pandemic_period, basket_value, basket_items, basket_margin, discount_total, promo_flag,
       promo_value, distinct_categories, distinct_plus, ecommerce_flag, email_flag
FROM (
  SELECT t.*, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY jdn, sale_hour, transactionuniqueid) AS rk
  FROM pos_sales_txn t
  WHERE txn_type = 'Regular Sale'
) x WHERE rk = 1
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS act_second;

CREATE TABLE act_second AS
SELECT customer_id, gap AS days_to_second
FROM ct_gaps
WHERE rk_asc = 2;

DROP TABLE IF EXISTS activation_training_set;

CREATE TABLE activation_training_set AS
SELECT a.customer_id, d.calendar_date AS first_purchase_date, a.jdn AS first_jdn,
       x.max_jdn - a.jdn AS days_since_first,
       a.storenumber AS first_store_number, a.sale_hour, a.dow_num, a.is_weekend, a.is_holiday,
       a.pandemic_period,
       a.basket_value AS first_basket_value, a.basket_items AS first_basket_items,
       a.basket_margin AS first_basket_margin, a.discount_total AS first_discount,
       a.promo_flag AS first_promo_flag, a.promo_value AS first_promo_value,
       a.distinct_categories AS first_categories, a.distinct_plus AS first_distinct_plus,
       a.ecommerce_flag AS first_ecommerce_flag, a.email_flag,
       cu.province, cu.home_region, cu.favorite_category,
       dm.age_band, dm.gender, dm.household_size, dm.household_income_band, dm.life_stage,
       dm.dwelling_type, dm.language_pref, dm.acquisition_channel,
       f.median_income AS fsa_median_income, f.urban_flag AS fsa_urban_flag,
       f.competitor_count_5km, f.stores_in_fsa,
       st.store_format, st.sales_per_sqft AS store_sales_per_sqft,
       s2.days_to_second,
       CASE WHEN a.jdn + 90 > x.max_jdn THEN NULL
            WHEN s2.days_to_second IS NOT NULL AND s2.days_to_second <= 90 THEN 1 ELSE 0 END AS activated_90,
       CASE WHEN s2.days_to_second IS NULL THEN 'Y' ELSE 'N' END AS is_one_time
FROM act_first a
CROSS JOIN (SELECT MAX(jdn) AS max_jdn FROM date_dim) x
JOIN date_dim d ON d.jdn = a.jdn
JOIN customers cu ON cu.customer_id = a.customer_id
LEFT JOIN act_second s2 ON s2.customer_id = a.customer_id
LEFT JOIN customer_demographics dm ON dm.customer_id = a.customer_id
LEFT JOIN fsa_demographics f ON f.fsa = LEFT(cu.postal_code, 3)
LEFT JOIN stores st ON st.storenumber = a.storenumber
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS act_second;

DROP TABLE IF EXISTS act_first;

DROP TABLE IF EXISTS ct_next;

DROP TABLE IF EXISTS ct_store;

DROP TABLE IF EXISTS ct_gift;

DROP TABLE IF EXISTS ct_ecom;

DROP TABLE IF EXISTS ct_cases;

DROP TABLE IF EXISTS ct_email;

DROP TABLE IF EXISTS ct_loy;

DROP TABLE IF EXISTS ct_txn;

DROP TABLE IF EXISTS ct_lastgap;

DROP TABLE IF EXISTS ct_base;

DROP TABLE IF EXISTS ct_gaps;

DROP TABLE IF EXISTS ct_days;

DROP TABLE IF EXISTS ct_cutoffs;

CREATE STATISTICS FOR churn_training_set;

CREATE STATISTICS FOR activation_training_set;
