-- build_targets_suppliers.sql -- DROP-and-rebuild of sales_targets and suppliers.
-- sales_targets: one row per (store, year, month) that has sales history.
-- Targets are FICTITIOUS but calibrated to the REAL monthly actuals -- each
-- target is the actual value scaled by a hash-deterministic factor between
-- 90 and 110 percent, so beat-vs-missed-plan analysis produces a believable
-- mix without being uniform.
-- suppliers: one row per distributor name already used by inventory and
-- purchase_orders. Scorecard KPIs (spend, fill rate, on-time percent,
-- stores served, SKUs) are REAL aggregates of those tables. Contact
-- identity and terms are hash-deterministic fiction.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS tg_actual;

CREATE TABLE tg_actual AS
SELECT storenumber,
       YEAR(DATE(saledate)) AS yr,
       MONTH(DATE(saledate)) AS mo,
       SUM(sellingprice * quantity) AS actual_sales,
       SUM(cost) AS actual_cost,
       COUNT(DISTINCT transactionuniqueid) AS actual_txns
FROM pos_sales_detail
GROUP BY storenumber, YEAR(DATE(saledate)), MONTH(DATE(saledate));

DROP TABLE IF EXISTS sales_targets;

CREATE TABLE sales_targets AS
SELECT storenumber, yr, mo, yr * 100 + mo AS yyyymm,
       DECIMAL(actual_sales * (90 + ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(yr * 100 + mo) + 'ts'), 21))) / 100.0, 14, 2) AS target_sales,
       DECIMAL((actual_sales - actual_cost) * (88 + ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(yr * 100 + mo) + 'tm'), 25))) / 100.0, 14, 2) AS target_margin,
       INT4(actual_txns * (90 + ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(yr * 100 + mo) + 'tt'), 21))) / 100.0) AS target_transactions
FROM tg_actual;

DROP TABLE IF EXISTS tg_actual;

DROP TABLE IF EXISTS sup_seed_first;

CREATE TABLE sup_seed_first AS
SELECT 0 AS id, 'Marc' AS name UNION ALL SELECT 1, 'Julie' UNION ALL SELECT 2, 'Peter'
UNION ALL SELECT 3, 'Anita' UNION ALL SELECT 4, 'Raj' UNION ALL SELECT 5, 'Helen'
UNION ALL SELECT 6, 'Georges' UNION ALL SELECT 7, 'Tanya' UNION ALL SELECT 8, 'Bill'
UNION ALL SELECT 9, 'Marie' UNION ALL SELECT 10, 'Doug' UNION ALL SELECT 11, 'Sylvie';

DROP TABLE IF EXISTS sup_seed_last;

CREATE TABLE sup_seed_last AS
SELECT 0 AS id, 'Arsenault' AS name UNION ALL SELECT 1, 'Beaumont' UNION ALL SELECT 2, 'Chow'
UNION ALL SELECT 3, 'Desjardins' UNION ALL SELECT 4, 'Epp' UNION ALL SELECT 5, 'Falconer'
UNION ALL SELECT 6, 'Godin' UNION ALL SELECT 7, 'Hebert' UNION ALL SELECT 8, 'Ivany'
UNION ALL SELECT 9, 'Jamieson' UNION ALL SELECT 10, 'Klassen' UNION ALL SELECT 11, 'Lachance';

DROP TABLE IF EXISTS suppliers;

CREATE TABLE suppliers AS
WITH po AS (
  SELECT supplier_name,
         COUNT(*) AS purchase_orders,
         SUM(po_value_cost) AS total_spend,
         DECIMAL(AVG(fill_rate_pct), 6, 1) AS avg_fill_rate_pct,
         DECIMAL(100.0 * SUM(CASE WHEN on_time = 'Y' THEN 1 ELSE 0 END) / COUNT(*), 6, 1) AS on_time_pct,
         COUNT(DISTINCT storenumber) AS stores_served,
         MAX(expected_lead_days) AS lead_time_days
  FROM purchase_orders
  GROUP BY supplier_name
), inv AS (
  SELECT supplier_name, COUNT(DISTINCT plu) AS skus_supplied,
         SUM(sales_total) AS retail_sales_of_skus
  FROM inventory
  GROUP BY supplier_name
), cat AS (
  SELECT supplier_name, category AS category_focus FROM (
    SELECT supplier_name, category,
           ROW_NUMBER() OVER (PARTITION BY supplier_name ORDER BY SUM(sales_total) DESC, category) AS rk
    FROM inventory
    WHERE COALESCE(category, '') <> ''
    GROUP BY supplier_name, category
  ) t WHERE rk = 1
)
SELECT po.supplier_name,
       sf.name + ' ' + sl.name AS contact_name,
       LOWERCASE(sf.name) + '.' + LOWERCASE(sl.name) + '@' +
         LOWERCASE(LEFT(po.supplier_name, LOCATE(po.supplier_name, ' ') - 1)) + '.example.ca' AS contact_email,
       '(' + CASE ABS(MOD(HASH(po.supplier_name + 'ac'), 4))
             WHEN 0 THEN '416' WHEN 1 THEN '514' WHEN 2 THEN '604' ELSE '204' END +
       ') 555-01' + RIGHT('0' + VARCHAR(ABS(MOD(HASH(po.supplier_name + 'ph'), 100))), 2) AS contact_phone,
       CASE ABS(MOD(HASH(po.supplier_name + 'tm'), 3))
            WHEN 0 THEN 'Net 30' WHEN 1 THEN 'Net 45' ELSE 'Net 60' END AS payment_terms,
       cat.category_focus,
       po.lead_time_days, po.purchase_orders,
       DECIMAL(po.total_spend, 14, 2) AS total_spend,
       po.avg_fill_rate_pct, po.on_time_pct, po.stores_served,
       inv.skus_supplied,
       DECIMAL(inv.retail_sales_of_skus, 14, 2) AS retail_sales_of_skus
FROM po
JOIN inv ON inv.supplier_name = po.supplier_name
LEFT JOIN cat ON cat.supplier_name = po.supplier_name
JOIN sup_seed_first sf ON sf.id = ABS(MOD(HASH(po.supplier_name + 'cf'), 12))
JOIN sup_seed_last  sl ON sl.id = ABS(MOD(HASH(po.supplier_name + 'cl'), 12));

DROP TABLE IF EXISTS sup_seed_first;

DROP TABLE IF EXISTS sup_seed_last;
