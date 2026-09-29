-- build_store_budget_monthly.sql -- DROP-and-rebuild of store_budget_monthly,
-- the budget for every line of store_pnl_monthly at the same grain, with a
-- budget_version so variance analysis has a believable story:
--   Original            every store-month. 2019 months: actual x 0.90-1.10
--                       per line (same convention as sales_targets). 2020
--                       months: the 2019 same-month actual x 1.03-1.08
--                       growth x per-line jitter 0.97-1.03, i.e. a plan set
--                       in late 2019 that does not know about the pandemic.
--                       Stores without a 2019 same-month actual (opened
--                       during 2019 or later) fall back to actual x 0.90-1.10.
--   Reforecast Q2 2020  months 2020-04 through 2020-12 only, actual x
--                       0.92-1.08 per line, the re-plan done in April 2020.
-- Budget COGS follows budget sales at the actual gross margin rate, fees
-- follow budget sales at the real franchisee rates, total_opex and
-- contribution are sums of the budgeted lines. All factors are
-- HASH(store + month + line + salt) deterministic.
-- Rows: about 7,900 Original + about 2,950 Reforecast.
-- Requires: store_pnl_monthly.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS bud_base;

CREATE TABLE bud_base AS
SELECT p.storenumber, p.franchisee_id, p.province, p.region, p.store_format, p.yyyymm, p.month_start, p.yr, p.mo,
       p.pandemic_period, p.trading_status,
       p.net_sales, p.cogs, p.transactions, p.labour_cost + p.labour_burden AS labour_cost,
       p.occupancy_cost, p.utilities_cost, p.shrinkage_cost, p.delivery_partner_cost,
       p.card_processing_fees, p.other_opex, p.promo_subsidy_income,
       p.royalty_rate_pct, p.marketing_fee_pct,
       p.gross_margin_pct,
       ly.net_sales AS ly_net_sales, ly.cogs AS ly_cogs, ly.transactions AS ly_transactions,
       ly.labour_cost + ly.labour_burden AS ly_labour_cost,
       ly.occupancy_cost AS ly_occupancy_cost, ly.utilities_cost AS ly_utilities_cost,
       ly.shrinkage_cost AS ly_shrinkage_cost, ly.delivery_partner_cost AS ly_delivery_partner_cost,
       ly.card_processing_fees AS ly_card_processing_fees, ly.other_opex AS ly_other_opex,
       ly.promo_subsidy_income AS ly_promo_subsidy_income
FROM store_pnl_monthly p
LEFT JOIN store_pnl_monthly ly ON ly.storenumber = p.storenumber AND ly.yyyymm = p.yyyymm - 100 AND ly.net_sales > 0;

DROP TABLE IF EXISTS bud_versions;

CREATE TABLE bud_versions AS
SELECT 'Original' AS budget_version, 201901 AS from_yyyymm, DATE('2018-12-15') AS set_date
UNION ALL SELECT 'Reforecast Q2 2020', 202004, DATE('2020-04-10');

DROP TABLE IF EXISTS store_budget_monthly;

CREATE TABLE store_budget_monthly AS
WITH f AS (
  SELECT b.*, v.budget_version, v.set_date,
         CASE WHEN v.budget_version = 'Original' AND b.yr = 2020 AND b.ly_net_sales IS NOT NULL THEN 'LY+growth'
              WHEN v.budget_version = 'Original' THEN 'Actual+-10'
              ELSE 'Actual+-8' END AS basis,
         VARCHAR(b.storenumber) + '|' + VARCHAR(b.yyyymm) + '|' + v.budget_version AS k
  FROM bud_base b
  JOIN bud_versions v ON b.yyyymm >= v.from_yyyymm
), g AS (
  SELECT f.*,
         1.03 + ABS(MOD(HASH(k + 'grow'), 6)) / 100.0 AS growth,
         -- per-line factors
         CASE basis WHEN 'LY+growth' THEN 0.97 + ABS(MOD(HASH(k + 'sal'), 7)) / 100.0
                    WHEN 'Actual+-10' THEN 0.90 + ABS(MOD(HASH(k + 'sal'), 21)) / 100.0
                    ELSE 0.92 + ABS(MOD(HASH(k + 'sal'), 17)) / 100.0 END AS f_sales,
         CASE basis WHEN 'LY+growth' THEN 0.97 + ABS(MOD(HASH(k + 'lab'), 7)) / 100.0
                    WHEN 'Actual+-10' THEN 0.90 + ABS(MOD(HASH(k + 'lab'), 21)) / 100.0
                    ELSE 0.92 + ABS(MOD(HASH(k + 'lab'), 17)) / 100.0 END AS f_labour,
         CASE basis WHEN 'LY+growth' THEN 0.98 + ABS(MOD(HASH(k + 'occ'), 5)) / 100.0
                    WHEN 'Actual+-10' THEN 0.95 + ABS(MOD(HASH(k + 'occ'), 11)) / 100.0
                    ELSE 0.97 + ABS(MOD(HASH(k + 'occ'), 7)) / 100.0 END AS f_occ,
         CASE basis WHEN 'LY+growth' THEN 0.95 + ABS(MOD(HASH(k + 'utl'), 11)) / 100.0
                    WHEN 'Actual+-10' THEN 0.90 + ABS(MOD(HASH(k + 'utl'), 21)) / 100.0
                    ELSE 0.92 + ABS(MOD(HASH(k + 'utl'), 17)) / 100.0 END AS f_utl,
         CASE basis WHEN 'LY+growth' THEN 0.90 + ABS(MOD(HASH(k + 'shr'), 21)) / 100.0
                    WHEN 'Actual+-10' THEN 0.85 + ABS(MOD(HASH(k + 'shr'), 31)) / 100.0
                    ELSE 0.90 + ABS(MOD(HASH(k + 'shr'), 21)) / 100.0 END AS f_shr,
         CASE basis WHEN 'LY+growth' THEN 0.90 + ABS(MOD(HASH(k + 'dlv'), 21)) / 100.0
                    WHEN 'Actual+-10' THEN 0.85 + ABS(MOD(HASH(k + 'dlv'), 31)) / 100.0
                    ELSE 0.90 + ABS(MOD(HASH(k + 'dlv'), 21)) / 100.0 END AS f_dlv,
         CASE basis WHEN 'LY+growth' THEN 0.95 + ABS(MOD(HASH(k + 'oth'), 11)) / 100.0
                    WHEN 'Actual+-10' THEN 0.90 + ABS(MOD(HASH(k + 'oth'), 21)) / 100.0
                    ELSE 0.92 + ABS(MOD(HASH(k + 'oth'), 17)) / 100.0 END AS f_oth,
         CASE basis WHEN 'LY+growth' THEN 0.90 + ABS(MOD(HASH(k + 'sub'), 21)) / 100.0
                    WHEN 'Actual+-10' THEN 0.85 + ABS(MOD(HASH(k + 'sub'), 31)) / 100.0
                    ELSE 0.90 + ABS(MOD(HASH(k + 'sub'), 21)) / 100.0 END AS f_sub
  FROM f
), l AS (
  SELECT g.*,
         CASE basis WHEN 'LY+growth' THEN ly_net_sales * growth * f_sales ELSE net_sales * f_sales END AS b_sales,
         CASE basis WHEN 'LY+growth' THEN ly_transactions * growth * f_sales ELSE transactions * f_sales END AS b_txn,
         CASE basis WHEN 'LY+growth' THEN ly_labour_cost * (1.0 + (growth - 1.0) / 2) * f_labour ELSE labour_cost * f_labour END AS b_labour,
         CASE basis WHEN 'LY+growth' THEN ly_occupancy_cost * 1.02 * f_occ ELSE occupancy_cost * f_occ END AS b_occ,
         CASE basis WHEN 'LY+growth' THEN ly_utilities_cost * f_utl ELSE utilities_cost * f_utl END AS b_utl,
         CASE basis WHEN 'LY+growth' THEN ly_shrinkage_cost * f_shr ELSE shrinkage_cost * f_shr END AS b_shr,
         CASE basis WHEN 'LY+growth' THEN ly_delivery_partner_cost * growth * f_dlv ELSE delivery_partner_cost * f_dlv END AS b_dlv,
         CASE basis WHEN 'LY+growth' THEN ly_net_sales * growth * f_sales * 0.011 ELSE card_processing_fees * f_sales END AS b_card,
         CASE basis WHEN 'LY+growth' THEN ly_other_opex * growth * f_oth ELSE other_opex * f_oth END AS b_oth,
         CASE basis WHEN 'LY+growth' THEN ly_promo_subsidy_income * f_sub ELSE promo_subsidy_income * f_sub END AS b_sub,
         CASE basis WHEN 'LY+growth' THEN 100.0 * (ly_net_sales - ly_cogs) / NULLIF(ly_net_sales, 0) ELSE gross_margin_pct END AS b_gm_pct
  FROM g
), m AS (
  SELECT l.*,
         b_sales * (1.0 - COALESCE(b_gm_pct, 31.5) / 100.0) AS b_cogs,
         b_sales * COALESCE(b_gm_pct, 31.5) / 100.0 AS b_gm,
         b_sales * COALESCE(royalty_rate_pct, 5) / 100.0 AS b_royalty,
         b_sales * COALESCE(marketing_fee_pct, 1) / 100.0 AS b_mkt,
         b_labour + b_occ + b_utl + b_shr + b_dlv + b_card + b_oth AS b_store_opex
  FROM l
)
SELECT storenumber, franchisee_id, province, region, store_format, yyyymm, month_start, yr, mo, pandemic_period,
       budget_version, set_date AS budget_set_date, basis AS budget_basis,
       DECIMAL(b_sales, 12, 2) AS budget_net_sales,
       INT4(b_txn + 0.5) AS budget_transactions,
       DECIMAL(b_cogs, 12, 2) AS budget_cogs,
       DECIMAL(b_gm, 12, 2) AS budget_gross_margin,
       DECIMAL(b_sub, 12, 2) AS budget_promo_subsidy_income,
       DECIMAL(b_labour, 12, 2) AS budget_labour_cost,
       DECIMAL(b_occ, 12, 2) AS budget_occupancy_cost,
       DECIMAL(b_utl, 12, 2) AS budget_utilities_cost,
       DECIMAL(b_shr, 12, 2) AS budget_shrinkage_cost,
       DECIMAL(b_dlv, 12, 2) AS budget_delivery_partner_cost,
       DECIMAL(b_card, 12, 2) AS budget_card_processing_fees,
       DECIMAL(b_oth, 12, 2) AS budget_other_opex,
       DECIMAL(b_store_opex, 12, 2) AS budget_total_store_opex,
       DECIMAL(b_royalty, 12, 2) AS budget_royalty_fee,
       DECIMAL(b_mkt, 12, 2) AS budget_marketing_fee,
       DECIMAL(b_royalty + b_mkt, 12, 2) AS budget_franchise_fees,
       DECIMAL(b_store_opex + b_royalty + b_mkt, 12, 2) AS budget_total_opex,
       DECIMAL(b_gm + b_sub - b_store_opex, 12, 2) AS budget_four_wall_ebitda,
       DECIMAL(b_gm + b_sub - b_store_opex - b_royalty - b_mkt, 12, 2) AS budget_store_contribution,
       DECIMAL(100.0 * (b_gm + b_sub - b_store_opex - b_royalty - b_mkt) / NULLIF(b_sales, 0), 8, 2) AS budget_contribution_margin_pct
FROM m;

DROP TABLE IF EXISTS bud_versions;

DROP TABLE IF EXISTS bud_base;

-- Budget next to actual at the same grain, with variances, so a single
-- semantic model can answer plan-vs-actual questions without a join

DROP TABLE IF EXISTS store_budget_vs_actual;

CREATE TABLE store_budget_vs_actual AS
SELECT b.storenumber, p.storename, b.franchisee_id, b.province, b.region, b.store_format,
       b.yyyymm, b.month_start, b.yr, b.mo, b.pandemic_period, p.trading_status,
       b.budget_version, b.budget_set_date, b.budget_basis,
       p.net_sales AS actual_net_sales, b.budget_net_sales,
       DECIMAL(p.net_sales - b.budget_net_sales, 12, 2) AS sales_variance,
       DECIMAL(100.0 * (p.net_sales - b.budget_net_sales) / NULLIF(b.budget_net_sales, 0), 8, 2) AS sales_variance_pct,
       p.transactions AS actual_transactions, b.budget_transactions,
       p.gross_margin AS actual_gross_margin, b.budget_gross_margin,
       DECIMAL(p.gross_margin - b.budget_gross_margin, 12, 2) AS gross_margin_variance,
       DECIMAL(p.labour_cost + p.labour_burden, 12, 2) AS actual_labour_cost, b.budget_labour_cost,
       DECIMAL(p.labour_cost + p.labour_burden - b.budget_labour_cost, 12, 2) AS labour_variance,
       p.occupancy_cost AS actual_occupancy_cost, b.budget_occupancy_cost,
       p.utilities_cost AS actual_utilities_cost, b.budget_utilities_cost,
       p.shrinkage_cost AS actual_shrinkage_cost, b.budget_shrinkage_cost,
       p.total_store_opex AS actual_total_store_opex, b.budget_total_store_opex,
       DECIMAL(p.total_store_opex - b.budget_total_store_opex, 12, 2) AS store_opex_variance,
       p.franchise_fees AS actual_franchise_fees, b.budget_franchise_fees,
       p.total_opex AS actual_total_opex, b.budget_total_opex,
       DECIMAL(p.total_opex - b.budget_total_opex, 12, 2) AS opex_variance,
       p.four_wall_ebitda AS actual_four_wall_ebitda, b.budget_four_wall_ebitda,
       p.store_contribution AS actual_store_contribution, b.budget_store_contribution,
       DECIMAL(p.store_contribution - b.budget_store_contribution, 12, 2) AS contribution_variance,
       DECIMAL(100.0 * (p.store_contribution - b.budget_store_contribution) / NULLIF(ABS(b.budget_store_contribution), 0), 8, 2) AS contribution_variance_pct,
       p.contribution_margin_pct AS actual_contribution_margin_pct, b.budget_contribution_margin_pct,
       CASE WHEN p.net_sales >= b.budget_net_sales THEN 'Y' ELSE 'N' END AS sales_on_plan,
       CASE WHEN p.total_opex <= b.budget_total_opex THEN 'Y' ELSE 'N' END AS opex_on_plan
FROM store_budget_monthly b
JOIN store_pnl_monthly p ON p.storenumber = b.storenumber AND p.yyyymm = b.yyyymm;

CREATE STATISTICS FOR store_budget_monthly;

CREATE STATISTICS FOR store_budget_vs_actual;
