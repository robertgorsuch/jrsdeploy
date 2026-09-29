-- dash_labour: shift_schedules rolled to store x date x shift, with date_dim
-- calendar attributes and a traffic-proportional sales allocation (no daily
-- store-level sales-by-shift table exists, so each shifts share of the
-- stores daily traffic sales is its share of that days total scheduled
-- hours -- a documented, disclosed allocation, not a measured figure).
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_labour;
CREATE TABLE dash_labour AS
SELECT s.storenumber, s.calendar_date, s.shift_name,
       d.yyyymm, d.dow_num, d.day_name, d.is_weekend,
       DECIMAL(SUM(s.scheduled_hours), 10, 2) AS scheduled_hours,
       DECIMAL(SUM(s.labour_cost), 12, 2) AS labour_cost,
       DECIMAL(FLOAT8(t.sales) * FLOAT8(SUM(s.scheduled_hours)) / FLOAT8(NULLIF(day_tot.day_hours, 0)), 12, 2) AS allocated_sales
FROM shift_schedules s
JOIN date_dim d ON d.calendar_date = s.calendar_date
LEFT JOIN store_traffic t ON t.storenumber = s.storenumber AND t.traffic_date = s.calendar_date
LEFT JOIN (
  SELECT storenumber, calendar_date, DECIMAL(SUM(scheduled_hours), 10, 2) AS day_hours
  FROM shift_schedules GROUP BY storenumber, calendar_date
) day_tot ON day_tot.storenumber = s.storenumber AND day_tot.calendar_date = s.calendar_date
GROUP BY s.storenumber, s.calendar_date, s.shift_name, d.yyyymm, d.dow_num, d.day_name, d.is_weekend, t.sales, day_tot.day_hours;
CREATE STATISTICS FOR dash_labour;
