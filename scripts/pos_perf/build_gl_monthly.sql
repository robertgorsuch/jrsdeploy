-- build_gl_monthly.sql -- DROP-and-rebuild of chart_of_accounts (13 P&L
-- accounts) and gl_monthly, the account-level long form of
-- store_pnl_monthly and store_budget_monthly (one row per store x month x
-- account, 7,891 x 13 = 102,583 rows).
-- SIGN CONVENTION: amounts are SIGNED -- revenue positive, costs negative --
-- so SUM(amount) over all accounts equals store_contribution plus
-- returns_value (returns are carried as account 4010, which the P&L result
-- columns do not net out), and variance = amount - budget is ALWAYS
-- favourable when positive (more revenue or less cost).
-- budget_original is the Original plan, budget_reforecast the Q2 2020
-- re-plan (NULL before 2020-04). Account 4010 Sales Returns has no budget.
-- Labour is one loaded account (wages + burden) so budgets map 1:1.
-- chart_of_accounts.basis says which lines are real vs modeled.
-- Requires: store_pnl_monthly, store_budget_monthly.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS chart_of_accounts;

CREATE TABLE chart_of_accounts AS
SELECT '4000' AS account_code, 'Net Sales' AS account_name, 'Revenue' AS account_group,
       'P&L' AS statement, 'Credit' AS normal_balance, 'Real' AS basis, 10 AS sort_order
UNION ALL SELECT '4010', 'Sales Returns', 'Revenue', 'P&L', 'Debit', 'Real', 20
UNION ALL SELECT '4100', 'Promotion Subsidy Income', 'Revenue', 'P&L', 'Credit', 'Real', 30
UNION ALL SELECT '5000', 'Cost of Goods Sold', 'COGS', 'P&L', 'Debit', 'Real', 40
UNION ALL SELECT '6000', 'Labour (loaded)', 'Labour', 'P&L', 'Debit', 'Real wages, modeled burden', 50
UNION ALL SELECT '6100', 'Occupancy', 'Occupancy', 'P&L', 'Debit', 'Modeled', 60
UNION ALL SELECT '6110', 'Utilities', 'Occupancy', 'P&L', 'Debit', 'Modeled, real weather', 70
UNION ALL SELECT '6200', 'Shrinkage', 'Store Opex', 'P&L', 'Debit', 'Real', 80
UNION ALL SELECT '6210', 'Delivery Partner Cost', 'Store Opex', 'P&L', 'Debit', 'Real orders, modeled commission', 90
UNION ALL SELECT '6220', 'Card Processing Fees', 'Store Opex', 'P&L', 'Debit', 'Modeled', 100
UNION ALL SELECT '6230', 'Other Operating Expense', 'Store Opex', 'P&L', 'Debit', 'Modeled', 110
UNION ALL SELECT '7000', 'Royalty Fee', 'Franchise Fees', 'P&L', 'Debit', 'Real', 120
UNION ALL SELECT '7010', 'Marketing Fee', 'Franchise Fees', 'P&L', 'Debit', 'Real', 130;

DROP TABLE IF EXISTS gl_bud;

CREATE TABLE gl_bud AS
SELECT o.storenumber, o.yyyymm,
       o.budget_net_sales AS o_sales, o.budget_promo_subsidy_income AS o_sub, o.budget_cogs AS o_cogs,
       o.budget_labour_cost AS o_lab, o.budget_occupancy_cost AS o_occ, o.budget_utilities_cost AS o_utl,
       o.budget_shrinkage_cost AS o_shr, o.budget_delivery_partner_cost AS o_dlv,
       o.budget_card_processing_fees AS o_card, o.budget_other_opex AS o_oth,
       o.budget_royalty_fee AS o_roy, o.budget_marketing_fee AS o_mkt,
       r.budget_net_sales AS r_sales, r.budget_promo_subsidy_income AS r_sub, r.budget_cogs AS r_cogs,
       r.budget_labour_cost AS r_lab, r.budget_occupancy_cost AS r_occ, r.budget_utilities_cost AS r_utl,
       r.budget_shrinkage_cost AS r_shr, r.budget_delivery_partner_cost AS r_dlv,
       r.budget_card_processing_fees AS r_card, r.budget_other_opex AS r_oth,
       r.budget_royalty_fee AS r_roy, r.budget_marketing_fee AS r_mkt
FROM store_budget_monthly o
LEFT JOIN store_budget_monthly r ON r.storenumber = o.storenumber AND r.yyyymm = o.yyyymm
     AND r.budget_version = 'Reforecast Q2 2020'
WHERE o.budget_version = 'Original';

DROP TABLE IF EXISTS gl_monthly;

CREATE TABLE gl_monthly AS
WITH g AS (
  SELECT p.storenumber, p.storename, p.franchisee_id, p.province, p.region, p.store_format,
         p.yyyymm, p.month_start, p.yr, p.mo, p.pandemic_period, p.trading_status,
         a.account_code, a.account_name, a.account_group, a.statement, a.normal_balance, a.basis, a.sort_order,
         CASE a.account_code
              WHEN '4000' THEN p.net_sales
              WHEN '4010' THEN p.returns_value
              WHEN '4100' THEN p.promo_subsidy_income
              WHEN '5000' THEN -p.cogs
              WHEN '6000' THEN -(p.labour_cost + p.labour_burden)
              WHEN '6100' THEN -p.occupancy_cost
              WHEN '6110' THEN -p.utilities_cost
              WHEN '6200' THEN -p.shrinkage_cost
              WHEN '6210' THEN -p.delivery_partner_cost
              WHEN '6220' THEN -p.card_processing_fees
              WHEN '6230' THEN -p.other_opex
              WHEN '7000' THEN -p.royalty_fee
              WHEN '7010' THEN -p.marketing_fee
         END AS amount,
         CASE a.account_code
              WHEN '4000' THEN b.o_sales
              WHEN '4100' THEN b.o_sub
              WHEN '5000' THEN -b.o_cogs
              WHEN '6000' THEN -b.o_lab
              WHEN '6100' THEN -b.o_occ
              WHEN '6110' THEN -b.o_utl
              WHEN '6200' THEN -b.o_shr
              WHEN '6210' THEN -b.o_dlv
              WHEN '6220' THEN -b.o_card
              WHEN '6230' THEN -b.o_oth
              WHEN '7000' THEN -b.o_roy
              WHEN '7010' THEN -b.o_mkt
         END AS budget_original,
         CASE a.account_code
              WHEN '4000' THEN b.r_sales
              WHEN '4100' THEN b.r_sub
              WHEN '5000' THEN -b.r_cogs
              WHEN '6000' THEN -b.r_lab
              WHEN '6100' THEN -b.r_occ
              WHEN '6110' THEN -b.r_utl
              WHEN '6200' THEN -b.r_shr
              WHEN '6210' THEN -b.r_dlv
              WHEN '6220' THEN -b.r_card
              WHEN '6230' THEN -b.r_oth
              WHEN '7000' THEN -b.r_roy
              WHEN '7010' THEN -b.r_mkt
         END AS budget_reforecast
  FROM store_pnl_monthly p
  CROSS JOIN chart_of_accounts a
  LEFT JOIN gl_bud b ON b.storenumber = p.storenumber AND b.yyyymm = p.yyyymm
)
SELECT storenumber, storename, franchisee_id, province, region, store_format,
       yyyymm, month_start, yr, mo, pandemic_period, trading_status,
       account_code, account_name, account_group, statement, normal_balance, basis, sort_order,
       DECIMAL(amount, 12, 2) AS amount,
       DECIMAL(budget_original, 12, 2) AS budget_original,
       DECIMAL(budget_reforecast, 12, 2) AS budget_reforecast,
       DECIMAL(amount - budget_original, 12, 2) AS variance_vs_original,
       DECIMAL(amount - budget_reforecast, 12, 2) AS variance_vs_reforecast,
       CASE WHEN amount - budget_original >= 0 THEN 'Y'
            WHEN budget_original IS NULL THEN NULL ELSE 'N' END AS favourable_vs_original
FROM g;

DROP TABLE IF EXISTS gl_bud;

CREATE STATISTICS FOR chart_of_accounts;

CREATE STATISTICS FOR gl_monthly;
