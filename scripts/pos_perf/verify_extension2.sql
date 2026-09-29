-- verify_extension2.sql -- sanity checks for date_dim, sales_targets,
-- suppliers, employees, shift_schedules, store_traffic, weather_daily,
-- email_engagement, marketing_campaigns, customer_service_cases, gift_cards,
-- and competitor_locations.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

-- 1. date_dim -- 731 days, unique jdn, 20 holidays, correct known weekday
SELECT (SELECT COUNT(*) FROM date_dim) AS days,
       (SELECT COUNT(DISTINCT jdn) FROM date_dim) AS distinct_jdn,
       (SELECT MIN(calendar_date) FROM date_dim) AS min_d,
       (SELECT MAX(calendar_date) FROM date_dim) AS max_d,
       (SELECT SUM(CASE WHEN is_holiday = 'Y' THEN 1 ELSE 0 END) FROM date_dim) AS holidays,
       (SELECT day_name FROM date_dim WHERE calendar_date = DATE('2020-12-25')) AS xmas_2020_dow;

-- 2. sales_targets -- grain matches fact store-months, factors inside bounds
SELECT (SELECT COUNT(*) FROM sales_targets) AS target_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT storenumber, YEAR(DATE(saledate)), MONTH(DATE(saledate)) FROM pos_sales_detail) t) AS fact_store_months,
       (SELECT COUNT(*) FROM sales_targets WHERE target_sales <= 0) AS nonpositive_targets;

-- 3. suppliers -- 12 rows, spend reconciles to purchase_orders
SELECT (SELECT COUNT(*) FROM suppliers) AS supplier_rows,
       (SELECT DECIMAL(SUM(total_spend), 14, 2) FROM suppliers) AS dim_spend,
       (SELECT DECIMAL(SUM(po_value_cost), 14, 2) FROM purchase_orders) AS fact_spend;

-- 4. employees -- headcount reconciles to stores, hire dates inside window
SELECT (SELECT COUNT(*) FROM employees) AS employee_rows,
       (SELECT SUM(staff_count) FROM stores) AS store_slots,
       (SELECT COUNT(*) FROM employees e JOIN stores s ON s.storenumber = e.storenumber
         WHERE e.hire_date < s.open_date) AS hired_before_open,
       (SELECT COUNT(*) FROM employees WHERE employment_status = 'Terminated'
         AND (termination_date IS NULL OR termination_date < hire_date)) AS bad_terminations,
       (SELECT COUNT(*) FROM employees WHERE role = 'Store Manager') AS managers;

-- 5. shift_schedules -- full grid, every shift maps to a real employee
SELECT (SELECT COUNT(*) FROM shift_schedules) AS shift_rows,
       (SELECT COUNT(*) FROM stores) * (SELECT COUNT(*) FROM date_dim) * 2 AS expected_rows,
       (SELECT COUNT(*) FROM shift_schedules sh LEFT JOIN employees e ON e.employee_id = sh.employee_id
         WHERE e.employee_id IS NULL) AS orphan_shifts;

-- 6. store_traffic -- grain matches fact store-days, visitors >= transactions
SELECT (SELECT COUNT(*) FROM store_traffic) AS traffic_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT storenumber, DATE(saledate) FROM pos_sales_detail) t) AS fact_store_days,
       (SELECT COUNT(*) FROM store_traffic WHERE visitors < transactions) AS impossible_conversion;

-- 7. weather_daily -- provinces x 731, snow only on cold days
SELECT (SELECT COUNT(*) FROM weather_daily) AS weather_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT province FROM stores) p) * 731 AS expected_rows,
       (SELECT COUNT(*) FROM weather_daily WHERE snow_cm > 0 AND temp_high_c > 1) AS warm_snow,
       (SELECT COUNT(*) FROM weather_daily WHERE temp_low_c >= temp_high_c) AS inverted_temps;

-- 8. email_engagement -- funnel logic, all campaigns covered, real conversions
SELECT (SELECT COUNT(*) FROM email_engagement) AS sends,
       (SELECT COUNT(DISTINCT campaign_id) FROM email_engagement) AS campaigns_covered,
       (SELECT COUNT(*) FROM email_engagement WHERE clicked_flag = 'Y' AND opened_flag = 'N') AS click_without_open,
       (SELECT SUM(CASE WHEN converted_flag = 'Y' THEN 1 ELSE 0 END) FROM email_engagement) AS real_conversions;

-- 9. marketing_campaigns -- one per promotion, funnel monotonic
SELECT (SELECT COUNT(*) FROM marketing_campaigns) AS campaign_rows,
       (SELECT COUNT(*) FROM promotions) AS promo_rows,
       (SELECT COUNT(*) FROM marketing_campaigns
         WHERE emails_opened > emails_sent OR emails_clicked > emails_opened) AS broken_funnels;

-- 10. customer_service_cases and gift_cards
SELECT (SELECT COUNT(*) FROM customer_service_cases) AS cases,
       (SELECT COUNT(*) FROM customer_service_cases WHERE status = 'Open' AND resolution_days IS NOT NULL) AS open_with_resolution,
       (SELECT COUNT(*) FROM gift_cards) AS cards,
       (SELECT COUNT(*) FROM gift_cards WHERE DECIMAL(redeemed_amount + balance, 8, 2) <> initial_value) AS bad_card_math;

-- 11. competitor_locations
SELECT COUNT(*) AS competitor_rows,
       COUNT(DISTINCT storenumber) AS stores_with_competitors,
       MIN(distance_km) AS min_km, MAX(distance_km) AS max_km
FROM competitor_locations;

-- 12. Eyeball -- a holiday row and the top campaign funnel
SELECT calendar_date, day_name, is_holiday, holiday_name, pandemic_period, promos_active
FROM date_dim WHERE holiday_name IS NOT NULL AND yr = 2020 ORDER BY calendar_date;

SELECT FIRST 3 campaign_id, campaign_name, primary_channel, budget_subsidy, emails_sent,
       emails_opened, emails_clicked, recipients_converted, conversion_rate_pct, subsidy_per_conversion
FROM marketing_campaigns ORDER BY recipients_converted DESC;
