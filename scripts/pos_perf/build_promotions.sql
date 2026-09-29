-- build_promotions.sql -- DROP-and-rebuild of the promotions dimension.
-- One row per distinct non-blank eventid in pos_sales_detail (115 events).
-- Everything measurable is REAL: start and end dates are the first and last
-- sale dates carrying the event, plus stores participating, units, sales,
-- margin, customers, transactions, marketing and expected subsidy dollars,
-- and discount depth vs the price book regular price. FICTITIOUS but
-- DETERMINISTIC: the campaign name (season from the real start month plus a
-- hash-picked theme). The mechanic label decodes the dominant REAL
-- promotiontype code on the event lines (T, M or O). Funding source is
-- Vendor Co-op when real marketing subsidy dollars exist, else Corporate.
-- The top_category comes from joining event lines to products.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS promo_agg;

CREATE TABLE promo_agg AS
SELECT eventid,
       MIN(DATE(saledate)) AS start_date,
       MAX(DATE(saledate)) AS end_date,
       COUNT(DISTINCT storenumber) AS stores_participating,
       COUNT(DISTINCT customernumber) AS distinct_customers,
       COUNT(DISTINCT transactionuniqueid) AS total_transactions,
       SUM(quantity) AS units_sold,
       SUM(sellingprice * quantity) AS promo_sales,
       SUM(cost) AS promo_cost,
       SUM(COALESCE(marketingsubsidy, 0)) AS marketing_subsidy,
       SUM(COALESCE(expectedsubsidy, 0)) AS expected_subsidy,
       SUM(pricebookregularprice * quantity) AS regular_value,
       SUM(CASE WHEN promotiontype = 'T' THEN 1 ELSE 0 END) AS t_lines,
       SUM(CASE WHEN promotiontype = 'M' THEN 1 ELSE 0 END) AS m_lines,
       SUM(CASE WHEN promotiontype = 'O' THEN 1 ELSE 0 END) AS o_lines
FROM pos_sales_detail
WHERE COALESCE(eventid,'') <> ''
GROUP BY eventid;

DROP TABLE IF EXISTS promo_cat;

CREATE TABLE promo_cat AS
SELECT eventid, top_category FROM (
  SELECT f.eventid, p.category AS top_category,
         ROW_NUMBER() OVER (PARTITION BY f.eventid ORDER BY SUM(f.sellingprice * f.quantity) DESC, p.category) AS rk
  FROM pos_sales_detail f
  JOIN products p ON p.plu = TRIM(f.plu)
  WHERE COALESCE(f.eventid,'') <> '' AND COALESCE(p.category,'') <> ''
  GROUP BY f.eventid, p.category
) t WHERE rk = 1;

DROP TABLE IF EXISTS promotions;

CREATE TABLE promotions AS
SELECT a.eventid AS promo_id,
       CASE WHEN MONTH(a.start_date) IN (12, 1, 2) THEN 'Winter'
            WHEN MONTH(a.start_date) IN (3, 4, 5) THEN 'Spring'
            WHEN MONTH(a.start_date) IN (6, 7, 8) THEN 'Summer'
            ELSE 'Fall' END + ' ' +
       CASE ABS(MOD(HASH(a.eventid + 'nm'), 8))
            WHEN 0 THEN 'Savings Spectacular' WHEN 1 THEN 'Family Favourites'
            WHEN 2 THEN 'Big Thaw Sale' WHEN 3 THEN 'Stock-Up Event'
            WHEN 4 THEN 'Weekend Flyer' WHEN 5 THEN 'Member Days'
            WHEN 6 THEN 'Freezer Fill' ELSE 'Harvest Deals' END +
       ' #' + a.eventid AS campaign_name,
       CASE WHEN a.t_lines >= a.m_lines AND a.t_lines >= a.o_lines THEN 'Temporary Price Reduction'
            WHEN a.m_lines >= a.o_lines THEN 'Manager Markdown'
            ELSE 'Price Override' END AS mechanic,
       CASE WHEN a.marketing_subsidy > 0 THEN 'Vendor Co-op' ELSE 'Corporate' END AS funding_source,
       a.start_date, a.end_date,
       a.stores_participating, a.distinct_customers, a.total_transactions,
       a.units_sold,
       DECIMAL(a.promo_sales, 14, 2) AS promo_sales,
       DECIMAL(a.promo_sales - a.promo_cost, 14, 2) AS promo_margin,
       DECIMAL(100.0 * (a.promo_sales - a.promo_cost) / NULLIF(a.promo_sales, 0), 8, 2) AS margin_pct,
       DECIMAL(100.0 * (1 - a.promo_sales / NULLIF(a.regular_value, 0)), 8, 2) AS discount_depth_pct,
       DECIMAL(a.marketing_subsidy, 12, 2) AS marketing_subsidy,
       DECIMAL(a.expected_subsidy, 12, 2) AS expected_subsidy,
       DECIMAL(a.promo_sales / NULLIF(a.total_transactions, 0), 10, 2) AS avg_txn_value,
       c.top_category
FROM promo_agg a
LEFT JOIN promo_cat c ON c.eventid = a.eventid;

DROP TABLE IF EXISTS promo_agg;

DROP TABLE IF EXISTS promo_cat;
