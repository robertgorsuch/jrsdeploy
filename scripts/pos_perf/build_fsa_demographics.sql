-- build_fsa_demographics.sql -- DROP-and-rebuild of fsa_demographics.
-- One row per distinct non-blank customer FSA in pos_sales_detail (~4,015).
-- REAL: shopper count, sales into the FSA, distinct stores shopped.
-- Structurally real: province decodes the REAL first letter of the FSA
-- (Canada Post scheme, uppercased first -- about a third of raw FSAs are
-- lowercase data entry) and urban_flag uses the REAL second-character-zero =
-- rural convention. valid_fsa_flag = N marks junk codes (digits, symbols,
-- invalid letters) whose province stays ZZ. FICTITIOUS but DETERMINISTIC: population (urban FSAs
-- 8K to 45K, rural 1.5K to 9.5K), households at 2.5 per, median income,
-- average household size. penetration_pct = real shoppers over fictitious
-- households, so treat it as indicative -- FSAs next to a store can exceed
-- plausible penetration.
-- Demographic enrichment (2026-08-23): median_age, pct_families_with_children,
-- pct_seniors, pct_french_speaking, pct_owner_occupied, unemployment_rate_pct
-- and pct_recent_movers are FICTITIOUS but DETERMINISTIC from HASH(fsa+salt),
-- anchored to the REAL province letter (French share) and the REAL urban flag
-- (ownership, seniors, movers). REAL: competitor_count_5km from
-- competitor_locations, stores_in_fsa and home_store_number from stores and
-- the fact. Swap the modeled columns for Statistics Canada 2021 Census
-- Profile values at FSA level when that load is done -- same column names.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS fsa_agg;

CREATE TABLE fsa_agg AS
SELECT TRIM(customerfsa) AS fsa,
       COUNT(DISTINCT customernumber) AS shoppers,
       COUNT(DISTINCT storenumber) AS stores_shopped,
       SUM(sellingprice * quantity) AS fsa_sales
FROM pos_sales_detail
WHERE COALESCE(customerfsa,'') <> ''
GROUP BY TRIM(customerfsa);

-- REAL context: modal store of the FSA shoppers, stores located in the FSA,
-- competitor banners within 5 km of a store whose trade area is the FSA

DROP TABLE IF EXISTS fsa_home_store;

CREATE TABLE fsa_home_store AS
SELECT fsa, storenumber AS home_store_number FROM (
  SELECT TRIM(customerfsa) AS fsa, storenumber,
         ROW_NUMBER() OVER (PARTITION BY TRIM(customerfsa) ORDER BY COUNT(*) DESC, storenumber) AS rk
  FROM pos_sales_detail
  WHERE COALESCE(customerfsa,'') <> ''
  GROUP BY TRIM(customerfsa), storenumber
) t WHERE rk = 1;

DROP TABLE IF EXISTS fsa_ctx;

CREATE TABLE fsa_ctx AS
SELECT a.fsa,
       (SELECT COUNT(*) FROM stores s WHERE UPPERCASE(s.postal_fsa) = UPPERCASE(a.fsa)) AS stores_in_fsa,
       (SELECT COUNT(*) FROM competitor_locations k
         WHERE UPPERCASE(k.trade_area_fsa) = UPPERCASE(a.fsa) AND k.distance_km <= 5) AS competitor_count_5km
FROM fsa_agg a;

DROP TABLE IF EXISTS fsa_demographics;

CREATE TABLE fsa_demographics AS
WITH c AS (
  SELECT a.*,
         UPPERCASE(LEFT(a.fsa, 1)) AS u1,
         CASE WHEN CHAREXTRACT(a.fsa, 2) = '0' THEN 'N' ELSE 'Y' END AS urban_flag,
         CASE WHEN LENGTH(TRIM(a.fsa)) = 3
                   AND UPPERCASE(CHAREXTRACT(a.fsa, 1)) IN ('A','B','C','E','G','H','J','K','L','M','N','P','R','S','T','V','X','Y')
                   AND CHAREXTRACT(a.fsa, 2) BETWEEN '0' AND '9'
                   AND UPPERCASE(CHAREXTRACT(a.fsa, 3)) BETWEEN 'A' AND 'Z'
              THEN 'Y' ELSE 'N' END AS valid_fsa_flag,
         ABS(MOD(HASH(a.fsa + 'pop'), 38)) AS pop_h,
         ABS(MOD(HASH(a.fsa + 'inc'), 80)) AS inc_h,
         ABS(MOD(HASH(a.fsa + 'hh'), 12)) AS hh_h,
         ABS(MOD(HASH(a.fsa + 'age'), 16)) AS age_h,
         ABS(MOD(HASH(a.fsa + 'fam'), 20)) AS fam_h,
         ABS(MOD(HASH(a.fsa + 'sen'), 12)) AS sen_h,
         ABS(MOD(HASH(a.fsa + 'fr'), 15))  AS fr_h,
         ABS(MOD(HASH(a.fsa + 'own'), 25)) AS own_h,
         ABS(MOD(HASH(a.fsa + 'une'), 60)) AS une_h,
         ABS(MOD(HASH(a.fsa + 'mov'), 10)) AS mov_h,
         x.stores_in_fsa, x.competitor_count_5km, h.home_store_number
  FROM fsa_agg a
  LEFT JOIN fsa_ctx x ON x.fsa = a.fsa
  LEFT JOIN fsa_home_store h ON h.fsa = a.fsa
)
SELECT fsa, valid_fsa_flag,
       CASE u1
            WHEN 'A' THEN 'NL' WHEN 'B' THEN 'NS' WHEN 'C' THEN 'PE' WHEN 'E' THEN 'NB'
            WHEN 'G' THEN 'QC' WHEN 'H' THEN 'QC' WHEN 'J' THEN 'QC'
            WHEN 'K' THEN 'ON' WHEN 'L' THEN 'ON' WHEN 'M' THEN 'ON'
            WHEN 'N' THEN 'ON' WHEN 'P' THEN 'ON'
            WHEN 'R' THEN 'MB' WHEN 'S' THEN 'SK' WHEN 'T' THEN 'AB' WHEN 'V' THEN 'BC'
            WHEN 'X' THEN 'NT' WHEN 'Y' THEN 'YT' ELSE 'ZZ' END AS province,
       urban_flag,
       CASE WHEN urban_flag = 'Y' THEN 8000 + pop_h * 1000
            ELSE 1500 + pop_h * 210 END AS population,
       CASE WHEN urban_flag = 'Y' THEN INT4((8000 + pop_h * 1000) * 0.4)
            ELSE INT4((1500 + pop_h * 210) * 0.4) END AS households,
       46000 + inc_h * 1000 AS median_income,
       DECIMAL(2.0 + hh_h / 10.0, 4, 1) AS avg_household_size,
       shoppers, stores_shopped,
       DECIMAL(fsa_sales, 14, 2) AS fsa_sales,
       DECIMAL(fsa_sales / NULLIF(shoppers, 0), 10, 2) AS sales_per_shopper,
       DECIMAL(100.0 * shoppers / (CASE WHEN urban_flag = 'Y'
              THEN INT4((8000 + pop_h * 1000) * 0.4)
              ELSE INT4((1500 + pop_h * 210) * 0.4) END), 8, 2) AS penetration_pct,
       DECIMAL(CASE WHEN urban_flag = 'Y' THEN 34.0 ELSE 40.0 END + age_h * 0.6, 4, 1) AS median_age,
       DECIMAL(CASE WHEN urban_flag = 'Y' THEN 22.0 ELSE 26.0 END + fam_h * 0.8, 5, 1) AS pct_families_with_children,
       DECIMAL(CASE WHEN urban_flag = 'Y' THEN 13.0 ELSE 18.0 END + sen_h * 0.9, 5, 1) AS pct_seniors,
       DECIMAL(CASE u1 WHEN 'G' THEN 88.0 WHEN 'H' THEN 62.0 WHEN 'J' THEN 84.0
                       WHEN 'K' THEN 14.0 WHEN 'E' THEN 28.0 ELSE 1.5 END + fr_h * 0.5, 5, 1) AS pct_french_speaking,
       DECIMAL(CASE WHEN urban_flag = 'Y' THEN 52.0 ELSE 74.0 END + own_h * 0.7, 5, 1) AS pct_owner_occupied,
       DECIMAL(4.5 + une_h * 0.1, 4, 1) AS unemployment_rate_pct,
       DECIMAL(CASE WHEN urban_flag = 'Y' THEN 12.0 ELSE 7.0 END + mov_h * 0.6, 4, 1) AS pct_recent_movers,
       COALESCE(stores_in_fsa, 0) AS stores_in_fsa,
       COALESCE(competitor_count_5km, 0) AS competitor_count_5km,
       home_store_number
FROM c;

DROP TABLE IF EXISTS fsa_agg;

DROP TABLE IF EXISTS fsa_ctx;

DROP TABLE IF EXISTS fsa_home_store;
