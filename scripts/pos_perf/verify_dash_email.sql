-- verify dash_email
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 row count and grain, expect 0 dup keys
SELECT COUNT(*) AS rows_,
       (SELECT COUNT(*) FROM (SELECT campaign_id, send_yyyymm FROM dash_email GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_email;
-- 2 ties to source exactly, expect sent 1770334
SELECT (SELECT SUM(sent) FROM dash_email) AS agg_sent, (SELECT COUNT(*) FROM email_engagement) AS src_sent;
-- 3 network lifetime rates, expect open 37.65 click 12.10 convert 4.71 (pct)
SELECT DECIMAL(100.0 * FLOAT8(SUM(opened)) / FLOAT8(SUM(sent)), 6, 2) AS open_pct,
       DECIMAL(100.0 * FLOAT8(SUM(clicked)) / FLOAT8(SUM(sent)), 6, 2) AS click_pct,
       DECIMAL(100.0 * FLOAT8(SUM(converted)) / FLOAT8(SUM(sent)), 6, 2) AS convert_pct
FROM dash_email;
-- 4 no NULL campaign_name, expect 0
SELECT COUNT(*) AS null_names FROM dash_email WHERE campaign_name IS NULL;
