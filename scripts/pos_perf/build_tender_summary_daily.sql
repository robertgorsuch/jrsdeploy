-- build_tender_summary_daily.sql -- DROP-and-rebuild of tender_summary_daily:
-- how each store-day of REAL sales was paid, one row per store x day x
-- tender type with a positive amount (about 1.7M rows over 229,594 real
-- store-days). Tender types: Cash, Debit, Credit Visa, Credit Mastercard,
-- Credit Amex, Mobile Wallet, Gift Card, Loyalty Points.
-- REAL: the store-day sales total and transaction count (pos_sales_txn,
-- Regular Sale), the Loyalty Points tender (loyalty_ledger REDEEM events at
-- the 1,000 points per CAD convention -- see the Loyalty liability spec),
-- and the Gift Card tender in aggregate (hash-spread across store-days but
-- scaled so the lifetime total equals gift_cards.redeemed_amount,
-- 1,692,490.75, to the cent).
-- FICTITIOUS but DETERMINISTIC: the split of the remainder across the six
-- payment tenders -- base mix by pandemic period (cash 22 to 10 pct,
-- mobile 6 to 15 pct after 2020-03), a per-store bias and per-day noise
-- from HASH(store|day + salt), normalised to the remainder.
-- processing_fee: Debit 0.06 CAD per transaction, Visa and Mastercard 1.6
-- pct, Amex 2.4 pct, Mobile Wallet 1.8 pct, Cash and stored value 0. These
-- fees replace the modeled card-fee rate in store_pnl_monthly.
-- Requires: pos_sales_txn, stores, loyalty_ledger, gift_cards, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS td_day;

CREATE TABLE td_day AS
SELECT t.storenumber, t.sale_date, t.jdn, t.yyyymm, MAX(t.is_weekend) AS is_weekend,
       MAX(t.pandemic_period) AS pandemic_period,
       MAX(s.province) AS province, MAX(s.region) AS region,
       SUM(t.basket_value) AS day_sales, COUNT(*) AS day_txns
FROM pos_sales_txn t
JOIN stores s ON s.storenumber = t.storenumber
WHERE t.txn_type = 'Regular Sale'
GROUP BY t.storenumber, t.sale_date, t.jdn, t.yyyymm;

-- REAL loyalty redemptions per store-day, 1,000 points = 1 CAD

DROP TABLE IF EXISTS td_loy;

CREATE TABLE td_loy AS
SELECT storenumber, entry_date, SUM(-points) / 1000.0 AS loyalty_amt, COUNT(*) AS loyalty_txns
FROM loyalty_ledger
WHERE entry_type = 'REDEEM'
GROUP BY storenumber, entry_date;

-- Gift card tender: hash weights scaled so the network total equals the
-- REAL lifetime gift_cards.redeemed_amount exactly

DROP TABLE IF EXISTS td_gift_w;

CREATE TABLE td_gift_w AS
SELECT storenumber, sale_date,
       day_sales * (50 + ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'gft'), 101))) / 100.0 AS w
FROM td_day;

DROP TABLE IF EXISTS td_gift_t;

CREATE TABLE td_gift_t AS
SELECT SUM(redeemed_amount) AS total_redeemed FROM gift_cards;

DROP TABLE IF EXISTS td_gift_s;

CREATE TABLE td_gift_s AS
SELECT SUM(w) AS wsum FROM td_gift_w;

DROP TABLE IF EXISTS td_gift_k;

CREATE TABLE td_gift_k AS
SELECT FLOAT8(t.total_redeemed) / FLOAT8(s.wsum) AS k FROM td_gift_t t CROSS JOIN td_gift_s s;

DROP TABLE IF EXISTS td_base;

CREATE TABLE td_base AS
SELECT d.*, COALESCE(l.loyalty_amt, 0) AS loyalty_amt, COALESCE(l.loyalty_txns, 0) AS loyalty_txns,
       g.w * k.k AS gift_amt,
       GREATEST(0.0, d.day_sales - COALESCE(l.loyalty_amt, 0) - g.w * k.k) AS remainder
FROM td_day d
LEFT JOIN td_loy l ON l.storenumber = d.storenumber AND l.entry_date = d.sale_date
JOIN td_gift_w g ON g.storenumber = d.storenumber AND g.sale_date = d.sale_date
CROSS JOIN td_gift_k k;

-- Six payment-tender weights: base mix by pandemic period, per-store bias,
-- per-day noise, then normalised to the remainder

DROP TABLE IF EXISTS td_wts;

CREATE TABLE td_wts AS
WITH w AS (
  SELECT b.*,
         (CASE WHEN pandemic_period = 'Pandemic' THEN 10.0 ELSE 22.0 END
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'csh'), 7)), 7) - 3
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'c'), 5)), 5) - 2) AS w_cash,
         (CASE WHEN pandemic_period = 'Pandemic' THEN 26.0 ELSE 28.0 END
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'dbt'), 7)), 7) - 3
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'd'), 5)), 5) - 2) AS w_debit,
         (CASE WHEN pandemic_period = 'Pandemic' THEN 27.0 ELSE 24.0 END
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'vsa'), 7)), 7) - 3
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'v'), 5)), 5) - 2) AS w_visa,
         (CASE WHEN pandemic_period = 'Pandemic' THEN 18.0 ELSE 16.0 END
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'mcd'), 5)), 5) - 2
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'm'), 5)), 5) - 2) AS w_mc,
         (4.0 + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'amx'), 5)), 5) - 2) AS w_amex,
         (CASE WHEN pandemic_period = 'Pandemic' THEN 15.0 ELSE 6.0 END
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + 'mob'), 5)), 5) - 2
          + MOD(ABS(MOD(HASH(VARCHAR(storenumber) + '|' + VARCHAR(jdn) + 'w'), 5)), 5) - 2) AS w_mobile
  FROM td_base b
)
SELECT w.*, GREATEST(1.0, w_cash) + GREATEST(1.0, w_debit) + GREATEST(1.0, w_visa)
          + GREATEST(1.0, w_mc) + GREATEST(1.0, w_amex) + GREATEST(1.0, w_mobile) AS w_sum
FROM w;

DROP TABLE IF EXISTS tender_summary_daily;

CREATE TABLE tender_summary_daily AS
WITH s AS (
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns,
         'Cash' AS tender_type, 'Cash' AS tender_group,
         remainder * GREATEST(1.0, w_cash) / w_sum AS amount,
         day_txns * GREATEST(1.0, w_cash) / w_sum AS est_txns,
         0.0 AS fee_pct, 0.0 AS fee_flat
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Debit', 'Card',
         remainder * GREATEST(1.0, w_debit) / w_sum,
         day_txns * GREATEST(1.0, w_debit) / w_sum, 0.0, 0.06
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Credit Visa', 'Card',
         remainder * GREATEST(1.0, w_visa) / w_sum,
         day_txns * GREATEST(1.0, w_visa) / w_sum, 1.6, 0.0
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Credit Mastercard', 'Card',
         remainder * GREATEST(1.0, w_mc) / w_sum,
         day_txns * GREATEST(1.0, w_mc) / w_sum, 1.6, 0.0
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Credit Amex', 'Card',
         remainder * GREATEST(1.0, w_amex) / w_sum,
         day_txns * GREATEST(1.0, w_amex) / w_sum, 2.4, 0.0
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Mobile Wallet', 'Card',
         remainder * GREATEST(1.0, w_mobile) / w_sum,
         day_txns * GREATEST(1.0, w_mobile) / w_sum, 1.8, 0.0
  FROM td_wts
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Gift Card', 'Stored Value', gift_amt,
         GREATEST(1.0, gift_amt / 30.0), 0.0, 0.0
  FROM td_wts WHERE gift_amt > 0
  UNION ALL
  SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
         day_sales, day_txns, 'Loyalty Points', 'Stored Value', loyalty_amt, loyalty_txns, 0.0, 0.0
  FROM td_wts WHERE loyalty_amt > 0
)
SELECT storenumber, province, region, sale_date, jdn, yyyymm, is_weekend, pandemic_period,
       tender_type, tender_group,
       DECIMAL(amount, 12, 2) AS amount,
       INT4(est_txns + 0.5) AS est_transactions,
       DECIMAL(fee_pct, 5, 2) AS fee_pct,
       DECIMAL(amount * fee_pct / 100.0 + est_txns * fee_flat, 10, 2) AS processing_fee
FROM s
WHERE amount > 0.005;

DROP TABLE IF EXISTS td_wts;

DROP TABLE IF EXISTS td_base;

DROP TABLE IF EXISTS td_gift_k;

DROP TABLE IF EXISTS td_gift_s;

DROP TABLE IF EXISTS td_gift_t;

DROP TABLE IF EXISTS td_gift_w;

DROP TABLE IF EXISTS td_loy;

DROP TABLE IF EXISTS td_day;

CREATE STATISTICS FOR tender_summary_daily;
