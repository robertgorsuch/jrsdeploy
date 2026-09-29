-- verify_extended.sql -- sanity checks for stores, franchisees, promotions,
-- purchase_orders, shrinkage_log, loyalty_ledger, fsa_demographics and
-- ecommerce_orders.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

-- 1. stores -- one row per fact store, sales reconcile exactly
SELECT (SELECT COUNT(*) FROM stores) AS store_rows,
       (SELECT COUNT(DISTINCT storenumber) FROM pos_sales_detail) AS fact_stores,
       (SELECT SUM(total_sales) FROM stores) AS dim_sales,
       (SELECT SUM(sellingprice * quantity) FROM pos_sales_detail) AS fact_sales;

-- 2. franchisees -- ids cover the stores assignment, store counts add up
SELECT (SELECT COUNT(*) FROM franchisees) AS franchisee_rows,
       (SELECT COUNT(DISTINCT franchisee_id) FROM stores) AS assigned_ids,
       (SELECT SUM(stores_owned) FROM franchisees) AS stores_covered;

-- 3. promotions -- one row per event, sales reconcile to promo fact lines
SELECT (SELECT COUNT(*) FROM promotions) AS promo_rows,
       (SELECT COUNT(DISTINCT eventid) FROM pos_sales_detail WHERE COALESCE(eventid,'') <> '') AS fact_events,
       (SELECT SUM(promo_sales) FROM promotions) AS dim_promo_sales,
       (SELECT SUM(sellingprice * quantity) FROM pos_sales_detail WHERE COALESCE(eventid,'') <> '') AS fact_promo_sales;

-- 4. purchase_orders -- volume, received never exceeds ordered
SELECT COUNT(*) AS po_rows,
       SUM(CASE WHEN received_units > ordered_units THEN 1 ELSE 0 END) AS bad_fill,
       SUM(CASE WHEN actual_lead_days < 1 THEN 1 ELSE 0 END) AS bad_lead,
       DECIMAL(AVG(fill_rate_pct), 6, 1) AS avg_fill
FROM purchase_orders;

-- 5. shrinkage_log -- volume, values positive, reason mix
SELECT reason, COUNT(*) AS n, DECIMAL(SUM(shrink_value), 12, 2) AS total_value,
       SUM(CASE WHEN qty_lost < 1 OR shrink_value < 0 THEN 1 ELSE 0 END) AS bad_rows
FROM shrinkage_log GROUP BY reason ORDER BY n DESC;

-- 6. loyalty_ledger -- EARN plus ADJUST rows must equal distinct transactions
SELECT (SELECT COUNT(*) FROM loyalty_ledger WHERE entry_type IN ('EARN','ADJUST')) AS earn_adjust_rows,
       (SELECT COUNT(DISTINCT transactionuniqueid) FROM pos_sales_detail) AS fact_txns,
       (SELECT COUNT(*) FROM loyalty_ledger WHERE entry_type = 'REDEEM') AS redeem_rows;

-- 7. fsa_demographics -- one row per fact FSA, ZZ only on invalid codes
SELECT (SELECT COUNT(*) FROM fsa_demographics) AS fsa_rows,
       (SELECT COUNT(DISTINCT TRIM(customerfsa)) FROM pos_sales_detail WHERE COALESCE(customerfsa,'') <> '') AS fact_fsas,
       (SELECT SUM(CASE WHEN province = 'ZZ' THEN 1 ELSE 0 END) FROM fsa_demographics) AS unmapped_province,
       (SELECT SUM(CASE WHEN valid_fsa_flag = 'N' THEN 1 ELSE 0 END) FROM fsa_demographics) AS invalid_fsas,
       (SELECT SUM(CASE WHEN valid_fsa_flag = 'Y' AND province = 'ZZ' THEN 1 ELSE 0 END) FROM fsa_demographics) AS valid_but_unmapped;

-- 8. ecommerce_orders -- all belong to opted-in customers, channel mix
SELECT (SELECT COUNT(*) FROM ecommerce_orders) AS order_rows,
       (SELECT COUNT(*) FROM ecommerce_orders e JOIN customers c ON c.customer_id = e.customer_id
         WHERE c.email_opt_in <> 'Y') AS non_optin_rows,
       (SELECT COUNT(*) FROM ecommerce_orders WHERE channel = 'Delivery') AS delivery_orders,
       (SELECT COUNT(*) FROM ecommerce_orders WHERE channel = 'Delivery' AND delivery_partner IS NULL) AS delivery_no_partner;

-- 9. Eyeball -- top five stores and three promotions
SELECT FIRST 5 storenumber, storename, city, province, street_address, postal_fsa, phone,
       store_format, square_feet, latitude, longitude, franchisee_id, total_sales, sales_per_sqft
FROM stores ORDER BY total_sales DESC;

SELECT FIRST 3 promo_id, campaign_name, mechanic, funding_source, start_date, end_date,
       stores_participating, promo_sales, discount_depth_pct, top_category
FROM promotions ORDER BY promo_sales DESC;
