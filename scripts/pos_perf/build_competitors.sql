-- build_competitors.sql -- DROP-and-rebuild of competitor_locations.
-- Zero to four fictitious competitor banners near each store (hash-picked),
-- with distance, format, and the store trade-area FSA carried from the
-- stores dimension so the table joins cleanly to fsa_demographics.
-- All banners are invented -- no real retail brands.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS cmp_slots;

CREATE TABLE cmp_slots AS
SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3;

DROP TABLE IF EXISTS competitor_locations;

CREATE TABLE competitor_locations AS
WITH g AS (
  SELECT st.storenumber, st.city, st.province, st.postal_fsa, sl.n,
         VARCHAR(st.storenumber) + '|' + VARCHAR(sl.n) AS hk
  FROM stores st
  JOIN cmp_slots sl ON sl.n < ABS(MOD(HASH(VARCHAR(st.storenumber) + 'nc'), 5))
)
SELECT 'CMP-' + VARCHAR(storenumber) + '-' + VARCHAR(n) AS competitor_id,
       storenumber, city, province, postal_fsa AS trade_area_fsa,
       CASE ABS(MOD(HASH(hk + 'bn'), 6))
            WHEN 0 THEN 'FrostMart' WHEN 1 THEN 'Glacier Foods'
            WHEN 2 THEN 'Polar Pantry' WHEN 3 THEN 'IceBox Grocers'
            WHEN 4 THEN 'Tundra Fresh' ELSE 'ChillCo Frozen' END AS competitor_banner,
       CASE ABS(MOD(HASH(hk + 'fm'), 3))
            WHEN 0 THEN 'Supermarket' WHEN 1 THEN 'Discount Grocer'
            ELSE 'Specialty Frozen' END AS competitor_format,
       DECIMAL(0.3 + ABS(MOD(HASH(hk + 'ds'), 78)) / 10.0, 4, 1) AS distance_km
FROM g;

DROP TABLE IF EXISTS cmp_slots;
