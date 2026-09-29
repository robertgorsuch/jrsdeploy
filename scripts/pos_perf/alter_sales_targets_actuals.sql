-- alter_sales_targets_actuals.sql -- adds REAL actual columns to
-- sales_targets so attainment is computable inside one model
-- (the Wobby metric sales_plan_attainment_pct previously returned the
-- target itself because the table held only targets).
-- actual_sales / actual_margin / actual_transactions come from
-- pos_sales_txn (Regular Sale) at store x month grain -- the same actuals
-- the targets were originally calibrated against.
-- Re-runnable: the DROP COLUMN statements fail on the first run (expected).
-- Requires: pos_sales_txn.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

ALTER TABLE sales_targets DROP COLUMN actual_sales RESTRICT;

ALTER TABLE sales_targets DROP COLUMN actual_margin RESTRICT;

ALTER TABLE sales_targets DROP COLUMN actual_transactions RESTRICT;

ALTER TABLE sales_targets ADD COLUMN actual_sales DECIMAL(14,2);

ALTER TABLE sales_targets ADD COLUMN actual_margin DECIMAL(14,2);

ALTER TABLE sales_targets ADD COLUMN actual_transactions INTEGER;

DROP TABLE IF EXISTS st_act;

CREATE TABLE st_act AS
SELECT storenumber, yyyymm,
       SUM(basket_value) AS actual_sales,
       SUM(basket_margin) AS actual_margin,
       COUNT(*) AS actual_transactions
FROM pos_sales_txn
WHERE txn_type = 'Regular Sale'
GROUP BY storenumber, yyyymm;

UPDATE sales_targets FROM st_act a
SET actual_sales = DECIMAL(a.actual_sales, 14, 2),
    actual_margin = DECIMAL(a.actual_margin, 14, 2),
    actual_transactions = a.actual_transactions
WHERE sales_targets.storenumber = a.storenumber AND sales_targets.yyyymm = a.yyyymm;

DROP TABLE IF EXISTS st_act;

SELECT COUNT(*) AS rows_, SUM(CASE WHEN actual_sales IS NULL THEN 1 ELSE 0 END) AS null_actuals,
       DECIMAL(100.0 * SUM(actual_sales) / SUM(target_sales), 7, 2) AS network_attainment_pct
FROM sales_targets;
