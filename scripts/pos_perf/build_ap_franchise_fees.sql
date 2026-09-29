-- build_ap_franchise_fees.sql -- DROP-and-rebuild of ap_invoices (accounts
-- payable to suppliers, one invoice per purchase order, 92,472 rows) and
-- franchise_fee_ledger (accounts receivable from franchisees, one invoice
-- per fee-bearing store-month, 7,706 rows). As-of date for status and aging
-- is 2020-12-31, the end of the dataset.
--
-- ap_invoices -- REAL: po_number, supplier, store, amount (= po_value_cost,
-- 524.2M lifetime), invoice_date (= order_date + the real actual_lead_days,
-- i.e. goods receipt), payment terms (suppliers.payment_terms Net 30/45/60).
-- FICTITIOUS but DETERMINISTIC from HASH(po_number + salt): payment
-- behaviour -- 10 pct early payers who take the early-payment discount
-- (2 pct on Net 30, 1 pct otherwise), 70 pct pay on or before due, 20 pct
-- pay 1-20 days late. Payments falling after 2020-12-31 revert to unpaid:
-- status Open (not yet due) or Overdue (past due), with aging buckets.
--
-- franchise_fee_ledger -- REAL: royalty_fee and marketing_fee from
-- store_pnl_monthly (real rates on real sales), invoice_date = month end.
-- FICTITIOUS but DETERMINISTIC from HASH(store|month + salt): 80 pct pay on
-- time (due = invoice + 15), 16 pct pay 1-45 days late, 4 pct miss --
-- unpaid as of 2020-12-31 with aging buckets.
-- Requires: purchase_orders, suppliers, stores, store_pnl_monthly,
-- franchisees, date_dim.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS ap_asof;

CREATE TABLE ap_asof AS
SELECT MAX(calendar_date) AS as_of_date FROM date_dim;

DROP TABLE IF EXISTS ap_invoices;

CREATE TABLE ap_invoices AS
WITH b AS (
  SELECT p.po_number, p.supplier_name, p.storenumber, st.province, st.region,
         p.order_date, p.order_date + p.actual_lead_days AS invoice_date,
         s.payment_terms, INT4(RIGHT(TRIM(s.payment_terms), 2)) AS terms_days,
         p.po_value_cost AS amount, a.as_of_date,
         ABS(MOD(HASH(p.po_number + 'pay'), 100)) AS h_pay,
         ABS(MOD(HASH(p.po_number + 'jit'), 100)) AS h_jit
  FROM purchase_orders p
  JOIN suppliers s ON s.supplier_name = p.supplier_name
  JOIN stores st ON st.storenumber = p.storenumber
  CROSS JOIN ap_asof a
), d AS (
  SELECT b.*, invoice_date + terms_days AS due_date,
         CASE WHEN h_pay < 10 THEN invoice_date + 5 + MOD(h_jit, 6)
              WHEN h_pay < 80 THEN invoice_date + terms_days - MOD(h_jit, 11)
              ELSE invoice_date + terms_days + 1 + MOD(h_jit, 20) END AS paid_calc,
         CASE WHEN h_pay < 10 AND payment_terms = 'Net 30' THEN 2.0
              WHEN h_pay < 10 THEN 1.0 ELSE 0.0 END AS discount_pct
  FROM b
)
SELECT 'INV-' + po_number AS invoice_number, po_number, supplier_name, storenumber, province, region,
       order_date, invoice_date, YEAR(invoice_date) * 100 + MONTH(invoice_date) AS invoice_yyyymm,
       payment_terms, terms_days, due_date,
       CASE WHEN paid_calc <= as_of_date THEN paid_calc END AS paid_date,
       DECIMAL(amount, 12, 2) AS amount,
       DECIMAL(CASE WHEN paid_calc <= as_of_date THEN amount * discount_pct / 100.0 ELSE 0 END, 10, 2) AS discount_taken,
       DECIMAL(CASE WHEN paid_calc <= as_of_date THEN amount * (1.0 - discount_pct / 100.0) ELSE 0 END, 12, 2) AS amount_paid,
       DECIMAL(CASE WHEN paid_calc <= as_of_date THEN 0 ELSE amount END, 12, 2) AS balance,
       CASE WHEN paid_calc <= as_of_date THEN 'Paid'
            WHEN due_date >= as_of_date THEN 'Open' ELSE 'Overdue' END AS status,
       CASE WHEN paid_calc <= as_of_date THEN paid_calc - invoice_date END AS days_to_pay,
       CASE WHEN paid_calc <= as_of_date AND paid_calc > due_date THEN paid_calc - due_date ELSE 0 END AS days_paid_late,
       CASE WHEN paid_calc > as_of_date AND due_date < as_of_date THEN as_of_date - due_date ELSE 0 END AS days_overdue,
       CASE WHEN paid_calc <= as_of_date THEN 'Paid'
            WHEN due_date >= as_of_date THEN 'Current'
            WHEN as_of_date - due_date <= 30 THEN '1-30 days'
            WHEN as_of_date - due_date <= 60 THEN '31-60 days'
            ELSE '60+ days' END AS aging_bucket,
       CASE WHEN h_pay < 10 THEN 'Early' WHEN h_pay < 80 THEN 'On time' ELSE 'Late' END AS payer_profile
FROM d;

DROP TABLE IF EXISTS ff_monthend;

CREATE TABLE ff_monthend AS
SELECT yyyymm, MAX(calendar_date) AS month_end FROM date_dim GROUP BY yyyymm;

DROP TABLE IF EXISTS franchise_fee_ledger;

CREATE TABLE franchise_fee_ledger AS
WITH b AS (
  SELECT p.storenumber, p.storename, p.franchisee_id, f.owner_name, p.province, p.region,
         p.yyyymm, p.month_start, m.month_end AS invoice_date, m.month_end + 15 AS due_date,
         p.royalty_fee, p.marketing_fee, p.royalty_fee + p.marketing_fee AS total_invoiced,
         p.net_sales, a.as_of_date,
         ABS(MOD(HASH(VARCHAR(p.storenumber) + '|' + VARCHAR(p.yyyymm) + 'ff'), 100)) AS h_pay,
         ABS(MOD(HASH(VARCHAR(p.storenumber) + '|' + VARCHAR(p.yyyymm) + 'fj'), 100)) AS h_jit
  FROM store_pnl_monthly p
  JOIN ff_monthend m ON m.yyyymm = p.yyyymm
  JOIN franchisees f ON f.franchisee_id = p.franchisee_id
  CROSS JOIN ap_asof a
  WHERE p.royalty_fee + p.marketing_fee > 0
), d AS (
  SELECT b.*,
         CASE WHEN h_pay < 80 THEN due_date - MOD(h_jit, 6)
              WHEN h_pay < 96 THEN due_date + 1 + MOD(h_jit, 45)
              ELSE due_date + 500 END AS paid_calc
  FROM b
)
SELECT 'FF-' + VARCHAR(storenumber) + '-' + VARCHAR(yyyymm) AS invoice_number,
       storenumber, storename, franchisee_id, owner_name, province, region,
       yyyymm, month_start, invoice_date, due_date,
       CASE WHEN paid_calc <= as_of_date THEN paid_calc END AS paid_date,
       DECIMAL(royalty_fee, 12, 2) AS royalty_fee,
       DECIMAL(marketing_fee, 12, 2) AS marketing_fee,
       DECIMAL(total_invoiced, 12, 2) AS total_invoiced,
       DECIMAL(CASE WHEN paid_calc <= as_of_date THEN total_invoiced ELSE 0 END, 12, 2) AS amount_paid,
       DECIMAL(CASE WHEN paid_calc <= as_of_date THEN 0 ELSE total_invoiced END, 12, 2) AS balance,
       CASE WHEN paid_calc <= as_of_date THEN 'Paid'
            WHEN due_date >= as_of_date THEN 'Open' ELSE 'Overdue' END AS status,
       CASE WHEN paid_calc <= as_of_date AND paid_calc > due_date THEN paid_calc - due_date ELSE 0 END AS days_paid_late,
       CASE WHEN paid_calc > as_of_date AND due_date < as_of_date THEN as_of_date - due_date ELSE 0 END AS days_overdue,
       CASE WHEN paid_calc <= as_of_date THEN 'Paid'
            WHEN due_date >= as_of_date THEN 'Current'
            WHEN as_of_date - due_date <= 30 THEN '1-30 days'
            WHEN as_of_date - due_date <= 60 THEN '31-60 days'
            ELSE '60+ days' END AS aging_bucket,
       DECIMAL(100.0 * total_invoiced / NULLIF(net_sales, 0), 6, 2) AS fee_pct_of_sales
FROM d;

DROP TABLE IF EXISTS ff_monthend;

DROP TABLE IF EXISTS ap_asof;

CREATE STATISTICS FOR ap_invoices;

CREATE STATISTICS FOR franchise_fee_ledger;
