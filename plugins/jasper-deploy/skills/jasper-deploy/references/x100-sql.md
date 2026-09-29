# Actian Avalanche / X100 SQL for report queries

What changes when the JRS datasource is an Actian Data Platform (Avalanche)
warehouse rather than PostgreSQL. X100 is the columnar engine behind Avalanche
tables; the SQL surface is Ingres-flavoured and a few constructs a PostgreSQL
report query takes for granted are rejected or behave differently. Everything
below was hit while building the POS performance suite (the `scripts/pos_perf`
SQL in the repo) and is cited to the file that carries the workaround.

Scope: report/Domain SQL and the loader tooling. Warehouse lifecycle (start,
stop, sleep, scale) is the `admiral` skill's job; a report datasource test that
fails `connection.failed` against a warehouse that worked yesterday usually
means the warehouse idle-stopped, not that the datasource is wrong.

ASCII only.

## Engine restrictions

| # | Rejected / unsupported | Workaround | Evidence |
| --- | --- | --- | --- |
| X1 | Ordered aggregate window functions (`SUM(x) OVER (PARTITION BY ... ORDER BY ...)`, running totals, `LAG`/`LEAD` style lags) | Running max/min via a self-join on `<=` with `GROUP BY`; lag and rolling features derived client-side (pandas) when the row count allows | `build_customer_month.sql` ("running max via self-join, X100 has no ordered aggregate windows"); `build_store_day_features.sql` ("Lag and rolling features are NOT built here ... cheaper and clearer to derive in pandas") |
| X2 | A correlated variable or scalar subquery referenced inside an aggregate (`MAX(CASE WHEN d <= (SELECT ...) ...)`) | Materialise the scalar into a one-row table first and cross join it, so the value is a plain column | `build_customer_ipt_stats.sql` ("X100 rejects aggregates that reference a scalar subquery, so the value is carried as a plain column") |
| X3 | `INTERVAL()` on X100 tables (date differences in days) | Pure integer arithmetic on a Julian day number (`jdn`) column; `DATE + integer` IS allowed, so a calendar spine can be generated arithmetically | `build_customers.sql` ("INTERVAL() is not supported on X100 tables"); `build_inventory.sql`; `build_date_dim.sql` ("X100 allows DATE plus integer") |
| X4 | Unordered window functions (`... OVER ()`) in a JRS report query are fine for the warehouse, but a query that STARTS with `WITH` is rejected by the JRS SQL security validator, not by X100 | Push each CTE down into a nested `FROM (...)` subquery so the statement begins with `SELECT`; `deploy_report.ps1` lints for it | `gotchas.md` G15 |

Things that DO work on X100 tables and are safe to scaffold against:
- `MEDIAN(col)` as a plain aggregate (used for inter-purchase-time medians in
  `build_churn_training_set.sql` and `build_customer_ipt_stats.sql`).
- `GREATEST` / `LEAST`, `INT4()` / `DECIMAL(x, p, s)` casts, `YEAR()` /
  `MONTH()`, `COALESCE`, `CASE`.
- `CREATE TABLE ... AS SELECT ... WITH PARTITION = (HASH ON key N PARTITIONS)`
  for the aggregates a report reads; pre-aggregate at the grain the tile needs
  and let the report do a plain `SELECT`, which also keeps the JRS validator
  happy.
- `DROP TABLE IF EXISTS` for drop-and-rebuild scripts.

## Naming
- A schema (owner) name that contains a dot must be double-quoted when
  qualified (`"first.last".table`); unqualified names resolve against the
  connecting user, which is the simplest way to write report SQL. Keep the
  datasource's user equal to the schema owner and leave names unqualified.

## Loader tooling (`admiral` skill, `sql.ps1`)

| # | Trap | Rule | Evidence |
| --- | --- | --- | --- |
| T1 | `run-file` splits the file on `;` with quote tracking but NO comment awareness: a `;` inside a `--` comment ends the statement early, and an unbalanced apostrophe inside a comment (`-- don't`) flips the quote state for the rest of the file, so everything after it silently becomes one statement | Never put `;` or an unbalanced apostrophe in a SQL-file comment; the POS pipeline's `check_sql_comments()` (in `pos_ml_common.py`) scans a file for both before it is ever run | `Split-SqlStatements` in `sql.ps1`; `pos_ml_common.py` docstring "SQL gotchas" |
| T2 | `export-csv` (PowerShell `Export-Csv` over the JDBC/ODBC result) is not a reliable bulk path for wide or large result sets | Read result sets in Python over `pyodbc` (Actian Ingres ODBC driver, `autocommit=True`), which is what every model pipeline in `scripts/pos_perf` does | `pos_ml_common.py`, `churn_model.py`, `plu_demand_model.py` all connect via `pyodbc` |
| T3 | The warehouse may be idle-stopped or asleep; any JDBC/ODBC or JRS `contexts` connection test then fails with a driver error that looks like bad credentials | Start / wake the warehouse through the `admiral` skill first, then re-run the datasource test (`create_datasource.ps1 -Test`, `doctor.ps1`) | `admiral` skill SKILL.md (warehouse lifecycle, idle-stop) |

## Checklist before scaffolding a report against X100
1. No ordered window, no `LAG`/`LEAD`, no correlated subquery inside an aggregate
   (X1, X2). Pre-aggregate into a table if the tile needs a running value.
2. No `INTERVAL()`; use `jdn` arithmetic or `DATE + n` (X3).
3. Statement starts with `SELECT` for JRS (X4); test the pushed-down form in the
   warehouse first for identical output.
4. `<field class>` per column type as usual (`jr7-schema.md` G6); `DECIMAL`
   casts land as `java.math.BigDecimal`.
5. If a metric is compared across boards, state its period window in the label
   (`data-and-semantic-layer.md` G58).
6. Warehouse awake (T3) before `deploy_report.ps1` runs the verify PDF.
