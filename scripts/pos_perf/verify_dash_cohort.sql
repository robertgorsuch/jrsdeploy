-- verify dash_cohort
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain, expect 0 dup keys, cohort years 2019 and 2020 only
SELECT COUNT(*) AS rows_, MIN(cohort_year) AS min_yr, MAX(cohort_year) AS max_yr,
       (SELECT COUNT(*) FROM (SELECT cohort_year, months_since_first FROM dash_cohort GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_cohort;
-- 2 month-0 active_pct must be 100.00 for both cohorts (everyone is active in their first month by definition)
SELECT cohort_year, active_pct FROM dash_cohort WHERE months_since_first = 0 ORDER BY cohort_year;
-- 3 sample the curve at months 3, 6, 9, 12 -- expect 2019 settling around 26-28, 2020 lower (partial year)
SELECT FIRST 20 cohort_year, months_since_first, active_pct, customers FROM dash_cohort
WHERE months_since_first IN (3, 6, 9, 12) ORDER BY cohort_year, months_since_first;
-- 4 ties to source row count
SELECT (SELECT SUM(customers) FROM dash_cohort) AS agg_rows, (SELECT COUNT(*) FROM customer_month) AS src_rows;
