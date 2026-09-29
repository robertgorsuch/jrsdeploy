-- build_dash_aggregates.sql -- DROP-and-rebuild, source table pos_sales_detail is static
--
-- Basis notes, settled in Task 2 margin-basis investigation:
--   sellingprice is PER-UNIT, net sales truth = SUM of sellingprice times quantity, column sales_ext
--   cost is ALREADY LINE-EXTENDED, quantity times unit cost, cost truth = SUM of cost, column cost_line
--   cost_ext, SUM of cost times quantity, is kept only so the table shape matches the plan.
--   It is NOT a meaningful figure and must not be used for margin math.
--   Gross margin = sales_ext minus cost_line, that is SUM of sellingprice times quantity minus SUM of cost.
--
-- promotiontype normalization: the source has two distinct no-promo groups, a
-- single-space value and a true NULL or empty value. TRIM of COALESCE of promotiontype
-- and empty string collapses both into one empty-string bucket so promo-mix aggregates
-- do not double count the non-promo group. Applied wherever promotiontype is grouped
-- or stored, in dash_monthly and dash_promo.
--
-- Avalanche and Ingres dialect confirmed via tiny pre-flight SELECTs before this build.
--   DATE of a varchar column, YEAR of DATE, MONTH of DATE all work as written.
--   DROP TABLE IF EXISTS and DROP VIEW IF EXISTS are both supported natively, OK on
--   a nonexistent object with no error, so no ignore-error fallback is needed.

DROP TABLE IF EXISTS dash_monthly;
CREATE TABLE dash_monthly AS
SELECT YEAR(DATE(saledate)) AS yr, MONTH(DATE(saledate)) AS mo,
       storeregion, TRIM(COALESCE(promotiontype,'')) AS promotiontype,
       CASE WHEN DATE(saledate) >= DATE('2020-03-01') THEN 'Pandemic' ELSE 'Pre-pandemic' END AS pandemic_period,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx, COUNT(*) AS line_items
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale'
GROUP BY 1,2,3,4,5;

DROP TABLE IF EXISTS dash_region;
CREATE TABLE dash_region AS
SELECT storeregion, COUNT(DISTINCT storenumber) AS stores,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx, COUNT(*) AS line_items
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1;

DROP TABLE IF EXISTS dash_province;
CREATE TABLE dash_province AS
SELECT storeprovince, COUNT(DISTINCT storenumber) AS stores,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1;

DROP TABLE IF EXISTS dash_promo;
CREATE TABLE dash_promo AS
SELECT TRIM(COALESCE(promotiontype,'')) AS promotiontype, storeregion,
       YEAR(DATE(saledate)) AS yr, MONTH(DATE(saledate)) AS mo,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(*) AS line_items
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1,2,3,4;

DROP TABLE IF EXISTS dash_store;
CREATE TABLE dash_store AS
SELECT storenumber, storename, storeregion, storeprovince,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1,2,3,4;

-- dash_kpi note: tx is NOT SUM(dash_monthly.tx). dash_monthly is grouped down to
-- promotiontype, and promotiontype is a line-item attribute -- 8.5M+ transactions
-- have line items spanning more than one normalized promotiontype in the same
-- month, so summing per-group COUNT(DISTINCT transactionuniqueid) double counts
-- those transactions (confirmed: SUM(dash_monthly.tx) = 28035086 versus the true
-- COUNT(DISTINCT transactionuniqueid) = 19487389). storeregion does not have this
-- problem, zero transactions span more than one region, so dash_region, dash_province
-- and dash_store tx columns are unaffected and stay grain-safe SUM(dash_monthly.tx)
-- rollups would not be. dash_kpi instead aggregates straight from pos_sales_detail,
-- the same grain as the tx_exact check in verify_dash_aggregates.sql, so sales_ext,
-- cost_line, tx and qty are all correct by construction.
DROP VIEW IF EXISTS dash_kpi;
CREATE VIEW dash_kpi AS
SELECT SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx, COUNT(*) AS line_items
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale';
