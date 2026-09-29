-- build_marketing.sql -- DROP-and-rebuild of email_engagement and
-- marketing_campaigns.
-- email_engagement: a 1-in-100 hash sample of (opted-in customer x campaign)
-- pairs -- about 1.8M send records. Send date is the REAL campaign start
-- date. Opened and clicked are hash-deterministic (opens around 38 percent,
-- clicks around a third of opens). converted_flag is REAL -- the customer
-- actually bought on that promotion event id in pos_sales_detail.
-- marketing_campaigns: one row per promotion with the REAL subsidy budget
-- and the engagement funnel aggregated from email_engagement.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS camp_buyers;

CREATE TABLE camp_buyers AS
SELECT DISTINCT eventid, customernumber
FROM pos_sales_detail
WHERE COALESCE(eventid, '') <> '';

DROP TABLE IF EXISTS email_engagement;

CREATE TABLE email_engagement AS
WITH s AS (
  SELECT p.promo_id AS campaign_id, c.customer_id, p.start_date AS send_date,
         ABS(MOD(HASH(c.customer_id + p.promo_id + 'op'), 100)) AS h_open,
         ABS(MOD(HASH(c.customer_id + p.promo_id + 'ck'), 100)) AS h_click
  FROM customers c, promotions p
  WHERE c.email_opt_in = 'Y'
    AND ABS(MOD(HASH(c.customer_id + p.promo_id + 'snd'), 100)) = 0
)
SELECT s.campaign_id, s.customer_id, s.send_date,
       CASE WHEN s.h_open < 38 THEN 'Y' ELSE 'N' END AS opened_flag,
       CASE WHEN s.h_open < 38 AND s.h_click < 32 THEN 'Y' ELSE 'N' END AS clicked_flag,
       CASE WHEN b.customernumber IS NOT NULL THEN 'Y' ELSE 'N' END AS converted_flag
FROM s
LEFT JOIN camp_buyers b ON b.eventid = s.campaign_id AND b.customernumber = s.customer_id;

DROP TABLE IF EXISTS camp_buyers;

DROP TABLE IF EXISTS marketing_campaigns;

CREATE TABLE marketing_campaigns AS
WITH e AS (
  SELECT campaign_id,
         COUNT(*) AS emails_sent,
         SUM(CASE WHEN opened_flag = 'Y' THEN 1 ELSE 0 END) AS emails_opened,
         SUM(CASE WHEN clicked_flag = 'Y' THEN 1 ELSE 0 END) AS emails_clicked,
         SUM(CASE WHEN converted_flag = 'Y' THEN 1 ELSE 0 END) AS recipients_converted
  FROM email_engagement
  GROUP BY campaign_id
)
SELECT p.promo_id AS campaign_id, p.campaign_name, p.mechanic, p.funding_source,
       p.start_date, p.end_date, p.stores_participating, p.top_category,
       CASE ABS(MOD(HASH(p.promo_id + 'ch'), 5))
            WHEN 0 THEN 'Email' WHEN 1 THEN 'Email' WHEN 2 THEN 'Flyer + Email'
            WHEN 3 THEN 'Flyer + Email' ELSE 'Social + Email' END AS primary_channel,
       DECIMAL(p.marketing_subsidy, 12, 2) AS budget_subsidy,
       e.emails_sent, e.emails_opened, e.emails_clicked, e.recipients_converted,
       DECIMAL(100.0 * e.emails_opened / NULLIF(e.emails_sent, 0), 6, 2) AS open_rate_pct,
       DECIMAL(100.0 * e.emails_clicked / NULLIF(e.emails_opened, 0), 6, 2) AS click_through_pct,
       DECIMAL(100.0 * e.recipients_converted / NULLIF(e.emails_sent, 0), 6, 2) AS conversion_rate_pct,
       DECIMAL(p.marketing_subsidy / NULLIF(e.recipients_converted, 0), 10, 2) AS subsidy_per_conversion,
       p.promo_sales, p.promo_margin
FROM promotions p
LEFT JOIN e ON e.campaign_id = p.promo_id;
