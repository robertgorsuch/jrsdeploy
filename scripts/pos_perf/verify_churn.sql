-- verify_churn.sql -- sanity checks for the churn / demographics extension:
-- pos_sales_txn, customer_ipt_stats, customers lifecycle columns,
-- customer_demographics, fsa_demographics enrichment, customer_diet_profile,
-- customer_month, churn_training_set, activation_training_set,
-- customer_churn_scores.
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon in a comment in this file.

-- 1. pos_sales_txn reconciles to the fact: one row per transaction, same sales
SELECT (SELECT COUNT(*) FROM pos_sales_txn) AS txn_rows,
       (SELECT COUNT(DISTINCT transactionuniqueid) FROM pos_sales_detail) AS fact_txns,
       (SELECT SUM(basket_value) FROM pos_sales_txn) AS txn_sales,
       (SELECT SUM(sellingprice * quantity) FROM pos_sales_detail) AS fact_sales;

SELECT txn_type, COUNT(*) AS n, SUM(CASE WHEN ecommerce_flag = 'Y' THEN 1 ELSE 0 END) AS ecom,
       SUM(CASE WHEN promo_flag = 'Y' THEN 1 ELSE 0 END) AS promo
FROM pos_sales_txn GROUP BY txn_type ORDER BY n DESC;

-- 2. IPT stats: lifecycle mix and cadence by tier
SELECT lifecycle_status, COUNT(*) AS n,
       DECIMAL(AVG(ipt_median_days), 8, 1) AS avg_median_gap,
       DECIMAL(AVG(overdue_ratio), 8, 2) AS avg_overdue,
       DECIMAL(AVG(days_silent), 8, 1) AS avg_days_silent
FROM customer_ipt_stats GROUP BY lifecycle_status ORDER BY n DESC;

SELECT c.loyalty_tier, COUNT(*) AS n,
       DECIMAL(AVG(i.ipt_median_days), 8, 1) AS avg_median_gap,
       SUM(CASE WHEN i.lifecycle_status = 'Churned' THEN 1 ELSE 0 END) AS churned,
       SUM(CASE WHEN i.lifecycle_status = 'Lapsing' THEN 1 ELSE 0 END) AS lapsing
FROM customer_ipt_stats i JOIN customers c ON c.customer_id = i.customer_id
GROUP BY c.loyalty_tier ORDER BY n DESC;

-- 3. customers lifecycle columns populated
SELECT lifecycle_status, COUNT(*) AS n,
       SUM(CASE WHEN first_store_number IS NULL THEN 1 ELSE 0 END) AS no_first_store,
       SUM(CASE WHEN tenure_days IS NULL THEN 1 ELSE 0 END) AS no_tenure
FROM customers GROUP BY lifecycle_status ORDER BY n DESC;

-- 4. Demographics: 1:1 with customers, distributions
SELECT (SELECT COUNT(*) FROM customer_demographics) AS dem_rows,
       (SELECT COUNT(*) FROM customers) AS cust_rows,
       (SELECT COUNT(*) FROM (SELECT customer_id FROM customer_demographics GROUP BY customer_id HAVING COUNT(*) > 1) t) AS dup_ids;

SELECT age_band, COUNT(*) AS n FROM customer_demographics GROUP BY age_band ORDER BY age_band;

SELECT life_stage, COUNT(*) AS n, DECIMAL(AVG(household_size), 4, 2) AS avg_hh FROM customer_demographics GROUP BY life_stage ORDER BY n DESC;

SELECT household_income_band, COUNT(*) AS n FROM customer_demographics GROUP BY household_income_band ORDER BY n DESC;

SELECT d.language_pref, c.province, COUNT(*) AS n
FROM customer_demographics d JOIN customers c ON c.customer_id = d.customer_id
WHERE c.province IN ('QC', 'ON', 'NB', 'AB')
GROUP BY d.language_pref, c.province ORDER BY c.province, d.language_pref;

SELECT acquisition_channel, COUNT(*) AS n FROM customer_demographics GROUP BY acquisition_channel ORDER BY n DESC;

SELECT data_source, demographics_consent, COUNT(*) AS n FROM customer_demographics GROUP BY data_source, demographics_consent ORDER BY n DESC;

-- 5. FSA enrichment
SELECT province, COUNT(*) AS fsas, DECIMAL(AVG(pct_french_speaking), 6, 1) AS avg_fr,
       DECIMAL(AVG(pct_owner_occupied), 6, 1) AS avg_own, SUM(competitor_count_5km) AS competitors,
       SUM(stores_in_fsa) AS stores
FROM fsa_demographics WHERE valid_fsa_flag = 'Y' GROUP BY province ORDER BY fsas DESC;

-- 6. Diet profile
SELECT diet_profile, COUNT(*) AS n, DECIMAL(AVG(flagged_coverage_pct), 6, 1) AS avg_coverage
FROM customer_diet_profile GROUP BY diet_profile ORDER BY n DESC;

SELECT basket_profile, COUNT(*) AS n FROM customer_diet_profile GROUP BY basket_profile ORDER BY n DESC;

-- 7. customer_month: dense spine, reconciles to pos_sales_txn for eligible customers
SELECT COUNT(*) AS rows_, COUNT(DISTINCT customer_id) AS customers_, MIN(yyyymm) AS min_m, MAX(yyyymm) AS max_m,
       SUM(CASE WHEN active_flag = 'Y' THEN 1 ELSE 0 END) AS active_rows
FROM customer_month;

SELECT (SELECT SUM(sales) FROM customer_month) AS cm_sales,
       (SELECT SUM(t.basket_value) FROM pos_sales_txn t JOIN customers c ON c.customer_id = t.customer_id WHERE c.total_transactions >= 2) AS txn_sales_eligible;

SELECT yyyymm, COUNT(*) AS customers_in_spine, SUM(CASE WHEN active_flag = 'Y' THEN 1 ELSE 0 END) AS active,
       DECIMAL(100.0 * SUM(CASE WHEN active_flag = 'Y' THEN 1 ELSE 0 END) / COUNT(*), 6, 2) AS active_pct
FROM customer_month GROUP BY yyyymm ORDER BY yyyymm;

-- 8. churn_training_set: rows per cutoff, label rates, censoring
SELECT as_of_date, is_scoring_row, COUNT(*) AS rows_,
       SUM(churn_90) AS churn_90_pos, COUNT(churn_90) AS churn_90_labelled,
       SUM(churn_adaptive) AS adaptive_pos, COUNT(churn_adaptive) AS adaptive_labelled,
       DECIMAL(AVG(overdue_ratio), 8, 2) AS avg_overdue
FROM churn_training_set GROUP BY as_of_date, is_scoring_row ORDER BY as_of_date;

-- 9. Leakage guard: no feature window may extend past the cutoff
SELECT COUNT(*) AS bad_rows FROM churn_training_set WHERE days_since_last < 0 OR purchase_days_l30 > purchase_days_l90 OR purchase_days_l90 > purchase_days_l180;

-- 10. Activation set
SELECT activated_90, is_one_time, COUNT(*) AS n FROM activation_training_set GROUP BY activated_90, is_one_time ORDER BY 1, 2;

-- 11. Scores (present after churn_model.py has run)
SELECT model_version, risk_band, COUNT(*) AS n, DECIMAL(AVG(churn_probability), 6, 4) AS avg_p,
       DECIMAL(SUM(expected_ltv_at_risk), 14, 2) AS ltv_at_risk
FROM customer_churn_scores GROUP BY model_version, risk_band ORDER BY model_version, avg_p DESC;

SELECT churn_risk_band, COUNT(*) AS n FROM customers GROUP BY churn_risk_band ORDER BY n DESC;
