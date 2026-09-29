-- dash_cohort: customer_month rolled up to cohort_year x months_since_first,
-- active share per cell. cohort_year comes from customers.first_purchase_date.
-- NOTE: EXTRACT(YEAR FROM date_col) works on ANSIDATE -- date_col / 10000 does
-- not (Rewriter error). NOTE: no semicolons or apostrophes inside comments.
DROP TABLE IF EXISTS dash_cohort;
CREATE TABLE dash_cohort AS
SELECT EXTRACT(YEAR FROM c.first_purchase_date) AS cohort_year,
       cm.months_since_first,
       INT4(COUNT(*)) AS customers,
       INT4(SUM(CASE WHEN cm.active_flag = 'Y' THEN 1 ELSE 0 END)) AS active_customers,
       DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN cm.active_flag = 'Y' THEN 1 ELSE 0 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS active_pct
FROM customer_month cm
JOIN customers c ON c.customer_id = cm.customer_id
GROUP BY 1, 2;
CREATE STATISTICS FOR dash_cohort;
