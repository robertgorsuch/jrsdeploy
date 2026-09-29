-- build_customer_diet_profile.sql -- DROP-and-rebuild of customer_diet_profile,
-- one row per customer (3.18M). Everything here is REAL -- behavioural
-- pseudo-demographics computed from pos_sales_detail x products using the
-- catalogue diet flags (vegan, vegetarian, gluten_free, single_serve), the
-- allergens list and the per-serving nutrition columns.
-- Only 203 of the 942 PLUs carry diet flags and about 170 carry allergens,
-- so every share is expressed over FLAGGED spend (spend on PLUs where the
-- flag is populated) and flagged_coverage_pct says how much of the customer
-- lifetime spend that denominator represents. Treat shares with coverage
-- under 20 percent as weak evidence.
-- Category shares use the categorised spend (products.category non-blank).
-- diet_profile is a simple label over the shares for segmentation tiles.
-- Requires: pos_sales_detail, products.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS diet_agg;

CREATE TABLE diet_agg AS
SELECT f.customernumber AS customer_id,
       SUM(f.sellingprice * f.quantity) AS total_spend,
       SUM(CASE WHEN COALESCE(p.vegan,'') <> '' THEN f.sellingprice * f.quantity ELSE 0 END) AS flagged_spend,
       SUM(CASE WHEN p.vegan = 'Y' THEN f.sellingprice * f.quantity ELSE 0 END) AS vegan_spend,
       SUM(CASE WHEN p.vegetarian = 'Y' THEN f.sellingprice * f.quantity ELSE 0 END) AS vegetarian_spend,
       SUM(CASE WHEN p.gluten_free = 'Y' THEN f.sellingprice * f.quantity ELSE 0 END) AS gluten_free_spend,
       SUM(CASE WHEN p.single_serve = 'Y' THEN f.sellingprice * f.quantity ELSE 0 END) AS single_serve_spend,
       SUM(CASE WHEN COALESCE(p.allergens,'') NOT IN ('', 'None', 'none', 'N/A') THEN f.sellingprice * f.quantity ELSE 0 END) AS allergen_spend,
       SUM(CASE WHEN COALESCE(p.category,'') <> '' THEN f.sellingprice * f.quantity ELSE 0 END) AS categorised_spend,
       SUM(CASE WHEN p.category = 'Prepared meals' THEN f.sellingprice * f.quantity ELSE 0 END) AS prepared_meals_spend,
       SUM(CASE WHEN p.category = 'Butcher' THEN f.sellingprice * f.quantity ELSE 0 END) AS butcher_spend,
       SUM(CASE WHEN p.category = 'Seafood' THEN f.sellingprice * f.quantity ELSE 0 END) AS seafood_spend,
       SUM(CASE WHEN p.category = 'Desserts' THEN f.sellingprice * f.quantity ELSE 0 END) AS desserts_spend,
       SUM(CASE WHEN p.category = 'Appetizers' THEN f.sellingprice * f.quantity ELSE 0 END) AS appetizers_spend,
       SUM(CASE WHEN p.category = 'Vegetables' THEN f.sellingprice * f.quantity ELSE 0 END) AS vegetables_spend,
       SUM(CASE WHEN p.calories IS NOT NULL THEN f.quantity ELSE 0 END) AS nutrition_units,
       SUM(CASE WHEN p.calories IS NOT NULL THEN f.quantity * p.calories ELSE 0 END) AS calories_units,
       SUM(CASE WHEN p.sodium_mg IS NOT NULL THEN f.quantity * p.sodium_mg ELSE 0 END) AS sodium_units,
       SUM(CASE WHEN p.sugars_g IS NOT NULL THEN f.quantity * p.sugars_g ELSE 0 END) AS sugars_units,
       SUM(CASE WHEN p.protein_g IS NOT NULL THEN f.quantity * p.protein_g ELSE 0 END) AS protein_units,
       SUM(CASE WHEN p.serving_g IS NOT NULL THEN f.quantity * p.serving_g ELSE 0 END) AS serving_units,
       COUNT(DISTINCT CASE WHEN COALESCE(p.category,'') <> '' THEN p.category END) AS categories_bought,
       COUNT(DISTINCT TRIM(f.plu)) AS distinct_plus
FROM pos_sales_detail f
LEFT JOIN products p ON p.plu = TRIM(f.plu)
WHERE f.transactiontype = 'Regular Sale'
GROUP BY f.customernumber;

DROP TABLE IF EXISTS customer_diet_profile;

CREATE TABLE customer_diet_profile AS
WITH s AS (
  SELECT a.*,
         DECIMAL(100.0 * flagged_spend / NULLIF(total_spend, 0), 6, 2) AS coverage,
         DECIMAL(100.0 * vegan_spend / NULLIF(flagged_spend, 0), 6, 2) AS vegan_p,
         DECIMAL(100.0 * vegetarian_spend / NULLIF(flagged_spend, 0), 6, 2) AS vegetarian_p,
         DECIMAL(100.0 * gluten_free_spend / NULLIF(flagged_spend, 0), 6, 2) AS gf_p,
         DECIMAL(100.0 * single_serve_spend / NULLIF(flagged_spend, 0), 6, 2) AS ss_p,
         DECIMAL(100.0 * allergen_spend / NULLIF(flagged_spend, 0), 6, 2) AS allergen_p,
         DECIMAL(100.0 * prepared_meals_spend / NULLIF(categorised_spend, 0), 6, 2) AS prepared_p,
         DECIMAL(100.0 * butcher_spend / NULLIF(categorised_spend, 0), 6, 2) AS butcher_p,
         DECIMAL(100.0 * seafood_spend / NULLIF(categorised_spend, 0), 6, 2) AS seafood_p,
         DECIMAL(100.0 * desserts_spend / NULLIF(categorised_spend, 0), 6, 2) AS desserts_p,
         DECIMAL(100.0 * appetizers_spend / NULLIF(categorised_spend, 0), 6, 2) AS appetizers_p,
         DECIMAL(100.0 * vegetables_spend / NULLIF(categorised_spend, 0), 6, 2) AS vegetables_p
  FROM diet_agg a
)
SELECT customer_id,
       DECIMAL(total_spend, 14, 2) AS total_spend,
       DECIMAL(flagged_spend, 14, 2) AS flagged_spend,
       coverage AS flagged_coverage_pct,
       vegan_p AS vegan_pct,
       vegetarian_p AS vegetarian_pct,
       gf_p AS gluten_free_pct,
       ss_p AS single_serve_pct,
       allergen_p AS allergen_pct,
       prepared_p AS prepared_meals_pct,
       butcher_p AS butcher_pct,
       seafood_p AS seafood_pct,
       desserts_p AS desserts_pct,
       appetizers_p AS appetizers_pct,
       vegetables_p AS vegetables_pct,
       categories_bought, distinct_plus,
       DECIMAL(1.0 * calories_units / NULLIF(nutrition_units, 0), 8, 1) AS avg_calories_per_serving,
       DECIMAL(1.0 * sodium_units / NULLIF(nutrition_units, 0), 8, 1) AS avg_sodium_mg_per_serving,
       DECIMAL(1.0 * sugars_units / NULLIF(nutrition_units, 0), 8, 1) AS avg_sugars_g_per_serving,
       DECIMAL(1.0 * protein_units / NULLIF(nutrition_units, 0), 8, 1) AS avg_protein_g_per_serving,
       DECIMAL(1.0 * serving_units / NULLIF(nutrition_units, 0), 8, 1) AS avg_serving_g,
       CASE WHEN coverage IS NULL OR coverage < 20 THEN 'Unclassified'
            WHEN vegan_p >= 30 THEN 'Plant-based'
            WHEN vegetarian_p >= 40 THEN 'Plant-forward'
            WHEN gf_p >= 25 THEN 'Gluten-aware'
            WHEN ss_p >= 40 THEN 'Convenience'
            WHEN allergen_p <= 15 THEN 'Allergen-cautious'
            ELSE 'Mainstream' END AS diet_profile,
       CASE WHEN categorised_spend <= 0 THEN 'Unclassified'
            WHEN prepared_p >= 45 THEN 'Ready meals'
            WHEN butcher_p + seafood_p >= 40 THEN 'Home cook'
            WHEN desserts_p + appetizers_p >= 40 THEN 'Entertainer'
            ELSE 'Balanced' END AS basket_profile
FROM s;

DROP TABLE IF EXISTS diet_agg;

CREATE STATISTICS FOR customer_diet_profile;
