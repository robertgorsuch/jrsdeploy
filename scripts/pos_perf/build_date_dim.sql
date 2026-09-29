-- build_date_dim.sql -- DROP-and-rebuild of the date_dim calendar dimension.
-- One row per day from 2019-01-01 through 2020-12-31 (731 rows) -- the exact
-- span of pos_sales_detail. Spine is generated arithmetically -- X100 allows
-- DATE plus integer -- so no dependence on the fact table having every day.
-- jdn is the Julian day number (2019-01-01 = 2458485), the join key other
-- generated tables use to pick dates without date arithmetic.
-- dow_num uses the JDN mod 7 identity where 0 = Monday.
-- Canadian statutory holidays for 2019 and 2020 are flagged by literal date.
-- promos_active counts promotions whose real start and end dates span the day.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS dd_digits;

CREATE TABLE dd_digits AS
SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
UNION ALL SELECT 8 UNION ALL SELECT 9;

DROP TABLE IF EXISTS date_dim;

CREATE TABLE date_dim AS
WITH nums AS (
  SELECT d1.n + d2.n * 10 + d3.n * 100 AS n
  FROM dd_digits d1, dd_digits d2, dd_digits d3
), s AS (
  SELECT n, DATE('2019-01-01') + n AS calendar_date, 2458485 + n AS jdn
  FROM nums WHERE n <= 730
), b AS (
  SELECT s.calendar_date, s.jdn,
         YEAR(s.calendar_date) AS yr,
         MONTH(s.calendar_date) AS mo,
         DAY(s.calendar_date) AS day_of_month,
         MOD(s.jdn, 7) AS dow_num,
         CASE WHEN YEAR(s.calendar_date) = 2019 THEN s.jdn - 2458485 + 1
              ELSE s.jdn - 2458850 + 1 END AS day_of_year
  FROM s
)
SELECT calendar_date, jdn, yr, mo, day_of_month, day_of_year,
       (mo + 2) / 3 AS quarter,
       yr * 100 + mo AS yyyymm,
       CASE mo WHEN 1 THEN 'January' WHEN 2 THEN 'February' WHEN 3 THEN 'March'
            WHEN 4 THEN 'April' WHEN 5 THEN 'May' WHEN 6 THEN 'June'
            WHEN 7 THEN 'July' WHEN 8 THEN 'August' WHEN 9 THEN 'September'
            WHEN 10 THEN 'October' WHEN 11 THEN 'November' ELSE 'December' END AS month_name,
       dow_num,
       CASE dow_num WHEN 0 THEN 'Monday' WHEN 1 THEN 'Tuesday' WHEN 2 THEN 'Wednesday'
            WHEN 3 THEN 'Thursday' WHEN 4 THEN 'Friday' WHEN 5 THEN 'Saturday'
            ELSE 'Sunday' END AS day_name,
       CASE WHEN dow_num >= 5 THEN 'Y' ELSE 'N' END AS is_weekend,
       (day_of_year - 1) / 7 + 1 AS week_of_year,
       CASE WHEN calendar_date IN (
              DATE('2019-01-01'), DATE('2020-01-01'),
              DATE('2019-02-18'), DATE('2020-02-17'),
              DATE('2019-04-19'), DATE('2020-04-10'),
              DATE('2019-05-20'), DATE('2020-05-18'),
              DATE('2019-07-01'), DATE('2020-07-01'),
              DATE('2019-08-05'), DATE('2020-08-03'),
              DATE('2019-09-02'), DATE('2020-09-07'),
              DATE('2019-10-14'), DATE('2020-10-12'),
              DATE('2019-12-25'), DATE('2020-12-25'),
              DATE('2019-12-26'), DATE('2020-12-26'))
            THEN 'Y' ELSE 'N' END AS is_holiday,
       CASE calendar_date
            WHEN DATE('2019-01-01') THEN 'New Years Day' WHEN DATE('2020-01-01') THEN 'New Years Day'
            WHEN DATE('2019-02-18') THEN 'Family Day' WHEN DATE('2020-02-17') THEN 'Family Day'
            WHEN DATE('2019-04-19') THEN 'Good Friday' WHEN DATE('2020-04-10') THEN 'Good Friday'
            WHEN DATE('2019-05-20') THEN 'Victoria Day' WHEN DATE('2020-05-18') THEN 'Victoria Day'
            WHEN DATE('2019-07-01') THEN 'Canada Day' WHEN DATE('2020-07-01') THEN 'Canada Day'
            WHEN DATE('2019-08-05') THEN 'Civic Holiday' WHEN DATE('2020-08-03') THEN 'Civic Holiday'
            WHEN DATE('2019-09-02') THEN 'Labour Day' WHEN DATE('2020-09-07') THEN 'Labour Day'
            WHEN DATE('2019-10-14') THEN 'Thanksgiving' WHEN DATE('2020-10-12') THEN 'Thanksgiving'
            WHEN DATE('2019-12-25') THEN 'Christmas Day' WHEN DATE('2020-12-25') THEN 'Christmas Day'
            WHEN DATE('2019-12-26') THEN 'Boxing Day' WHEN DATE('2020-12-26') THEN 'Boxing Day'
            END AS holiday_name,
       CASE WHEN calendar_date >= DATE('2020-03-01') THEN 'Pandemic' ELSE 'Pre-pandemic' END AS pandemic_period,
       (SELECT COUNT(*) FROM promotions p
         WHERE b.calendar_date BETWEEN p.start_date AND p.end_date) AS promos_active
FROM b;

DROP TABLE IF EXISTS dd_digits;
