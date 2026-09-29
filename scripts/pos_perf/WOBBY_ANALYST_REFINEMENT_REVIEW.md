# Wobby POS Sales Analyst: refinement review

2026-08-23, against the environment export of 20:48Z (50 models, 61
relationships, 110 metrics, 67 glossary terms) and the live robert.gorsuch
catalog (49 tables). Read-only review; nothing was changed.

## 0. Status: ALL TEN ITEMS EXECUTED 2026-08-23

Applied by wobby_refinements.py (single PUT, 200: created 9, updated 13,
deleted 0) plus build_liability_monthly.sql, verified against a fresh GET:
risk bands corrected in all 3 places (0 old remaining), plan-arbitration
and fee-authority rules added, franchise_fee_burden_pct repointed to the
real monthly ledger (legacy estimates marked), training-set guidance
corrected AND both models removed from analyst access, the 5 dash_* models
and pos_sales_detail_v removed from access (guidance labelled fast-path),
3 pricebook metrics granted, 8 lifecycle dimensions exposed on customers,
transactions -> promotions relationship added, the 17 finance metrics and
7 finance models documented in the reference, and Step 5 built:
loyalty_liability_monthly (closing 7,367,650,182 points = the ledger sum,
7.37M CAD at 1,000 pts/CAD) and gift_card_liability_monthly (closing
1,694,634.25 = gift_cards outstanding TO THE CENT), registered as
loyalty_liability / gift_card_liability with 2 metrics and glossary terms
Deferred Revenue and Breakage. Environment: 52 models / 64 relationships /
112 metrics / 69 glossary terms. Build gotcha for the record: an
apostrophe in a SQL comment collapsed the run-file into one statement (the
documented splitter trap).

## 1. Where the analyst stands

Strong. Every warehouse table except store_budget_monthly (superseded by
store_budget_vs_actual, by design) is modeled -- full coverage of sales,
customers, churn, supply, workforce, and the new finance stack (P&L,
budget, GL, tenders, AP/AR, pricebook, tax, assets). The instructions have
been professionally curated in the UI: an efficiency rule that skips
semantic search for known metrics, a hardened pandemic_period warning, a
Defaults & Caveats table, and analysis patterns per domain. The UI pass
also fixed the last access residual (shift_schedules now grants
total_labour_cost) and normalised all 49 access entries.

The refinements below are ordered by how wrong an answer gets if they are
not made.

## 2. Fix now -- these produce wrong answers today

### 2.1 Churn risk bands are wrong in three places (regression)

The instructions state "Low (<0.3), Watch (0.3-0.5), High (0.5-0.75),
Critical (>0.75)" in the Model Reference, in the Churn & Retention pattern
(labelled "Correct risk bands"), and in Defaults & Caveats. The
customer_churn_scores table actually uses Watch >= 0.25, High >= 0.45,
Critical >= 0.70 (verified against the data; also stated in the model's
own description). This was fixed via the API on the morning pass and the
UI rewrite restored the old values. Any answer that re-derives bands from
churn_probability will disagree with risk_band. Fix in the UI, all three
places.

### 2.2 churn_training_set model guidance misdescribes the grain

The model says "one row per customer per month... is_scoring_row = Y marks
the most recent month per customer." Actually: one row per customer per
CUTOFF -- 16 month-end cutoffs (2019-07 to 2020-09 plus 2020-12-31), not
every month; is_scoring_row = Y is the single 2020-12-31 scoring snapshot
(2,095,432 rows); churn labels are NULL when the horizon is right-censored.
Worse, the same customer appears up to 16 times, so any SUM across the
table (sales_asof, LTV) is inflated up to 16x.

Recommendation: remove churn_training_set and activation_training_set from
the analyst's access entirely. They are ML plumbing, not analytics -- every
business question they could answer is answered correctly by
customer_churn_scores, customer_ipt_stats or customer_month. If they stay,
rewrite the guidance with the cutoff grain and a "never SUM across
cutoffs" warning.

### 2.3 Two plan systems with materially different numbers, no arbitration

"Did we hit plan in 2020?" has two answers: sales_targets says plan was
415.2M (calibrated 90-110 pct of actuals -- actual 416.5M, attainment
100.3) while store_budget Original says 368.6M (set pre-pandemic, actual
+13 pct). Both are legitimate stories; the analyst has no rule for which
to use, and the Plan vs Actuals pattern only mentions sales_targets.

Recommendation, one Defaults row plus a pattern update: sales_targets =
OPERATIONAL targets (store-manager attainment, always close to actual);
store_budget = FINANCIAL plan (Original shows the pandemic upheaval,
Reforecast shows discipline after April 2020). Default "plan" questions to
sales_targets unless the user says budget, variance, reforecast or P&L.

### 2.4 Two fee systems, close but not equal

franchisees.est_royalty_paid / est_marketing_fee (lifetime estimates:
38.81M / 9.10M) vs the real monthly royalty_fee / marketing_fee in
store_pnl and franchise_fees (38.86M / 9.11M) -- about 0.14 pct apart, so
answers differ by path. total_royalty_cost and franchise_fee_burden_pct
anchor on the estimates; total_royalty_revenue and franchise_fees_invoiced
on the real ledger.

Recommendation: declare the monthly ledger authoritative. Repoint
franchise_fee_burden_pct to store_pnl (franchise_fees / net_sales), mark
total_royalty_cost / total_est_marketing_fee as legacy lifetime estimates
in their guidance, and add a Defaults row.

## 3. Documentation drift (right answers, wrong map)

- The metric reference says "All 95 metrics"; the layer has 110. The 15
  undocumented are exactly the AP/AR and pricing/tax/asset metrics:
  ap_outstanding, avg_days_to_pay, ap_pct_paid_on_time,
  early_pay_discounts_taken, franchise_fees_invoiced,
  franchise_fees_collected, ar_outstanding, ar_pct_paid_on_time,
  avg_cost_change_pct, avg_price_change_pct, price_cost_spread,
  tax_collected, taxable_sales_share_pct, total_depreciation,
  total_net_book_value. Add a "Working Capital" and a "Pricing, Tax &
  Assets" section (suggested text is in
  WOBBY_FINANCIAL_EXTENSION_RECOMMENDATION.md).
- The Model Reference lacks payables, franchise_fees, pricebook,
  sales_tax, tax_rates and store_assets (the UI rewrite dropped the
  API-added block).
- Three metrics exist but are NOT granted to the analyst:
  avg_cost_change_pct, avg_price_change_pct, price_cost_spread -- the
  margin-bridge story is invisible until they are toggled on in the UI.
- New analysis patterns worth adding: DPO and AP aging (payables),
  collections by owner (franchise_fees, 60+ bucket = true delinquency),
  margin bridge (avg_price_change_pct - avg_cost_change_pct = rate effect),
  tax remittance (never revenue; MB RST cut 2019-07 is real).

## 4. Model hygiene

- customers does not expose the 8 lifecycle columns added to the table:
  lifecycle_status, churn_risk_band, overdue_ratio, ipt_median_days,
  expected_next_purchase, tenure_days, first_store_number,
  churn_horizon_days. lifecycle_status and churn_risk_band are the two
  most useful segmentation dimensions in the schema -- adding them lets
  every customer-joined metric slice by lifecycle without a churn-model
  join.
- The six dash_* models are isolated (no relationships), duplicate what
  store_pnl / gl / transactions now answer, and total at the line grain
  (764,167,990.73) while transactions totals at the basket grain
  (764,167,888.75 -- a 102 CAD mixed-transaction edge). Two sources of
  truth invite inconsistent answers. Recommendation: keep dash_kpi as the
  headline fast path, retire the other five from the analyst's access (or
  add explicit "fast path, line-grain totals" guidance to each).
- pos_sales_detail_v duplicates pos_sales_detail plus transactions;
  recommend removing it from analyst access.
- Missing relationship worth adding: transactions.promo_id ->
  promotions.promo_id (promotion economics at basket grain currently
  requires the line fact). Optional: month_date -> date_dim.calendar_date
  for store_pnl, store_budget and gl so calendar attributes (holidays,
  pandemic_period) reach the finance models.
- tax_rates is isolated by design (reference table) -- fine.

## 5. Content gaps (the only unbuilt recommendation)

Step 5 of the finance extension remains: loyalty_liability_monthly and
gift_card_liability_monthly (24 rows each), the two balance-sheet
roll-forwards. The loyalty point value decision (1,000 points per CAD,
implying a 7.4M liability) is already embedded in the tenders build, so
the liability table should use the same convention. Until then the
analyst can state gift card liability (gift_cards.outstanding_liability)
but not its monthly movement, and loyalty liability not at all.

## 6. Process note

The environment now has two active editors: the UI (instructions, grants,
metric curation) and the API scripts in scripts/pos_perf (tables, models,
relationships, metrics). The August 23 UI pass improved a great deal and
regressed two things the API had fixed (risk bands, finance model
references). Suggested convention going forward: instructions and grants
are UI-owned; models, relationships and metric definitions are API-owned
(scripts always GET fresh and never touch instructions); after each API
step, a one-line UI checklist (grant new metrics, paste reference rows)
closes the loop.

## 7. Priority list

| # | Action | Where | Effort |
|---|---|---|---|
| 1 | Correct risk bands in 3 places (0.25 / 0.45 / 0.70) | UI instructions | 5 min |
| 2 | Remove churn/activation training sets from analyst access (or fix their grain guidance) | UI | 5 min |
| 3 | Grant avg_cost_change_pct, avg_price_change_pct, price_cost_spread | UI | 2 min |
| 4 | Add plan-arbitration rule (sales_targets vs store_budget) | UI instructions | 10 min |
| 5 | Declare monthly fee ledger authoritative; repoint franchise_fee_burden_pct | UI + API | 15 min |
| 6 | Document the 15 finance metrics + 6 finance models in the reference | UI instructions | 20 min |
| 7 | Expose lifecycle_status + churn_risk_band (and the other 6 columns) on customers | API script | 15 min |
| 8 | Retire dash_monthly/promo/province/region/store and pos_sales_detail_v from access, keep dash_kpi | UI | 10 min |
| 9 | Add transactions -> promotions relationship | API script | 5 min |
| 10 | Build Step 5 liability roll-forwards | warehouse + API | 0.25 day |


## 8. Completeness audit, 2026-08-23 21:08Z (read-only)

Full cross-validation of the environment (52 models, 64 relationships, 112
metrics, 69 glossary terms) against the warehouse catalog: every dimension,
measure and filter expression checked against real columns, every metric
anchor, group-by, time dimension, join alias and filter reference resolved,
every relationship key traced, every grant compared, every glossary mapping
followed.

### Verified sound

- All 64 relationships: keys resolve to the right models, none dangling.
- All 112 metrics: anchors valid, group-by dimensions exist, time
  dimensions exist and are date-typed, cross-model join aliases (pos, st,
  churn, prod, store) all reference valid models and keys. All 112 granted.
- Glossary: 65 of 69 terms fully mapped (model / dimension / measure /
  metric mappings), ZERO broken mappings, every term has synonyms and tags.
  The UI curation mapped even the API-created finance terms.
- Every dimension, measure and filter expression resolves to real
  warehouse columns, with the two exceptions below.

### Defects (wrong answers or errors)

1. sales_plan_attainment_pct is broken: its expression is
   sales_targets.total_target_sales -- it returns the TARGET, not
   attainment, while its description promises actual / target x 100. The
   sales_targets table has no actual columns to divide by (they are
   computed and dropped inside build_targets_suppliers.sql). Fix: add
   actual_sales / actual_margin / actual_transactions columns to
   sales_targets and repoint the expression, or retire the metric in
   favour of store_budget.sales_variance_pct.
2. churn_training_set.churn_rate_90 and
   activation_training_set.activation_rate use the Postgres cast
   AVG(x::numeric) -- Actian does not support ::, the measure errors when
   queried. Fix: AVG(FLOAT8(x)) * 100. Relevant because both models are
   granted again (see grant drift below).
3. promotional_sales and dietary_sales share the exact expression of
   total_net_sales (pos_sales_detail.total_sales) and every
   differentiating filter has apply_default = false -- called without a
   filter they return TOTAL sales, silently. Fix: promoted_items
   apply_default = true on promotional_sales; guidance on dietary_sales
   that an attribute filter is mandatory. (The null-expression filter
   entries are fine -- they reference products model filters.)

### Coverage gaps

4. Four glossary terms unmapped (the four newest): Breakage, Deferred
   Revenue, Margin Bridge, Pricebook.
5. fsa_demographics model exposes NONE of the 11 enrichment columns added
   to the table (median_age, pct_families_with_children, pct_seniors,
   pct_french_speaking, pct_owner_occupied, unemployment_rate_pct,
   pct_recent_movers, stores_in_fsa, competitor_count_5km,
   home_store_number, stores_shopped partially) -- the whole FSA
   demographic enrichment is invisible to the agent.
6. customer_month exposes 15 measures but leaves 14 useful columns
   unmodeled: returns, purchase_days, min_csat, ecommerce_late,
   distinct_stores, discount, items, home_store_txns, loyalty_redemptions,
   open_cases, gift_cards_bought, avg_categories_per_basket,
   min_ecommerce_satisfaction -- monthly service/returns analysis cannot
   reach them.
7. Smaller exposure gaps worth one pass: promotions (distinct_customers,
   total_transactions), loyalty_liability (redemption_rate_pct,
   active_members, points_adjusted, opening balance), gift_card_liability
   (opening_liability), franchise_fees (fee_pct_of_sales), pricebook
   (avg_sale_price, selling_price_change_pct, stores_selling), payables
   (terms_days). The remaining unexposed columns are intentional (PII-ish
   names/emails/street, jdn helpers, per-row pct columns superseded by
   sum-over-sum measures).
8. Grant drift continues: 5 of the 8 grants removed in the refinement pass
   are back (churn_training_set, activation_training_set, dash_monthly,
   dash_store, pos_sales_detail_v; dash_promo/province/region stayed
   removed). Mitigated -- their guidance now carries the correct grain and
   never-SUM warnings -- but the UI and API keep overwriting each other's
   grants; the access list needs a single owner. If dash_store and
   pos_sales_detail_v stay granted, give them their store/product
   relationships.

### Fix list

| # | Fix | Where |
|---|---|---|
| 1 | sales_targets actuals + repoint sales_plan_attainment_pct | warehouse + API |
| 2 | ::numeric -> FLOAT8 in the two training-set measures | API |
| 3 | promotional_sales default filter, dietary_sales guidance | API |
| 4 | Map the 4 glossary terms | UI or API |
| 5 | Expose fsa_demographics enrichment (11 dims) | API |
| 6 | Expose the customer_month columns as measures | API |
| 7 | Small exposure pass (promotions, liabilities, pricebook, payables) | API |
| 8 | Decide grant ownership; add rels for re-granted models | UI decision |


### Audit fixes applied 2026-08-23 (API side)

alter_sales_targets_actuals.sql added real actual_sales / actual_margin /
actual_transactions to sales_targets (7,706 rows, 0 nulls, network
attainment 100.24 pct). wobby_audit_fixes.py then applied everything in one
PUT (200: created 3, updated 14) plus one follow-up:

- sales_plan_attainment_pct now computes real attainment
  (sales_targets.sales_attainment_pct, actual over target sum-over-sum);
  margin_attainment_pct and the actual measures added alongside.
- The two Postgres ::numeric casts removed (AVG(FLOAT8(x))) -- zero remain.
- promotional_sales: the server does NOT honour apply_default changes on
  metric filters via PUT (flip was silently dropped), so the metric
  description and guidance now state the promoted_items filter is
  MANDATORY; dietary_sales guidance likewise hardened.
- All four glossary terms mapped (Breakage, Deferred Revenue, Margin
  Bridge, Pricebook) -- mapping edits on existing glossary entries DO
  persist via PUT.
- fsa_demographics: 11 enrichment dimensions exposed.
- customer_month: 9 measures added (returns, purchase days, items,
  discount, late deliveries, min CSAT, redemptions, gift cards, home-store
  transactions).
- Exposure pass: promotions +2, loyalty_liability +3, gift_card_liability
  +1, franchise_fees +1, pricebook +3 measures, payables +1 dimension.
- Relationships for the re-granted models: dash_store -> stores,
  pos_sales_detail_v -> stores and -> products.

Environment after: 52 models / 67 relationships / 112 metrics / 69
glossary terms; 69 of 69 terms mapped. Remaining open item is the UI-side
decision on grant ownership (item 8) and, optionally, flipping
promotional_sales promoted_items to default in the UI where the flag is
editable.
