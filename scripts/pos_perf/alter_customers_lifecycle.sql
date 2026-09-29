-- alter_customers_lifecycle.sql -- adds the churn-lite columns to the
-- customers dimension in place so existing reports can filter on them
-- without a join: lifecycle_status, ipt_median_days, expected_next_purchase,
-- overdue_ratio, churn_horizon_days, tenure_days, first_store_number, and
-- churn_risk_band (filled later by load_churn_scores from
-- customer_churn_scores, NULL until then).
-- Re-runnable: the DROP COLUMN statements at the top FAIL on the first run
-- (column does not exist yet) -- that is expected, run-file keeps going.
-- Requires: customer_ipt_stats (build_customer_ipt_stats.sql), pos_sales_txn.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

ALTER TABLE customers DROP COLUMN lifecycle_status RESTRICT;

ALTER TABLE customers DROP COLUMN ipt_median_days RESTRICT;

ALTER TABLE customers DROP COLUMN expected_next_purchase RESTRICT;

ALTER TABLE customers DROP COLUMN overdue_ratio RESTRICT;

ALTER TABLE customers DROP COLUMN churn_horizon_days RESTRICT;

ALTER TABLE customers DROP COLUMN tenure_days RESTRICT;

ALTER TABLE customers DROP COLUMN first_store_number RESTRICT;

ALTER TABLE customers DROP COLUMN churn_risk_band RESTRICT;

ALTER TABLE customers ADD COLUMN lifecycle_status VARCHAR(8);

ALTER TABLE customers ADD COLUMN ipt_median_days DECIMAL(8,1);

ALTER TABLE customers ADD COLUMN expected_next_purchase ANSIDATE;

ALTER TABLE customers ADD COLUMN overdue_ratio DECIMAL(8,2);

ALTER TABLE customers ADD COLUMN churn_horizon_days INTEGER;

ALTER TABLE customers ADD COLUMN tenure_days INTEGER;

ALTER TABLE customers ADD COLUMN first_store_number INTEGER;

ALTER TABLE customers ADD COLUMN churn_risk_band VARCHAR(8);

UPDATE customers FROM customer_ipt_stats s
SET lifecycle_status = s.lifecycle_status,
    ipt_median_days = s.ipt_median_days,
    expected_next_purchase = s.expected_next_purchase,
    overdue_ratio = s.overdue_ratio,
    churn_horizon_days = s.churn_horizon_days,
    tenure_days = s.tenure_days
WHERE customers.customer_id = s.customer_id;

DROP TABLE IF EXISTS cust_first_store;

CREATE TABLE cust_first_store AS
SELECT customer_id, storenumber AS first_store_number FROM (
  SELECT customer_id, storenumber,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY jdn, sale_hour, transactionuniqueid) AS rk
  FROM pos_sales_txn
) t WHERE rk = 1;

UPDATE customers FROM cust_first_store f
SET first_store_number = f.first_store_number
WHERE customers.customer_id = f.customer_id;

DROP TABLE IF EXISTS cust_first_store;

UPDATE customers SET lifecycle_status = 'One-time' WHERE lifecycle_status IS NULL AND total_transactions <= 1;

UPDATE customers SET lifecycle_status = 'Inactive' WHERE lifecycle_status IS NULL;
