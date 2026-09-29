-- verify_store_pnl.sql -- sanity checks for store_pnl_monthly and
-- store_budget_monthly.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.

-- 1. Grain: one row per store per month from the open month, no duplicates
SELECT COUNT(*) AS rows_, COUNT(DISTINCT storenumber) AS stores, MIN(yyyymm) AS min_m, MAX(yyyymm) AS max_m,
       (SELECT COUNT(*) FROM (SELECT storenumber, yyyymm FROM store_pnl_monthly GROUP BY storenumber, yyyymm HAVING COUNT(*) > 1) d) AS dup_keys
FROM store_pnl_monthly;

-- 2. Reconciliation to the transaction grain (must match to the cent)
SELECT (SELECT SUM(net_sales) FROM store_pnl_monthly) AS pnl_sales,
       (SELECT SUM(basket_value) FROM pos_sales_txn WHERE txn_type = 'Regular Sale') AS txn_sales,
       (SELECT SUM(cogs) FROM store_pnl_monthly) AS pnl_cogs,
       (SELECT SUM(basket_cost) FROM pos_sales_txn WHERE txn_type = 'Regular Sale') AS txn_cogs,
       (SELECT SUM(shrinkage_cost) FROM store_pnl_monthly) AS pnl_shrink,
       (SELECT SUM(shrink_value) FROM shrinkage_log) AS log_shrink;

-- 3. Labour: pnl excludes shifts before the store open month, so pnl <= shifts
SELECT (SELECT SUM(labour_cost) FROM store_pnl_monthly) AS pnl_labour,
       (SELECT SUM(labour_cost) FROM shift_schedules) AS shift_labour;

-- 4. Network P&L as percent of sales
SELECT DECIMAL(100.0 * SUM(cogs) / SUM(net_sales), 6, 2) AS cogs_pct,
       DECIMAL(100.0 * SUM(gross_margin) / SUM(net_sales), 6, 2) AS gm_pct,
       DECIMAL(100.0 * SUM(labour_cost + labour_burden) / SUM(net_sales), 6, 2) AS labour_pct,
       DECIMAL(100.0 * SUM(occupancy_cost) / SUM(net_sales), 6, 2) AS occupancy_pct,
       DECIMAL(100.0 * SUM(utilities_cost) / SUM(net_sales), 6, 2) AS utilities_pct,
       DECIMAL(100.0 * SUM(shrinkage_cost) / SUM(net_sales), 6, 2) AS shrink_pct,
       DECIMAL(100.0 * SUM(card_processing_fees) / SUM(net_sales), 6, 2) AS card_pct,
       DECIMAL(100.0 * SUM(other_opex) / SUM(net_sales), 6, 2) AS other_pct,
       DECIMAL(100.0 * SUM(franchise_fees) / SUM(net_sales), 6, 2) AS fees_pct,
       DECIMAL(100.0 * SUM(four_wall_ebitda) / SUM(net_sales), 6, 2) AS four_wall_pct,
       DECIMAL(100.0 * SUM(store_contribution) / SUM(net_sales), 6, 2) AS contribution_pct
FROM store_pnl_monthly WHERE trading_status = 'Trading';

-- 5. Trading status and loss-making months
SELECT trading_status, COUNT(*) AS n, SUM(CASE WHEN store_contribution < 0 THEN 1 ELSE 0 END) AS loss_months FROM store_pnl_monthly GROUP BY trading_status;

SELECT CASE WHEN net_sales < 40000 THEN 'a under 40K' WHEN net_sales < 70000 THEN 'b 40-70K' WHEN net_sales < 100000 THEN 'c 70-100K' ELSE 'd 100K+' END AS sales_band,
       COUNT(*) AS n, DECIMAL(100.0 * SUM(labour_cost + labour_burden) / SUM(net_sales), 6, 1) AS labour_pct,
       DECIMAL(100.0 * SUM(store_contribution) / SUM(net_sales), 6, 1) AS contribution_pct
FROM store_pnl_monthly WHERE trading_status = 'Trading' GROUP BY 1 ORDER BY 1;

-- 6. Seasonality of the weather-driven utilities line (Ontario 2019)
SELECT mo, DECIMAL(AVG(mean_temp_c), 6, 1) AS mean_temp_c, DECIMAL(AVG(utilities_cost), 10, 0) AS avg_utilities
FROM store_pnl_monthly WHERE province = 'ON' AND yr = 2019 GROUP BY mo ORDER BY mo;

-- 7. Budget grain and versions
SELECT budget_version, budget_basis, COUNT(*) AS n, MIN(yyyymm) AS min_m, MAX(yyyymm) AS max_m FROM store_budget_monthly GROUP BY budget_version, budget_basis ORDER BY 1, 2;

-- 8. Budget vs actual by year and version: Original 2020 should miss the pandemic, Reforecast should track
SELECT b.budget_version, p.yr,
       DECIMAL(SUM(p.net_sales), 14, 0) AS actual_sales, DECIMAL(SUM(b.budget_net_sales), 14, 0) AS budget_sales,
       DECIMAL(100.0 * (SUM(p.net_sales) - SUM(b.budget_net_sales)) / SUM(b.budget_net_sales), 6, 2) AS sales_var_pct,
       DECIMAL(SUM(p.store_contribution), 14, 0) AS actual_contrib, DECIMAL(SUM(b.budget_store_contribution), 14, 0) AS budget_contrib
FROM store_budget_monthly b
JOIN store_pnl_monthly p ON p.storenumber = b.storenumber AND p.yyyymm = b.yyyymm
GROUP BY b.budget_version, p.yr ORDER BY 1, 2;

-- 9. Monthly 2020 sales variance against the Original plan (pandemic signature)
SELECT p.mo, DECIMAL(100.0 * (SUM(p.net_sales) - SUM(b.budget_net_sales)) / SUM(b.budget_net_sales), 6, 2) AS sales_var_pct_vs_original
FROM store_budget_monthly b
JOIN store_pnl_monthly p ON p.storenumber = b.storenumber AND p.yyyymm = b.yyyymm
WHERE b.budget_version = 'Original' AND p.yr = 2020 AND b.budget_basis = 'LY+growth'
GROUP BY p.mo ORDER BY p.mo;

-- 10. Eyeball one store
SELECT FIRST 6 storenumber, yyyymm, trading_status, net_sales, gross_margin, labour_cost, occupancy_cost, utilities_cost,
       royalty_fee, marketing_fee, total_opex, four_wall_ebitda, store_contribution, contribution_margin_pct
FROM store_pnl_monthly WHERE storenumber = (SELECT MIN(storenumber) FROM stores) ORDER BY yyyymm;
