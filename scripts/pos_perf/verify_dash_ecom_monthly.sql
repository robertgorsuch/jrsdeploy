-- verify dash_ecom_monthly
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 row count and grain, expect 0 dup keys, 4 distinct delivery_partner values
SELECT COUNT(*) AS rows_,
       (SELECT COUNT(*) FROM (SELECT yyyymm, delivery_partner FROM dash_ecom_monthly GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys,
       (SELECT COUNT(DISTINCT delivery_partner) FROM dash_ecom_monthly) AS n_partners
FROM dash_ecom_monthly;
-- 2 ties to source exactly, expect orders 261177
SELECT (SELECT SUM(orders) FROM dash_ecom_monthly) AS agg_orders, (SELECT COUNT(*) FROM ecommerce_orders) AS src_orders;
-- 3 Pickup bucket equals the blank-delivery_partner source rows, expect 174151
SELECT (SELECT SUM(orders) FROM dash_ecom_monthly WHERE delivery_partner = 'Pickup') AS agg_pickup,
       (SELECT COUNT(*) FROM ecommerce_orders WHERE TRIM(delivery_partner) = '' OR delivery_partner IS NULL) AS src_pickup;
-- 4 network avg satisfaction and late pct, expect about 3.87 and 6.8-6.9 pct
SELECT DECIMAL(SUM(avg_satisfaction * orders) / SUM(orders), 6, 2) AS wtd_avg_satisfaction,
       DECIMAL(100.0 * FLOAT8(SUM(late_orders)) / FLOAT8(SUM(orders)), 6, 2) AS late_pct
FROM dash_ecom_monthly;
