-- build_customer_demographics.sql -- DROP-and-rebuild of customer_demographics,
-- one row per customer (3.18M), 1:1 with customers on customer_id.
-- Kept separate from customers: it models a different source system (loyalty
-- signup / survey), carries consent semantics, and customers is rebuilt on
-- its own by build_customers.sql.
-- FICTITIOUS but DETERMINISTIC: every modeled attribute derives from
-- HASH(customer_id + salt), so rebuilds always give the same person the same
-- demographics. Modeled values are ANCHORED to real data --
--   income band around the REAL-structured fsa_demographics.median_income of
--   the customer FSA (province average when the customer has no FSA),
--   household size around fsa avg_household_size,
--   age skewed younger for single-serve / snack buyers and older for large
--   baskets with little promo dependence,
--   language FR-weighted for Quebec FSAs (G, H, J) and eastern Ontario (K),
--   dwelling mix by the FSA urban flag.
-- REAL: acquisition_channel (Online if the first basket was an ecommerce
-- order, Campaign if the first basket carried a promotion), signup_date
-- (= first purchase), marketing_consent (= email opt-in).
-- No column names a vendor, data panel or third-party source.
-- Requires: customers, fsa_demographics, pos_sales_txn.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

-- Province-level income / household fallback for customers without an FSA

DROP TABLE IF EXISTS dem_prov;

CREATE TABLE dem_prov AS
SELECT province,
       INT4(AVG(median_income)) AS median_income,
       DECIMAL(AVG(avg_household_size), 4, 1) AS avg_household_size,
       CASE WHEN SUM(CASE WHEN urban_flag = 'Y' THEN 1 ELSE 0 END) * 2 >= COUNT(*) THEN 'Y' ELSE 'N' END AS urban_flag
FROM fsa_demographics
WHERE valid_fsa_flag = 'Y'
GROUP BY province;

-- First basket per customer (REAL) for acquisition channel

DROP TABLE IF EXISTS dem_first;

CREATE TABLE dem_first AS
SELECT customer_id, sale_date AS first_sale_date, promo_flag AS first_promo_flag,
       ecommerce_flag AS first_ecommerce_flag, storenumber AS first_store_number
FROM (
  SELECT customer_id, sale_date, promo_flag, ecommerce_flag, storenumber,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY jdn, sale_hour, transactionuniqueid) AS rk
  FROM pos_sales_txn
) t WHERE rk = 1;

DROP TABLE IF EXISTS customer_demographics;

CREATE TABLE customer_demographics AS
WITH base AS (
  SELECT c.customer_id, c.province, c.email_opt_in, c.first_purchase_date,
         c.avg_basket, c.promo_sales_pct, c.favorite_category, c.total_transactions,
         LEFT(c.postal_code, 3) AS fsa,
         UPPERCASE(LEFT(c.postal_code, 1)) AS fsa1,
         COALESCE(f.median_income, p.median_income, 65000) AS anchor_income,
         COALESCE(f.avg_household_size, p.avg_household_size, 2.5) AS anchor_hh,
         COALESCE(f.urban_flag, p.urban_flag, 'Y') AS urban_flag,
         ABS(MOD(HASH(c.customer_id + 'age'), 100)) AS h_age,
         ABS(MOD(HASH(c.customer_id + 'gen'), 100)) AS h_gen,
         ABS(MOD(HASH(c.customer_id + 'inc'), 100)) AS h_inc,
         ABS(MOD(HASH(c.customer_id + 'hh'), 100))  AS h_hh,
         ABS(MOD(HASH(c.customer_id + 'dw'), 100))  AS h_dw,
         ABS(MOD(HASH(c.customer_id + 'tn'), 100))  AS h_tn,
         ABS(MOD(HASH(c.customer_id + 'lg'), 100))  AS h_lg,
         ABS(MOD(HASH(c.customer_id + 'em'), 100))  AS h_em,
         ABS(MOD(HASH(c.customer_id + 'ed'), 100))  AS h_ed,
         ABS(MOD(HASH(c.customer_id + 'aq'), 100))  AS h_aq,
         ABS(MOD(HASH(c.customer_id + 'cs'), 100))  AS h_cs,
         ABS(MOD(HASH(c.customer_id + 'ds'), 100))  AS h_ds,
         fs.first_promo_flag, fs.first_ecommerce_flag
  FROM customers c
  LEFT JOIN fsa_demographics f ON f.fsa = LEFT(c.postal_code, 3)
  LEFT JOIN dem_prov p ON p.province = c.province
  LEFT JOIN dem_first fs ON fs.customer_id = c.customer_id
), age AS (
  SELECT b.*,
         -- base age draw 18..84 on a population-shaped curve, then shifted by behaviour
         CASE WHEN h_age < 12 THEN 18 + MOD(h_age * 7, 7)
              WHEN h_age < 32 THEN 25 + MOD(h_age * 5, 10)
              WHEN h_age < 52 THEN 35 + MOD(h_age * 3, 10)
              WHEN h_age < 70 THEN 45 + MOD(h_age * 11, 10)
              WHEN h_age < 85 THEN 55 + MOD(h_age * 13, 10)
              ELSE 65 + MOD(h_age * 17, 20) END
         + CASE WHEN favorite_category = 'Single serve' THEN -6
                WHEN favorite_category IN ('Desserts', 'Appetizers') THEN -2
                WHEN avg_basket >= 60 AND promo_sales_pct < 20 THEN 6
                WHEN favorite_category = 'Butcher' THEN 3
                ELSE 0 END AS age_raw
  FROM base b
), attrs AS (
  SELECT a.*,
         2020 - LEAST(84, GREATEST(18, age_raw)) AS birth_year,
         LEAST(84, GREATEST(18, age_raw)) AS age_yrs,
         -- household income = anchor x 0.55..1.75 multiplier
         INT4(anchor_income * (55 + h_inc * 1.2) / 100.0) AS hh_income,
         -- household size around the FSA average, clamped 1..6
         LEAST(6, GREATEST(1, INT4(anchor_hh + (h_hh / 20) - 2 + 0.5))) AS hh_size
  FROM age a
), bands AS (
  SELECT t.*,
         CASE WHEN age_yrs < 25 THEN '18-24' WHEN age_yrs < 35 THEN '25-34'
              WHEN age_yrs < 45 THEN '35-44' WHEN age_yrs < 55 THEN '45-54'
              WHEN age_yrs < 65 THEN '55-64' ELSE '65+' END AS age_band,
         CASE WHEN hh_income < 40000 THEN 'Under 40K' WHEN hh_income < 60000 THEN '40K-60K'
              WHEN hh_income < 80000 THEN '60K-80K' WHEN hh_income < 100000 THEN '80K-100K'
              WHEN hh_income < 150000 THEN '100K-150K' ELSE '150K+' END AS household_income_band,
         CASE WHEN age_yrs >= 65 THEN 'Retiree'
              WHEN age_yrs >= 50 AND hh_size <= 2 THEN 'Empty Nester'
              WHEN age_yrs < 35 AND hh_size <= 2 THEN 'Young Single'
              WHEN age_yrs < 40 AND hh_size >= 3 THEN 'Young Family'
              WHEN hh_size >= 3 THEN 'Established Family'
              ELSE 'Mid-life Couple' END AS life_stage,
         CASE WHEN urban_flag = 'Y' THEN
                CASE WHEN h_dw < 35 THEN 'Apartment' WHEN h_dw < 60 THEN 'Condo'
                     WHEN h_dw < 90 THEN 'House' ELSE 'Townhouse' END
              ELSE
                CASE WHEN h_dw < 75 THEN 'House' WHEN h_dw < 85 THEN 'Townhouse'
                     WHEN h_dw < 95 THEN 'Apartment' ELSE 'Condo' END END AS dwelling_type
  FROM attrs t
)
SELECT customer_id,
       birth_year,
       age_band,
       CASE WHEN h_gen < 49 THEN 'Female' WHEN h_gen < 96 THEN 'Male'
            WHEN h_gen < 98 THEN 'Non-binary' ELSE 'Undisclosed' END AS gender,
       hh_size AS household_size,
       household_income_band,
       life_stage,
       CASE WHEN life_stage IN ('Young Family', 'Established Family') THEN 'Y' ELSE 'N' END AS children_flag,
       dwelling_type,
       CASE WHEN dwelling_type = 'House' AND h_tn < 82 THEN 'Own'
            WHEN dwelling_type = 'Condo' AND h_tn < 60 THEN 'Own'
            WHEN dwelling_type = 'Townhouse' AND h_tn < 65 THEN 'Own'
            WHEN dwelling_type = 'Apartment' AND h_tn < 12 THEN 'Own'
            ELSE 'Rent' END AS tenure_type,
       CASE WHEN fsa1 IN ('G', 'H', 'J') AND h_lg < 85 THEN 'FR'
            WHEN fsa1 = 'K' AND h_lg < 22 THEN 'FR'
            WHEN fsa1 = 'E' AND h_lg < 30 THEN 'FR'
            WHEN fsa1 IS NULL AND province = 'QC' AND h_lg < 80 THEN 'FR'
            WHEN h_lg < 3 THEN 'FR'
            ELSE 'EN' END AS language_pref,
       CASE WHEN age_band = '18-24' THEN
              CASE WHEN h_em < 50 THEN 'Student' WHEN h_em < 94 THEN 'Employed' ELSE 'Other' END
            WHEN age_band = '65+' THEN
              CASE WHEN h_em < 85 THEN 'Retired' WHEN h_em < 95 THEN 'Employed' ELSE 'Other' END
            WHEN age_band = '55-64' THEN
              CASE WHEN h_em < 68 THEN 'Employed' WHEN h_em < 80 THEN 'Self-employed'
                   WHEN h_em < 92 THEN 'Retired' ELSE 'Other' END
            ELSE
              CASE WHEN h_em < 78 THEN 'Employed' WHEN h_em < 89 THEN 'Self-employed'
                   WHEN h_em < 93 THEN 'Student' ELSE 'Other' END END AS employment_status,
       CASE WHEN household_income_band IN ('150K+', '100K-150K') THEN
              CASE WHEN h_ed < 8 THEN 'High school' WHEN h_ed < 35 THEN 'College'
                   WHEN h_ed < 75 THEN 'Bachelor' ELSE 'Graduate' END
            WHEN household_income_band IN ('80K-100K', '60K-80K') THEN
              CASE WHEN h_ed < 22 THEN 'High school' WHEN h_ed < 55 THEN 'College'
                   WHEN h_ed < 88 THEN 'Bachelor' ELSE 'Graduate' END
            ELSE
              CASE WHEN h_ed < 42 THEN 'High school' WHEN h_ed < 75 THEN 'College'
                   WHEN h_ed < 95 THEN 'Bachelor' ELSE 'Graduate' END END AS education_level,
       CASE WHEN first_ecommerce_flag = 'Y' THEN 'Online'
            WHEN first_promo_flag = 'Y' THEN 'Campaign'
            WHEN h_aq < 80 THEN 'In-store' ELSE 'Referral' END AS acquisition_channel,
       first_purchase_date AS signup_date,
       CASE WHEN email_opt_in = 'Y' AND h_cs < 70 THEN 'Y'
            WHEN email_opt_in <> 'Y' AND h_cs < 25 THEN 'Y'
            ELSE 'N' END AS demographics_consent,
       email_opt_in AS marketing_consent,
       CASE WHEN (email_opt_in = 'Y' AND h_cs < 70) OR (email_opt_in <> 'Y' AND h_cs < 25) THEN
              CASE WHEN h_ds < 75 THEN 'Signup' ELSE 'Survey' END
            ELSE 'Modeled' END AS data_source
FROM bands;

DROP TABLE IF EXISTS dem_first;

DROP TABLE IF EXISTS dem_prov;

CREATE STATISTICS FOR customer_demographics;
