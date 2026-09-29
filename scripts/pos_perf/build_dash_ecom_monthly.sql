-- dash_ecom_monthly: ecommerce_orders rolled to month x delivery_partner.
-- delivery_partner is blank on every Pickup-channel row (confirmed
-- 2026-08-25) -- coalesced to the literal Pickup here so mkt_ecom_share can
-- sum across the whole dimension with no blank/NULL member, while
-- mkt_partners (delivery-specific) filters delivery_partner <> Pickup.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_ecom_monthly;
CREATE TABLE dash_ecom_monthly AS
SELECT EXTRACT(YEAR FROM order_date) * 100 + EXTRACT(MONTH FROM order_date) AS yyyymm,
       CASE WHEN TRIM(delivery_partner) = '' OR delivery_partner IS NULL THEN 'Pickup' ELSE delivery_partner END AS delivery_partner,
       COUNT(*) AS orders,
       DECIMAL(SUM(order_value), 14, 2) AS order_value,
       COUNT(CASE WHEN fulfilled_late = 'Y' THEN 1 END) AS late_orders,
       DECIMAL(AVG(satisfaction_score), 6, 2) AS avg_satisfaction
FROM ecommerce_orders
GROUP BY EXTRACT(YEAR FROM order_date) * 100 + EXTRACT(MONTH FROM order_date),
         CASE WHEN TRIM(delivery_partner) = '' OR delivery_partner IS NULL THEN 'Pickup' ELSE delivery_partner END;
CREATE STATISTICS FOR dash_ecom_monthly;
