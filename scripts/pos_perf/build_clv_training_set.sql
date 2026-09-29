-- build_clv_training_set.sql -- customer-level features and a forward-margin
-- target for the customer lifetime value model.
--
-- Grain: one row per (customer_id, as_of_seq). Two as-of points are built so
-- the model can be validated OUT OF TIME rather than on a random split:
--   as_of_seq 11 = 2019-12, target = gross margin over 2020-01 .. 2020-06
--   as_of_seq 17 = 2020-06, target = gross margin over 2020-07 .. 2020-12
-- Training uses the earlier cohort, evaluation the later one. A random split
-- would let the model learn from the same months it is scored on.
--
-- Every feature is computed from months at or before the as-of month. Nothing
-- from the target window crosses over -- that is the whole point of the
-- as_of_seq join condition below, and it is the easiest thing to get wrong in
-- a value model.
--
-- HORIZON is 6 months, not 12, because the data spans only 24 months. A
-- 12-month horizon would leave exactly one usable cohort and no way to
-- validate out of time.
--
-- Requires: customer_month, customers, customer_demographics,
--           customer_diet_profile, customer_ipt_stats.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS clv_asof;

CREATE TABLE clv_asof AS
SELECT 11 AS as_of_seq, 6 AS horizon FROM (SELECT 1 AS one) d1
UNION ALL
SELECT 17 AS as_of_seq, 6 AS horizon FROM (SELECT 1 AS one) d2;

-- Behaviour up to and including the as-of month.

DROP TABLE IF EXISTS clv_hist;

CREATE TABLE clv_hist AS
SELECT m.customer_id,
       a.as_of_seq,
       COUNT(*)                                     AS months_observed,
       MAX(m.months_since_first)                    AS months_since_first,
       SUM(m.sales)                                 AS sales_life,
       SUM(m.margin)                                AS margin_life,
       SUM(m.transactions)                          AS txns_life,
       SUM(m.purchase_days)                         AS purchase_days_life,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 3  THEN m.sales ELSE 0 END)        AS sales_l3,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.sales ELSE 0 END)        AS sales_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 12 THEN m.sales ELSE 0 END)        AS sales_l12,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 3  THEN m.margin ELSE 0 END)       AS margin_l3,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.margin ELSE 0 END)       AS margin_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 12 THEN m.margin ELSE 0 END)       AS margin_l12,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.transactions ELSE 0 END) AS txns_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 12 THEN m.transactions ELSE 0 END) AS txns_l12,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.purchase_days ELSE 0 END) AS purchase_days_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.returns ELSE 0 END)      AS returns_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.promo_sales ELSE 0 END)  AS promo_sales_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.discount ELSE 0 END)     AS discount_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.ecommerce_orders ELSE 0 END) AS ecom_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.loyalty_points_earned ELSE 0 END)   AS points_earned_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.loyalty_redemptions ELSE 0 END)     AS redemptions_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.emails_sent ELSE 0 END)             AS emails_sent_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.emails_opened ELSE 0 END)           AS emails_opened_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.emails_clicked ELSE 0 END)          AS emails_clicked_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.service_cases ELSE 0 END)           AS cases_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.gift_cards_bought ELSE 0 END)       AS giftcards_l6,
       SUM(CASE WHEN m.month_seq > a.as_of_seq - 6  AND m.transactions > 0 THEN 1 ELSE 0 END)  AS active_months_l6,
       MAX(CASE WHEN m.month_seq = a.as_of_seq THEN m.days_since_last_purchase ELSE NULL END)  AS days_since_last,
       MAX(CASE WHEN m.month_seq = a.as_of_seq THEN m.distinct_stores ELSE NULL END)           AS distinct_stores_asof,
       MIN(CASE WHEN m.month_seq > a.as_of_seq - 6  THEN m.min_csat ELSE NULL END)             AS min_csat_l6
FROM customer_month m
JOIN clv_asof a
  ON m.month_seq <= a.as_of_seq
GROUP BY m.customer_id, a.as_of_seq;

-- Forward target: gross margin in the HORIZON months after the as-of month.

DROP TABLE IF EXISTS clv_target;

CREATE TABLE clv_target AS
SELECT m.customer_id,
       a.as_of_seq,
       SUM(m.margin)                                  AS future_margin,
       SUM(m.sales)                                   AS future_sales,
       SUM(m.transactions)                            AS future_txns,
       MAX(CASE WHEN m.transactions > 0 THEN 1 ELSE 0 END) AS future_active
FROM customer_month m
JOIN clv_asof a
  ON m.month_seq > a.as_of_seq
 AND m.month_seq <= a.as_of_seq + a.horizon
GROUP BY m.customer_id, a.as_of_seq;

-- Assemble. A customer with no rows in the target window has genuinely zero
-- forward value, so the target is coalesced to zero rather than dropped --
-- excluding the silent customers would train the model only on survivors and
-- overstate every prediction.

DROP TABLE IF EXISTS clv_training_set;

CREATE TABLE clv_training_set AS
SELECT h.customer_id,
       h.as_of_seq,
       h.months_observed, h.months_since_first,
       h.sales_life, h.margin_life, h.txns_life, h.purchase_days_life,
       h.sales_l3, h.sales_l6, h.sales_l12,
       h.margin_l3, h.margin_l6, h.margin_l12,
       h.txns_l6, h.txns_l12, h.purchase_days_l6, h.returns_l6,
       h.promo_sales_l6, h.discount_l6, h.ecom_l6,
       h.points_earned_l6, h.redemptions_l6,
       h.emails_sent_l6, h.emails_opened_l6, h.emails_clicked_l6,
       h.cases_l6, h.giftcards_l6, h.active_months_l6,
       h.days_since_last, h.distinct_stores_asof, h.min_csat_l6,
       c.province, c.home_region, c.loyalty_tier, c.favorite_category,
       c.email_opt_in, c.rfm_segment, c.lifecycle_status,
       d.age_band, d.gender, d.household_size, d.household_income_band,
       d.life_stage, d.children_flag, d.dwelling_type, d.acquisition_channel,
       p.diet_profile, p.basket_profile, p.categories_bought,
       i.ipt_median_days, i.overdue_ratio, i.tenure_days,
       COALESCE(t.future_margin, 0) AS future_margin,
       COALESCE(t.future_sales, 0)  AS future_sales,
       COALESCE(t.future_txns, 0)   AS future_txns,
       COALESCE(t.future_active, 0) AS future_active
FROM clv_hist h
LEFT JOIN clv_target t
  ON t.customer_id = h.customer_id AND t.as_of_seq = h.as_of_seq
LEFT JOIN customers c              ON c.customer_id = h.customer_id
LEFT JOIN customer_demographics d  ON d.customer_id = h.customer_id
LEFT JOIN customer_diet_profile p  ON p.customer_id = h.customer_id
LEFT JOIN customer_ipt_stats i     ON i.customer_id = h.customer_id;

-- Shape check. Both cohorts should be present, the target should be mostly
-- non-negative, and a healthy share of customers should be silent in the
-- forward window.

SELECT as_of_seq,
       COUNT(*)                                            AS rows_built,
       COUNT(DISTINCT customer_id)                         AS customers,
       DECIMAL(AVG(future_margin), 12, 4)                  AS mean_future_margin,
       DECIMAL(AVG(FLOAT8(future_active)), 10, 4)          AS share_active_forward,
       SUM(CASE WHEN future_margin = 0 THEN 1 ELSE 0 END)  AS zero_target,
       SUM(CASE WHEN future_margin < 0 THEN 1 ELSE 0 END)  AS negative_target
FROM clv_training_set
GROUP BY as_of_seq
ORDER BY as_of_seq;
