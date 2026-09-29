-- verify_customers.sql -- sanity checks for the customers dimension.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.

-- 1. Row count must equal distinct customernumber in the fact table (3,184,947)
SELECT (SELECT COUNT(*) FROM customers) AS customers_rows,
       (SELECT COUNT(DISTINCT customernumber) FROM pos_sales_detail) AS fact_customers;

-- 2. customer_id must be unique
SELECT COUNT(*) AS dup_ids FROM (
  SELECT customer_id FROM customers GROUP BY customer_id HAVING COUNT(*) > 1
) t;

-- 3. Sales reconciliation -- dimension lifetime sales vs fact extended sales
SELECT (SELECT SUM(total_sales) FROM customers) AS dim_sales,
       (SELECT SUM(sellingprice * quantity) FROM pos_sales_detail) AS fact_sales;

-- 4. Segment and tier distributions
SELECT rfm_segment, COUNT(*) AS n, DECIMAL(AVG(total_sales), 12, 2) AS avg_sales
FROM customers GROUP BY rfm_segment ORDER BY n DESC;

SELECT loyalty_tier, COUNT(*) AS n, DECIMAL(MIN(total_sales), 12, 2) AS min_sales,
       DECIMAL(MAX(total_sales), 12, 2) AS max_sales
FROM customers GROUP BY loyalty_tier ORDER BY min_sales;

-- 5. Address completeness
SELECT SUM(CASE WHEN postal_code IS NULL THEN 1 ELSE 0 END) AS no_postal,
       SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END) AS no_email,
       SUM(CASE WHEN city IS NULL OR city = '' THEN 1 ELSE 0 END) AS no_city
FROM customers;

-- 6. Eyeball ten sample customers
SELECT FIRST 10 customer_id, full_name, street_address, city, province, postal_code,
       phone, email, total_transactions, total_sales, avg_basket, favorite_category,
       rfm_segment, loyalty_tier
FROM customers ORDER BY total_sales DESC;
