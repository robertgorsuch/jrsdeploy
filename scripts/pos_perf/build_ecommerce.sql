-- build_ecommerce.sql -- DROP-and-rebuild of ecommerce_orders.
-- A 1-in-50 hash sample of REAL transactions belonging to email-opted-in
-- customers becomes online orders. REAL: order id derives from the real
-- transactionuniqueid, customer, fulfillment store, order date, order value
-- and item count all come from the fact table. FICTITIOUS but DETERMINISTIC:
-- channel split (about one third Delivery, two thirds Pickup), a fictional
-- delivery partner for Delivery orders, delivery fee (free at 50 dollars or
-- more), fulfillment window minutes, late flag (10 percent), and a
-- satisfaction score skewed toward 4 and 5.
-- Ties: customer_id joins customers (all rows are email_opt_in = Y),
-- storenumber joins stores and inventory, transactionuniqueid joins
-- pos_sales_detail lines.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS ec_txn;

CREATE TABLE ec_txn AS
SELECT transactionuniqueid,
       MAX(customernumber) AS customer_id,
       MAX(storenumber) AS storenumber,
       MAX(DATE(saledate)) AS order_date,
       SUM(sellingprice * quantity) AS order_value,
       SUM(quantity) AS items
FROM pos_sales_detail
GROUP BY transactionuniqueid;

DROP TABLE IF EXISTS ecommerce_orders;

CREATE TABLE ecommerce_orders AS
WITH s AS (
  SELECT t.*,
         ABS(MOD(HASH(t.transactionuniqueid + 'ch'), 3)) AS ch_sel,
         ABS(MOD(HASH(t.transactionuniqueid + 'dp'), 3)) AS dp_sel,
         ABS(MOD(HASH(t.transactionuniqueid + 'fee'), 2)) AS fee_sel,
         ABS(MOD(HASH(t.transactionuniqueid + 'win'), 4)) AS win_sel,
         ABS(MOD(HASH(t.transactionuniqueid + 'late'), 10)) AS late_sel,
         ABS(MOD(HASH(t.transactionuniqueid + 'sat'), 20)) AS sat_sel
  FROM ec_txn t
  JOIN customers c ON c.customer_id = t.customer_id
  WHERE c.email_opt_in = 'Y'
    AND t.order_value > 0
    AND ABS(MOD(HASH(t.transactionuniqueid + 'ec'), 50)) = 0
)
SELECT 'WEB-' + transactionuniqueid AS order_id,
       transactionuniqueid, customer_id,
       storenumber AS fulfillment_store,
       order_date,
       CASE WHEN ch_sel = 0 THEN 'Delivery' ELSE 'Pickup' END AS channel,
       CASE WHEN ch_sel = 0 THEN
         CASE dp_sel WHEN 0 THEN 'SnowRoute Express'
              WHEN 1 THEN 'Maple Courier Co' ELSE 'UrbanSled Delivery' END
       END AS delivery_partner,
       CASE WHEN ch_sel = 0 AND order_value < 50 THEN
              CASE fee_sel WHEN 0 THEN DECIMAL(4.99, 6, 2) ELSE DECIMAL(7.99, 6, 2) END
            ELSE DECIMAL(0.00, 6, 2) END AS delivery_fee,
       DECIMAL(order_value, 12, 2) AS order_value,
       items,
       CASE WHEN ch_sel = 0 THEN 60 + win_sel * 30 ELSE 30 + win_sel * 15 END AS promised_window_mins,
       CASE WHEN late_sel = 0 THEN 'Y' ELSE 'N' END AS fulfilled_late,
       CASE WHEN sat_sel = 0 THEN 1
            WHEN sat_sel <= 2 THEN 2
            WHEN sat_sel <= 5 THEN 3
            WHEN sat_sel <= 12 THEN 4
            ELSE 5 END AS satisfaction_score
FROM s;

DROP TABLE IF EXISTS ec_txn;
