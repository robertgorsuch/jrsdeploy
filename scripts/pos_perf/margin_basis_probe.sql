-- margin_basis_probe.sql: decide unit vs extended semantics on qty>1 lines
-- A) If sellingprice is a UNIT price, sellingprice ~= pricebooksaleprice (or regular) regardless of quantity.
SELECT quantity, COUNT(*) AS n,
       AVG(sellingprice) AS avg_sp,
       AVG(pricebookregularprice) AS avg_reg,
       AVG(sellingprice / NULLIF(quantity,0)) AS avg_sp_per_unit
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale' AND quantity BETWEEN 2 AND 5
GROUP BY quantity ORDER BY quantity;
-- B) Same for cost vs pricebookcost
SELECT quantity, COUNT(*) AS n,
       AVG(cost) AS avg_cost,
       AVG(pricebookcost) AS avg_pbcost,
       AVG(cost / NULLIF(quantity,0)) AS avg_cost_per_unit
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale' AND quantity BETWEEN 2 AND 5
GROUP BY quantity ORDER BY quantity;
-- C) Spot-check 20 raw multi-qty lines
SELECT saledate, plu, productdescription, quantity, sellingprice, pricebookregularprice, pricebooksaleprice, cost, pricebookcost
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale' AND quantity = 3
FETCH FIRST 20 ROWS ONLY;
