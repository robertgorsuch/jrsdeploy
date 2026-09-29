-- build_pricebook_tax_assets.sql -- DROP-and-rebuild of four tables:
--
-- pricebook_history (PLU x month, REAL) -- monthly average pricebook cost,
-- regular price, sale price and realised selling price per PLU from
-- pos_sales_detail, with month-over-month cost and price change and the
-- price-cost spread. Powers cost-inflation, price pass-through and
-- margin-bridge questions.
--
-- provincial_tax_rates (province x effective_from) -- REAL Canadian
-- GST/HST/PST rates for 2019-2020, including the real Manitoba RST cut
-- from 8 to 7 percent on 2019-07-01. Basic groceries are zero-rated and
-- the taxable categories here are: Prepared meals, Single serve, Appetizers,
-- Desserts, Kitchen essentials. Uncatalogued PLUs (79 percent of the
-- catalogue) are treated as zero-rated basic groceries -- conservative,
-- documented.
--
-- tax_collected_monthly (store x month, DERIVED) -- taxable vs zero-rated
-- sales and GST/HST + PST collected, from the line fact x products x rates.
-- Tax is collected on top of the selling price (a remittance liability,
-- never revenue -- it does not touch the P&L).
--
-- store_assets (one row per store, MODELED anchored) -- build cost,
-- leasehold improvements and equipment (freezer-heavy) from square feet and
-- format, straight-line depreciation (leasehold 10y, equipment 7y), net
-- book value as of 2020-12-31, lease expiry from the REAL open date, and a
-- hash-picked 2020 refit for about 15 percent of the 2019-H1 openers (for
-- refit-ROI stories against store_traffic).
-- Requires: pos_sales_detail, products, stores, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

-- ---------------------------------------------------------------- pricebook

DROP TABLE IF EXISTS pb_month;

CREATE TABLE pb_month AS
SELECT TRIM(f.plu) AS plu,
       YEAR(DATE(f.saledate)) * 100 + MONTH(DATE(f.saledate)) AS yyyymm,
       MAX(f.productdescription) AS product_description,
       AVG(f.pricebookcost) AS avg_pricebook_cost,
       AVG(f.pricebookregularprice) AS avg_regular_price,
       AVG(f.pricebooksaleprice) AS avg_sale_price,
       SUM(f.sellingprice * f.quantity) / NULLIF(SUM(f.quantity), 0) AS avg_selling_price,
       SUM(f.quantity) AS units,
       SUM(f.sellingprice * f.quantity) AS sales,
       COUNT(DISTINCT f.storenumber) AS stores_selling
FROM pos_sales_detail f
WHERE f.transactiontype = 'Regular Sale'
GROUP BY TRIM(f.plu), YEAR(DATE(f.saledate)) * 100 + MONTH(DATE(f.saledate));

DROP TABLE IF EXISTS pb_me;

CREATE TABLE pb_me AS
SELECT yyyymm, MIN(calendar_date) AS month_start FROM date_dim GROUP BY yyyymm;

DROP TABLE IF EXISTS pricebook_history;

CREATE TABLE pricebook_history AS
WITH l AS (
  SELECT m.*,
         LAG(m.avg_pricebook_cost) OVER (PARTITION BY m.plu ORDER BY m.yyyymm) AS prev_cost,
         LAG(m.avg_regular_price) OVER (PARTITION BY m.plu ORDER BY m.yyyymm) AS prev_regular,
         LAG(m.avg_selling_price) OVER (PARTITION BY m.plu ORDER BY m.yyyymm) AS prev_selling
  FROM pb_month m
)
SELECT l.plu, e.month_start, l.yyyymm, l.yyyymm / 100 AS yr, MOD(l.yyyymm, 100) AS mo,
       COALESCE(p.product_name, l.product_description) AS product_name,
       p.category, p.sub_category,
       CASE WHEN COALESCE(p.category, '') <> '' THEN 'Y' ELSE 'N' END AS catalogued,
       DECIMAL(l.avg_pricebook_cost, 8, 2) AS avg_pricebook_cost,
       DECIMAL(l.avg_regular_price, 8, 2) AS avg_regular_price,
       DECIMAL(l.avg_sale_price, 8, 2) AS avg_sale_price,
       DECIMAL(l.avg_selling_price, 8, 2) AS avg_selling_price,
       l.units, DECIMAL(l.sales, 12, 2) AS sales, l.stores_selling,
       DECIMAL(l.avg_regular_price - l.avg_pricebook_cost, 8, 2) AS price_cost_spread,
       DECIMAL(100.0 * FLOAT8(l.avg_regular_price - l.avg_pricebook_cost) / NULLIF(FLOAT8(l.avg_regular_price), 0), 8, 2) AS margin_pct_at_regular,
       DECIMAL(100.0 * FLOAT8(l.avg_selling_price - l.avg_pricebook_cost) / NULLIF(FLOAT8(l.avg_selling_price), 0), 8, 2) AS margin_pct_realised,
       DECIMAL(100.0 * FLOAT8(l.avg_pricebook_cost - l.prev_cost) / NULLIF(FLOAT8(l.prev_cost), 0), 10, 2) AS cost_change_pct,
       DECIMAL(100.0 * FLOAT8(l.avg_regular_price - l.prev_regular) / NULLIF(FLOAT8(l.prev_regular), 0), 10, 2) AS price_change_pct,
       DECIMAL(100.0 * FLOAT8(l.avg_selling_price - l.prev_selling) / NULLIF(FLOAT8(l.prev_selling), 0), 10, 2) AS selling_price_change_pct
FROM l
JOIN pb_me e ON e.yyyymm = l.yyyymm
LEFT JOIN products p ON p.plu = l.plu;

DROP TABLE IF EXISTS pb_me;

DROP TABLE IF EXISTS pb_month;

-- ---------------------------------------------------------------- tax rates

DROP TABLE IF EXISTS provincial_tax_rates;

CREATE TABLE provincial_tax_rates AS
SELECT 'ON' AS province, 'Ontario' AS province_name, DATE('2019-01-01') AS effective_from,
       5.0 AS gst_pct, 8.0 AS provincial_pct, 13.0 AS combined_pct, 'HST' AS provincial_tax_name
UNION ALL SELECT 'NB', 'New Brunswick', DATE('2019-01-01'), 5.0, 10.0, 15.0, 'HST'
UNION ALL SELECT 'NL', 'Newfoundland and Labrador', DATE('2019-01-01'), 5.0, 10.0, 15.0, 'HST'
UNION ALL SELECT 'NS', 'Nova Scotia', DATE('2019-01-01'), 5.0, 10.0, 15.0, 'HST'
UNION ALL SELECT 'PE', 'Prince Edward Island', DATE('2019-01-01'), 5.0, 10.0, 15.0, 'HST'
UNION ALL SELECT 'QC', 'Quebec', DATE('2019-01-01'), 5.0, 9.975, 14.975, 'QST'
UNION ALL SELECT 'BC', 'British Columbia', DATE('2019-01-01'), 5.0, 7.0, 12.0, 'PST'
UNION ALL SELECT 'SK', 'Saskatchewan', DATE('2019-01-01'), 5.0, 6.0, 11.0, 'PST'
UNION ALL SELECT 'MB', 'Manitoba', DATE('2019-01-01'), 5.0, 8.0, 13.0, 'RST'
UNION ALL SELECT 'MB', 'Manitoba', DATE('2019-07-01'), 5.0, 7.0, 12.0, 'RST'
UNION ALL SELECT 'AB', 'Alberta', DATE('2019-01-01'), 5.0, 0.0, 5.0, 'None'
UNION ALL SELECT 'YT', 'Yukon', DATE('2019-01-01'), 5.0, 0.0, 5.0, 'None'
UNION ALL SELECT 'NT', 'Northwest Territories', DATE('2019-01-01'), 5.0, 0.0, 5.0, 'None';

-- ---------------------------------------------------------------- tax collected

DROP TABLE IF EXISTS txm_lines;

CREATE TABLE txm_lines AS
SELECT f.storenumber, s.province, s.region,
       YEAR(DATE(f.saledate)) * 100 + MONTH(DATE(f.saledate)) AS yyyymm,
       SUM(CASE WHEN p.category IN ('Prepared meals', 'Single serve', 'Appetizers', 'Desserts', 'Kitchen essentials')
                THEN f.sellingprice * f.quantity ELSE 0 END) AS taxable_sales,
       SUM(CASE WHEN p.category IN ('Prepared meals', 'Single serve', 'Appetizers', 'Desserts', 'Kitchen essentials')
                THEN 0 ELSE f.sellingprice * f.quantity END) AS zero_rated_sales
FROM pos_sales_detail f
JOIN stores s ON s.storenumber = f.storenumber
LEFT JOIN products p ON p.plu = TRIM(f.plu)
WHERE f.transactiontype = 'Regular Sale'
GROUP BY f.storenumber, s.province, s.region, YEAR(DATE(f.saledate)) * 100 + MONTH(DATE(f.saledate));

DROP TABLE IF EXISTS pb_me2;

CREATE TABLE pb_me2 AS
SELECT yyyymm, MIN(calendar_date) AS month_start FROM date_dim GROUP BY yyyymm;

DROP TABLE IF EXISTS tax_collected_monthly;

CREATE TABLE tax_collected_monthly AS
WITH r AS (
  SELECT t.*, e.month_start, x.gst_pct, x.provincial_pct, x.combined_pct, x.provincial_tax_name,
         ROW_NUMBER() OVER (PARTITION BY t.storenumber, t.yyyymm ORDER BY x.effective_from DESC) AS rk
  FROM txm_lines t
  JOIN pb_me2 e ON e.yyyymm = t.yyyymm
  JOIN provincial_tax_rates x ON x.province = t.province AND x.effective_from <= e.month_start
)
SELECT storenumber, province, region, yyyymm, month_start,
       yyyymm / 100 AS yr, MOD(yyyymm, 100) AS mo,
       DECIMAL(taxable_sales, 12, 2) AS taxable_sales,
       DECIMAL(zero_rated_sales, 12, 2) AS zero_rated_sales,
       DECIMAL(taxable_sales + zero_rated_sales, 12, 2) AS net_sales,
       DECIMAL(100.0 * taxable_sales / NULLIF(taxable_sales + zero_rated_sales, 0), 6, 2) AS taxable_share_pct,
       gst_pct, provincial_pct, combined_pct, provincial_tax_name,
       DECIMAL(taxable_sales * gst_pct / 100.0, 12, 2) AS gst_collected,
       DECIMAL(taxable_sales * provincial_pct / 100.0, 12, 2) AS provincial_tax_collected,
       DECIMAL(taxable_sales * combined_pct / 100.0, 12, 2) AS total_tax_collected
FROM r WHERE rk = 1;

DROP TABLE IF EXISTS txm_lines;

DROP TABLE IF EXISTS pb_me2;

-- ---------------------------------------------------------------- store assets

DROP TABLE IF EXISTS store_assets;

CREATE TABLE store_assets AS
WITH b AS (
  SELECT s.storenumber, s.storename, s.province, s.region, s.store_format, s.square_feet,
         s.open_date, s.franchisee_id, a.as_of_date,
         CASE s.store_format WHEN 'Shopping Mall' THEN 240.0 WHEN 'Urban Storefront' THEN 220.0
                             WHEN 'Strip Plaza' THEN 190.0 ELSE 180.0 END
           * (0.90 + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'bld'), 21)) / 100.0) AS build_rate,
         55.0 + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'eqp'), 21)) AS equip_rate,
         CASE WHEN ABS(MOD(HASH(VARCHAR(s.storenumber) + 'lse'), 2)) = 0 THEN 5 ELSE 10 END AS lease_years,
         CASE WHEN s.open_date < DATE('2019-07-01')
                   AND ABS(MOD(HASH(VARCHAR(s.storenumber) + 'rft'), 100)) < 15
              THEN DATE('2020-01-01') + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'rfd'), 270))
         END AS refit_date
  FROM stores s
  CROSS JOIN (SELECT MAX(calendar_date) AS as_of_date FROM date_dim) a
), c AS (
  SELECT b.*,
         b.square_feet * b.build_rate AS leasehold_cost,
         b.square_feet * b.equip_rate AS equipment_cost,
         CASE WHEN b.refit_date IS NOT NULL
              THEN b.square_feet * (35.0 + ABS(MOD(HASH(VARCHAR(b.storenumber) + 'rfc'), 26))) END AS refit_cost,
         GREATEST(0, b.as_of_date - b.open_date) AS days_open,
         CASE WHEN b.refit_date IS NOT NULL THEN GREATEST(0, b.as_of_date - b.refit_date) END AS days_since_refit
  FROM b
)
SELECT storenumber, storename, province, region, store_format, square_feet, franchisee_id,
       open_date,
       DECIMAL(leasehold_cost, 12, 2) AS leasehold_improvements_cost,
       DECIMAL(equipment_cost, 12, 2) AS equipment_cost,
       DECIMAL(leasehold_cost + equipment_cost, 12, 2) AS total_build_cost,
       refit_date,
       DECIMAL(refit_cost, 12, 2) AS refit_cost,
       DECIMAL(leasehold_cost / 120.0, 10, 2) AS leasehold_monthly_depreciation,
       DECIMAL(equipment_cost / 84.0, 10, 2) AS equipment_monthly_depreciation,
       DECIMAL(leasehold_cost / 120.0 + equipment_cost / 84.0
               + COALESCE(refit_cost, 0) / 120.0, 10, 2) AS total_monthly_depreciation,
       DECIMAL(GREATEST(0, leasehold_cost * (1.0 - (days_open / 30.44) / 120.0))
             + GREATEST(0, equipment_cost * (1.0 - (days_open / 30.44) / 84.0))
             + COALESCE(GREATEST(0, refit_cost * (1.0 - (days_since_refit / 30.44) / 120.0)), 0), 12, 2) AS net_book_value,
       open_date + lease_years * 365 AS lease_expiry,
       lease_years,
       CASE WHEN ABS(MOD(HASH(VARCHAR(storenumber) + 'ren'), 100)) < 70 THEN 'Y' ELSE 'N' END AS renewal_option,
       days_open
FROM c;

CREATE STATISTICS FOR pricebook_history;

CREATE STATISTICS FOR provincial_tax_rates;

CREATE STATISTICS FOR tax_collected_monthly;

CREATE STATISTICS FOR store_assets;
