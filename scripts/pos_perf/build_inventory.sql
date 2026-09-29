-- build_inventory.sql -- DROP-and-rebuild of the fictitious inventory table.
-- One row per (storenumber, plu) combination with sales history in
-- pos_sales_detail (215,009 rows -- 330 stores x 942 PLUs, sparse).
-- Snapshot semantics: stock positions are AS OF the dataset end (the max
-- sale date, 2020-12-31).
-- Ties into the rest of the schema:
--   products  -- plu joins to products.plu, supplier is assigned PER PLU so
--                the same product has the same supplier chain-wide
--   pos_sales_detail -- units, sales, velocity, first/last sold are REAL
--                aggregates from the fact table
--   customers -- distinct_customers and premium_sales_pct (share of sales to
--                Platinum or Gold loyalty_tier members) come from joining the
--                fact table to the customers dimension
-- Stock numbers (on hand, safety stock, reorder point) are FICTITIOUS but
-- DETERMINISTIC -- HASH(store + plu + salt) -- and are scaled to the item
-- recent REAL sales velocity so days-of-supply and turns look plausible.
-- About 3 percent of active items are forced to zero on hand (stockouts).
-- Margin basis follows build_dash_aggregates.sql -- sellingprice is PER-UNIT,
-- cost is a LINE total. Julian day arithmetic is used for day spans because
-- INTERVAL() is not supported on X100 tables.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments, and its splitter tracks quote state with NO comment awareness --
-- never put a semicolon OR an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS inv_seed_supplier;

CREATE TABLE inv_seed_supplier AS
SELECT 0 AS id, 'Northline Distribution' AS name, 3 AS lead_time_days
UNION ALL SELECT 1, 'Great Lakes Wholesale', 5
UNION ALL SELECT 2, 'Laurentide Supply Co', 7
UNION ALL SELECT 3, 'Pacific Crest Foods', 4
UNION ALL SELECT 4, 'Prairie Peak Distributors', 6
UNION ALL SELECT 5, 'Maritime Provisions', 8
UNION ALL SELECT 6, 'TrueNorth Logistics', 5
UNION ALL SELECT 7, 'Boreal Foods Group', 4
UNION ALL SELECT 8, 'Cascadia Candy Supply', 7
UNION ALL SELECT 9, 'Champlain Trading', 6
UNION ALL SELECT 10, 'Redwood Snack Partners', 9
UNION ALL SELECT 11, 'Silver Birch Wholesale', 5;

-- Real per-store-per-PLU sales aggregates, joined to customers for the
-- loyalty-tier sales share

DROP TABLE IF EXISTS inv_sales;

-- Grain is STRICTLY (storenumber, plu) -- store attributes are MAX()ed
-- because renamed stores would otherwise split the key and fan out joins
CREATE TABLE inv_sales AS
SELECT f.storenumber,
       MAX(f.storename) AS storename,
       MAX(f.storeprovince) AS storeprovince,
       MAX(f.storeregion) AS storeregion,
       TRIM(f.plu) AS plu,
       SUM(f.quantity) AS units_sold_total,
       SUM(f.sellingprice * f.quantity) AS sales_total,
       SUM(f.cost) AS cost_total,
       COUNT(DISTINCT f.customernumber) AS distinct_customers,
       SUM(CASE WHEN cu.loyalty_tier IN ('Platinum','Gold')
                THEN f.sellingprice * f.quantity ELSE 0 END) AS premium_sales,
       SUM(CASE WHEN DATE(f.saledate) >= DATE('2020-10-03') THEN f.quantity ELSE 0 END) AS units_90d,
       MIN(DATE(f.saledate)) AS first_sold_date,
       MAX(DATE(f.saledate)) AS last_sold_date
FROM pos_sales_detail f
JOIN customers cu ON cu.customer_id = f.customernumber
GROUP BY f.storenumber, TRIM(f.plu);

DROP TABLE IF EXISTS inventory;

CREATE TABLE inventory AS
WITH j1 AS (
  SELECT storenumber, plu,
         YEAR(first_sold_date) + 4800 - (14 - MONTH(first_sold_date)) / 12 AS fy,
         MONTH(first_sold_date) + 12 * ((14 - MONTH(first_sold_date)) / 12) - 3 AS fm,
         DAY(first_sold_date) AS fd,
         YEAR(last_sold_date) + 4800 - (14 - MONTH(last_sold_date)) / 12 AS ly,
         MONTH(last_sold_date) + 12 * ((14 - MONTH(last_sold_date)) / 12) - 3 AS lm,
         DAY(last_sold_date) AS ld
  FROM inv_sales
), j2 AS (
  SELECT storenumber, plu,
         fd + (153 * fm + 2) / 5 + 365 * fy + fy / 4 - fy / 100 + fy / 400 - 32045 AS first_jdn,
         ld + (153 * lm + 2) / 5 + 365 * ly + ly / 4 - ly / 100 + ly / 400 - 32045 AS last_jdn
  FROM j1
), calc AS (
  SELECT s.storenumber, s.storename, s.storeprovince, s.storeregion, s.plu,
         COALESCE(p.product_name, p.pos_description) AS product_name,
         p.category, p.sub_category,
         sup.name AS supplier_name, sup.lead_time_days,
         s.units_sold_total, s.sales_total, s.cost_total, s.distinct_customers,
         s.premium_sales, s.units_90d, s.first_sold_date, s.last_sold_date,
         j.first_jdn, j.last_jdn,
         (SELECT MAX(last_jdn) FROM j2) - j.last_jdn AS days_since_last_sale,
         CASE WHEN s.units_90d > 0 THEN DECIMAL(s.units_90d, 12, 3) / 90
              WHEN s.units_sold_total > 0 THEN DECIMAL(s.units_sold_total, 12, 3) /
                   (CASE WHEN j.last_jdn - j.first_jdn + 1 < 30 THEN 30
                         ELSE j.last_jdn - j.first_jdn + 1 END)
              ELSE DECIMAL(0, 12, 3) END AS v,
         CASE WHEN s.units_sold_total > 0
              THEN DECIMAL(s.cost_total / s.units_sold_total, 8, 2) END AS unit_cost,
         CASE WHEN s.units_sold_total > 0
              THEN DECIMAL(s.sales_total / s.units_sold_total, 8, 2) END AS unit_retail,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'dos'), 35)) AS h_dos,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'out'), 33)) AS h_out,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'min'), 4))  AS h_min,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'ss'),  5))  AS h_ss,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'rc'),  21)) AS h_rc,
         CASE ABS(MOD(HASH(s.plu + 'cs'), 4)) WHEN 0 THEN 8 WHEN 1 THEN 12
              WHEN 2 THEN 24 ELSE 36 END AS case_size,
         CHAREXTRACT('ABCDEF', 1 + ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'ai'), 6))) + '-' +
           VARCHAR(1 + ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'ba'), 20))) + '-' +
           VARCHAR(1 + ABS(MOD(HASH(VARCHAR(s.storenumber) + '|' + s.plu + 'sh'), 5))) AS aisle_bin
  FROM inv_sales s
  JOIN j2 j ON j.storenumber = s.storenumber AND j.plu = s.plu
  LEFT JOIN products p ON p.plu = s.plu
  JOIN inv_seed_supplier sup ON sup.id = ABS(MOD(HASH(s.plu + 'sup'), 12))
), stock AS (
  SELECT c.*,
         CASE WHEN c.days_since_last_sale > 60 THEN
                CASE WHEN MOD(c.h_out, 3) = 0 THEN 0 ELSE MOD(c.h_out, 6) END
              WHEN c.h_out = 0 THEN 0
              WHEN INT4(c.v * (7 + c.h_dos) + 0.5) < 1 THEN 1 + c.h_min
              ELSE INT4(c.v * (7 + c.h_dos) + 0.5) END AS on_hand_qty,
         INT4(c.v * (3 + c.h_ss) + 1) AS safety_stock,
         INT4(c.v * (3 + c.h_ss) + 1) + INT4(c.v * c.lead_time_days + 0.5) AS reorder_point,
         ((INT4(c.v * 14 + 1) + c.case_size - 1) / c.case_size) * c.case_size AS reorder_qty
  FROM calc c
)
SELECT storenumber, storename, storeprovince, storeregion,
       plu, product_name, category, sub_category,
       supplier_name, lead_time_days, aisle_bin, case_size,
       on_hand_qty, safety_stock, reorder_point, reorder_qty,
       unit_cost, unit_retail,
       DECIMAL(on_hand_qty * unit_cost, 12, 2) AS inventory_value_cost,
       DECIMAL(on_hand_qty * unit_retail, 12, 2) AS inventory_value_retail,
       DECIMAL(v, 10, 3) AS avg_daily_units,
       CASE WHEN v > 0 THEN DECIMAL(on_hand_qty / v, 8, 1) END AS days_of_supply,
       CASE WHEN on_hand_qty > 0 AND v > 0
            THEN DECIMAL(365.0 * v / on_hand_qty, 8, 1) END AS annual_turns,
       CASE WHEN on_hand_qty > 0 AND unit_cost > 0
            THEN DECIMAL(365.0 * v * (unit_retail - unit_cost) / (on_hand_qty * unit_cost), 8, 2)
            END AS gmroi,
       CASE WHEN on_hand_qty = 0 THEN 'Out of Stock'
            WHEN on_hand_qty <= safety_stock THEN 'Critical'
            WHEN on_hand_qty <= reorder_point THEN 'Reorder'
            WHEN v > 0 AND on_hand_qty > v * 60 THEN 'Overstock'
            ELSE 'In Stock' END AS stock_status,
       1 + h_rc AS days_since_receipt,
       units_sold_total, units_90d,
       DECIMAL(sales_total, 14, 2) AS sales_total,
       distinct_customers,
       DECIMAL(100.0 * premium_sales / NULLIF(sales_total, 0), 8, 2) AS premium_sales_pct,
       first_sold_date, last_sold_date, days_since_last_sale
FROM stock;

DROP TABLE IF EXISTS inv_sales;

DROP TABLE IF EXISTS inv_seed_supplier;
