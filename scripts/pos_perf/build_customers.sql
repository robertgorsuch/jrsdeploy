-- build_customers.sql -- DROP-and-rebuild of the fictitious customers dimension.
-- One row per distinct customernumber in pos_sales_detail (3.18M customers).
-- Identity (name, address, email, phone) is FICTITIOUS but DETERMINISTIC --
-- every attribute derives from HASH(customer_id + salt) against small seed
-- lookup tables, so rebuilds always produce the same person for the same id.
-- Geography is anchored in the real data: city and province come from the
-- customer's modal (home) store, postal code = the customer's modal FSA plus
-- a generated LDU. Phone numbers use the reserved fictional 555-01XX range.
-- KPIs follow the settled margin basis from build_dash_aggregates.sql --
-- sellingprice is PER-UNIT, sales = SUM(sellingprice*quantity), cost is a
-- LINE total, gross margin = sales minus SUM(cost).
-- RFM scores are NTILE(5) quintiles, loyalty tier is a monetary 20-tile.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.

DROP TABLE IF EXISTS cust_seed_first;

CREATE TABLE cust_seed_first AS
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

DROP TABLE IF EXISTS cust_seed_last;

CREATE TABLE cust_seed_last AS
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

DROP TABLE IF EXISTS cust_seed_street;

CREATE TABLE cust_seed_street AS
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

DROP TABLE IF EXISTS cust_seed_stype;

CREATE TABLE cust_seed_stype AS
SELECT 0 AS id, 'St' AS name UNION ALL SELECT 1, 'Ave' UNION ALL SELECT 2, 'Rd'
UNION ALL SELECT 3, 'Dr' UNION ALL SELECT 4, 'Cres' UNION ALL SELECT 5, 'Blvd'
UNION ALL SELECT 6, 'Lane' UNION ALL SELECT 7, 'Crt';

-- Per-customer lifetime KPIs from the 63.6M-row fact table

DROP TABLE IF EXISTS cust_kpi;

CREATE TABLE cust_kpi AS
SELECT customernumber AS customer_id,
       COUNT(DISTINCT transactionuniqueid) AS total_transactions,
       SUM(quantity) AS total_items,
       SUM(sellingprice * quantity) AS total_sales,
       SUM(cost) AS total_cost,
       SUM(COALESCE(transactiondiscount,0) + COALESCE(itemdiscount,0) + COALESCE(overridediscount,0)) AS total_discount,
       SUM(CASE WHEN COALESCE(promotiontype,'') <> '' THEN sellingprice * quantity ELSE 0 END) AS promo_sales,
       COUNT(DISTINCT storenumber) AS distinct_stores,
       MIN(DATE(saledate)) AS first_purchase_date,
       MAX(DATE(saledate)) AS last_purchase_date,
       MAX(CASE WHEN customeremailflag IN ('1','Y','y','true','TRUE','True') THEN 1 ELSE 0 END) AS email_flag
FROM pos_sales_detail
GROUP BY customernumber;

-- Home store = the store where the customer transacted most (ties by store number)

DROP TABLE IF EXISTS cust_home;

CREATE TABLE cust_home AS
SELECT customer_id, home_store_number, home_store, home_province, home_region FROM (
  SELECT customernumber AS customer_id, storenumber AS home_store_number,
         storename AS home_store, storeprovince AS home_province, storeregion AS home_region,
         ROW_NUMBER() OVER (PARTITION BY customernumber ORDER BY COUNT(*) DESC, storenumber) AS rk
  FROM pos_sales_detail
  GROUP BY customernumber, storenumber, storename, storeprovince, storeregion
) t WHERE rk = 1;

-- Modal FSA per customer (about 90 percent of fact rows carry one)

DROP TABLE IF EXISTS cust_fsa;

CREATE TABLE cust_fsa AS
SELECT customer_id, fsa FROM (
  SELECT customernumber AS customer_id, TRIM(customerfsa) AS fsa,
         ROW_NUMBER() OVER (PARTITION BY customernumber ORDER BY COUNT(*) DESC, TRIM(customerfsa)) AS rk
  FROM pos_sales_detail
  WHERE COALESCE(customerfsa,'') <> ''
  GROUP BY customernumber, TRIM(customerfsa)
) t WHERE rk = 1;

-- Favorite category = the products.category with the highest lifetime spend

DROP TABLE IF EXISTS cust_cat;

CREATE TABLE cust_cat AS
SELECT customer_id, favorite_category FROM (
  SELECT f.customernumber AS customer_id, p.category AS favorite_category,
         ROW_NUMBER() OVER (PARTITION BY f.customernumber ORDER BY SUM(f.sellingprice * f.quantity) DESC, p.category) AS rk
  FROM pos_sales_detail f
  JOIN products p ON TRIM(f.plu) = p.plu
  WHERE COALESCE(p.category,'') <> ''
  GROUP BY f.customernumber, p.category
) t WHERE rk = 1;

-- Final dimension -- identity generation plus RFM and tiering

DROP TABLE IF EXISTS customers;

CREATE TABLE customers AS
WITH jb AS (
  -- Julian day number pieces -- INTERVAL() is not supported on X100 tables,
  -- so recency in days is computed with pure integer arithmetic
  SELECT customer_id,
         YEAR(last_purchase_date) + 4800 - (14 - MONTH(last_purchase_date)) / 12 AS jy,
         MONTH(last_purchase_date) + 12 * ((14 - MONTH(last_purchase_date)) / 12) - 3 AS jm,
         DAY(last_purchase_date) AS jd
  FROM cust_kpi
), jdn AS (
  SELECT customer_id,
         jd + (153 * jm + 2) / 5 + 365 * jy + jy / 4 - jy / 100 + jy / 400 - 32045 AS last_jdn
  FROM jb
), base AS (
  SELECT k.customer_id, k.total_transactions, k.total_items, k.total_sales, k.total_cost,
         k.total_discount, k.promo_sales, k.distinct_stores,
         k.first_purchase_date, k.last_purchase_date, k.email_flag,
         h.home_store_number, h.home_store, h.home_province, h.home_region,
         fs.fsa, c.favorite_category, j.last_jdn,
         NTILE(5)  OVER (ORDER BY k.last_purchase_date)  AS rfm_recency,
         NTILE(5)  OVER (ORDER BY k.total_transactions)  AS rfm_frequency,
         NTILE(5)  OVER (ORDER BY k.total_sales)         AS rfm_monetary,
         NTILE(20) OVER (ORDER BY k.total_sales)         AS m20
  FROM cust_kpi k
  JOIN cust_home h  ON h.customer_id  = k.customer_id
  JOIN jdn j        ON j.customer_id  = k.customer_id
  LEFT JOIN cust_fsa fs ON fs.customer_id = k.customer_id
  LEFT JOIN cust_cat c  ON c.customer_id  = k.customer_id
), named AS (
  SELECT b.*, sf.name AS first_name, sl.name AS last_name,
         ss.name AS street_name, st.name AS street_type,
         10 + ABS(MOD(HASH(b.customer_id + 'no'), 9890)) AS street_no,
         ABS(MOD(HASH(b.customer_id + 'u'), 4))          AS unit_sel,
         1 + ABS(MOD(HASH(b.customer_id + 'un'), 120))   AS unit_no,
         ABS(MOD(HASH(b.customer_id + 'd'), 5))          AS dom_sel,
         ABS(MOD(HASH(b.customer_id + 'ac'), 3))         AS ac_sel,
         ABS(MOD(HASH(b.customer_id + 'ph'), 100))       AS ph_n,
         ABS(MOD(HASH(b.customer_id + 'p1'), 10))        AS p1,
         CHAREXTRACT('ABCEGHJKLMNPRSTVWXYZ', 1 + ABS(MOD(HASH(b.customer_id + 'p2'), 20))) AS p2,
         ABS(MOD(HASH(b.customer_id + 'p3'), 10))        AS p3
  FROM base b
  JOIN cust_seed_first  sf ON sf.id = ABS(MOD(HASH(b.customer_id + 'fn'), 60))
  JOIN cust_seed_last   sl ON sl.id = ABS(MOD(HASH(b.customer_id + 'ln'), 60))
  JOIN cust_seed_street ss ON ss.id = ABS(MOD(HASH(b.customer_id + 'st'), 40))
  JOIN cust_seed_stype  st ON st.id = ABS(MOD(HASH(b.customer_id + 'ty'), 8))
)
SELECT customer_id,
       first_name,
       last_name,
       first_name + ' ' + last_name AS full_name,
       CASE WHEN email_flag = 1 THEN
         LOWERCASE(first_name) + '.' + LOWERCASE(last_name) + customer_id + '@' +
         CASE dom_sel WHEN 0 THEN 'gmail.com' WHEN 1 THEN 'outlook.com'
              WHEN 2 THEN 'yahoo.ca' WHEN 3 THEN 'hotmail.com' ELSE 'icloud.com' END
       END AS email,
       CASE WHEN email_flag = 1 THEN 'Y' ELSE 'N' END AS email_opt_in,
       '(' +
       CASE home_province
            WHEN 'ON' THEN CASE ac_sel WHEN 0 THEN '416' WHEN 1 THEN '613' ELSE '705' END
            WHEN 'QC' THEN CASE ac_sel WHEN 0 THEN '514' WHEN 1 THEN '418' ELSE '450' END
            WHEN 'AB' THEN CASE ac_sel WHEN 0 THEN '403' WHEN 1 THEN '780' ELSE '587' END
            WHEN 'BC' THEN CASE ac_sel WHEN 0 THEN '604' WHEN 1 THEN '250' ELSE '778' END
            WHEN 'MB' THEN '204' WHEN 'SK' THEN '306' WHEN 'NS' THEN '902'
            WHEN 'NB' THEN '506' WHEN 'NL' THEN '709' ELSE '867' END +
       ') 555-01' + RIGHT('0' + VARCHAR(MOD(ph_n, 100)), 2) AS phone,
       CASE WHEN unit_sel = 0 THEN VARCHAR(unit_no) + '-' ELSE '' END +
         VARCHAR(street_no) + ' ' + street_name + ' ' + street_type AS street_address,
       CASE WHEN LOCATE(home_store, '-') <= LENGTH(home_store)
            THEN TRIM(LEFT(home_store, LOCATE(home_store, '-') - 1))
            ELSE TRIM(home_store) END AS city,
       home_province AS province,
       CASE WHEN fsa IS NOT NULL THEN fsa + ' ' + VARCHAR(p1) + p2 + VARCHAR(p3) END AS postal_code,
       home_store_number, home_store, home_region,
       first_purchase_date, last_purchase_date,
       (SELECT MAX(last_jdn) FROM jdn) - last_jdn AS recency_days,
       total_transactions, total_items,
       DECIMAL(total_sales, 14, 2) AS total_sales,
       DECIMAL(total_cost, 14, 2) AS total_cost,
       DECIMAL(total_sales - total_cost, 14, 2) AS gross_margin,
       DECIMAL(100.0 * (total_sales - total_cost) / NULLIF(total_sales, 0), 8, 2) AS margin_pct,
       DECIMAL(total_sales / NULLIF(total_transactions, 0), 10, 2) AS avg_basket,
       DECIMAL(1.0 * total_items / NULLIF(total_transactions, 0), 8, 2) AS avg_items_per_txn,
       DECIMAL(total_discount, 12, 2) AS total_discount,
       DECIMAL(promo_sales, 14, 2) AS promo_sales,
       DECIMAL(100.0 * promo_sales / NULLIF(total_sales, 0), 8, 2) AS promo_sales_pct,
       distinct_stores, favorite_category,
       rfm_recency, rfm_frequency, rfm_monetary,
       CASE WHEN rfm_recency >= 4 AND rfm_frequency >= 4 AND rfm_monetary >= 4 THEN 'Champion'
            WHEN rfm_recency >= 4 AND rfm_frequency >= 3 THEN 'Loyal'
            WHEN rfm_recency >= 4 THEN 'Recent'
            WHEN rfm_recency <= 2 AND rfm_frequency >= 4 THEN 'At Risk'
            WHEN rfm_recency <= 2 AND rfm_frequency <= 2 THEN 'Lost'
            ELSE 'Regular' END AS rfm_segment,
       CASE WHEN m20 = 20 THEN 'Platinum' WHEN m20 >= 17 THEN 'Gold'
            WHEN m20 >= 11 THEN 'Silver' ELSE 'Bronze' END AS loyalty_tier
FROM named;

DROP TABLE IF EXISTS cust_kpi;

DROP TABLE IF EXISTS cust_home;

DROP TABLE IF EXISTS cust_fsa;

DROP TABLE IF EXISTS cust_cat;

DROP TABLE IF EXISTS cust_seed_first;

DROP TABLE IF EXISTS cust_seed_last;

DROP TABLE IF EXISTS cust_seed_street;

DROP TABLE IF EXISTS cust_seed_stype;
