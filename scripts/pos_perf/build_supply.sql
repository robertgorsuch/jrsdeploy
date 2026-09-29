-- build_supply.sql -- DROP-and-rebuild of purchase_orders and shrinkage_log.
-- purchase_orders: one CLOSED historical PO per (store, supplier, month) --
-- roughly 75K rows. Supplier assignment comes from the inventory table so it
-- is guaranteed consistent with the per-PLU supplier hash. REAL inputs:
-- monthly units and cost from pos_sales_detail, order_date = first sale date
-- of that store-supplier-month, supplier lead times. FICTITIOUS but
-- DETERMINISTIC: ordered quantity (units rounded up to tens), fill rate
-- 90 to 100 percent, received and backordered units, actual lead days,
-- on-time flag (about 85 percent).
-- shrinkage_log: a 1-in-20 hash sample of (store, plu, month) sales cells,
-- each becoming one waste event -- reason mix is Expiry 45, Damage 25,
-- Temperature Excursion 15, Theft 10, Inventory Adjustment 5 percent.
-- Quantity lost scales with real monthly volume, valued at the real average
-- unit cost. event_date = last sale date in the cell (a real date).
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS po_base;

CREATE TABLE po_base AS
SELECT f.storenumber,
       i.supplier_name,
       YEAR(DATE(f.saledate)) AS yr,
       MONTH(DATE(f.saledate)) AS mo,
       SUM(f.quantity) AS units,
       SUM(f.cost) AS cost_line,
       COUNT(DISTINCT TRIM(f.plu)) AS line_count,
       MIN(DATE(f.saledate)) AS order_date,
       MAX(i.lead_time_days) AS lead_days
FROM pos_sales_detail f
JOIN inventory i ON i.storenumber = f.storenumber AND i.plu = TRIM(f.plu)
GROUP BY f.storenumber, i.supplier_name, YEAR(DATE(f.saledate)), MONTH(DATE(f.saledate));

DROP TABLE IF EXISTS purchase_orders;

CREATE TABLE purchase_orders AS
WITH c AS (
  SELECT b.*,
         VARCHAR(b.yr * 100 + b.mo) AS yyyymm,
         ((b.units + 9) / 10) * 10 AS ordered_units,
         90 + ABS(MOD(HASH(VARCHAR(b.storenumber) + b.supplier_name + VARCHAR(b.yr * 100 + b.mo) + 'fill'), 11)) AS fill_rate_pct,
         ABS(MOD(HASH(VARCHAR(b.storenumber) + b.supplier_name + VARCHAR(b.yr * 100 + b.mo) + 'lead'), 5)) AS lead_j,
         ABS(MOD(HASH(VARCHAR(b.storenumber) + b.supplier_name + VARCHAR(b.yr * 100 + b.mo) + 'ot'), 20)) AS ot_sel
  FROM po_base b
  WHERE b.units > 0
)
SELECT 'PO-' + VARCHAR(storenumber) + '-' + yyyymm + '-' +
         VARCHAR(10 + ABS(MOD(HASH(supplier_name), 90))) AS po_number,
       storenumber, supplier_name,
       yr AS order_year, mo AS order_month, order_date,
       lead_days AS expected_lead_days,
       CASE WHEN lead_days + lead_j - 2 < 1 THEN 1 ELSE lead_days + lead_j - 2 END AS actual_lead_days,
       CASE WHEN ot_sel < 17 THEN 'Y' ELSE 'N' END AS on_time,
       line_count, ordered_units,
       fill_rate_pct,
       ordered_units * fill_rate_pct / 100 AS received_units,
       ordered_units - (ordered_units * fill_rate_pct / 100) AS backordered_units,
       DECIMAL(cost_line * ordered_units / NULLIF(units, 0), 12, 2) AS po_value_cost,
       'Closed' AS po_status
FROM c;

DROP TABLE IF EXISTS po_base;

DROP TABLE IF EXISTS shr_base;

CREATE TABLE shr_base AS
SELECT f.storenumber,
       TRIM(f.plu) AS plu,
       YEAR(DATE(f.saledate)) AS yr,
       MONTH(DATE(f.saledate)) AS mo,
       SUM(f.quantity) AS units,
       SUM(f.cost) AS cost_line,
       MAX(DATE(f.saledate)) AS event_date
FROM pos_sales_detail f
GROUP BY f.storenumber, TRIM(f.plu), YEAR(DATE(f.saledate)), MONTH(DATE(f.saledate));

DROP TABLE IF EXISTS shrinkage_log;

CREATE TABLE shrinkage_log AS
WITH s AS (
  SELECT b.*,
         VARCHAR(b.yr * 100 + b.mo) AS yyyymm,
         ABS(MOD(HASH(VARCHAR(b.storenumber) + '|' + b.plu + '|' + VARCHAR(b.yr * 100 + b.mo) + 'shr'), 20)) AS pick,
         ABS(MOD(HASH(VARCHAR(b.storenumber) + '|' + b.plu + '|' + VARCHAR(b.yr * 100 + b.mo) + 'qty'), 24)) AS q_h,
         ABS(MOD(HASH(VARCHAR(b.storenumber) + '|' + b.plu + '|' + VARCHAR(b.yr * 100 + b.mo) + 'rsn'), 20)) AS r_h
  FROM shr_base b
  WHERE b.units > 0
)
SELECT 'SHR-' + VARCHAR(storenumber) + '-' + s.plu + '-' + yyyymm AS shrink_id,
       storenumber, s.plu,
       p.product_name, p.category,
       event_date, yr AS event_year, mo AS event_month,
       1 + MOD(q_h, CASE WHEN units / 8 < 1 THEN 1
                         WHEN units / 8 > 24 THEN 24
                         ELSE units / 8 END) AS qty_lost,
       DECIMAL(cost_line / units, 8, 2) AS unit_cost,
       DECIMAL((1 + MOD(q_h, CASE WHEN units / 8 < 1 THEN 1
                                  WHEN units / 8 > 24 THEN 24
                                  ELSE units / 8 END)) * cost_line / units, 10, 2) AS shrink_value,
       CASE WHEN r_h <= 8 THEN 'Expiry'
            WHEN r_h <= 13 THEN 'Damage'
            WHEN r_h <= 16 THEN 'Temperature Excursion'
            WHEN r_h <= 18 THEN 'Theft'
            ELSE 'Inventory Adjustment' END AS reason
FROM s
LEFT JOIN products p ON p.plu = s.plu
WHERE s.pick = 0;

DROP TABLE IF EXISTS shr_base;
