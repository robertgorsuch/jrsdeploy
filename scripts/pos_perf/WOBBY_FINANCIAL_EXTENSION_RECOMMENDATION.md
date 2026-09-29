# Wobby POS Sales Analyst: financial extension of the semantic layer

Recommendation, 2026-08-23. Source of truth: GET /api/public/v1/environment
exported 2026-08-23T17:59Z. Analyst agent_ak2os72a8 "Sales Analyst", the
only analyst in the environment. 29 models, 37 relationships, 56 metrics,
33 glossary terms, all on data source "POS Data" = robert.gorsuch on
pos_data (av-flm7ykoxlcvq).

## 1. Current state of the semantic layer

| Domain | Models | Financial measures available today |
|---|---|---|
| Sales | pos_sales_detail, products, promotions, marketing_campaigns, date_dim | net sales, COGS, gross margin and rate, discount, promo discount, subsidy, expected subsidy, royalty sales |
| Stores and people | stores, franchisees, employees, shift_schedules, store_traffic, weather_daily, competitor_locations, sales_targets | lifetime sales and margin per store, est. royalty and marketing fee per franchisee (lifetime), hourly wage, scheduled hours, target sales / margin / transactions per store-month |
| Customers | customers, customer_demographics, customer_diet_profile, customer_ipt_stats, customer_month, customer_churn_scores, loyalty_ledger, email_engagement, gift_cards, customer_service_cases, ecommerce_orders | lifetime revenue, monthly sales and margin, points earned and redeemed, gift card liability, LTV at risk, ecommerce order value and delivery fee |
| Supply | inventory, purchase_orders, suppliers, shrinkage_log | inventory value at cost and retail, GMROI, PO cost value, shrink value |

What is missing, in order of how often a retail finance question would hit
the gap:

1. No operating expenses of any kind, so no P&L, no store contribution, no
   four-wall margin, no EBITDA. The analyst can say what a store sold and
   what it cost to buy, nothing about what it cost to run.
2. No time series for franchise fees. Royalty and marketing fee exist only
   as lifetime estimates on franchisees. "Royalty billed in Q3 2020" cannot
   be answered.
3. No budget beyond sales, margin and transactions, so no opex variance.
4. No payment or tender data: cash vs card vs gift card vs points, card
   processing cost, cash over/short.
5. No payables or receivables: when suppliers were paid, whether franchisees
   paid their fees, aging, DPO, DSO.
6. No tax: GST/HST/PST by province, the zero-rated basic-grocery rule.
7. No liability roll-forward for loyalty points or gift cards by month.
8. No cost or price history per PLU, so no margin bridge (price vs cost vs
   mix) and no cost-inflation view.

## 2. Defects in the current layer to fix first

These cost nothing in new data and change answers the analyst gives today.

| Defect | Evidence | Fix |
|---|---|---|
| total_labour_cost is hours, not cost | metric expression = shift_schedules.total_scheduled_hours, same as total_labour_hours. Instructions promise "hours x wage proxy" | Build labour cost (section 3, table A) or add a measure SUM(scheduled_hours * employees.hourly_wage). The real number is available today: 3,377,504 hours x wage = 70,225,002 CAD (9.2 percent of sales) |
| customer_demographics, customer_diet_profile and customer_month have no relationships | 37 relationships, none touch these three models | Add one_to_one customer_demographics -> customers, customer_diet_profile -> customers, many_to_one customer_month -> customers, customer_month -> date_dim (yyyymm). Until then age band, life stage and diet profile cannot be joined to sales, churn or anything else |
| Risk band thresholds in the instructions are wrong | Instructions: Low < 0.3, Watch 0.3-0.5, High 0.5-0.75, Critical > 0.75. customer_churn_scores actual: Watch >= 0.25, High >= 0.45, Critical >= 0.70 | Edit the Model Reference block in the instructions |
| Instructions say 52 metrics, the layer has 56 | total_ltv_at_risk_by_overdue, avg_overdue_ratio, pct_customers_overdue, avg_days_to_expected_next_purchase are unlisted | Add them to the metrics reference |
| Transaction-level measures run COUNT DISTINCT over 63.6M lines | avg_basket_value, total_transactions on pos_sales_detail | Model pos_sales_txn (already built, 19.5M rows, one per transaction) as "transactions" with basket_value, basket_margin, promo_flag, ecommerce_flag; point basket and transaction metrics at it |

### Status: all five fixed on 2026-08-23 (Step 0 done)

Applied with scripts/pos_perf/wobby_fix_defects.py (PUT 200: created 8,
updated 7, deleted 0) after alter_shift_schedules_labour_cost.sql added the
real labour_cost column. The environment now has 30 models, 43
relationships, 57 metrics. Backup of the pre-fix export:
out/pos_perf/wobby_env_backup_20260823.json (gitignored); post-fix export
next to it.

| Defect | What was done |
|---|---|
| labour cost | shift_schedules.labour_cost column (482,460 rows, 70,225,001.95 CAD); measure total_labour_cost = SUM(labour_cost); metric repointed; guidance rewritten |
| missing relationships | demographics_to_customer (1:1), diet_profile_to_customer (1:1), customer_month_to_customer (N:1) |
| risk bands | instructions now read Low < 0.25, Watch 0.25-0.45, High 0.45-0.70, Critical >= 0.70 |
| metric reference | the 4 unlisted metrics added, count corrected to 57 |
| transaction metrics | new model `transactions` on pos_sales_txn (20 dims, 16 measures, 4 filters, relationships to customers, stores, date_dim); total_transactions, avg_basket_size, avg_items_per_basket repointed to it; new metric transactions_by_product keeps category-level counts on the line fact; querying rule and model reference updated |

One residual: the public PUT does not change the measure grant list of an
existing access entry (three approaches tried: same body, analyst text
change, remove-and-re-add). The total_labour_cost METRIC is granted, so
query_metric is fixed. To expose the total_labour_cost MEASURE for direct
model queries, toggle it on for the Sales Analyst in the Wobby UI
(semantic layer access, shift_schedules).

### Status: Step 1 built and registered 2026-08-23 (A and B)

| Table | Rows | Script | Notes |
|---|---|---|---|
| store_pnl_monthly | 7,891 (330 stores, open month to 2020-12) | build_store_pnl_monthly.sql | Sales, COGS, margin and shrink reconcile to the cent; labour 69.98M of 70.23M (shifts before a store opens are excluded). trading_status marks 172 Closed months (13 stores closed before 2020-12) and 13 No-sales months |
| store_budget_monthly | 10,854 (7,891 Original + 2,963 Reforecast Q2 2020) | build_store_budget_monthly.sql | 2020 Original = 2019 same-month actual + 3-8 pct growth, blind to the pandemic; Reforecast = actual +-8 pct |
| store_budget_vs_actual | 10,854 | same script | budget next to actual with variances, one model for plan-vs-actual |
| verify_store_pnl.sql | | | 11 checks |

Network P&L (trading months): COGS 68.3, gross margin 31.7, loaded labour
10.4, occupancy 5.1, utilities 1.1, shrink 0.25, card fees 1.2, other 2.2,
franchise fees 6.3, four-wall EBITDA 12.4, contribution 6.1 percent of
sales. Four-wall by format: Standalone 14.2, Strip Plaza 13.4, Urban
Storefront 12.1, Shopping Mall 9.3 (occupancy 7.7). Utilities follow the
real temperature: Ontario 1,427 CAD in January, 863 in July.

Budget story as designed: 2019 actual vs Original -0.03 percent; 2020 vs
Original +13.0 percent with the pandemic stock-up at +40.5 (March) and
+42.0 (April); 2020 vs Reforecast +0.07 percent.

Known property, not a defect: shift_schedules is a flat two-shift schedule,
about 8.8K CAD of labour per store-month regardless of volume, so stores
under 70K monthly sales run negative contribution (33 percent of trading
store-months, 17 percent labour at 40-70K, 38 percent under 40K). If the
demo needs fewer red months, rebuild shift_schedules scaled by store volume
and re-run the P&L.

Registered in Wobby with wobby_add_pnl_models.py (PUT 200: created 29,
updated 1): models store_pnl (13 dims, 35 measures, 3 filters) and
store_budget (17 dims, 27 measures, 3 filters) with relationships to
stores and franchisees, 15 finance metrics (total_opex, store_contribution,
contribution_margin_pct, four_wall_ebitda, four_wall_margin_pct,
loaded_labour_pct_of_sales, occupancy_pct_of_sales, total_royalty_revenue,
total_marketing_fee_revenue, total_promo_subsidy_income, budget_net_sales,
budget_store_contribution, sales_variance_vs_budget, opex_variance_vs_budget,
contribution_variance_vs_budget), 8 glossary terms, and a Finance section in
the instructions. Environment now 32 models / 47 relationships / 89
metrics / 41 glossary terms (17 metrics were added by someone else between
the defect fix and this step; the script layers on the live export so they
are preserved). Check in the UI that the access entries for store_pnl,
store_budget and transactions (exported name-only, like the glossary
mode ALL) expose all measures.

### Status: Step 2 built and registered 2026-08-23 (C)

chart_of_accounts (13 P&L accounts with group, normal balance, real-vs-
modeled basis, sort order) and gl_monthly (102,583 rows = 13 accounts x
7,891 store-months) built by build_gl_monthly.sql. Amounts are SIGNED
(revenue positive, costs negative), so SUM over accounts = store
contribution plus sales returns, and variance vs budget is favourable
whenever positive -- no per-account sign logic anywhere. budget_original
covers every month, budget_reforecast is NULL before 2020-04, Sales
Returns (4010) has no budget. Tie-outs: 0 store-months deviate from the
P&L beyond 5 cents; gross margin via the GL matches exactly.

Registered by wobby_add_gl_models.py (PUT 200: created 10, updated 2):
models gl and accounts, relationships gl -> accounts / stores /
franchisees, metrics gl_amount, gl_budget_original,
gl_variance_vs_original, glossary Chart of Accounts and Favourable
Variance, model and metric reference in the instructions. Environment now
43 models / 50 relationships / 92 metrics / 43 glossary terms.

Concurrent-editing note: between steps someone added 9 models in the UI
(dash_* aggregates, the ML training sets, pos_sales_detail_v). One of
them, dash_kpi, is a deliberate single-row model with no dimensions; the
UI allows that but the PUT validator does not, so the first PUT failed 422
on a round-trip of the server's own export. wobby_add_gl_models.py now
guards this: any dimension-less model gets one constant period_label
dimension, documented as sync-only. All Wobby scripts here GET fresh
before building, so concurrent UI work is preserved.

### Status: Step 3 built and registered 2026-08-23 (D)

tender_summary_daily built by build_tender_summary_daily.sql: 1,823,991
rows across all 229,594 real store-days, eight tender types. REAL: store-
day totals (each day's tenders sum to that day's Regular Sale total, zero
days off by more than a dime), the Loyalty Points tender (ledger REDEEM
events at 1,000 points per CAD, 266K CAD), and the Gift Card tender in
aggregate (1,691,344 vs the 1,692,491 lifetime redemptions -- the 0.07 pct
gap is per-row cent rounding). MODELED: the six-way payment split with the
designed cashless shift (cash 22.1 to 10.1 pct, mobile 6.0 to 14.9 pct at
2020-03; cashless share 77.9 to 89.9 pct).

card_processing_fees in store_pnl_monthly is now DERIVED from the tender
mix (7,607,921.36 CAD, both sides equal to the cent; effective rate 0.89
pct pre-pandemic, 1.12 pct pandemic) instead of a flat modeled rate, and
the budget and GL were rebuilt on top (all tie-outs still pass). Build
order is now: tenders -> P&L -> budget -> GL.

Gotcha for the record: Ingres DECIMAL / DECIMAL division truncates scale
(1.69M / 764M came out 0.00, silently zeroing the gift tender on the first
run) -- wrap ratio computations in FLOAT8().

Registered by wobby_add_tender_models.py (PUT 200: created 8, updated 2):
model tenders (10 dims, 8 measures, 3 filters), relationships to stores
and date_dim, metrics tender_amount, total_card_processing_fees,
cashless_share_pct, glossary Tender and Interchange, and the store_pnl
description updated (card fees now derived). Environment: 44 models / 52
relationships / 95 metrics / 58 glossary terms.

Note on the instructions: they are now being reformatted in the Wobby UI
(the markdown metric table is flattened to the UI structure, and the
UI-side edits merged the finance metrics in). The three tender metric rows
could not be anchored into that format from the API -- add them in the UI
if the reference table should list them; the metrics themselves are live
and granted.

### Status: Step 4 built and registered 2026-08-23 (E and F)

Both built by build_ap_franchise_fees.sql, as-of date 2020-12-31.

ap_invoices (92,472 rows, one per PO, 524.2M CAD): REAL po/supplier/store/
amount/invoice date (order date + real lead time) and terms (Net 30/45/60);
modeled deterministic payment behaviour (10 pct early with discount -- 2 pct
on Net 30, 1 pct otherwise -- 70 pct on time, 20 pct late 1-20 days).
Results: 89,058 Paid, 3,211 Open (29.3M, year-end invoices not yet due),
203 Overdue (1.08M). DPO 26.2 / 39.6 / 52.9 days on Net 30/45/60, 80 pct
on time, 793,522 CAD of early-pay discounts captured.

franchise_fee_ledger (7,706 rows, one per fee-bearing store-month): fees
tie to store_pnl_monthly TO THE CENT (47,971,634.88 = 38.86M royalty +
9.11M marketing). Invoiced month end, due +15; 80 pct on time, 16 pct late
1-45 days, 4 pct unpaid. Results: 7,134 Paid, 317 Open (3.76M December
fees inside term), 255 Overdue (1.64M, of which 1.27M aged 60+ days) --
named delinquents by owner for the collections story.

Registered by wobby_add_ap_models.py (PUT 200: created 19, updated 1):
models payables (13 dims, 9 measures, 3 filters; relationships to
suppliers, stores, purchase_orders) and franchise_fees (14 dims, 10
measures, 2 filters; relationships to franchisees, stores); metrics
ap_outstanding, avg_days_to_pay (DPO), ap_pct_paid_on_time,
early_pay_discounts_taken, franchise_fees_invoiced,
franchise_fees_collected, ar_outstanding, ar_pct_paid_on_time; glossary
DPO, AP Aging, AR Aging, Early-Payment Discount; model references added to
the instructions (the metric table itself is UI-managed now, left alone).
Environment: 46 models / 57 relationships / 103 metrics / 62 glossary
terms.

### Status: Step 6 built and registered 2026-08-23 (I, J, K)

All four tables by build_pricebook_tax_assets.sql:

| Table | Rows | Highlights |
|---|---|---|
| pricebook_history (REAL) | 16,088 (942 PLUs x months sold) | sales tie to the line fact within 102 CAD (mixed-type transactions); network cost inflation 0.1-0.25 pct per month; nameable spikes (Stuffed Turkey Breast +255 pct cost in 2020-08) for margin-bridge stories |
| provincial_tax_rates (REAL rates) | 13 | GST/HST/QST/PST/RST 2019-2020 incl. the REAL Manitoba RST cut 8 to 7 pct on 2019-07-01, effective-dated |
| tax_collected_monthly (derived) | 7,706 | 28.1M collected (11.7M GST + 16.4M provincial); taxable share 30.6 pct (Prepared meals, Single serve, Appetizers, Desserts, Kitchen essentials; uncatalogued PLUs zero-rated, conservative); MB cut visible at 201907. Remittance liability, never revenue, not in the P&L |
| store_assets (modeled, anchored) | 330 | 194.6M build cost, NBV 156.6M at 2020-12-31, 1.83M monthly depreciation (NOT in the P&L), lease expiries cluster 2024 (169 stores) and 2028, 50 stores refitted in 2020 for refit-ROI vs store_traffic |

Two build gotchas for the record: a semicolon inside a header comment split
the file (the run-file splitter rule bites even in this repo), and the
month-over-month percent columns overflow DECIMAL when a small prior cost
makes the change huge -- ratio math is wrapped in FLOAT8 (same class of bug
as the gift-tender scale in Step 3).

Registered by wobby_add_pricing_models.py (PUT 200: created 20, updated 1):
models pricebook, tax_rates, sales_tax, store_assets with 4 relationships,
metrics avg_cost_change_pct, avg_price_change_pct, price_cost_spread,
tax_collected, taxable_sales_share_pct, total_depreciation,
total_net_book_value, glossary Pricebook, Margin Bridge, Zero-Rated, HST,
Net Book Value. Environment: 50 models / 61 relationships / 110 metrics /
67 glossary terms.

IMPORTANT -- instructions are now UI-owned: the UI-side curation of the
analyst instructions removed the API-added payables/franchise_fees model
reference, so API scripts no longer touch the instructions. If the model
reference section should cover the finance models, paste something like
this in the UI:

    payables / franchise_fees: supplier invoices per PO (DPO, aging,
    early-pay discounts; big Current balance is year-end normal) and
    franchisee fee invoices per store-month (tie to store_pnl to the cent;
    60+ days bucket is true delinquency, group by owner_name).
    pricebook: monthly cost and price per PLU (real). Cost inflation,
    pass-through, margin bridge. Exclude MoM changes beyond +-50 pct.
    sales_tax + tax_rates: GST/HST/PST collected per store-month, taxable
    share ~31 pct, MB RST cut 8->7 at 2019-07 (real). Remittance
    liability, never revenue, not in the P&L.
    store_assets: build cost, depreciation (not in the P&L), NBV, lease
    expiries cluster 2024/2028, 50 stores refitted 2020 (refit ROI vs
    store_traffic).

### Status: Step 5 built and registered 2026-08-23 (G and H) -- ALL 11 TABLES DONE

build_liability_monthly.sql: loyalty_liability_monthly (24 rows, real
flows, 1,000 points per CAD -- closing 2020-12 ties to the ledger sum
exactly, about 7.37M CAD) and gift_card_liability_monthly (24 rows, real
issued value, redemption timing modeled 0-3 months, closing ties to
gift_cards outstanding to the cent, 1,694,634.25). Registered as models
loyalty_liability and gift_card_liability with metrics
loyalty_liability_cad and gift_card_liability_cad and glossary Deferred
Revenue and Breakage (part of the wobby_refinements.py PUT). The full
11-table finance extension is now complete.

## 3. Recommended tables

Grain, anchoring and the questions each unlocks. REAL = derived from the
fact or existing tables. MODELED = hash-deterministic from HASH(key + salt),
anchored to real totals, consistent with every other build in
scripts/pos_perf. No column names a vendor or third-party source.

### Tier 1: the P&L backbone

**A. store_pnl_monthly** (store x month, 330 x 24 = 7,920 rows). The single
most valuable addition. One row per store per month with the full
contribution statement.

| Column | Basis | Derivation |
|---|---|---|
| storenumber, yyyymm, franchisee_id, province, region, store_format | key | stores |
| net_sales, returns_value, cogs, gross_margin, transactions, units | REAL | pos_sales_txn by store-month, Regular Sale and Regular Return |
| promo_subsidy_income, expected_subsidy | REAL | pos_sales_detail subsidy and marketingsubsidy (8.17M and 3.54M lifetime) |
| royalty_fee | REAL | royalty_base_sales x franchisees.royalty_rate_pct (4, 5 or 6 percent) |
| marketing_fee | REAL | net_sales x franchisees.marketing_fee_pct (1 or 2 percent) |
| labour_cost, labour_hours | REAL | shift_schedules.scheduled_hours x employees.hourly_wage, plus a burden_pct column (modeled, 12 to 18 percent by province) for CPP/EI/vacation |
| occupancy_cost | MODELED | square_feet x monthly rate per sqft by store_format and province (mall highest, standalone lowest), flat across months |
| utilities_cost | MODELED | base by square_feet plus a seasonal term from weather_daily monthly mean temperature (heating in winter, freezers in summer), so it moves with the real weather table |
| shrinkage_cost | REAL | shrinkage_log by store-month |
| delivery_partner_cost | REAL | ecommerce_orders delivery orders x partner commission (modeled 18 to 22 percent of order value by partner) minus delivery_fee collected |
| card_processing_fees | DERIVED | from table D tender mix x fee schedule |
| other_opex | MODELED | 1.5 to 3 percent of sales, hash by store |
| total_opex, store_contribution, contribution_margin_pct, four_wall_ebitda | computed | contribution = gross_margin + promo_subsidy_income - total_opex |
| pandemic_period | REAL | date_dim |

Unlocks: store P&L, four-wall margin ranking, franchisee profitability,
labour as percent of sales, occupancy burden by format, pandemic impact on
contribution, region margin bridge.

**B. store_budget_monthly** (same grain as A). Budget for every line in A,
calibrated 90 to 110 percent of actual like sales_targets, plus
budget_version (Original, Reforecast Q2 2020 for the pandemic). Keep
sales_targets for compatibility; point the Plan vs Actuals metrics at B.
Unlocks: opex variance, labour over budget, margin vs plan by store.

**C. chart_of_accounts + gl_monthly** (long form of A and B). gl_monthly is
one row per store x month x account (about 7,920 x 22 accounts = 174K
rows) with account_code, amount, budget_amount, debit_credit.
chart_of_accounts is the dimension: account_code, account_name,
account_group (Revenue, COGS, Gross Margin, Labour, Occupancy, Marketing,
Franchise Fees, Other Opex, Contribution), statement (P&L, Balance Sheet),
sort_order. Unlocks: "show me the P&L for Ontario in 2020" as a single
grouped query, account-level drill-down, and a natural place for balance
sheet lines (gift card liability, loyalty liability, AP, AR) from Tier 2.

### Tier 2: working capital and cash

**D. tender_summary_daily** (store x day x tender_type, about 1.4M rows).
Tender types Cash, Debit, Credit Visa, Credit Mastercard, Credit Amex,
Gift Card, Loyalty Points, Mobile Wallet. Amounts split from the REAL
store-day sales total (store_traffic) with a hash-drawn mix that shifts
toward cards and mobile after 2020-03 (pandemic). gift_card and
loyalty_points tenders reconcile to gift_cards.redeemed_amount and
loyalty_ledger REDEEM entries. Fee schedule: Debit flat 0.06, Visa/MC 1.6
percent, Amex 2.4 percent, Mobile 1.8 percent, so card_processing_fees in
A is derived, not invented. Optional transaction grain: a tender_type
column on pos_sales_txn. Unlocks: tender mix, processing cost, cash
handling, cashless shift through the pandemic.

**E. ap_invoices** (one per purchase order, 92,472 rows). invoice_number,
po_number, supplier_name, storenumber, invoice_date (= receipt date),
payment_terms from suppliers (Net 30/45/60), due_date, paid_date
(hash-drawn around due: 70 percent on time, 20 percent late 1 to 20 days,
10 percent early with 1 to 2 percent discount), amount = po_value_cost,
discount_taken, status (Paid, Open, Overdue as of 2020-12-31),
days_to_pay. Unlocks: DPO, AP aging, early-payment capture, supplier
payment behaviour by store.

**F. franchise_fee_ledger** (franchisee x store x month, about 7,920 rows).
royalty_fee and marketing_fee from A, invoice_date (month end), due_date
(+15), paid_date (hash-drawn: 80 percent on time, the rest 1 to 45 days
late, a few Open), amount_paid, balance, status, days_late. Unlocks: AR
aging, collections, delinquent franchisees, royalty revenue by month for
the franchisor view.

**G. loyalty_liability_monthly** (month, optional store, 24 to 7,920
rows). points_earned, points_redeemed, points_expired (modeled, 24-month
expiry), closing_balance, point_value_cad, liability_cad, breakage_pct.
The ledger holds 7.37B points outstanding with no defined value. Decide
point_value explicitly: at 1,000 points per CAD the liability is 7.4M
(about 1 percent of sales, typical); at 100 per CAD it would be 73.7M.
Unlocks: deferred revenue, breakage, programme cost as percent of sales.

**H. gift_card_liability_monthly** (month, 24 rows). issued, redeemed,
breakage, closing_liability. gift_cards has purchase_date but no redemption
date, so redemption timing is modeled (60 percent within 90 days). Balance
reconciles to gift_cards.outstanding_liability at 2020-12-31.

### Tier 3: pricing, tax, assets

**I. pricebook_history** (PLU x month, about 22,600 rows). avg
pricebookcost, pricebookregularprice, pricebooksaleprice, avg sellingprice,
units, all REAL from pos_sales_detail, plus cost_change_pct and
price_change_pct vs prior month. Unlocks: cost inflation, price
pass-through, margin bridge (price / cost / mix), which PLUs lost margin
in 2020.

**J. provincial_tax_rates** (province x effective_date, about 15 rows) with
gst_pct, pst_pct, hst_pct, and a taxable rule: basic groceries zero-rated,
prepared meals and single-serve taxable. Add tax_collected to pos_sales_txn
or A. Unlocks: tax remittance by province, taxable share of sales.

**K. store_assets** (store, 330 rows, optional refit events). build_cost,
open_date (real), last_refit_date, refit_cost, equipment_value,
monthly_depreciation, lease_expiry. Unlocks: refit ROI (sales lift after
refit using store_traffic), depreciation line in the P&L, lease cliff
analysis.

## 4. Semantic layer additions per table

| Table | Model name | Relationships | Metrics to add |
|---|---|---|---|
| store_pnl_monthly | store_pnl | -> stores, -> franchisees, -> date_dim (yyyymm) | total_opex, total_labour_cost (replace), labour_pct_of_sales, occupancy_pct_of_sales, store_contribution, contribution_margin_pct, four_wall_ebitda, total_royalty_revenue, total_marketing_fee_revenue |
| store_budget_monthly | store_budget | -> store_pnl (store, month), -> stores | budget_sales, budget_opex, budget_contribution, sales_variance, opex_variance, contribution_variance_pct |
| gl_monthly + chart_of_accounts | gl, accounts | gl -> accounts, gl -> stores, gl -> date_dim | gl_amount, gl_budget, gl_variance; filters by account_group |
| tender_summary_daily | tenders | -> stores, -> date_dim | tender_amount, card_processing_fees, cash_share_pct, cashless_share_pct |
| ap_invoices | payables | -> purchase_orders, -> suppliers, -> stores | ap_outstanding, avg_days_to_pay (DPO), pct_paid_on_time, early_pay_discount_taken, ap_overdue |
| franchise_fee_ledger | franchise_fees | -> franchisees, -> stores, -> date_dim | fees_invoiced, fees_collected, ar_outstanding, avg_days_late, pct_paid_on_time |
| loyalty_liability_monthly | loyalty_liability | -> date_dim | loyalty_liability_cad, breakage_pct, points_outstanding |
| gift_card_liability_monthly | gift_card_liability | -> date_dim | gift_card_liability_cad, gift_card_breakage |
| pricebook_history | pricebook | -> products, -> date_dim | avg_cost, avg_regular_price, cost_change_pct, price_change_pct, price_cost_spread |
| provincial_tax_rates | tax_rates | stores -> tax_rates (province) | tax_collected, taxable_sales_share |
| store_assets | store_assets | -> stores | total_depreciation, refit_roi |

Glossary terms to add: Four-Wall Margin, Store Contribution, Occupancy
Cost, Labour Burden, Royalty Fee, Marketing Fee, Tender, Interchange,
DPO, DSO, AP Aging, Breakage, Deferred Revenue, Zero-Rated, HST,
Margin Bridge, Budget Version, Reforecast.

Instructions to update: the Metrics Reference (56 today plus the new ones),
the SCOR Cost row (real labour cost, card fees, occupancy), the risk band
thresholds, and a new "Finance" section stating that opex lines are
modeled and anchored while sales, COGS, fees, labour, shrink and subsidy
are real.

## 5. Build order and effort

| Step | Deliverable | Rows | Effort |
|---|---|---|---|
| 0 | Fix labour cost metric, add the three missing relationships, correct risk bands and metric count in instructions, model pos_sales_txn | - | 1 hour, PUT environment |
| 1 | store_pnl_monthly (A), store_budget_monthly (B) | 7,920 each | 0.5 day |
| 2 | chart_of_accounts, gl_monthly (C) | 22 / 174K | 0.25 day |
| 3 | tender_summary_daily (D) and card fees back into A | 1.4M | 0.5 day |
| 4 | ap_invoices (E), franchise_fee_ledger (F) | 92K / 7.9K | 0.5 day |
| 5 | loyalty_liability_monthly (G), gift_card_liability_monthly (H) | 24 each | 0.25 day |
| 6 | pricebook_history (I), provincial_tax_rates (J), store_assets (K) | 22.6K / 15 / 330 | 0.5 day |
| 7 | Models, relationships, metrics, glossary, instructions; PUT environment (one call, 2 req per 5 s limit) | - | 0.5 day |

Each build is a DROP-and-rebuild script in scripts/pos_perf with a
verify_*.sql, following the HASH(salt) convention. Every modeled line is
anchored to a real total so the P&L reconciles to pos_sales_txn to the
cent on sales, COGS and margin.

## 6. Two design decisions to make before building

- Loyalty point value. The ledger has 7.37B points outstanding and no
  value. Recommend 1,000 points per CAD (1 percent earn rate), which puts
  the liability at 7.4M. This number flows into G, C and the glossary.
- Whose P&L. store_pnl_monthly as specified is the franchisee view
  (royalty and marketing fee are costs). The franchisor view is the
  mirror: fees are revenue, store opex is not theirs. The gl_monthly
  account structure handles both with an entity column (Store,
  Franchisor); decide whether the analyst should answer franchisor
  questions, because the instructions currently frame it as a network
  analyst, not a corporate finance one.
