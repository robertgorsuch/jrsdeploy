-- verify dash_labour
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain and row count, expect 0 dup keys, date range 2019-01-01 to 2020-12-31
SELECT COUNT(*) AS rows_, MIN(calendar_date) AS min_d, MAX(calendar_date) AS max_d,
       (SELECT COUNT(*) FROM (SELECT storenumber, calendar_date, shift_name FROM dash_labour GROUP BY 1,2,3 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_labour;
-- 2 ties to source to the cent, expect both sides equal (labour_cost 70225001.95, hours 3377504.00)
SELECT (SELECT SUM(labour_cost) FROM dash_labour) AS agg_cost, (SELECT SUM(labour_cost) FROM shift_schedules) AS src_cost,
       (SELECT SUM(scheduled_hours) FROM dash_labour) AS agg_hrs, (SELECT SUM(scheduled_hours) FROM shift_schedules) AS src_hrs;
-- 3 2020 labour cost, expect 35169013.40
SELECT DECIMAL(SUM(labour_cost), 14, 2) AS labour_2020 FROM dash_labour WHERE yyyymm / 100 = 2020;
-- 4 allocated_sales sanity: each store-day two shifts should sum back to that days traffic sales
SELECT FIRST 10 storenumber, calendar_date,
       DECIMAL(SUM(allocated_sales), 12, 2) AS day_alloc_sum
FROM dash_labour GROUP BY storenumber, calendar_date ORDER BY storenumber, calendar_date;
-- 5 heatmap shape sanity: 7 days x 2 shifts, no missing day_name
SELECT day_name, shift_name, COUNT(*) AS n, DECIMAL(AVG(scheduled_hours), 8, 2) AS avg_hrs FROM dash_labour GROUP BY day_name, shift_name ORDER BY day_name, shift_name;
