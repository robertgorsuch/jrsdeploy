-- verify_dash_aggregates.sql -- every row must match the acceptance targets in
-- task-3-brief.md, extended-basis (sales_ext, cost_line), Regular Sale, Jan 2019
-- through Dec 2020.
--
-- Expected:
--   kpi:      sales_ext = 764167990.73, cost_line = 522326380.94,
--             tx = 19487389, qty = 81616420
--   months:   n = 24
--   region:   ON  411.7M  163 stores
--             WEST 237.6M 111 stores
--             QC   80.0M  42 stores
--             ATL  34.8M  14 stores
--   tx_exact: equals dash_kpi.tx

SELECT 'kpi' AS chk, sales_ext, cost_line, tx, qty FROM dash_kpi;

SELECT 'region' AS chk, storeregion, sales_ext, stores
FROM dash_region ORDER BY sales_ext DESC;

SELECT 'months' AS chk, COUNT(*) AS n
FROM (SELECT DISTINCT yr, mo FROM dash_monthly) t;

SELECT 'tx_exact' AS chk, COUNT(DISTINCT transactionuniqueid) AS tx_exact
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale';
