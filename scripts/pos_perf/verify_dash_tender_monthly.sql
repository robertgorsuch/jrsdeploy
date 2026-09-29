-- verify dash_tender_monthly
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain
SELECT COUNT(*) AS rows_, COUNT(DISTINCT storenumber) AS stores, MIN(yyyymm) AS min_m, MAX(yyyymm) AS max_m,
       (SELECT COUNT(*) FROM (SELECT storenumber, yyyymm, tender_type FROM dash_tender_monthly GROUP BY 1,2,3 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_tender_monthly;
-- 2 ties to source to the cent
SELECT (SELECT SUM(amount) FROM dash_tender_monthly) AS agg_amount,
       (SELECT SUM(amount) FROM tender_summary_daily) AS src_amount,
       (SELECT SUM(processing_fee) FROM dash_tender_monthly) AS agg_fee,
       (SELECT SUM(processing_fee) FROM tender_summary_daily) AS src_fee;
-- 3 cashless share pre vs pandemic, expect about 77.9 then 89.9
SELECT CASE WHEN yyyymm >= 202003 THEN 'Pandemic' ELSE 'Pre-pandemic' END AS period,
       DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN tender_group <> 'Cash' THEN amount ELSE 0 END)) / FLOAT8(SUM(amount)), 6, 2) AS cashless_pct
FROM dash_tender_monthly GROUP BY 1 ORDER BY 1;
-- 4 monthly mix eyeball, first 12 rows
SELECT FIRST 12 yyyymm, tender_group, DECIMAL(SUM(amount), 14, 2) AS amount FROM dash_tender_monthly GROUP BY 1,2 ORDER BY 1,2;
