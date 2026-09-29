-- verify_products.sql -- checks for the products dimension table.

-- 1. Row count must equal distinct PLU count in pos_sales_detail (942), and
--    plu must be unique.
SELECT COUNT(*) AS rows, COUNT(DISTINCT plu) AS distinct_plu FROM products;

-- 2. Catalog coverage by PLU.
SELECT on_website, COUNT(*) AS plus FROM products GROUP BY 1;

-- 3. Catalog coverage weighted by sales volume (Regular Sale net sales).
SELECT p.on_website,
       COUNT(*) AS line_items,
       SUM(f.sellingprice * f.quantity) AS sales_ext
FROM pos_sales_detail f
JOIN products p ON TRIM(f.plu) = p.plu
WHERE f.transactiontype = 'Regular Sale'
GROUP BY 1;

-- 4. Enrichment field fill-rates among matched rows.
SELECT COUNT(*) AS matched,
       SUM(CASE WHEN category       IS NOT NULL AND category    <> '' THEN 1 ELSE 0 END) AS has_category,
       SUM(CASE WHEN sub_category   IS NOT NULL AND sub_category<> '' THEN 1 ELSE 0 END) AS has_sub_category,
       SUM(CASE WHEN package_size   IS NOT NULL AND package_size<> '' THEN 1 ELSE 0 END) AS has_size,
       SUM(CASE WHEN price_cad      IS NOT NULL THEN 1 ELSE 0 END) AS has_price,
       SUM(CASE WHEN ingredients    IS NOT NULL AND ingredients <> '' THEN 1 ELSE 0 END) AS has_ingredients,
       SUM(CASE WHEN allergens      IS NOT NULL AND allergens   <> '' THEN 1 ELSE 0 END) AS has_allergens,
       SUM(CASE WHEN calories       IS NOT NULL THEN 1 ELSE 0 END) AS has_calories
FROM products WHERE on_website = 'Y';

-- 5. Spot-check: top sellers with their enrichment.
SELECT FIRST 10 plu, pos_description, product_name, category, sub_category,
       package_size, price_cad, calories, sodium_mg, on_website
FROM products
WHERE plu IN ('214','37','205','4301','416','517','432','371','500','682')
ORDER BY plu;
