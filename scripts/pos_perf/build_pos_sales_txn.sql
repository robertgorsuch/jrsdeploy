-- build_pos_sales_txn.sql -- DROP-and-rebuild of pos_sales_txn, the
-- transaction-grain rollup of pos_sales_detail (19.5M rows, one per
-- transactionuniqueid). Everything here is REAL and derived from the fact.
-- Replaces the loy_txn / ec_txn / svc_txn / camp_buyers rollups that the
-- loyalty, ecommerce, service and marketing builders each recompute, and
-- gives downstream scripts a typed sale_date plus the date_dim jdn so nobody
-- has to call DATE() on the VARCHAR saledate over 63.6M rows again.
-- Margin basis follows build_dash_aggregates.sql -- sellingprice is PER-UNIT,
-- basket_value = SUM(sellingprice*quantity), cost is a LINE total.
-- txn_type is the fact transactiontype (Regular Sale, Regular Return,
-- Post Void TX). Churn and IPT logic downstream counts Regular Sale only.
-- HASH-partitioned on customer_id so customer_month, churn_training_set and
-- customer_churn_scores (same partition spec) join co-located.
-- Also creates pos_sales_detail_v, a thin view over the fact that adds
-- sale_date and jdn, for ad hoc work that needs line grain with real dates.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS txn_agg;

CREATE TABLE txn_agg AS
SELECT f.transactionuniqueid,
       MAX(f.customernumber) AS customer_id,
       MAX(f.storenumber) AS storenumber,
       MAX(f.storeprovince) AS storeprovince,
       MAX(f.storeregion) AS storeregion,
       MAX(DATE(f.saledate)) AS sale_date,
       MAX(INT4(LEFT(f.saletime, 2))) AS sale_hour,
       MIN(f.transactiontype) AS txn_type,
       COUNT(*) AS line_items,
       SUM(f.quantity) AS basket_items,
       SUM(f.sellingprice * f.quantity) AS basket_value,
       SUM(f.cost) AS basket_cost,
       SUM(COALESCE(f.transactiondiscount,0) + COALESCE(f.itemdiscount,0) + COALESCE(f.overridediscount,0)) AS discount_total,
       SUM(CASE WHEN COALESCE(f.promotiontype,'') <> '' THEN f.sellingprice * f.quantity ELSE 0 END) AS promo_value,
       MAX(CASE WHEN COALESCE(f.eventid,'') <> '' THEN f.eventid END) AS promo_id,
       COUNT(DISTINCT TRIM(f.plu)) AS distinct_plus,
       COUNT(DISTINCT p.category) AS distinct_categories,
       MAX(CASE WHEN COALESCE(f.customerfsa,'') <> '' THEN TRIM(f.customerfsa) END) AS fsa,
       MAX(CASE WHEN f.customeremailflag IN ('1','Y','y','true','TRUE','True') THEN 1 ELSE 0 END) AS email_flag
FROM pos_sales_detail f
LEFT JOIN products p ON p.plu = TRIM(f.plu) AND COALESCE(p.category,'') <> ''
GROUP BY f.transactionuniqueid;

DROP TABLE IF EXISTS pos_sales_txn;

CREATE TABLE pos_sales_txn AS
SELECT t.transactionuniqueid, t.customer_id, t.storenumber, t.storeprovince, t.storeregion,
       t.sale_date, d.jdn, d.yyyymm, t.sale_hour, d.dow_num, d.is_weekend, d.is_holiday,
       d.pandemic_period, t.txn_type, t.line_items, t.basket_items,
       DECIMAL(t.basket_value, 12, 2) AS basket_value,
       DECIMAL(t.basket_cost, 12, 2) AS basket_cost,
       DECIMAL(t.basket_value - t.basket_cost, 12, 2) AS basket_margin,
       DECIMAL(t.discount_total, 12, 2) AS discount_total,
       DECIMAL(t.promo_value, 12, 2) AS promo_value,
       CASE WHEN t.promo_value > 0 THEN 'Y' ELSE 'N' END AS promo_flag,
       t.promo_id, t.distinct_plus, t.distinct_categories, t.fsa, t.email_flag,
       CASE WHEN e.order_id IS NOT NULL THEN 'Y' ELSE 'N' END AS ecommerce_flag
FROM txn_agg t
JOIN date_dim d ON d.calendar_date = t.sale_date
LEFT JOIN ecommerce_orders e ON e.transactionuniqueid = t.transactionuniqueid
WITH PARTITION = (HASH ON customer_id 16 PARTITIONS);

DROP TABLE IF EXISTS txn_agg;

DROP VIEW IF EXISTS pos_sales_detail_v;

CREATE VIEW pos_sales_detail_v AS
SELECT f.*, DATE(f.saledate) AS sale_date, d.jdn, d.yyyymm
FROM pos_sales_detail f
JOIN date_dim d ON d.calendar_date = DATE(f.saledate);

CREATE STATISTICS FOR pos_sales_txn;
