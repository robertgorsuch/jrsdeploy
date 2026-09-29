-- verify dash_churn
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain and row count, expect 3184743, 0 dup keys
SELECT COUNT(*) AS rows_, COUNT(DISTINCT customer_id) AS distinct_customers,
       (SELECT COUNT(*) FROM (SELECT customer_id FROM dash_churn GROUP BY customer_id HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_churn;
-- 2 ties to source to the row, expect all four equal to 3184743
SELECT (SELECT COUNT(*) FROM dash_churn) AS agg_n,
       (SELECT COUNT(*) FROM customer_churn_scores) AS src_n,
       (SELECT COUNT(*) FROM dash_churn WHERE region IS NULL) AS null_region,
       (SELECT COUNT(*) FROM dash_churn WHERE loyalty_tier IS NULL) AS null_tier;
-- 3 risk band distribution, expect Critical 684159 / High 1447344 / Watch 587944 / Low 465296
SELECT risk_band, COUNT(*) AS n FROM dash_churn GROUP BY risk_band ORDER BY risk_band;
-- 4 LTV at risk for Critical+High, expect 20807163.28
SELECT DECIMAL(SUM(expected_ltv_at_risk), 14, 2) AS ltv_at_risk FROM dash_churn WHERE risk_band IN ('Critical', 'High');
-- 5 region and tier vocab, expect 4 regions and 4 tiers, no unexpected values
SELECT region, COUNT(*) AS n FROM dash_churn GROUP BY region ORDER BY region;
SELECT loyalty_tier, COUNT(*) AS n FROM dash_churn GROUP BY loyalty_tier ORDER BY loyalty_tier;
