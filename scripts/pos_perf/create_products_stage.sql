-- create_products_stage.sql -- recreate the transient staging table for the
-- products dimension rebuild. Column order must match mm_products.csv exactly.
-- All VARCHAR so empty strings never hit numeric columns at load time (casts
-- happen in build_products.sql). Full rebuild flow:
--   1. python scripts/pos_perf/scrape_mm_products.py   (refresh mm_products.csv)
--   2. sql.ps1 run-file this file
--   3. sql.ps1 load-csv -Table mm_products_stage -CsvFile scripts/pos_perf/mm_products.csv
--   4. sql.ps1 run-file scripts/pos_perf/build_products.sql
--   5. sql.ps1 run-file scripts/pos_perf/verify_products.sql
--   6. optionally drop mm_products_stage again
-- NOTE: run-file splits on EVERY semicolon, even in comments -- never use one here.
DROP TABLE IF EXISTS mm_products_stage;

CREATE TABLE mm_products_stage (
  plu VARCHAR(20), product_name VARCHAR(150), web_description VARCHAR(1500),
  category VARCHAR(60), sub_category VARCHAR(80),
  single_serve VARCHAR(2), vegetarian VARCHAR(2), vegan VARCHAR(2), gluten_free VARCHAR(2),
  package_size VARCHAR(50),
  size_g VARCHAR(15), price_cad VARCHAR(15), in_stock VARCHAR(2),
  ingredients VARCHAR(4000), allergens VARCHAR(300), serving_size VARCHAR(80),
  serving_g VARCHAR(15), calories VARCHAR(10), fat_g VARCHAR(15),
  sat_fat_g VARCHAR(15), carbs_g VARCHAR(15), fibre_g VARCHAR(15),
  sugars_g VARCHAR(15), protein_g VARCHAR(15), cholesterol_mg VARCHAR(15),
  sodium_mg VARCHAR(15), potassium_mg VARCHAR(15)
);
