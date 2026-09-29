-- relabel_drivers.sql -- one-off: map raw feature names left in
-- customer_churn_scores.driver_1..3 by the first churn-gbm-v1 run to the
-- reader-facing labels now in churn_model.py DRIVER_LABELS. Safe to re-run.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS drv_map;

CREATE TABLE drv_map AS
SELECT 'vegetarian pct' AS raw, 'Plant-forward basket mix' AS lbl
UNION ALL SELECT 'single serve pct', 'Single-serve basket mix'
UNION ALL SELECT 'prepared meals pct', 'Ready-meal basket mix'
UNION ALL SELECT 'vegan pct', 'Plant-based basket mix'
UNION ALL SELECT 'gluten free pct', 'Gluten-free basket mix'
UNION ALL SELECT 'ipt max asof', 'Longest gap on record'
UNION ALL SELECT 'ipt median asof', 'Slow buying cadence'
UNION ALL SELECT 'ipt mean asof', 'Slow buying cadence'
UNION ALL SELECT 'avg categories l180', 'Narrow basket mix'
UNION ALL SELECT 'avg items l180', 'Small baskets'
UNION ALL SELECT 'avg basket asof', 'Small baskets'
UNION ALL SELECT 'sales asof', 'Low lifetime spend'
UNION ALL SELECT 'purchase days asof', 'Few purchases to date'
UNION ALL SELECT 'purchase days l180', 'Few visits last 180 days'
UNION ALL SELECT 'baskets asof', 'Few purchases to date'
UNION ALL SELECT 'bgnbd recency', 'Long since first purchase'
UNION ALL SELECT 'bgnbd t', 'Long since first purchase'
UNION ALL SELECT 'store sales per sqft', 'Low-traffic home store'
UNION ALL SELECT 'store margin pct', 'Home store margin'
UNION ALL SELECT 'fsa median income', 'Neighbourhood income'
UNION ALL SELECT 'distinct stores l180', 'Shops around'
UNION ALL SELECT 'margin l180', 'Low recent margin'
UNION ALL SELECT 'margin l90', 'Low recent margin'
UNION ALL SELECT 'sales l180', 'Low recent spend'
UNION ALL SELECT 'sales l30', 'No spend last 30 days'
UNION ALL SELECT 'discount l180', 'Discount driven'
UNION ALL SELECT 'points earned l180', 'Few loyalty points earned'
UNION ALL SELECT 'emails sent l180', 'Low email reach'
UNION ALL SELECT 'weekend txns l180', 'Weekend shopper'
UNION ALL SELECT 'household size', 'Household size'
UNION ALL SELECT 'fsa penetration pct', 'Low-penetration area'
UNION ALL SELECT 'fsa pct families', 'Neighbourhood family mix'
UNION ALL SELECT 'fsa median age', 'Neighbourhood age'
UNION ALL SELECT 'stores in fsa', 'Store density'
UNION ALL SELECT 'store square feet', 'Home store size'
UNION ALL SELECT 'store staff count', 'Home store staffing';

UPDATE customer_churn_scores FROM drv_map m SET driver_1 = m.lbl WHERE customer_churn_scores.driver_1 = m.raw;

UPDATE customer_churn_scores FROM drv_map m SET driver_2 = m.lbl WHERE customer_churn_scores.driver_2 = m.raw;

UPDATE customer_churn_scores FROM drv_map m SET driver_3 = m.lbl WHERE customer_churn_scores.driver_3 = m.raw;

UPDATE customer_churn_scores SET driver_1 = NULL WHERE driver_1 = '';

UPDATE customer_churn_scores SET driver_2 = NULL WHERE driver_2 = '';

UPDATE customer_churn_scores SET driver_3 = NULL WHERE driver_3 = '';

DROP TABLE IF EXISTS drv_map;

SELECT driver_1, COUNT(*) AS n FROM customer_churn_scores WHERE model_version = 'churn-gbm-v1' GROUP BY driver_1 ORDER BY n DESC;
