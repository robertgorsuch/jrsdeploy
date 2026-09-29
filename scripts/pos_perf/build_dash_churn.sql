-- dash_churn: customer_churn_scores joined to customers (region, tier, store)
-- and customer_ipt_stats (expected next purchase). Customer grain, one row
-- per scored customer -- no further pre-aggregation needed, X100 is columnar
-- and 3.18M rows scans fine for live GROUP BY in dashboard tiles.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_churn;
CREATE TABLE dash_churn AS
SELECT s.customer_id,
       c.home_region AS region,
       c.loyalty_tier,
       c.home_store_number AS storenumber,
       s.score_date,
       s.risk_band,
       s.churn_probability,
       s.expected_ltv_at_risk,
       s.overdue_ratio,
       s.lifecycle_status,
       s.driver_1,
       s.driver_2,
       s.driver_3,
       s.recommended_action,
       i.expected_next_purchase
FROM customer_churn_scores s
JOIN customers c ON c.customer_id = s.customer_id
LEFT JOIN customer_ipt_stats i ON i.customer_id = s.customer_id;
CREATE STATISTICS FOR dash_churn;
