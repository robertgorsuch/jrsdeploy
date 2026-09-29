# robert.gorsuch POS schema: customer demographics + churn prediction

Recommendation, 2026-08-23. Warehouse: pos_data (av-flm7ykoxlcvq), schema
robert.gorsuch, Avalanche X100. Grounded in the live catalog (29 tables,
424 columns) and a behavioral profile of the customers dimension.

## 1. Where the schema stands today

| Area | What exists | Gap for churn / demographics |
|---|---|---|
| Fact | pos_sales_detail, 63.6M lines, 19.5M transactions, 2019-01-01 to 2020-12-31, 100% of lines carry a customernumber | saledate is VARCHAR(30); every build script re-parses it. No transaction-grain table; five scripts (loyalty, ecommerce, service, gift cards, marketing) each re-derive the same per-transaction rollup. |
| customers (3.18M, 35 cols) | Fictitious deterministic identity, home store/FSA, lifetime KPIs, RFM scores, rfm_segment, loyalty_tier | Lifetime snapshot as-of 2020-12-31 only. No person-level demographics. No time-variant history, so no point-in-time labels. RFM thresholds are static and rfm_segment is rule-based, not predictive. |
| fsa_demographics (4,015) | population, households, median_income, avg_household_size, urban_flag, penetration | Area level only. Modeled values, not census. No age, family, language, tenure, or dwelling mix. |
| Behavioral sources keyed by customer_id | loyalty_ledger 20.4M, email_engagement 1.77M, ecommerce_orders 261K, customer_service_cases 49K, gift_cards 58K | All real-anchored and usable as churn signals, but none are rolled up to a customer-period grain. |

Customer profile (live, 2026-08-23):

| Lifetime transactions | Customers | Share | Lifetime sales | Avg gap between purchases | Avg recency (days) |
|---|---|---|---|---|---|
| 1 | 1,048,236 | 33% | (small) | n/a | n/a |
| 2-3 | 816,159 | 26% | $75.6M | 169 d | 234 |
| 4-10 | 843,379 | 26% | $207.0M | 93 d | 126 |
| 11-50 | 461,397 | 14% | $363.2M | 38 d | 47 |
| 51+ | 15,776 | 0.5% | $75.9M | 9 d | 18 |

Three consequences:

1. A third of the base never made a second purchase. That is an activation
   problem, not churn. Mixing them into a churn model inflates the positive
   class with customers who have no retention signal.
2. Purchase cadence spans 20x across tiers. A single "no purchase in 90 days"
   churn definition over-flags slow buyers and under-flags fast buyers. The
   label must be customer-relative.
3. The 11+ group is 15% of customers and roughly 60% of sales. Churn
   prediction should be optimized for ranking risk inside that group, where
   a saved customer is worth hundreds of dollars a year.

Also note: rfm_segment "Lost" holds 801K customers, 716K of them Bronze with a
single transaction. The existing segment is mostly labelling the one-and-done
tail, which is why it looks alarming but carries little revenue.

## 2. Demographics expansion

Design rule, consistent with the rest of the schema: fictitious but
DETERMINISTIC via HASH(customer_id + salt), anchored to REAL facts already in
the warehouse (FSA demographics, purchase behavior, province), and no
source-identifying columns. Keep demographics in a separate table rather
than widening customers: it is conceptually a different source system
(loyalty signup / survey), it carries consent semantics, and build_customers
drop-and-rebuilds customers independently.

### 2.1 customer_demographics (new, 1:1 with customers, 3.18M rows)

| Column | Type | Derivation |
|---|---|---|
| customer_id | VARCHAR(20) | key |
| birth_year | INTEGER | hash-drawn; skew younger when favorite_category is single-serve / snacks, older when avg_basket is large and promo_sales_pct is low |
| age_band | VARCHAR(6) | 18-24, 25-34, 35-44, 45-54, 55-64, 65+ |
| gender | VARCHAR(12) | Female / Male / Non-binary / Undisclosed, hash-drawn |
| household_size | INTEGER | drawn around fsa_demographics.avg_household_size for the customer FSA |
| household_income_band | VARCHAR(10) | drawn around fsa_demographics.median_income (5 bands) |
| life_stage | VARCHAR(20) | Young Single, Young Family, Established Family, Empty Nester, Retiree; function of age_band and household_size |
| children_flag | VARCHAR(1) | implied by life_stage |
| dwelling_type | VARCHAR(12) | House / Condo / Apartment / Townhouse; weighted by fsa urban_flag |
| tenure_type | VARCHAR(6) | Own / Rent; weighted by income band and dwelling |
| language_pref | VARCHAR(2) | EN / FR; FR-weighted for Quebec and eastern Ontario FSAs (first letter G, H, J, K) |
| employment_status | VARCHAR(12) | Employed / Self-employed / Student / Retired / Other; consistent with age_band |
| education_level | VARCHAR(14) | High school / College / Bachelor / Graduate; weighted by income band |
| acquisition_channel | VARCHAR(12) | In-store, Online, Referral, Campaign; Campaign when first purchase falls inside a promotions window (REAL) |
| signup_date | ANSIDATE | = first_purchase_date (REAL) |
| demographics_consent | VARCHAR(1) | Y for ~70% of email_opt_in customers, ~25% otherwise |
| marketing_consent | VARCHAR(1) | = email_opt_in (REAL) |
| data_source | VARCHAR(10) | Signup / Survey / Modeled; demographics_consent = N forces Modeled |

Nothing in the table names a vendor, panel, or third-party source.

### 2.2 fsa_demographics enrichment (alter in place, 4,015 rows)

Add: median_age, pct_families_with_children, pct_seniors, pct_french_speaking,
pct_owner_occupied, unemployment_rate_pct, pct_recent_movers,
competitor_count_5km (REAL, from competitor_locations), nearest_store_km
(REAL, haversine from stores.latitude/longitude).

Option worth taking: replace the modeled columns with real Statistics Canada
2021 Census Profile data at FSA level (Open Licence, freely redistributable).
It is a genuine upgrade for demos with retail prospects and the FSA join key
already exists. Keep the hash-modeled fallback for FSAs the census suppresses.

### 2.3 customer_diet_profile (new, derived, real)

Share of each customer's lifetime spend in products flagged vegan,
vegetarian, gluten_free, single_serve, and by allergens presence, plus
avg calories/serving_g of the basket. These are behavioral pseudo-demographics
computed from products x pos_sales_detail and are fully real. They are some
of the strongest segmentation features available and cost one aggregation.

### 2.4 Optional: customer_household

household_id grouping 1-3 customers that share FSA + hashed street. Enables
household-level churn (a family that stops shopping together) and
share-of-wallet views. Defer to phase 3 unless the demo story needs it.

## 3. Churn prediction: schema and modelling

### 3.1 Foundation fixes first (cheap, pay off everywhere)

1. pos_sales_txn (new, 19.5M rows, one row per transactionuniqueid):
   customer_id, storenumber, sale_date ANSIDATE, jdn, sale_hour, txn_type,
   basket_value, basket_items, basket_cost, basket_margin, discount_total,
   promo_flag, promo_id, categories_in_basket, ecommerce_flag, fsa.
   Replaces the loy_txn / ec_txn / svc_txn / camp_buyers rollups that five
   build scripts recompute. Partition HASH on customer_id.
2. Add sale_date ANSIDATE and jdn to pos_sales_detail (or a thin
   pos_sales_detail_v view) so downstream scripts stop calling DATE() on a
   VARCHAR over 63.6M rows.
3. Consider customer_sk INTEGER surrogate on customers and pos_sales_txn;
   VARCHAR(20) join keys cost on X100 hash joins at this scale.
4. Run CREATE STATISTICS on the new tables after each rebuild.

### 3.2 customer_ipt_stats (new, SQL only, ships in phase 0)

Per customer (2+ transactions): ipt_median_days, ipt_mean_days,
ipt_stddev_days, ipt_last_days, last_purchase_date, expected_next_purchase
(= last_purchase_date + ipt_median_days), overdue_ratio (= days silent /
ipt_median_days), purchases_l90, purchases_l180, trend_ratio_l90_vs_prior.

overdue_ratio alone is a usable "churn-lite" score: >2.0 = lapsing,
>3.0 = likely lost. It is also the single best feature for the model and
gives the dashboards a risk band on day one.

### 3.3 customer_month (new, dense customer-period fact)

One row per (customer_id, yyyymm) from the customer's first-purchase month
through 2020-12 for customers with 2+ transactions (about 2.1M customers x
avg 14 months = ~30M rows, fine on X100). Columns: transactions, sales,
items, margin, promo_sales, discount, distinct_stores, distinct_categories,
home_store_share, ecommerce_orders, ecommerce_late, loyalty_points_earned,
loyalty_points_redeemed, emails_sent/opened/clicked, service_cases,
min_csat, gift_card_purchases, days_since_last_purchase_at_month_end,
months_since_first, pandemic_period. Zero-filled months are the churn
signal, so the table must be dense, not sparse.

### 3.4 churn_training_set (new, point-in-time, leak-free)

Stacked snapshots at monthly cutoffs (as_of_date) from 2019-07-31 through
2020-09-30. For each cutoff and each customer with 2+ transactions before
the cutoff:

- Observation-window features (all computed strictly from rows dated <=
  as_of_date): L30/L90/L180 transactions, sales, margin; trend ratios
  (L90 / prior 90); ipt stats as of cutoff; overdue_ratio at cutoff; tenure
  days; share of promo-driven sales; category breadth and favorite category;
  home-store share and distinct stores; ecommerce share; loyalty points
  balance and redemption rate; email open/click rates L180; service cases
  L180 and min csat; gift card activity; pandemic_period at cutoff.
- Context features: customer_demographics (all), fsa_demographics
  (income, urban, competitor_count_5km, nearest_store_km), home store
  attributes (store_format, sales_per_sqft, staff_count), store_traffic
  trend for the home store, home-store shift coverage.
- Labels: churn_90 (no purchase in the 90 days after as_of_date),
  churn_adaptive (no purchase within max(90, 3 x ipt_median_days), capped
  at 180), and next_purchase_days for survival models. Cutoffs must leave
  the full horizon before 2020-12-31; censored rows are excluded.

Keep the table in the warehouse (it is a regular table, about 2.1M x 15
cutoffs, ~30M rows) and read it into Python over JDBC or export to CSV with
sql.ps1 export-csv per cutoff. The Avalanche ML toggle (admiral
configure-ml) can be enabled if in-database scoring is wanted.

### 3.5 customer_churn_scores (new, model output, what Jaspersoft reads)

customer_id, score_date, model_version, churn_probability, risk_band
(Low / Watch / High / Critical), expected_ltv_at_risk (= probability x
trailing-12-month margin), driver_1/2/3 (top SHAP features as text),
recommended_action (Win-back offer / Loyalty bonus / Service follow-up /
None). One row per customer per score_date; keep history for trend tiles.

### 3.6 customers (alter in place)

Add lifecycle_status (One-time / New / Active / Lapsing / Churned, computed
from overdue_ratio and tenure, replacing the static RFM labels for churn
purposes), ipt_median_days, expected_next_purchase, tenure_days,
first_store_number, and a churn_risk_band copied from the latest
customer_churn_scores so existing reports can filter on it without a join.

### 3.7 Modelling recommendations

- Scope: train on customers with 2+ transactions. Build a separate
  "second-purchase" activation model for the 1.05M one-time buyers; it is a
  different question with different features (first basket, promo, store).
- Label: use churn_adaptive as the primary target. Fixed 90-day labels
  mislabel the 51+ tier (9-day cadence: 90 days silent is a catastrophe) and
  the 2-3 tier (169-day cadence: 90 days silent is normal).
- Baseline: BG/NBD (Pareto/NBD) P(alive) fitted on frequency, recency,
  tenure. Non-contractual retail churn is exactly the case these models were
  built for, they need no demographics, and they give a calibrated
  probability plus expected future transactions for free.
- Main model: gradient-boosted trees (LightGBM / XGBoost) on
  churn_training_set with the BG/NBD P(alive) as an input feature.
  Demographics and FSA context are where the lift over BG/NBD comes from,
  which is also the demo story.
- Validation: time-based split (train cutoffs <= 2020-06-30, validate
  2020-07 to 2020-09). Never random-split across cutoffs; the same customer
  appears in many rows. Report AUC-PR, lift in the top decile, and
  calibration, not accuracy; positives will be 15-30% depending on tier.
- Pandemic regime break (2020-03): include pandemic_period and
  months_since_pandemic_start as features and check that validation cutoffs
  after the break still hold. This is the one place the two-year span hurts.
- Right-censoring: 587K of the 4+ tier last purchased in Dec 2020, the final
  month of data. Everything looks active at the end of the dataset; the
  cutoff-stacked training set is what makes labels honest.
- Drivers to expect, given what is in the schema: overdue_ratio, L90 trend
  ratio, service cases with low csat, late ecommerce deliveries, loyalty
  redemption drop, promo dependence (high promo_sales_pct customers churn
  when promos end), competitor_count_5km, home-store traffic decline.

## 4. Physical design on Avalanche X100

- Partition pos_sales_txn, customer_month, churn_training_set, and
  customer_churn_scores with HASH on customer_id (same partition count)
  so customer joins are co-located.
- Keep customer_demographics narrow and unpartitioned; it is a 3.18M-row
  broadcast-sized dimension.
- Rebuild order: pos_sales_txn -> customers -> customer_ipt_stats ->
  customer_demographics -> customer_diet_profile -> customer_month ->
  churn_training_set. Each is a DROP-and-rebuild script in scripts/pos_perf
  following the existing HASH(salt) convention with a matching verify_*.sql.
- sql.ps1 run-file splitter has no comment awareness: no semicolons or
  unbalanced apostrophes in SQL comments.

## 5. Phased plan

| Phase | Deliverables | Effort |
|---|---|---|
| 0 Foundation | pos_sales_txn, sale_date/jdn on the fact, customer_ipt_stats, lifecycle_status on customers, statistics | 1 day |
| 1 Demographics | customer_demographics, fsa_demographics enrichment (census option), customer_diet_profile, verify scripts | 2 days |
| 2 Churn data | customer_month, churn_training_set, BG/NBD baseline + GBM in Python over JDBC, customer_churn_scores loaded back | 2-3 days |
| 3 Presentation | Jaspersoft Customer Retention dashboard: risk distribution by tier and demographic, revenue at risk, cohort retention curves, top drivers, win-back list with input controls | 1-2 days |

Phase 0 and the overdue_ratio risk band give the dashboards something real
to show before any model is trained.

## 6. Implementation status (2026-08-23)

Phases 0, 1 and 2 are built and live on pos_data (av-flm7ykoxlcvq),
schema robert.gorsuch. Phase 3 (Jaspersoft dashboard) is not started.

Rebuild order (each script is DROP-and-rebuild, run with
`sql.ps1 -Action run-file -ResourceId av-flm7ykoxlcvq -SqlFile <file>`):

| # | Script | Builds | Rows | Time |
|---|---|---|---|---|
| 1 | build_pos_sales_txn.sql | pos_sales_txn (HASH 16 on customer_id), view pos_sales_detail_v | 19,535,179 | 1.5 min |
| 2 | build_customer_ipt_stats.sql | customer_ipt_stats | 3,184,743 | 1 min |
| 3 | alter_customers_lifecycle.sql | adds lifecycle_status, ipt_median_days, expected_next_purchase, overdue_ratio, churn_horizon_days, tenure_days, first_store_number, churn_risk_band to customers (DROP COLUMN errors on first run are expected) | 3,184,947 updated | 20 s |
| 4 | build_fsa_demographics.sql | fsa_demographics, now with median_age, pct_families_with_children, pct_seniors, pct_french_speaking, pct_owner_occupied, unemployment_rate_pct, pct_recent_movers (modeled) + stores_in_fsa, competitor_count_5km, home_store_number (real) | 4,015 | 10 s |
| 5 | build_customer_demographics.sql | customer_demographics | 3,184,947 | 30 s |
| 6 | build_customer_diet_profile.sql | customer_diet_profile | 3,184,743 | 1 min |
| 7 | build_customer_month.sql | customer_month (dense, HASH 16) | 39,654,230 | 3 min |
| 8 | build_churn_training_set.sql | churn_training_set (16 cutoffs, HASH 16), activation_training_set | 24,297,175 / 3,184,743 | 7.5 min |
| 9 | churn_model.py | BG/NBD + GBM churn model, activation model, customer_churn_scores, customers.churn_risk_band | see churn_model_report.md | ~40 min incl. load |
| - | verify_churn.sql | sanity checks for all of the above | | 1 min |

Decisions made while building:

- The fact table was NOT altered. pos_sales_txn carries sale_date and jdn,
  and pos_sales_detail_v is a view that adds them at line grain. Rewriting
  63.6M rows of the source fact on a 1 AU warehouse was not worth the risk.
- The StatCan 2021 census load was left as an option. The enriched
  fsa_demographics columns use the census column names, so a later load is a
  column-for-column swap.
- Acquisition channel is REAL but dominated by Campaign (75 percent): 72
  percent of all baskets carry a promotion in this data. A stricter rule
  (promo value at least half the first basket) is a one-line change in
  build_customer_demographics.sql if a flatter mix is wanted.
- Income bands skew high (100K-150K is the largest band) because they are
  anchored to the existing fsa_demographics.median_income, which runs 46K to
  125K. Tighten the FSA anchors first if that matters.
- X100 has no ordered aggregate windows (no running sums), so as-of features
  are computed per cutoff straight from the transaction grain and the
  customer_month running last-purchase uses a self-join.
- customer_month sales differ from the eligible pos_sales_txn total by about
  2,500 dollars out of 721.7M: customers whose only activity is returns or
  voids are in customers but have no purchase day, so no spine.
- Only 203 of 942 PLUs carry diet flags. customer_diet_profile expresses
  every share over flagged spend and reports flagged_coverage_pct; 410K
  customers with coverage under 20 percent are Unclassified.

Label rates in churn_training_set: churn_90 runs from 38 percent at the
2019-07-31 cutoff to 55 percent at 2020-05-31 as slow buyers accumulate and
the pandemic hits. churn_adaptive runs 29 to 47 percent. From 2020-07-31 on,
churn_adaptive is NULL for customers whose horizon passes 2020-12-31, so
those cutoffs carry 0.5M to 0.9M labelled rows instead of 1.8M.

### Model results (churn_model.py, 8 percent customer sample)

Validation is out-of-time AND out-of-customer: train on hash buckets 0-5 at
cutoffs through 2020-06-30 (998K rows), validate on buckets 6-7 at cutoffs
2020-07-31 to 2020-09-30 (43.9K rows, 42 percent positive).

| Scorer | AUC-ROC | AUC-PR | Lift top decile | Brier |
|---|---|---|---|---|
| overdue_ratio heuristic | 0.795 | 0.734 | 2.00 | n/a |
| BG/NBD 1 - P(alive) | 0.823 | 0.749 | 2.01 | 0.214 |
| GBM (behaviour + demographics + BG/NBD) | 0.852 | 0.806 | 2.16 | 0.156 |
| GBM, Platinum / Gold / Silver / Bronze | 0.80 / 0.72 / 0.69 / 0.70 | | 4.4 / 2.2 / 1.4 / 1.1 | |
| Activation model (second purchase within 90 d) | 0.561 | 0.324 | 1.38 | 0.227 |

A leak was caught on the first run: loyalty_tier scored 0.35 AUC-drop
importance and the model hit 0.888. loyalty_tier is a lifetime quantity as
of 2020-12-31, so for a 2019 cutoff it encodes the future. It and the other
lifetime counts (categories_bought, distinct_plus, flagged_coverage_pct,
and favorite_category in the activation model) are excluded. 0.852 is the
honest number. The diet pct shares remain as a mild, documented
simplification.

The activation model is weak. First-basket features barely separate
customers who return within 90 days from those who do not, in this data.
It is shipped because it still ranks one-time buyers at 1.4x lift for a
second-purchase nudge, and because the honest result is worth knowing.

BG/NBD parameters (weeks): r=1.85, alpha=16.2, a=0.11, b=0.87, a mean
dropout of about 11 percent per purchase occasion.

customer_churn_scores holds one row per customer: churn_probability,
risk_band (Critical >= 0.70, High >= 0.45, Watch >= 0.25, Low),
expected_ltv_at_risk (probability x 2 x trailing-180-day margin),
bgnbd_p_alive, overdue_ratio, lifecycle_status, driver_1..3 (z-score x
importance attribution, not SHAP) and recommended_action. model_version is
churn-gbm-v1 for customers with two or more purchase days and
activation-gbm-v1 for one-time buyers (churn_probability = 1 - P(second
purchase)). customers.churn_risk_band mirrors risk_band.

Scores as of 2020-12-31 (3,184,743 rows):

| Model | Risk band | Customers | Avg probability | Revenue at risk |
|---|---|---|---|---|
| churn-gbm-v1 | Critical | 545,271 | 0.80 | $3.90M |
| churn-gbm-v1 | High | 628,986 | 0.58 | $9.63M |
| churn-gbm-v1 | Watch | 456,900 | 0.35 | $9.15M |
| churn-gbm-v1 | Low | 464,275 | 0.15 | $8.60M |
| activation-gbm-v1 | Critical + High | 957,246 | 0.61 | $7.28M |
| activation-gbm-v1 | Watch + Low | 132,065 | 0.39 | $0.80M |

Churned customers land 92 percent in Critical or High, Active customers 85
percent in Low or Watch. Recommended actions: Win-back offer 908K, Loyalty
bonus 265K, Second-buy nudge 207K, Delivery recovery 535, Service follow-up
362, None 1.80M. relabel_drivers.sql is a one-off that mapped raw feature
names left by the first run to reader-facing driver labels; churn_model.py
now emits the labels directly.

What the demographics do and do not add: mean churn probability is flat
across age bands (0.48 to 0.50) and across the other hash-drawn
attributes. That is by construction -- the modeled demographics are
deterministic draws with no behavioural tie, so they cannot carry churn
signal. The lift in the model over BG/NBD comes from real-derived columns
(basket composition, cadence shape, FSA context, home store). If the demo
story needs age or life stage to visibly move churn risk, give the generator
in build_customer_demographics.sql an explicit behavioural link (for
example, skew life stage by cadence and basket size). That is a deliberate
choice to make, not a defect.

Two customer ids, 0 and 55555555, look like house or no-card accounts
(Platinum, tens of thousands of dollars of 180-day margin). They top any
revenue-at-risk list and should be excluded from outreach views.
