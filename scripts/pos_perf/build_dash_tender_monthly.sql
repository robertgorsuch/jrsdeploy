-- build_dash_tender_monthly.sql -- DROP-and-rebuild, source table tender_summary_daily is static
--
-- dash_tender_monthly: tender_summary_daily rolled to store x month x tender type
-- Feeds the Treasury dashboard tender tiles, Task 6.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_tender_monthly;
CREATE TABLE dash_tender_monthly AS
SELECT storenumber, region, province, yyyymm,
       yyyymm / 100 AS yr, MOD(yyyymm, 100) AS mo,
       tender_group, tender_type,
       DECIMAL(SUM(amount), 14, 2) AS amount,
       INT4(SUM(est_transactions)) AS est_transactions,
       DECIMAL(SUM(processing_fee), 12, 2) AS processing_fee
FROM tender_summary_daily
GROUP BY storenumber, region, province, yyyymm, tender_group, tender_type;
CREATE STATISTICS FOR dash_tender_monthly;
