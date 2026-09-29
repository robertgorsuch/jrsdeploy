-- alter_shift_schedules_labour_cost.sql -- adds a REAL labour_cost column to
-- shift_schedules: scheduled_hours x employees.hourly_wage for the employee
-- on the shift (every shift row joins to an employee). Fixes the Wobby
-- metric total_labour_cost, whose expression was SUM(scheduled_hours), i.e.
-- hours not dollars. No burden or overtime uplift here -- that belongs to
-- store_pnl_monthly (see WOBBY_FINANCIAL_EXTENSION_RECOMMENDATION.md).
-- Re-runnable: the DROP COLUMN fails on the first run, which is expected.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

ALTER TABLE shift_schedules DROP COLUMN labour_cost RESTRICT;

ALTER TABLE shift_schedules ADD COLUMN labour_cost DECIMAL(10,2);

UPDATE shift_schedules FROM employees e
SET labour_cost = DECIMAL(shift_schedules.scheduled_hours * e.hourly_wage, 10, 2)
WHERE shift_schedules.employee_id = e.employee_id;

SELECT COUNT(*) AS shifts, SUM(CASE WHEN labour_cost IS NULL THEN 1 ELSE 0 END) AS null_cost,
       SUM(scheduled_hours) AS hours, SUM(labour_cost) AS labour_cost
FROM shift_schedules;
