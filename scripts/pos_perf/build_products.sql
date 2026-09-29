-- build_products.sql -- DROP-and-rebuild of the products dimension table.
-- Inputs: pos_sales_detail (63.6M rows, static) for the 942 distinct PLUs +
-- descriptions, and mm_products_stage (all-VARCHAR staging, loaded from
-- mm_products.csv by scrape_mm_products.py via sql.ps1 load-csv).
-- One row per distinct PLU. pos_description is the most frequent
-- productdescription for the PLU (ties broken alphabetically). Catalog
-- enrichment joins on PLU, and PLUs absent from the catalog keep their POS
-- description with on_website = 'N' and NULL enrichment columns.
-- Staging is all VARCHAR so empty strings never hit numeric columns at load
-- time -- numeric casts happen here, guarded by CASE WHEN TRIM(x) <> ''.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.
DROP TABLE IF EXISTS products;

CREATE TABLE products AS
WITH d AS (
  SELECT TRIM(plu) AS plu, TRIM(productdescription) AS pos_description, COUNT(*) AS c
  FROM pos_sales_detail
  GROUP BY 1, 2
), r AS (
  SELECT plu, pos_description,
         ROW_NUMBER() OVER (PARTITION BY plu ORDER BY c DESC, pos_description) AS rn
  FROM d
)
SELECT r.plu,
       r.pos_description,
       s.product_name,
       s.web_description,
       s.category,
       s.sub_category,
       s.single_serve,
       s.vegetarian,
       s.vegan,
       s.gluten_free,
       s.package_size,
       CASE WHEN TRIM(COALESCE(s.size_g,          '')) <> '' THEN CAST(s.size_g          AS DECIMAL(8,1)) END AS size_g,
       CASE WHEN TRIM(COALESCE(s.price_cad,       '')) <> '' THEN CAST(s.price_cad       AS DECIMAL(8,2)) END AS price_cad,
       s.in_stock,
       s.ingredients,
       s.allergens,
       s.serving_size,
       CASE WHEN TRIM(COALESCE(s.serving_g,       '')) <> '' THEN CAST(s.serving_g       AS DECIMAL(8,1)) END AS serving_g,
       CASE WHEN TRIM(COALESCE(s.calories,        '')) <> '' THEN CAST(s.calories        AS INTEGER)      END AS calories,
       CASE WHEN TRIM(COALESCE(s.fat_g,           '')) <> '' THEN CAST(s.fat_g           AS DECIMAL(6,1)) END AS fat_g,
       CASE WHEN TRIM(COALESCE(s.sat_fat_g,       '')) <> '' THEN CAST(s.sat_fat_g       AS DECIMAL(6,1)) END AS sat_fat_g,
       CASE WHEN TRIM(COALESCE(s.carbs_g,         '')) <> '' THEN CAST(s.carbs_g         AS DECIMAL(6,1)) END AS carbs_g,
       CASE WHEN TRIM(COALESCE(s.fibre_g,         '')) <> '' THEN CAST(s.fibre_g         AS DECIMAL(6,1)) END AS fibre_g,
       CASE WHEN TRIM(COALESCE(s.sugars_g,        '')) <> '' THEN CAST(s.sugars_g        AS DECIMAL(6,1)) END AS sugars_g,
       CASE WHEN TRIM(COALESCE(s.protein_g,       '')) <> '' THEN CAST(s.protein_g       AS DECIMAL(6,1)) END AS protein_g,
       CASE WHEN TRIM(COALESCE(s.cholesterol_mg,  '')) <> '' THEN CAST(s.cholesterol_mg  AS DECIMAL(7,1)) END AS cholesterol_mg,
       CASE WHEN TRIM(COALESCE(s.sodium_mg,       '')) <> '' THEN CAST(s.sodium_mg       AS DECIMAL(7,1)) END AS sodium_mg,
       CASE WHEN TRIM(COALESCE(s.potassium_mg,    '')) <> '' THEN CAST(s.potassium_mg    AS DECIMAL(7,1)) END AS potassium_mg,
       CASE WHEN s.plu IS NULL THEN 'N' ELSE 'Y' END AS on_website
FROM r
LEFT JOIN mm_products_stage s ON r.plu = s.plu
WHERE r.rn = 1;
