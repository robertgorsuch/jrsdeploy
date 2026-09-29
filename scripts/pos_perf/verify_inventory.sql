-- verify_inventory.sql -- sanity checks for the inventory table.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.

-- 1. Row count must equal distinct (storenumber, plu) pairs in the fact table
SELECT (SELECT COUNT(*) FROM inventory) AS inventory_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT storenumber, TRIM(plu) FROM pos_sales_detail) t) AS fact_pairs;

-- 2. (storenumber, plu) must be unique
SELECT COUNT(*) AS dup_keys FROM (
  SELECT storenumber, plu FROM inventory GROUP BY storenumber, plu HAVING COUNT(*) > 1
) t;

-- 3. Units and sales reconcile against the fact table
SELECT (SELECT SUM(units_sold_total) FROM inventory) AS dim_units,
       (SELECT SUM(quantity) FROM pos_sales_detail) AS fact_units,
       (SELECT SUM(sales_total) FROM inventory) AS dim_sales,
       (SELECT SUM(sellingprice * quantity) FROM pos_sales_detail) AS fact_sales;

-- 4. Every row joins to products and has a supplier
SELECT SUM(CASE WHEN product_name IS NULL THEN 1 ELSE 0 END) AS no_product,
       SUM(CASE WHEN supplier_name IS NULL THEN 1 ELSE 0 END) AS no_supplier,
       COUNT(DISTINCT supplier_name) AS suppliers
FROM inventory;

-- 5. Stock status distribution and value totals
SELECT stock_status, COUNT(*) AS n,
       DECIMAL(SUM(inventory_value_cost), 14, 2) AS value_cost,
       DECIMAL(AVG(days_of_supply), 10, 1) AS avg_dos
FROM inventory GROUP BY stock_status ORDER BY n DESC;

-- 6. A PLU must have ONE supplier chain-wide
SELECT COUNT(*) AS plu_with_multi_supplier FROM (
  SELECT plu FROM inventory GROUP BY plu HAVING COUNT(DISTINCT supplier_name) > 1
) t;

-- 7. Eyeball ten sample rows
SELECT FIRST 10 storenumber, storename, plu, product_name, supplier_name, aisle_bin,
       on_hand_qty, safety_stock, reorder_point, reorder_qty, stock_status,
       days_of_supply, annual_turns, gmroi, avg_daily_units, distinct_customers,
       premium_sales_pct
FROM inventory ORDER BY inventory_value_cost DESC;
