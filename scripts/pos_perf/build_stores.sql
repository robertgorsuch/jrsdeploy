-- build_stores.sql -- DROP-and-rebuild of the stores dimension (330 rows,
-- one per storenumber) and the franchisees table (about 200 owners).
-- Real facts from pos_sales_detail: store name, province, region, open date
-- (first sale in dataset), lifetime sales, margin, transactions, customers,
-- royalty base sales and subsidies. Fictitious but DETERMINISTIC via
-- HASH(storenumber + salt): street address, phone (fictional 555-01XX),
-- store format, square footage, staff count, lat and long (province anchor
-- plus jitter -- indicative only, not real geocodes), franchisee assignment.
-- postal_fsa is the modal customer FSA seen at the store, so it is plausible
-- local geography. Franchisees aggregate their assigned stores -- owner
-- identity is hash-generated, royalty economics use the REAL royaltysales
-- and subsidy columns.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS st_seed_first;

CREATE TABLE st_seed_first AS
SELECT 0 AS id, 'Liam' AS name UNION ALL SELECT 1, 'Olivia' UNION ALL SELECT 2, 'Noah'
UNION ALL SELECT 3, 'Emma' UNION ALL SELECT 4, 'Jackson' UNION ALL SELECT 5, 'Ava'
UNION ALL SELECT 6, 'Lucas' UNION ALL SELECT 7, 'Sophia' UNION ALL SELECT 8, 'Ethan'
UNION ALL SELECT 9, 'Charlotte' UNION ALL SELECT 10, 'Benjamin' UNION ALL SELECT 11, 'Amelia'
UNION ALL SELECT 12, 'William' UNION ALL SELECT 13, 'Mia' UNION ALL SELECT 14, 'James'
UNION ALL SELECT 15, 'Harper' UNION ALL SELECT 16, 'Alexander' UNION ALL SELECT 17, 'Evelyn'
UNION ALL SELECT 18, 'Michael' UNION ALL SELECT 19, 'Abigail' UNION ALL SELECT 20, 'Daniel'
UNION ALL SELECT 21, 'Emily' UNION ALL SELECT 22, 'Matthew' UNION ALL SELECT 23, 'Ella'
UNION ALL SELECT 24, 'Samuel' UNION ALL SELECT 25, 'Grace' UNION ALL SELECT 26, 'David'
UNION ALL SELECT 27, 'Chloe' UNION ALL SELECT 28, 'Joseph' UNION ALL SELECT 29, 'Camila'
UNION ALL SELECT 30, 'Carter' UNION ALL SELECT 31, 'Aria' UNION ALL SELECT 32, 'Owen'
UNION ALL SELECT 33, 'Scarlett' UNION ALL SELECT 34, 'Wyatt' UNION ALL SELECT 35, 'Lily'
UNION ALL SELECT 36, 'John' UNION ALL SELECT 37, 'Hannah' UNION ALL SELECT 38, 'Jack'
UNION ALL SELECT 39, 'Nora' UNION ALL SELECT 40, 'Luke' UNION ALL SELECT 41, 'Zoey'
UNION ALL SELECT 42, 'Ryan' UNION ALL SELECT 43, 'Mila' UNION ALL SELECT 44, 'Nathan'
UNION ALL SELECT 45, 'Aubrey' UNION ALL SELECT 46, 'Isaac' UNION ALL SELECT 47, 'Violet'
UNION ALL SELECT 48, 'Gabriel' UNION ALL SELECT 49, 'Stella' UNION ALL SELECT 50, 'Anthony'
UNION ALL SELECT 51, 'Claire' UNION ALL SELECT 52, 'Dylan' UNION ALL SELECT 53, 'Lucy'
UNION ALL SELECT 54, 'Leo' UNION ALL SELECT 55, 'Audrey' UNION ALL SELECT 56, 'Marcus'
UNION ALL SELECT 57, 'Sadie' UNION ALL SELECT 58, 'Simon' UNION ALL SELECT 59, 'Naomi';

DROP TABLE IF EXISTS st_seed_last;

CREATE TABLE st_seed_last AS
SELECT 0 AS id, 'Smith' AS name UNION ALL SELECT 1, 'Brown' UNION ALL SELECT 2, 'Tremblay'
UNION ALL SELECT 3, 'Martin' UNION ALL SELECT 4, 'Roy' UNION ALL SELECT 5, 'Wilson'
UNION ALL SELECT 6, 'MacDonald' UNION ALL SELECT 7, 'Gagnon' UNION ALL SELECT 8, 'Johnson'
UNION ALL SELECT 9, 'Taylor' UNION ALL SELECT 10, 'Campbell' UNION ALL SELECT 11, 'Anderson'
UNION ALL SELECT 12, 'Leblanc' UNION ALL SELECT 13, 'Cote' UNION ALL SELECT 14, 'Williams'
UNION ALL SELECT 15, 'Miller' UNION ALL SELECT 16, 'Thompson' UNION ALL SELECT 17, 'Gauthier'
UNION ALL SELECT 18, 'White' UNION ALL SELECT 19, 'Morin' UNION ALL SELECT 20, 'Lavoie'
UNION ALL SELECT 21, 'Fortin' UNION ALL SELECT 22, 'Clark' UNION ALL SELECT 23, 'Gagne'
UNION ALL SELECT 24, 'Ouellet' UNION ALL SELECT 25, 'Pelletier' UNION ALL SELECT 26, 'Moore'
UNION ALL SELECT 27, 'Belanger' UNION ALL SELECT 28, 'Levesque' UNION ALL SELECT 29, 'Walker'
UNION ALL SELECT 30, 'Bergeron' UNION ALL SELECT 31, 'Young' UNION ALL SELECT 32, 'Leclerc'
UNION ALL SELECT 33, 'Robinson' UNION ALL SELECT 34, 'Simard' UNION ALL SELECT 35, 'Wright'
UNION ALL SELECT 36, 'Boucher' UNION ALL SELECT 37, 'Mitchell' UNION ALL SELECT 38, 'Caron'
UNION ALL SELECT 39, 'Stewart' UNION ALL SELECT 40, 'Beaulieu' UNION ALL SELECT 41, 'Scott'
UNION ALL SELECT 42, 'Cloutier' UNION ALL SELECT 43, 'Reid' UNION ALL SELECT 44, 'Dube'
UNION ALL SELECT 45, 'King' UNION ALL SELECT 46, 'Poirier' UNION ALL SELECT 47, 'Fraser'
UNION ALL SELECT 48, 'Nadeau' UNION ALL SELECT 49, 'Ross' UNION ALL SELECT 50, 'Girard'
UNION ALL SELECT 51, 'Murray' UNION ALL SELECT 52, 'Lapointe' UNION ALL SELECT 53, 'Kelly'
UNION ALL SELECT 54, 'Grant' UNION ALL SELECT 55, 'Fournier' UNION ALL SELECT 56, 'Bennett'
UNION ALL SELECT 57, 'Marchand' UNION ALL SELECT 58, 'Watson' UNION ALL SELECT 59, 'Chan';

DROP TABLE IF EXISTS st_seed_street;

CREATE TABLE st_seed_street AS
SELECT 0 AS id, 'Maple' AS name UNION ALL SELECT 1, 'King' UNION ALL SELECT 2, 'Queen'
UNION ALL SELECT 3, 'Main' UNION ALL SELECT 4, 'Church' UNION ALL SELECT 5, 'Mill'
UNION ALL SELECT 6, 'Park' UNION ALL SELECT 7, 'Victoria' UNION ALL SELECT 8, 'Elm'
UNION ALL SELECT 9, 'Pine' UNION ALL SELECT 10, 'Cedar' UNION ALL SELECT 11, 'Oak'
UNION ALL SELECT 12, 'Birch' UNION ALL SELECT 13, 'Wellington' UNION ALL SELECT 14, 'Albert'
UNION ALL SELECT 15, 'York' UNION ALL SELECT 16, 'Dundas' UNION ALL SELECT 17, 'Bloor'
UNION ALL SELECT 18, 'Lakeshore' UNION ALL SELECT 19, 'Riverside' UNION ALL SELECT 20, 'Hillcrest'
UNION ALL SELECT 21, 'Fairview' UNION ALL SELECT 22, 'Sunset' UNION ALL SELECT 23, 'Meadow'
UNION ALL SELECT 24, 'Orchard' UNION ALL SELECT 25, 'Willow' UNION ALL SELECT 26, 'Aspen'
UNION ALL SELECT 27, 'Chestnut' UNION ALL SELECT 28, 'Spruce' UNION ALL SELECT 29, 'Bayview'
UNION ALL SELECT 30, 'Highland' UNION ALL SELECT 31, 'Valley' UNION ALL SELECT 32, 'Forest'
UNION ALL SELECT 33, 'Spring' UNION ALL SELECT 34, 'Harbour' UNION ALL SELECT 35, 'Prairie'
UNION ALL SELECT 36, 'Rosewood' UNION ALL SELECT 37, 'Brookside' UNION ALL SELECT 38, 'Sherbrooke'
UNION ALL SELECT 39, 'Portage';

DROP TABLE IF EXISTS st_seed_stype;

CREATE TABLE st_seed_stype AS
SELECT 0 AS id, 'St' AS name UNION ALL SELECT 1, 'Ave' UNION ALL SELECT 2, 'Rd'
UNION ALL SELECT 3, 'Dr' UNION ALL SELECT 4, 'Cres' UNION ALL SELECT 5, 'Blvd'
UNION ALL SELECT 6, 'Lane' UNION ALL SELECT 7, 'Crt';

-- Real per-store aggregates

DROP TABLE IF EXISTS st_sales;

CREATE TABLE st_sales AS
SELECT storenumber,
       MAX(storename) AS storename,
       MAX(storeprovince) AS province,
       MAX(storeregion) AS region,
       SUM(sellingprice * quantity) AS total_sales,
       SUM(cost) AS cost_line,
       COUNT(DISTINCT transactionuniqueid) AS total_transactions,
       COUNT(DISTINCT customernumber) AS distinct_customers,
       MIN(DATE(saledate)) AS first_sale_date,
       MAX(DATE(saledate)) AS last_sale_date,
       SUM(COALESCE(royaltysales, 0)) AS royalty_base_sales,
       SUM(COALESCE(subsidy, 0)) AS total_subsidy
FROM pos_sales_detail
GROUP BY storenumber;

-- Modal customer FSA per store, used as the store postal FSA

DROP TABLE IF EXISTS st_fsa;

CREATE TABLE st_fsa AS
SELECT storenumber, fsa FROM (
  SELECT storenumber, TRIM(customerfsa) AS fsa,
         ROW_NUMBER() OVER (PARTITION BY storenumber ORDER BY COUNT(*) DESC, TRIM(customerfsa)) AS rk
  FROM pos_sales_detail
  WHERE COALESCE(customerfsa,'') <> ''
  GROUP BY storenumber, TRIM(customerfsa)
) t WHERE rk = 1;

DROP TABLE IF EXISTS stores;

CREATE TABLE stores AS
WITH c AS (
  SELECT s.*, f.fsa,
         ss.name AS street_name, st.name AS street_type,
         10 + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'no'), 9890)) AS street_no,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + 'fmt'), 4)) AS fmt_sel,
         1200 + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'sq'), 21)) * 100 AS square_feet,
         4 + ABS(MOD(HASH(VARCHAR(s.storenumber) + 'stf'), 9)) AS staff_count,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + 'ac'), 3)) AS ac_sel,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + 'ph'), 100)) AS ph_n,
         (ABS(MOD(HASH(VARCHAR(s.storenumber) + 'la'), 3000)) - 1500) / 1000.0 AS lat_j,
         (ABS(MOD(HASH(VARCHAR(s.storenumber) + 'lo'), 4000)) - 2000) / 1000.0 AS lon_j,
         ABS(MOD(HASH(VARCHAR(s.storenumber) + 'fr'), 210)) AS franchisee_id
  FROM st_sales s
  LEFT JOIN st_fsa f ON f.storenumber = s.storenumber
  JOIN st_seed_street ss ON ss.id = ABS(MOD(HASH(VARCHAR(s.storenumber) + 'st'), 40))
  JOIN st_seed_stype  st ON st.id = ABS(MOD(HASH(VARCHAR(s.storenumber) + 'ty'), 8))
)
SELECT storenumber, storename,
       CASE WHEN LOCATE(storename, '-') <= LENGTH(storename)
            THEN TRIM(LEFT(storename, LOCATE(storename, '-') - 1))
            ELSE TRIM(storename) END AS city,
       province, region,
       VARCHAR(street_no) + ' ' + street_name + ' ' + street_type AS street_address,
       fsa AS postal_fsa,
       '(' +
       CASE province
            WHEN 'ON' THEN CASE ac_sel WHEN 0 THEN '416' WHEN 1 THEN '613' ELSE '705' END
            WHEN 'QC' THEN CASE ac_sel WHEN 0 THEN '514' WHEN 1 THEN '418' ELSE '450' END
            WHEN 'AB' THEN CASE ac_sel WHEN 0 THEN '403' WHEN 1 THEN '780' ELSE '587' END
            WHEN 'BC' THEN CASE ac_sel WHEN 0 THEN '604' WHEN 1 THEN '250' ELSE '778' END
            WHEN 'MB' THEN '204' WHEN 'SK' THEN '306' WHEN 'NS' THEN '902'
            WHEN 'NB' THEN '506' WHEN 'NL' THEN '709' ELSE '867' END +
       ') 555-01' + RIGHT('0' + VARCHAR(MOD(ph_n, 100)), 2) AS phone,
       CASE fmt_sel WHEN 0 THEN 'Standalone' WHEN 1 THEN 'Strip Plaza'
            WHEN 2 THEN 'Shopping Mall' ELSE 'Urban Storefront' END AS store_format,
       square_feet, staff_count,
       DECIMAL(CASE province WHEN 'ON' THEN 43.8 WHEN 'QC' THEN 45.6 WHEN 'BC' THEN 49.3
            WHEN 'AB' THEN 52.0 WHEN 'SK' THEN 52.0 WHEN 'MB' THEN 49.9 WHEN 'NS' THEN 44.7
            WHEN 'NB' THEN 45.9 WHEN 'NL' THEN 47.6 ELSE 60.7 END + lat_j, 8, 4) AS latitude,
       DECIMAL(CASE province WHEN 'ON' THEN -79.5 WHEN 'QC' THEN -73.7 WHEN 'BC' THEN -122.8
            WHEN 'AB' THEN -113.9 WHEN 'SK' THEN -106.5 WHEN 'MB' THEN -97.2 WHEN 'NS' THEN -63.6
            WHEN 'NB' THEN -66.5 WHEN 'NL' THEN -52.8 ELSE -135.1 END + lon_j, 9, 4) AS longitude,
       franchisee_id,
       first_sale_date AS open_date, last_sale_date,
       total_transactions, distinct_customers,
       DECIMAL(total_sales, 14, 2) AS total_sales,
       DECIMAL(total_sales - cost_line, 14, 2) AS gross_margin,
       DECIMAL(100.0 * (total_sales - cost_line) / NULLIF(total_sales, 0), 8, 2) AS margin_pct,
       DECIMAL(total_sales * 7.0 / 731, 12, 2) AS avg_weekly_sales,
       DECIMAL(total_sales / square_feet, 10, 2) AS sales_per_sqft,
       DECIMAL(royalty_base_sales, 14, 2) AS royalty_base_sales,
       DECIMAL(total_subsidy, 12, 2) AS total_subsidy
FROM c;

DROP TABLE IF EXISTS franchisees;

CREATE TABLE franchisees AS
WITH f AS (
  SELECT st.franchisee_id,
         COUNT(*) AS stores_owned,
         MAX(st.province) AS province,
         MIN(st.open_date) AS first_store_open,
         SUM(st.total_sales) AS total_sales,
         SUM(st.royalty_base_sales) AS royalty_base_sales,
         SUM(st.total_subsidy) AS total_subsidy
  FROM stores st
  GROUP BY st.franchisee_id
), n AS (
  SELECT f.*, sf.name AS first_name, sl.name AS last_name,
         4 + ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'rr'), 3)) AS royalty_rate_pct,
         1 + ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'mf'), 2)) AS marketing_fee_pct,
         ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'd'), 3)) AS dom_sel,
         ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'ac'), 3)) AS ac_sel,
         ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'ph'), 100)) AS ph_n
  FROM f
  JOIN st_seed_first sf ON sf.id = ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'ofn'), 60))
  JOIN st_seed_last  sl ON sl.id = ABS(MOD(HASH(VARCHAR(f.franchisee_id) + 'oln'), 60))
)
SELECT franchisee_id, first_name, last_name,
       first_name + ' ' + last_name AS owner_name,
       LOWERCASE(first_name) + '.' + LOWERCASE(last_name) + VARCHAR(franchisee_id) + '@' +
         CASE dom_sel WHEN 0 THEN 'gmail.com' WHEN 1 THEN 'outlook.com' ELSE 'yahoo.ca' END AS email,
       '(' +
       CASE province
            WHEN 'ON' THEN CASE ac_sel WHEN 0 THEN '416' WHEN 1 THEN '613' ELSE '705' END
            WHEN 'QC' THEN CASE ac_sel WHEN 0 THEN '514' WHEN 1 THEN '418' ELSE '450' END
            WHEN 'AB' THEN CASE ac_sel WHEN 0 THEN '403' WHEN 1 THEN '780' ELSE '587' END
            WHEN 'BC' THEN CASE ac_sel WHEN 0 THEN '604' WHEN 1 THEN '250' ELSE '778' END
            WHEN 'MB' THEN '204' WHEN 'SK' THEN '306' WHEN 'NS' THEN '902'
            WHEN 'NB' THEN '506' WHEN 'NL' THEN '709' ELSE '867' END +
       ') 555-01' + RIGHT('0' + VARCHAR(MOD(ph_n, 100)), 2) AS phone,
       stores_owned, province AS primary_province, first_store_open,
       royalty_rate_pct, marketing_fee_pct,
       DECIMAL(total_sales, 14, 2) AS total_sales,
       DECIMAL(royalty_base_sales, 14, 2) AS royalty_base_sales,
       DECIMAL(royalty_base_sales * royalty_rate_pct / 100.0, 14, 2) AS est_royalty_paid,
       DECIMAL(royalty_base_sales * marketing_fee_pct / 100.0, 14, 2) AS est_marketing_fee,
       DECIMAL(total_subsidy, 12, 2) AS total_subsidy
FROM n;

DROP TABLE IF EXISTS st_sales;

DROP TABLE IF EXISTS st_fsa;

DROP TABLE IF EXISTS st_seed_first;

DROP TABLE IF EXISTS st_seed_last;

DROP TABLE IF EXISTS st_seed_street;

DROP TABLE IF EXISTS st_seed_stype;
