-- build_store_pnl_monthly.sql -- DROP-and-rebuild of store_pnl_monthly, the
-- store x month contribution statement (330 stores x months from each store
-- open month through 2020-12, about 7,900 rows). Franchisee view: royalty
-- and marketing fee are costs.
-- REAL (from the warehouse): net_sales, returns_value, cogs, gross_margin,
-- transactions, units (pos_sales_txn), promo_subsidy_income and its vendor
-- co-op component (pos_sales_detail subsidy / marketingsubsidy -- subsidy is
-- the total credit, marketingsubsidy a component of it, never added
-- together), royalty_base_sales, royalty_fee (x franchisee royalty rate 4,
-- 5 or 6 pct), marketing_fee (net sales x franchisee marketing rate 1 or 2
-- pct), labour_hours and labour_cost (shift_schedules.labour_cost),
-- shrinkage_cost (shrinkage_log), delivery orders and fees collected
-- (ecommerce_orders).
-- FICTITIOUS but DETERMINISTIC from HASH(store + salt), anchored to real
-- quantities: labour_burden_pct (12-20 by province), occupancy_cost
-- (square_feet x annual rate by store_format and province x store jitter),
-- utilities_cost (square_feet x base, scaled by the REAL monthly mean
-- temperature from weather_daily -- heating in winter, freezers in summer),
-- delivery_partner_cost (order value x partner commission 18-22 pct minus
-- delivery fees collected), other_opex (1.5-3.0 pct of sales by store).
-- card_processing_fees is DERIVED from tender_summary_daily (Debit 0.06 per
-- transaction, Visa and MC 1.6 pct, Amex 2.4 pct, Mobile 1.8 pct on the
-- tender mix), so run build_tender_summary_daily.sql FIRST.
-- card_fee_rate_pct is now the resulting effective rate, informational.
-- Computed: total_store_opex (store-run costs), four_wall_ebitda = gross
-- margin + subsidy income - store opex (before franchise fees),
-- franchise_fees = royalty + marketing, total_opex = store opex + fees,
-- store_contribution = four_wall_ebitda - franchise_fees, pct columns.
-- Sales, COGS and margin reconcile to pos_sales_txn to the cent.
-- Requires: pos_sales_txn, pos_sales_detail, stores, franchisees,
-- shift_schedules (with labour_cost), shrinkage_log, ecommerce_orders,
-- weather_daily, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS pnl_months;

CREATE TABLE pnl_months AS
SELECT yyyymm, COUNT(*) AS days_in_month, MAX(pandemic_period) AS pandemic_period,
       MIN(calendar_date) AS month_start, MAX(calendar_date) AS month_end
FROM date_dim GROUP BY yyyymm;

DROP TABLE IF EXISTS pnl_spine;

CREATE TABLE pnl_spine AS
SELECT s.storenumber, s.storename, s.franchisee_id, s.province, s.region, s.store_format, s.square_feet,
       m.yyyymm, m.month_start, m.days_in_month, m.pandemic_period,
       YEAR(s.open_date) * 100 + MONTH(s.open_date) AS open_yyyymm,
       YEAR(s.last_sale_date) * 100 + MONTH(s.last_sale_date) AS last_sale_yyyymm
FROM stores s
JOIN pnl_months m ON m.yyyymm >= YEAR(s.open_date) * 100 + MONTH(s.open_date);

-- REAL sales block from the transaction grain

DROP TABLE IF EXISTS pnl_sales;

CREATE TABLE pnl_sales AS
SELECT storenumber, yyyymm,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN basket_value ELSE 0 END) AS net_sales,
       SUM(CASE WHEN txn_type = 'Regular Return' THEN basket_value ELSE 0 END) AS returns_value,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN basket_cost ELSE 0 END) AS cogs,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN 1 ELSE 0 END) AS transactions,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN basket_items ELSE 0 END) AS units,
       SUM(CASE WHEN txn_type = 'Regular Sale' AND ecommerce_flag = 'Y' THEN 1 ELSE 0 END) AS ecommerce_transactions,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN promo_value ELSE 0 END) AS promo_sales,
       SUM(CASE WHEN txn_type = 'Regular Sale' THEN discount_total ELSE 0 END) AS discounts,
       COUNT(DISTINCT CASE WHEN txn_type = 'Regular Sale' THEN customer_id END) AS distinct_customers
FROM pos_sales_txn
GROUP BY storenumber, yyyymm;

-- REAL subsidy and royalty base from the line fact

DROP TABLE IF EXISTS pnl_subsidy;

CREATE TABLE pnl_subsidy AS
SELECT storenumber, YEAR(DATE(saledate)) * 100 + MONTH(DATE(saledate)) AS yyyymm,
       SUM(COALESCE(subsidy, 0)) AS promo_subsidy_income,
       SUM(COALESCE(marketingsubsidy, 0)) AS vendor_coop_subsidy,
       SUM(COALESCE(expectedsubsidy, 0)) AS expected_subsidy,
       SUM(CASE WHEN transactiontype = 'Regular Sale' THEN COALESCE(royaltysales, 0) ELSE 0 END) AS royalty_base_sales
FROM pos_sales_detail
GROUP BY storenumber, YEAR(DATE(saledate)) * 100 + MONTH(DATE(saledate));

-- REAL labour from shifts

DROP TABLE IF EXISTS pnl_labour;

CREATE TABLE pnl_labour AS
SELECT s.storenumber, YEAR(s.calendar_date) * 100 + MONTH(s.calendar_date) AS yyyymm,
       SUM(s.scheduled_hours) AS labour_hours,
       SUM(s.labour_cost) AS labour_cost,
       SUM(CASE WHEN s.is_weekend = 'Y' OR s.is_holiday = 'Y' THEN s.labour_cost ELSE 0 END) AS premium_day_labour_cost
FROM shift_schedules s
GROUP BY s.storenumber, YEAR(s.calendar_date) * 100 + MONTH(s.calendar_date);

-- REAL shrink

DROP TABLE IF EXISTS pnl_shrink;

CREATE TABLE pnl_shrink AS
SELECT storenumber, event_year * 100 + event_month AS yyyymm,
       SUM(shrink_value) AS shrinkage_cost, COUNT(*) AS shrinkage_events
FROM shrinkage_log
GROUP BY storenumber, event_year * 100 + event_month;

-- REAL delivery orders, MODELED partner commission (18-22 pct by partner)

DROP TABLE IF EXISTS pnl_delivery;

CREATE TABLE pnl_delivery AS
SELECT fulfillment_store AS storenumber, YEAR(order_date) * 100 + MONTH(order_date) AS yyyymm,
       COUNT(*) AS delivery_orders,
       SUM(order_value) AS delivery_order_value,
       SUM(delivery_fee) AS delivery_fees_collected,
       SUM(order_value * CASE delivery_partner WHEN 'SnowRoute Express' THEN 0.20
                                              WHEN 'Maple Courier Co' THEN 0.18
                                              WHEN 'UrbanSled Delivery' THEN 0.22 ELSE 0.20 END) AS partner_commission
FROM ecommerce_orders
WHERE channel = 'Delivery'
GROUP BY fulfillment_store, YEAR(order_date) * 100 + MONTH(order_date);

-- Card processing fees from the tender mix (build_tender_summary_daily.sql)

DROP TABLE IF EXISTS pnl_tender;

CREATE TABLE pnl_tender AS
SELECT storenumber, yyyymm,
       SUM(processing_fee) AS card_processing_fees,
       SUM(CASE WHEN tender_type <> 'Cash' THEN amount ELSE 0 END) AS cashless_amount,
       SUM(amount) AS tender_amount
FROM tender_summary_daily
GROUP BY storenumber, yyyymm;

-- REAL monthly mean temperature by province (drives utilities)

DROP TABLE IF EXISTS pnl_weather;

CREATE TABLE pnl_weather AS
SELECT w.province, d.yyyymm, AVG((w.temp_high_c + w.temp_low_c) / 2.0) AS mean_temp_c
FROM weather_daily w
JOIN date_dim d ON d.calendar_date = w.calendar_date
GROUP BY w.province, d.yyyymm;

DROP TABLE IF EXISTS store_pnl_monthly;

CREATE TABLE store_pnl_monthly AS
WITH r AS (
  SELECT p.*,
         f.royalty_rate_pct, f.marketing_fee_pct,
         COALESCE(sa.net_sales, 0) AS net_sales,
         COALESCE(sa.returns_value, 0) AS returns_value,
         COALESCE(sa.cogs, 0) AS cogs,
         COALESCE(sa.transactions, 0) AS transactions,
         COALESCE(sa.units, 0) AS units,
         COALESCE(sa.ecommerce_transactions, 0) AS ecommerce_transactions,
         COALESCE(sa.promo_sales, 0) AS promo_sales,
         COALESCE(sa.discounts, 0) AS discounts,
         COALESCE(sa.distinct_customers, 0) AS distinct_customers,
         COALESCE(su.promo_subsidy_income, 0) AS promo_subsidy_income,
         COALESCE(su.vendor_coop_subsidy, 0) AS vendor_coop_subsidy,
         COALESCE(su.expected_subsidy, 0) AS expected_subsidy,
         COALESCE(su.royalty_base_sales, 0) AS royalty_base_sales,
         COALESCE(l.labour_hours, 0) AS labour_hours,
         COALESCE(l.labour_cost, 0) AS labour_cost,
         COALESCE(l.premium_day_labour_cost, 0) AS premium_day_labour_cost,
         COALESCE(sh.shrinkage_cost, 0) AS shrinkage_cost,
         COALESCE(sh.shrinkage_events, 0) AS shrinkage_events,
         COALESCE(dl.delivery_orders, 0) AS delivery_orders,
         COALESCE(dl.delivery_order_value, 0) AS delivery_order_value,
         COALESCE(dl.delivery_fees_collected, 0) AS delivery_fees_collected,
         COALESCE(dl.partner_commission, 0) AS partner_commission,
         COALESCE(w.mean_temp_c, 8.0) AS mean_temp_c,
         COALESCE(tn.card_processing_fees, 0) AS card_processing_fees,
         COALESCE(tn.cashless_amount, 0) AS cashless_amount,
         -- modeled rate parameters, deterministic per store
         CASE p.province WHEN 'QC' THEN 18.0 WHEN 'ON' THEN 15.0 WHEN 'BC' THEN 15.0 WHEN 'AB' THEN 13.0 ELSE 14.0 END
           + ABS(MOD(HASH(VARCHAR(p.storenumber) + 'bur'), 21)) / 10.0 AS labour_burden_pct,
         CASE p.store_format WHEN 'Shopping Mall' THEN 36.0 WHEN 'Urban Storefront' THEN 30.0
                             WHEN 'Strip Plaza' THEN 22.0 ELSE 18.0 END
           * CASE p.province WHEN 'ON' THEN 1.15 WHEN 'BC' THEN 1.25 WHEN 'QC' THEN 0.95 WHEN 'AB' THEN 1.00
                             WHEN 'YT' THEN 1.30 WHEN 'NT' THEN 1.30 ELSE 0.85 END
           * (0.90 + ABS(MOD(HASH(VARCHAR(p.storenumber) + 'occ'), 21)) / 100.0) AS occupancy_rate_sqft_yr,
         0.36 + ABS(MOD(HASH(VARCHAR(p.storenumber) + 'utl'), 9)) / 100.0 AS utilities_base_sqft_mo,
         1.5 + ABS(MOD(HASH(VARCHAR(p.storenumber) + 'oth'), 16)) / 10.0 AS other_opex_pct
  FROM pnl_spine p
  LEFT JOIN franchisees f ON f.franchisee_id = p.franchisee_id
  LEFT JOIN pnl_sales sa   ON sa.storenumber = p.storenumber AND sa.yyyymm = p.yyyymm
  LEFT JOIN pnl_subsidy su ON su.storenumber = p.storenumber AND su.yyyymm = p.yyyymm
  LEFT JOIN pnl_labour l   ON l.storenumber = p.storenumber AND l.yyyymm = p.yyyymm
  LEFT JOIN pnl_shrink sh  ON sh.storenumber = p.storenumber AND sh.yyyymm = p.yyyymm
  LEFT JOIN pnl_delivery dl ON dl.storenumber = p.storenumber AND dl.yyyymm = p.yyyymm
  LEFT JOIN pnl_weather w  ON w.province = p.province AND w.yyyymm = p.yyyymm
  LEFT JOIN pnl_tender tn  ON tn.storenumber = p.storenumber AND tn.yyyymm = p.yyyymm
), c AS (
  SELECT r.*,
         net_sales - cogs AS gross_margin,
         labour_cost * labour_burden_pct / 100.0 AS labour_burden,
         square_feet * occupancy_rate_sqft_yr / 12.0 AS occupancy_cost,
         square_feet * utilities_base_sqft_mo
           * (1.0 + 0.025 * GREATEST(0.0, 12.0 - mean_temp_c) + 0.02 * GREATEST(0.0, mean_temp_c - 20.0)) AS utilities_cost,
         GREATEST(0.0, partner_commission - delivery_fees_collected) AS delivery_partner_cost,
         net_sales * other_opex_pct / 100.0 AS other_opex,
         royalty_base_sales * royalty_rate_pct / 100.0 AS royalty_fee,
         net_sales * marketing_fee_pct / 100.0 AS marketing_fee
  FROM r
), t AS (
  SELECT c.*,
         labour_cost + labour_burden + occupancy_cost + utilities_cost + shrinkage_cost
           + delivery_partner_cost + card_processing_fees + other_opex AS total_store_opex,
         royalty_fee + marketing_fee AS franchise_fees
  FROM c
)
SELECT storenumber, storename, franchisee_id, province, region, store_format, square_feet,
       yyyymm, month_start, yyyymm / 100 AS yr, MOD(yyyymm, 100) AS mo, days_in_month, pandemic_period,
       CASE WHEN yyyymm = open_yyyymm THEN 'Y' ELSE 'N' END AS opening_month,
       CASE WHEN yyyymm > last_sale_yyyymm THEN 'Closed'
            WHEN net_sales = 0 THEN 'No sales' ELSE 'Trading' END AS trading_status,
       -- revenue and margin (REAL)
       DECIMAL(net_sales, 12, 2) AS net_sales,
       DECIMAL(returns_value, 12, 2) AS returns_value,
       DECIMAL(cogs, 12, 2) AS cogs,
       DECIMAL(gross_margin, 12, 2) AS gross_margin,
       DECIMAL(100.0 * gross_margin / NULLIF(net_sales, 0), 8, 2) AS gross_margin_pct,
       transactions, units, ecommerce_transactions, distinct_customers,
       DECIMAL(promo_sales, 12, 2) AS promo_sales,
       DECIMAL(discounts, 12, 2) AS discounts,
       DECIMAL(promo_subsidy_income, 12, 2) AS promo_subsidy_income,
       DECIMAL(vendor_coop_subsidy, 12, 2) AS vendor_coop_subsidy,
       DECIMAL(expected_subsidy, 12, 2) AS expected_subsidy,
       -- store operating costs
       DECIMAL(labour_hours, 10, 1) AS labour_hours,
       DECIMAL(labour_cost, 12, 2) AS labour_cost,
       DECIMAL(labour_burden_pct, 5, 1) AS labour_burden_pct,
       DECIMAL(labour_burden, 12, 2) AS labour_burden,
       DECIMAL(premium_day_labour_cost, 12, 2) AS premium_day_labour_cost,
       DECIMAL(occupancy_rate_sqft_yr, 8, 2) AS occupancy_rate_sqft_yr,
       DECIMAL(occupancy_cost, 12, 2) AS occupancy_cost,
       DECIMAL(mean_temp_c, 6, 1) AS mean_temp_c,
       DECIMAL(utilities_cost, 12, 2) AS utilities_cost,
       DECIMAL(shrinkage_cost, 12, 2) AS shrinkage_cost,
       shrinkage_events,
       delivery_orders,
       DECIMAL(delivery_order_value, 12, 2) AS delivery_order_value,
       DECIMAL(delivery_fees_collected, 12, 2) AS delivery_fees_collected,
       DECIMAL(partner_commission, 12, 2) AS delivery_partner_commission,
       DECIMAL(delivery_partner_cost, 12, 2) AS delivery_partner_cost,
       DECIMAL(100.0 * card_processing_fees / NULLIF(net_sales, 0), 5, 2) AS card_fee_rate_pct,
       DECIMAL(card_processing_fees, 12, 2) AS card_processing_fees,
       DECIMAL(100.0 * cashless_amount / NULLIF(net_sales, 0), 6, 2) AS cashless_share_pct,
       DECIMAL(other_opex_pct, 5, 1) AS other_opex_pct,
       DECIMAL(other_opex, 12, 2) AS other_opex,
       DECIMAL(total_store_opex, 12, 2) AS total_store_opex,
       -- franchise fees (REAL rates)
       DECIMAL(royalty_base_sales, 12, 2) AS royalty_base_sales,
       royalty_rate_pct,
       DECIMAL(royalty_fee, 12, 2) AS royalty_fee,
       marketing_fee_pct,
       DECIMAL(marketing_fee, 12, 2) AS marketing_fee,
       DECIMAL(franchise_fees, 12, 2) AS franchise_fees,
       DECIMAL(total_store_opex + franchise_fees, 12, 2) AS total_opex,
       -- results
       DECIMAL(gross_margin + promo_subsidy_income - total_store_opex, 12, 2) AS four_wall_ebitda,
       DECIMAL(gross_margin + promo_subsidy_income - total_store_opex - franchise_fees, 12, 2) AS store_contribution,
       DECIMAL(100.0 * (gross_margin + promo_subsidy_income - total_store_opex) / NULLIF(net_sales, 0), 8, 2) AS four_wall_margin_pct,
       DECIMAL(100.0 * (gross_margin + promo_subsidy_income - total_store_opex - franchise_fees) / NULLIF(net_sales, 0), 8, 2) AS contribution_margin_pct,
       DECIMAL(100.0 * (labour_cost + labour_burden) / NULLIF(net_sales, 0), 8, 2) AS labour_pct_of_sales,
       DECIMAL(100.0 * occupancy_cost / NULLIF(net_sales, 0), 8, 2) AS occupancy_pct_of_sales,
       DECIMAL(100.0 * total_store_opex / NULLIF(net_sales, 0), 8, 2) AS store_opex_pct_of_sales,
       DECIMAL(net_sales / NULLIF(square_feet, 0), 10, 2) AS sales_per_sqft
FROM t;

DROP TABLE IF EXISTS pnl_tender;

DROP TABLE IF EXISTS pnl_weather;

DROP TABLE IF EXISTS pnl_delivery;

DROP TABLE IF EXISTS pnl_shrink;

DROP TABLE IF EXISTS pnl_labour;

DROP TABLE IF EXISTS pnl_subsidy;

DROP TABLE IF EXISTS pnl_sales;

DROP TABLE IF EXISTS pnl_spine;

DROP TABLE IF EXISTS pnl_months;

CREATE STATISTICS FOR store_pnl_monthly;
