-- build_loyalty.sql -- DROP-and-rebuild of loyalty_ledger (about 20.5M rows).
-- One EARN entry per REAL transaction (19.5M transactions from
-- pos_sales_detail) -- points = 10 per dollar of the real transaction total.
-- Negative-total transactions (returns) become ADJUST entries with negative
-- points. About 1 in 20 transactions with spend of 10 dollars or more also
-- gets a REDEEM entry -- a hash-deterministic redemption of 100 to 500
-- points. Balances are derivable downstream by summing points per customer.
-- Ties: customer_id joins customers, storenumber joins stores,
-- transactionuniqueid joins pos_sales_detail line items.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS loy_txn;

CREATE TABLE loy_txn AS
SELECT transactionuniqueid,
       MAX(customernumber) AS customer_id,
       MAX(storenumber) AS storenumber,
       MAX(DATE(saledate)) AS entry_date,
       SUM(sellingprice * quantity) AS spend
FROM pos_sales_detail
GROUP BY transactionuniqueid;

DROP TABLE IF EXISTS loyalty_ledger;

CREATE TABLE loyalty_ledger AS
SELECT transactionuniqueid, customer_id, storenumber, entry_date,
       CASE WHEN spend >= 0 THEN 'EARN' ELSE 'ADJUST' END AS entry_type,
       INT4(spend * 10 + CASE WHEN spend >= 0 THEN 0.5 ELSE -0.5 END) AS points,
       DECIMAL(spend, 12, 2) AS spend_amount
FROM loy_txn
UNION ALL
SELECT transactionuniqueid, customer_id, storenumber, entry_date,
       'REDEEM' AS entry_type,
       -(100 + ABS(MOD(HASH(transactionuniqueid + 'ra'), 9)) * 50) AS points,
       CAST(NULL AS DECIMAL(12, 2)) AS spend_amount
FROM loy_txn
WHERE ABS(MOD(HASH(transactionuniqueid + 'rd'), 20)) = 0 AND spend >= 10;

DROP TABLE IF EXISTS loy_txn;
