-- build_service_giftcards.sql -- DROP-and-rebuild of customer_service_cases
-- and gift_cards. Both sample REAL transactions (shared aggregate svc_txn),
-- so every case and card ties to a real customer, store, date, and amount.
-- customer_service_cases: 1-in-400 transaction sample (about 49K cases).
-- Reason mix: Product Quality 30, Billing Dispute 15, Store Experience 15,
-- Freezer Burn 10, Delivery Issue 10, Loyalty Points 10, Other 10 percent.
-- 90 percent of cases are Closed with a resolution time and CSAT skewed
-- toward 4 and 5.
-- gift_cards: 1-in-200 sample of transactions of 25 dollars or more (about
-- 90K cards) -- value 25 / 50 / 100, hash-deterministic redemption progress.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS svc_txn;

CREATE TABLE svc_txn AS
SELECT transactionuniqueid,
       MAX(customernumber) AS customer_id,
       MAX(storenumber) AS storenumber,
       MAX(DATE(saledate)) AS txn_date,
       SUM(sellingprice * quantity) AS spend,
       MIN(TRIM(plu)) AS sample_plu
FROM pos_sales_detail
GROUP BY transactionuniqueid;

DROP TABLE IF EXISTS customer_service_cases;

CREATE TABLE customer_service_cases AS
WITH s AS (
  SELECT t.*,
         ABS(MOD(HASH(t.transactionuniqueid + 'rs'), 20)) AS r_h,
         ABS(MOD(HASH(t.transactionuniqueid + 'chn'), 4)) AS ch_h,
         ABS(MOD(HASH(t.transactionuniqueid + 'res'), 15)) AS res_h,
         ABS(MOD(HASH(t.transactionuniqueid + 'stt'), 20)) AS st_h,
         ABS(MOD(HASH(t.transactionuniqueid + 'sat'), 10)) AS sat_h
  FROM svc_txn t
  WHERE ABS(MOD(HASH(t.transactionuniqueid + 'cs'), 400)) = 0
)
SELECT 'CS-' + s.transactionuniqueid AS case_id,
       s.customer_id, s.storenumber, s.txn_date AS open_date,
       s.transactionuniqueid, s.sample_plu AS related_plu,
       p.product_name AS related_product,
       CASE s.ch_h WHEN 0 THEN 'Phone' WHEN 1 THEN 'Email' WHEN 2 THEN 'In-Store' ELSE 'Web' END AS channel,
       CASE WHEN s.r_h <= 5 THEN 'Product Quality'
            WHEN s.r_h <= 7 THEN 'Freezer Burn'
            WHEN s.r_h <= 10 THEN 'Billing Dispute'
            WHEN s.r_h <= 12 THEN 'Delivery Issue'
            WHEN s.r_h <= 15 THEN 'Store Experience'
            WHEN s.r_h <= 17 THEN 'Loyalty Points'
            ELSE 'Other' END AS reason,
       CASE WHEN s.st_h < 18 THEN 'Closed' ELSE 'Open' END AS status,
       CASE WHEN s.st_h < 18 THEN s.res_h END AS resolution_days,
       CASE WHEN s.st_h < 18 THEN
            CASE WHEN s.sat_h = 0 THEN 1 WHEN s.sat_h = 1 THEN 2
                 WHEN s.sat_h <= 3 THEN 3 WHEN s.sat_h <= 6 THEN 4 ELSE 5 END
       END AS csat_score
FROM s
LEFT JOIN products p ON p.plu = s.sample_plu;

DROP TABLE IF EXISTS gift_cards;

CREATE TABLE gift_cards AS
WITH g AS (
  SELECT t.*,
         ABS(MOD(HASH(t.transactionuniqueid + 'gv'), 3)) AS v_h,
         ABS(MOD(HASH(t.transactionuniqueid + 'gr'), 101)) AS redeemed_pct
  FROM svc_txn t
  WHERE ABS(MOD(HASH(t.transactionuniqueid + 'gc'), 200)) = 0
    AND t.spend >= 25
)
SELECT 'GC-' + g.transactionuniqueid AS card_id,
       g.customer_id AS purchased_by, g.storenumber AS purchase_store,
       g.txn_date AS purchase_date,
       CASE g.v_h WHEN 0 THEN DECIMAL(25.00, 8, 2) WHEN 1 THEN DECIMAL(50.00, 8, 2)
            ELSE DECIMAL(100.00, 8, 2) END AS initial_value,
       g.redeemed_pct,
       DECIMAL(CASE g.v_h WHEN 0 THEN 25.00 WHEN 1 THEN 50.00 ELSE 100.00 END
               * g.redeemed_pct / 100.0, 8, 2) AS redeemed_amount,
       DECIMAL(CASE g.v_h WHEN 0 THEN 25.00 WHEN 1 THEN 50.00 ELSE 100.00 END
               * (100 - g.redeemed_pct) / 100.0, 8, 2) AS balance,
       CASE WHEN g.redeemed_pct = 0 THEN 'Unused'
            WHEN g.redeemed_pct = 100 THEN 'Depleted'
            ELSE 'Partially Redeemed' END AS status
FROM g;

DROP TABLE IF EXISTS svc_txn;
