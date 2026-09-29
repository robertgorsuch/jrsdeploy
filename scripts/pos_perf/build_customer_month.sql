-- build_customer_month.sql -- DROP-and-rebuild of customer_month, the DENSE
-- customer x calendar-month fact used for retention curves, cohort views and
-- monthly engagement features. One row per (customer_id, yyyymm) from the
-- month of the first purchase through 2020-12 for every customer with two or
-- more transactions (about 2.1M customers, roughly 30M rows). Months with no
-- activity are present as zero rows -- those zeros ARE the churn signal.
-- Everything here is REAL, rolled up from pos_sales_txn, ecommerce_orders,
-- loyalty_ledger, email_engagement, customer_service_cases and gift_cards.
-- days_since_last_purchase is measured at month end (the last calendar day of
-- the month) against the most recent Regular Sale on or before that day.
-- HASH-partitioned on customer_id, same spec as pos_sales_txn.
-- Requires: pos_sales_txn, customer_ipt_stats, customers, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS cm_months;

CREATE TABLE cm_months AS
SELECT yyyymm, MIN(jdn) AS month_start_jdn, MAX(jdn) AS month_end_jdn,
       MAX(pandemic_period) AS pandemic_period,
       ROW_NUMBER() OVER (ORDER BY yyyymm) AS month_seq
FROM date_dim
GROUP BY yyyymm;

-- Spine: eligible customers x months from first purchase month onward

DROP TABLE IF EXISTS cm_spine;

CREATE TABLE cm_spine AS
SELECT s.customer_id, m.yyyymm, m.month_seq, m.month_end_jdn, m.pandemic_period,
       s.first_jdn, s.first_month_seq,
       m.month_seq - s.first_month_seq AS months_since_first
FROM (
  SELECT i.customer_id, i.first_jdn, fm.month_seq AS first_month_seq
  FROM customer_ipt_stats i
  JOIN customers c ON c.customer_id = i.customer_id
  JOIN cm_months fm ON fm.yyyymm = YEAR(i.first_purchase_date) * 100 + MONTH(i.first_purchase_date)
  WHERE c.total_transactions >= 2
) s
JOIN cm_months m ON m.month_seq >= s.first_month_seq
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- Monthly transaction rollup

DROP TABLE IF EXISTS cm_txn;

CREATE TABLE cm_txn AS
SELECT t.customer_id, t.yyyymm,
       SUM(CASE WHEN t.txn_type = 'Regular Sale' THEN 1 ELSE 0 END) AS transactions,
       SUM(CASE WHEN t.txn_type = 'Regular Return' THEN 1 ELSE 0 END) AS returns,
       COUNT(DISTINCT CASE WHEN t.txn_type = 'Regular Sale' THEN t.jdn END) AS purchase_days,
       SUM(t.basket_value) AS sales,
       SUM(t.basket_items) AS items,
       SUM(t.basket_margin) AS margin,
       SUM(t.promo_value) AS promo_sales,
       SUM(t.discount_total) AS discount,
       COUNT(DISTINCT t.storenumber) AS distinct_stores,
       SUM(CASE WHEN t.storenumber = c.home_store_number THEN 1 ELSE 0 END) AS home_store_txns,
       SUM(CASE WHEN t.ecommerce_flag = 'Y' THEN 1 ELSE 0 END) AS ecommerce_orders,
       AVG(1.0 * t.distinct_categories) AS avg_categories_per_basket,
       MAX(CASE WHEN t.txn_type = 'Regular Sale' THEN t.jdn END) AS last_sale_jdn
FROM pos_sales_txn t
JOIN customers c ON c.customer_id = t.customer_id
GROUP BY t.customer_id, t.yyyymm
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

-- Monthly event rollups from the satellite tables

DROP TABLE IF EXISTS cm_ecom;

CREATE TABLE cm_ecom AS
SELECT customer_id, YEAR(order_date) * 100 + MONTH(order_date) AS yyyymm,
       SUM(CASE WHEN fulfilled_late = 'Y' THEN 1 ELSE 0 END) AS ecommerce_late,
       MIN(satisfaction_score) AS min_ecommerce_satisfaction
FROM ecommerce_orders
GROUP BY customer_id, YEAR(order_date) * 100 + MONTH(order_date);

DROP TABLE IF EXISTS cm_loy;

CREATE TABLE cm_loy AS
SELECT customer_id, YEAR(entry_date) * 100 + MONTH(entry_date) AS yyyymm,
       SUM(CASE WHEN entry_type = 'EARN' THEN points ELSE 0 END) AS loyalty_points_earned,
       SUM(CASE WHEN entry_type = 'REDEEM' THEN -points ELSE 0 END) AS loyalty_points_redeemed,
       SUM(CASE WHEN entry_type = 'REDEEM' THEN 1 ELSE 0 END) AS loyalty_redemptions
FROM loyalty_ledger
GROUP BY customer_id, YEAR(entry_date) * 100 + MONTH(entry_date)
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS cm_email;

CREATE TABLE cm_email AS
SELECT customer_id, YEAR(send_date) * 100 + MONTH(send_date) AS yyyymm,
       COUNT(*) AS emails_sent,
       SUM(CASE WHEN opened_flag = 'Y' THEN 1 ELSE 0 END) AS emails_opened,
       SUM(CASE WHEN clicked_flag = 'Y' THEN 1 ELSE 0 END) AS emails_clicked,
       SUM(CASE WHEN converted_flag = 'Y' THEN 1 ELSE 0 END) AS emails_converted
FROM email_engagement
GROUP BY customer_id, YEAR(send_date) * 100 + MONTH(send_date);

DROP TABLE IF EXISTS cm_cases;

CREATE TABLE cm_cases AS
SELECT customer_id, YEAR(open_date) * 100 + MONTH(open_date) AS yyyymm,
       COUNT(*) AS service_cases,
       MIN(csat_score) AS min_csat,
       SUM(CASE WHEN status <> 'Closed' THEN 1 ELSE 0 END) AS open_cases
FROM customer_service_cases
GROUP BY customer_id, YEAR(open_date) * 100 + MONTH(open_date);

DROP TABLE IF EXISTS cm_gift;

CREATE TABLE cm_gift AS
SELECT purchased_by AS customer_id, YEAR(purchase_date) * 100 + MONTH(purchase_date) AS yyyymm,
       COUNT(*) AS gift_cards_bought,
       SUM(initial_value) AS gift_card_value
FROM gift_cards
GROUP BY purchased_by, YEAR(purchase_date) * 100 + MONTH(purchase_date);

-- Last Regular Sale on or before each month end (running max via self-join,
-- X100 has no ordered aggregate windows)

DROP TABLE IF EXISTS cm_last;

CREATE TABLE cm_last AS
SELECT s.customer_id, s.yyyymm, MAX(x.last_sale_jdn) AS last_sale_jdn_to_date
FROM cm_spine s
JOIN cm_txn x ON x.customer_id = s.customer_id AND x.yyyymm <= s.yyyymm
WHERE x.last_sale_jdn IS NOT NULL
GROUP BY s.customer_id, s.yyyymm
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS customer_month;

CREATE TABLE customer_month AS
SELECT s.customer_id, s.yyyymm, s.month_seq, s.months_since_first, s.pandemic_period,
       COALESCE(t.transactions, 0) AS transactions,
       COALESCE(t.returns, 0) AS returns,
       COALESCE(t.purchase_days, 0) AS purchase_days,
       DECIMAL(COALESCE(t.sales, 0), 12, 2) AS sales,
       COALESCE(t.items, 0) AS items,
       DECIMAL(COALESCE(t.margin, 0), 12, 2) AS margin,
       DECIMAL(COALESCE(t.promo_sales, 0), 12, 2) AS promo_sales,
       DECIMAL(COALESCE(t.discount, 0), 12, 2) AS discount,
       COALESCE(t.distinct_stores, 0) AS distinct_stores,
       COALESCE(t.home_store_txns, 0) AS home_store_txns,
       COALESCE(t.ecommerce_orders, 0) AS ecommerce_orders,
       COALESCE(e.ecommerce_late, 0) AS ecommerce_late,
       e.min_ecommerce_satisfaction,
       DECIMAL(t.avg_categories_per_basket, 6, 2) AS avg_categories_per_basket,
       COALESCE(l.loyalty_points_earned, 0) AS loyalty_points_earned,
       COALESCE(l.loyalty_points_redeemed, 0) AS loyalty_points_redeemed,
       COALESCE(l.loyalty_redemptions, 0) AS loyalty_redemptions,
       COALESCE(m.emails_sent, 0) AS emails_sent,
       COALESCE(m.emails_opened, 0) AS emails_opened,
       COALESCE(m.emails_clicked, 0) AS emails_clicked,
       COALESCE(m.emails_converted, 0) AS emails_converted,
       COALESCE(k.service_cases, 0) AS service_cases,
       k.min_csat,
       COALESCE(k.open_cases, 0) AS open_cases,
       COALESCE(g.gift_cards_bought, 0) AS gift_cards_bought,
       DECIMAL(COALESCE(g.gift_card_value, 0), 10, 2) AS gift_card_value,
       CASE WHEN ls.last_sale_jdn_to_date IS NOT NULL
            THEN s.month_end_jdn - ls.last_sale_jdn_to_date END AS days_since_last_purchase,
       CASE WHEN COALESCE(t.transactions, 0) > 0 THEN 'Y' ELSE 'N' END AS active_flag
FROM cm_spine s
LEFT JOIN cm_txn t   ON t.customer_id = s.customer_id AND t.yyyymm = s.yyyymm
LEFT JOIN cm_ecom e  ON e.customer_id = s.customer_id AND e.yyyymm = s.yyyymm
LEFT JOIN cm_loy l   ON l.customer_id = s.customer_id AND l.yyyymm = s.yyyymm
LEFT JOIN cm_email m ON m.customer_id = s.customer_id AND m.yyyymm = s.yyyymm
LEFT JOIN cm_cases k ON k.customer_id = s.customer_id AND k.yyyymm = s.yyyymm
LEFT JOIN cm_gift g  ON g.customer_id = s.customer_id AND g.yyyymm = s.yyyymm
LEFT JOIN cm_last ls ON ls.customer_id = s.customer_id AND ls.yyyymm = s.yyyymm
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS cm_last;

DROP TABLE IF EXISTS cm_gift;

DROP TABLE IF EXISTS cm_cases;

DROP TABLE IF EXISTS cm_email;

DROP TABLE IF EXISTS cm_loy;

DROP TABLE IF EXISTS cm_ecom;

DROP TABLE IF EXISTS cm_txn;

DROP TABLE IF EXISTS cm_spine;

DROP TABLE IF EXISTS cm_months;

CREATE STATISTICS FOR customer_month;
