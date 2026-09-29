-- build_liability_monthly.sql -- DROP-and-rebuild of the two balance-sheet
-- roll-forwards (Step 5 of the finance extension), month grain, 24 rows each.
--
-- loyalty_liability_monthly -- REAL flows from loyalty_ledger by entry
-- month: points earned (EARN), redeemed (REDEEM), adjustments (ADJUST,
-- negative points on returns). Point value convention: 1,000 points per CAD
-- (the same convention as the Loyalty Points tender in
-- tender_summary_daily), so the closing liability at 2020-12 is about 7.37M
-- CAD. No expiry is modeled inside the 24-month window -- breakage is a
-- disclosure, not a movement, here.
--
-- gift_card_liability_monthly -- issued value is REAL by purchase month.
-- gift_cards has no redemption dates, so redemption timing is FICTITIOUS
-- but DETERMINISTIC: the real redeemed_amount of each card is recognised at
-- purchase month plus HASH(card_id) months (0-3), capped at 2020-12 so the
-- closing liability equals gift_cards outstanding balance TO THE CENT
-- (1,694,634.25). Balances are cumulative issued minus cumulative redeemed.
-- Requires: loyalty_ledger, gift_cards, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS ll_months;

CREATE TABLE ll_months AS
SELECT yyyymm, MIN(calendar_date) AS month_start,
       ROW_NUMBER() OVER (ORDER BY yyyymm) AS month_seq
FROM date_dim GROUP BY yyyymm;

-- ---------------------------------------------------------------- loyalty

DROP TABLE IF EXISTS ll_flows;

CREATE TABLE ll_flows AS
SELECT YEAR(entry_date) * 100 + MONTH(entry_date) AS yyyymm,
       SUM(CASE WHEN entry_type = 'EARN' THEN points ELSE 0 END) AS points_earned,
       SUM(CASE WHEN entry_type = 'REDEEM' THEN -points ELSE 0 END) AS points_redeemed,
       SUM(CASE WHEN entry_type = 'ADJUST' THEN points ELSE 0 END) AS points_adjusted,
       SUM(CASE WHEN entry_type = 'REDEEM' THEN 1 ELSE 0 END) AS redemption_events,
       COUNT(DISTINCT customer_id) AS active_members
FROM loyalty_ledger
GROUP BY YEAR(entry_date) * 100 + MONTH(entry_date);

DROP TABLE IF EXISTS loyalty_liability_monthly;

CREATE TABLE loyalty_liability_monthly AS
WITH cum AS (
  SELECT m.yyyymm, m.month_start, m.month_seq,
         SUM(f2.points_earned) AS cum_earned,
         SUM(f2.points_redeemed) AS cum_redeemed,
         SUM(f2.points_adjusted) AS cum_adjusted
  FROM ll_months m
  JOIN ll_months m2 ON m2.month_seq <= m.month_seq
  JOIN ll_flows f2 ON f2.yyyymm = m2.yyyymm
  GROUP BY m.yyyymm, m.month_start, m.month_seq
)
SELECT c.yyyymm, c.month_start, c.yyyymm / 100 AS yr, MOD(c.yyyymm, 100) AS mo,
       f.points_earned, f.points_redeemed, f.points_adjusted,
       f.redemption_events, f.active_members,
       c.cum_earned + c.cum_adjusted - c.cum_redeemed - COALESCE(f.points_earned + f.points_adjusted - f.points_redeemed, 0) AS opening_points_balance,
       c.cum_earned + c.cum_adjusted - c.cum_redeemed AS closing_points_balance,
       0.001 AS point_value_cad,
       DECIMAL((c.cum_earned + c.cum_adjusted - c.cum_redeemed) / 1000.0, 12, 2) AS closing_liability_cad,
       DECIMAL(f.points_earned / 1000.0, 12, 2) AS earned_value_cad,
       DECIMAL(f.points_redeemed / 1000.0, 12, 2) AS redeemed_value_cad,
       DECIMAL(100.0 * FLOAT8(f.points_redeemed) / NULLIF(FLOAT8(f.points_earned), 0), 6, 2) AS redemption_rate_pct
FROM cum c
JOIN ll_flows f ON f.yyyymm = c.yyyymm;

DROP TABLE IF EXISTS ll_flows;

-- ---------------------------------------------------------------- gift cards

DROP TABLE IF EXISTS gc_issue;

CREATE TABLE gc_issue AS
SELECT g.card_id, g.initial_value, g.redeemed_amount,
       m.month_seq AS issue_seq, m.yyyymm AS issue_yyyymm,
       LEAST(24, m.month_seq + ABS(MOD(HASH(g.card_id + 'rdm'), 4))) AS redeem_seq
FROM gift_cards g
JOIN ll_months m ON m.yyyymm = YEAR(g.purchase_date) * 100 + MONTH(g.purchase_date);

DROP TABLE IF EXISTS gc_flows;

CREATE TABLE gc_flows AS
SELECT m.yyyymm, m.month_start, m.month_seq,
       COALESCE(i.issued_value, 0) AS issued_value,
       COALESCE(i.issued_cards, 0) AS issued_cards,
       COALESCE(r.redeemed_value, 0) AS redeemed_value
FROM ll_months m
LEFT JOIN (SELECT issue_seq, SUM(initial_value) AS issued_value, COUNT(*) AS issued_cards
           FROM gc_issue GROUP BY issue_seq) i ON i.issue_seq = m.month_seq
LEFT JOIN (SELECT redeem_seq, SUM(redeemed_amount) AS redeemed_value
           FROM gc_issue GROUP BY redeem_seq) r ON r.redeem_seq = m.month_seq;

DROP TABLE IF EXISTS gift_card_liability_monthly;

CREATE TABLE gift_card_liability_monthly AS
WITH cum AS (
  SELECT m.yyyymm, SUM(f2.issued_value) AS cum_issued, SUM(f2.redeemed_value) AS cum_redeemed
  FROM ll_months m
  JOIN gc_flows f2 ON f2.month_seq <= m.month_seq
  GROUP BY m.yyyymm
)
SELECT f.yyyymm, f.month_start, f.yyyymm / 100 AS yr, MOD(f.yyyymm, 100) AS mo,
       DECIMAL(f.issued_value, 12, 2) AS issued_value,
       f.issued_cards,
       DECIMAL(f.redeemed_value, 12, 2) AS redeemed_value,
       DECIMAL(c.cum_issued - c.cum_redeemed - f.issued_value + f.redeemed_value, 12, 2) AS opening_liability,
       DECIMAL(c.cum_issued - c.cum_redeemed, 12, 2) AS closing_liability,
       DECIMAL(100.0 * FLOAT8(c.cum_redeemed) / NULLIF(FLOAT8(c.cum_issued), 0), 6, 2) AS cumulative_redemption_pct
FROM gc_flows f
JOIN cum c ON c.yyyymm = f.yyyymm;

DROP TABLE IF EXISTS gc_flows;

DROP TABLE IF EXISTS gc_issue;

DROP TABLE IF EXISTS ll_months;

CREATE STATISTICS FOR loyalty_liability_monthly;

CREATE STATISTICS FOR gift_card_liability_monthly;

-- Reconciliation: closing gift liability at 2020-12 must equal the real
-- outstanding balance, and loyalty closing points the ledger sum

SELECT (SELECT closing_liability FROM gift_card_liability_monthly WHERE yyyymm = 202012) AS gc_close,
       (SELECT SUM(balance) FROM gift_cards) AS gc_outstanding,
       (SELECT closing_points_balance FROM loyalty_liability_monthly WHERE yyyymm = 202012) AS loy_close,
       (SELECT SUM(points) FROM loyalty_ledger) AS ledger_points;
