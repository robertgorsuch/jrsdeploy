-- dash_email: email_engagement rolled to campaign x send-month, with the
-- campaign name carried for a readable tile label. Every row already joins
-- cleanly to marketing_campaigns (verified 2026-08-25, 0 orphans), so this
-- is a plain inner join, not a left join with a fallback label.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_email;
CREATE TABLE dash_email AS
SELECT e.campaign_id, m.campaign_name,
       EXTRACT(YEAR FROM e.send_date) * 100 + EXTRACT(MONTH FROM e.send_date) AS send_yyyymm,
       COUNT(*) AS sent,
       COUNT(CASE WHEN e.opened_flag = 'Y' THEN 1 END) AS opened,
       COUNT(CASE WHEN e.clicked_flag = 'Y' THEN 1 END) AS clicked,
       COUNT(CASE WHEN e.converted_flag = 'Y' THEN 1 END) AS converted
FROM email_engagement e
JOIN marketing_campaigns m ON m.campaign_id = e.campaign_id
GROUP BY e.campaign_id, m.campaign_name, EXTRACT(YEAR FROM e.send_date) * 100 + EXTRACT(MONTH FROM e.send_date);
CREATE STATISTICS FOR dash_email;
