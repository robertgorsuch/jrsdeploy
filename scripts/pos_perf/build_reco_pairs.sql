-- build_reco_pairs.sql -- item-item co-occurrence base for the market-basket
-- recommender.
--
-- Grain: one row per unordered PLU pair, with the number of baskets containing
-- both. 942 products give at most 443,211 pairs, so the output is small even
-- though the input is 63.6M sale lines.
--
-- The split is OUT OF TIME. Pairs and item counts are built only from baskets
-- before RECO_CUTOFF, and the later baskets are held back for evaluation. A
-- recommender scored on the same baskets that trained it will look excellent
-- and tell you nothing.
--
-- Only Regular Sale lines count. A return or a void is not evidence that two
-- products belong together.
--
-- plu_a < plu_b keeps each pair once. Comparing the VARCHAR keys directly is
-- safe here because the ordering only has to be consistent, not numeric.
--
-- Requires: pos_sales_detail, pos_sales_txn.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS rec_basket_item;

CREATE TABLE rec_basket_item AS
SELECT DISTINCT
       d.transactionuniqueid AS basket,
       d.plu,
       t.jdn,
       t.sale_date
FROM pos_sales_detail d
JOIN pos_sales_txn t
  ON d.transactionuniqueid = t.transactionuniqueid
WHERE TRIM(d.transactiontype) = 'Regular Sale'
  AND d.quantity > 0;

-- Item popularity in the training window. This doubles as the popularity
-- baseline the model has to beat.

DROP TABLE IF EXISTS rec_item_counts;

CREATE TABLE rec_item_counts AS
SELECT plu,
       COUNT(*) AS baskets
FROM rec_basket_item
WHERE sale_date < DATE '2020-11-01'
GROUP BY plu;

-- Basket size, used to drop single-item baskets from the pair build. A basket
-- of one contributes no pair and only slows the self-join down.

DROP TABLE IF EXISTS rec_basket_size;

CREATE TABLE rec_basket_size AS
SELECT basket, COUNT(*) AS n_items
FROM rec_basket_item
WHERE sale_date < DATE '2020-11-01'
GROUP BY basket;

-- Co-occurrence. Self-join restricted to multi-item training baskets.

DROP TABLE IF EXISTS rec_pair_counts;

CREATE TABLE rec_pair_counts AS
SELECT a.plu AS plu_a,
       b.plu AS plu_b,
       COUNT(*) AS pair_baskets
FROM rec_basket_item a
JOIN rec_basket_item b
  ON a.basket = b.basket
 AND a.plu < b.plu
JOIN rec_basket_size s
  ON s.basket = a.basket
WHERE a.sale_date < DATE '2020-11-01'
  AND b.sale_date < DATE '2020-11-01'
  AND s.n_items BETWEEN 2 AND 40
GROUP BY a.plu, b.plu;

-- Evaluation baskets: multi-item baskets from the held-out window only.

DROP TABLE IF EXISTS rec_test_basket;

CREATE TABLE rec_test_basket AS
SELECT basket, COUNT(*) AS n_items
FROM rec_basket_item
WHERE sale_date >= DATE '2020-11-01'
GROUP BY basket
HAVING COUNT(*) BETWEEN 2 AND 40;

-- Shape check.

SELECT (SELECT COUNT(*) FROM rec_item_counts)  AS train_items,
       (SELECT COUNT(*) FROM rec_basket_size)  AS train_baskets,
       (SELECT COUNT(*) FROM rec_pair_counts)  AS distinct_pairs,
       (SELECT SUM(pair_baskets) FROM rec_pair_counts) AS pair_observations,
       (SELECT COUNT(*) FROM rec_test_basket)  AS test_baskets;
