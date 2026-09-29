# POS Dashboard Suite - Phase 3 (Operations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy to STAGE the Supply and Inventory console (dashboard 7), the Workforce and Labour cockpit (dashboard 8), and their three paginated reports (Inventory Reorder List, Supplier Scorecard, Weekly Flash), fed by tables that already exist and reconcile.

**Architecture:** One new aggregate (`dash_labour`, store x calendar-date x shift grain, joining `shift_schedules` to `date_dim` and a traffic-proportional sales allocation from `store_traffic`) plus direct reads of `inventory` (215,009 rows), `purchase_orders` (92,472 rows), `suppliers`, `shrinkage_log` — all small enough to query live, matching the AR/AP precedent from Phase 1 (no new aggregate needed for supply). Dashboard 7 is a Console (filter strip via the manifest `"filters"` key); dashboard 8 is a Cockpit (no filter strip, matching the `pnl_dashboard.json` precedent). Weekly Flash reads date-scoped slices of daily-grain tables directly rather than needing a new weekly aggregate.

**Tech Stack:** Actian Avalanche X100 (Ingres JDBC, `av-flm7ykoxlcvq`, schema `robert.gorsuch`), JasperReports Server 10.0.0 Pro (STAGE `http://localhost:8081/jasperserver-pro`), PowerShell 5.1, jasper-deploy skill, admiral skill.

**Spec:** `specs/2026-08-23-pos-suite-design.md` (dashboards 7 and 8, and the three Phase 3 reports). Phase 4 gets its own plan after this one ships.

## Global Constraints

- Repo is PUBLIC. No credentials, hostnames-with-passwords, or API keys in any committed file. JRS creds from `.claude/skills/jasper-deploy/jrs.config.json` (gitignored); warehouse creds from `.claude/skills/admiral/admiral.config.json`. **`.claude/` is gitignored — the tracked mirror of any `.claude/skills/jasper-deploy/...` reference file is `plugins/jasper-deploy/skills/jasper-deploy/...`; edit the tracked path, not the symlink** (confirmed this session, Phase 2 Task's final fix wave).
- Environment selection: `$env:JRS_ENV = "stage"` before any `$jd` script. **Never run a `$jd` script against `prod` in this plan.** PROD promotion is a separate go/no-go the user runs later (RUNBOOK.md pattern already established for Phases 1 and 2) — the last task documents the block, nobody executes it.
- Warehouse calls: `& "$adm\sql.ps1" -Action run-file -SqlFile <file> -ResourceId av-flm7ykoxlcvq`. `run-file` splits on EVERY `;` and tracks `'`/`"` state with no comment awareness: **no `;`, `'`, or `"` inside any SQL comment**. Wrap every ratio in `FLOAT8(...)`. Use `FIRST n`, not `LIMIT`. Views: `DROP VIEW IF EXISTS`; tables: `DROP TABLE IF EXISTS ... ; CREATE TABLE ... AS SELECT ...; CREATE STATISTICS FOR <table>;`.
- Confirmed X100 gotchas from Phases 1-2 (all durably referenced in `RUNBOOK.md` and `memory/x100-sql-quirks.md` — read the RUNBOOK Phase 1/2 gotchas paragraphs before writing SQL): arithmetic directly on an `ANSIDATE` column throws `Rewriter error` (use `EXTRACT(YEAR FROM ...)` / join to `date_dim` instead); `--` inside an XML `<!-- -->` comment is not well-formed XML and passes `lint_jrxml.ps1` but fails at deploy/compile with an opaque error (never use a literal double-hyphen inside a JRXML comment); `COUNT(DISTINCT col)` inside a derived table subquery that also uses `FIRST n` throws `Rewriter error` (compute distinct counts and `FIRST n` caps in separate steps).
- JRXML is JR7-native: `<query language="SQL">`, `<element kind="staticText|textField|line|rectangle|image|chart">`, `<text>`/`<expression>` children, `<element kind="chart" chartType="bar|stackedBar|line|area|pie|meter">` with `<dataset kind="category">` and `<plot><seriesColor order="n" color="#hex"/></plot>`. Charts in the `title` band need `evaluationTime="Report"`. Never mix JR6 legacy syntax into a JR7 file. `<seriesColor order="n">` binds by series REGISTRATION order — a null value on the first row does not register, shifting/inverting colours. Guard every chart series with a zero default.
- **Heatmap technique (new this phase — resolve empirically, do not assume):** the spec calls `lab_heatmap` an "HTML5 heatmap". Phase 1 hit the identical situation with the waterfall tile and the plan's assumed HTML5 chart type did not exist in this JR7 install; the resolved, shipped answer was a JFreeChart-native technique instead (stacked bar with an invisible base series), fully documented in `pnl_waterfall.jrxml`'s header comment. Task 4 below follows the same discovery process: try the native approach first (check `.claude/skills/jasper-deploy/references/` — really `plugins/jasper-deploy/skills/jasper-deploy/references/` — for a heatmap-capable component; JR7 does not ship an `<element kind="chart" chartType="heatmap">`, so the real options are (a) a `crosstab` with per-cell `conditionalStyle` backgrounds keyed to a value bucket, giving a heatmap-styled grid without a "chart" at all, or (b) an `xyBubble`/`scatter` chart with cell centers as points sized/coloured by value). Pick whichever renders correctly on this server, document the choice and why in the file's header comment (matching the waterfall precedent), and do not spend more than one extra redeploy cycle chasing a "more HTML5" alternative once one approach compiles and renders correctly.
- Brand, light theme (this whole phase is light — Console and Cockpit archetypes, no navy): Actian logo top-left (`"repo:/images/actian_logo"`, 44x44 at 0,0), title centered `forecolor="#1F4E79"` 16pt bold, subtitle `#5B7DA6` 9pt; KPI label `fontSize="13.0" forecolor="#5B7DA6"`, KPI value `fontSize="26.0" bold forecolor="#1F4E79"`, dividers `#D6E0EF`; table header `#1F4E79` on white, zebra `#D6E0EF`; series order `#0550DC`, `#1DB6C0`, `#0A4CAD`, `#239CA8`; favourable/unfavourable `#5CB85C` / `#D9534F`.
- No "Foodmart", "Wobby", datasource URIs, SQL, table or column names in user-visible text. Dashboard labels contain no `&` (compose does not XML-escape). Current-year rule does not apply: this data is dated 2019-2020 and the tiles say so.
- Dashboards: 40-unit grid, every dashlet `showTitleBar:false`. Dashboard 7 (Console) gets a filter strip synthesized by the composer from the manifest's top-level `"filters"` array (no explicit control-tile jrxml, no `dashletFilterShowPopup` — matches `trs_dashboard.json`/`chn_dashboard.json`). Dashboard 8 (Cockpit) gets NO filters key and NO controls attached to any tile (matches `pnl_dashboard.json`, which has no `"filters"` key at all). Delete the dashboard (`teardown_dashboard.ps1 -Uri ...`) before every recompose. Dashboards cannot be run to PDF — verify tiles individually.
- Page sizes by tile shape (pageWidth x pageHeight, margins 10 unless stated): 40x4 KPI strip 1600x130; 40x3 control strip 1600x100 (unused this phase — no explicit control tile); 20x10 or 20x11 chart 800x420 (from the established 800-width list/chart bucket); 21x10 chart 1000x380; 40x12 wide table/heatmap 1600x460 (new this phase, derived from the 40x4-strip's 40px/unit width rule: 40*40=1600, height scaled from the 20x12->440 bucket: 440*12/12=440 plus a 20px title-band allowance for the heatmap's legend = 460).
- `deploy_report.ps1 -Overwrite` DROPS a report unit's attached inputControls — re-attach and GET-verify after every redeploy. A tile already composed into a dashboard 403s `resource.in.use` on redeploy — teardown the dashboard first, redeploy, re-attach (dashboard 7 tiles only), recompose.
- Acceptance references (from the queries run to ground this plan, warehouse state as of 2026-08-24): `shift_schedules` spans 2019-01-01 to 2020-12-31; total labour cost (lifetime) 70,225,001.95, 2020-only 35,169,013.40; total scheduled hours (lifetime) 3,377,504.00; 2020 net sales 416,459,363.90 (matches Phase 1's figure); `inventory` 215,009 rows across 5 `stock_status` values (In Stock 118,716 / Reorder 26,262 / Critical 33,201 / Out of Stock 26,110 / Overstock 10,720 — OOS pct 12.14, overstock pct 4.98, avg days of supply 27.78); `purchase_orders` 92,472 rows, all `po_status = 'Closed'`, `on_time` Y 78,603 / N 13,869 (85.00 pct on time); `shrinkage_log` total shrink value 1,944,877.43 (5 reasons: Expiry/Damage/Temperature Excursion/Theft/Inventory Adjustment); lifetime COGS (`store_pnl_monthly`) 522,234,650.42, 2020-only 276,039,736.04, so lifetime shrink pct of COGS is about 0.37; `employees` 2,556 total, 2,340 Active (roles: Store Manager/Assistant Manager/Keyholder/Sales Associate); `store_pnl_monthly.store_format` values Standalone/Strip Plaza/Urban Storefront/Shopping Mall (already used in `pnl_worst_stores.jrxml`, no new lookup needed).
- Categorical values used in SQL: `stock_status` = `In Stock` | `Reorder` | `Critical` | `Out of Stock` | `Overstock`; `po_status` = `Closed` (the only value present — do not add a WHERE filter expecting `Open`, there is none in this data); `on_time` = `Y` | `N`; `shift_name` = `Opening` | `Closing`; `role` (employees) = `Store Manager` | `Assistant Manager` | `Keyholder` | `Sales Associate`; `employment_status` = `Active` | `Terminated`; `reason` (shrinkage_log) = `Expiry` | `Damage` | `Temperature Excursion` | `Theft` | `Inventory Adjustment`; `store_format` = `Standalone` | `Strip Plaza` | `Urban Storefront` | `Shopping Mall`; `region` = `Ontario` | `Western` | `Quebec` | `Atlantic` (same vocabulary as Phases 1-2). `date_dim` provides `calendar_date`, `yyyymm`, `yr`, `mo`, `dow_num` (0-6), `day_name`, `is_weekend`, `is_holiday`, `week_of_year`, `quarter` — join on `calendar_date` for any daily-grain table needing calendar attributes.
- **Weekly Flash "vs plan" derivation (controller design decision, binding on Task 7):** `sales_targets` is monthly grain (keyed `storenumber`, `yyyymm`), there is no weekly target table. Derive a weekly plan figure as `target_sales * (days of the report week that fall in that yyyymm) / (days in that yyyymm)` — a simple pro-rated share. If the report week spans a month boundary, sum this pro-ration across both months' `sales_targets` rows. Disclose the derivation in the report's own text (a short subtitle line), not just a code comment — this is a real methodology choice a reader should be able to see, matching this suite's established pattern of visible disclosure (see `rpt_churn_action_list`'s Phase 2 disclosure sentence).

---

### Task 1: dash_labour aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_labour.sql`
- Create: `scripts/pos_perf/verify_dash_labour.sql`

**Interfaces:**
- Consumes: `shift_schedules` (shift_id, storenumber, calendar_date, shift_name, employee_id, scheduled_hours, is_holiday, is_weekend, labour_cost); `date_dim` (calendar_date, yyyymm, dow_num, day_name, is_weekend); `store_traffic` (storenumber, traffic_date, sales).
- Produces: table `dash_labour(storenumber INTEGER, calendar_date ANSIDATE, shift_name VARCHAR(7), yyyymm INTEGER, dow_num INTEGER, day_name VARCHAR, is_weekend VARCHAR(1), scheduled_hours DECIMAL(10,2), labour_cost DECIMAL(12,2), allocated_sales DECIMAL(12,2))`, one row per store x date x shift (up to 330 stores x ~730 days x 2 shifts). Tasks 4 (lab_* tiles) read it.

- [ ] **Step 1: Write the build script**

```sql
-- dash_labour: shift_schedules rolled to store x date x shift, with date_dim
-- calendar attributes and a traffic-proportional sales allocation (no daily
-- store-level sales-by-shift table exists, so each shift's share of the
-- store's daily traffic sales is its share of that day's total scheduled
-- hours -- a documented, disclosed allocation, not a measured figure).
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_labour;
CREATE TABLE dash_labour AS
SELECT s.storenumber, s.calendar_date, s.shift_name,
       d.yyyymm, d.dow_num, d.day_name, d.is_weekend,
       DECIMAL(SUM(s.scheduled_hours), 10, 2) AS scheduled_hours,
       DECIMAL(SUM(s.labour_cost), 12, 2) AS labour_cost,
       DECIMAL(FLOAT8(t.sales) * FLOAT8(SUM(s.scheduled_hours)) / FLOAT8(NULLIF(day_tot.day_hours, 0)), 12, 2) AS allocated_sales
FROM shift_schedules s
JOIN date_dim d ON d.calendar_date = s.calendar_date
LEFT JOIN store_traffic t ON t.storenumber = s.storenumber AND t.traffic_date = s.calendar_date
LEFT JOIN (
  SELECT storenumber, calendar_date, DECIMAL(SUM(scheduled_hours), 10, 2) AS day_hours
  FROM shift_schedules GROUP BY storenumber, calendar_date
) day_tot ON day_tot.storenumber = s.storenumber AND day_tot.calendar_date = s.calendar_date
GROUP BY s.storenumber, s.calendar_date, s.shift_name, d.yyyymm, d.dow_num, d.day_name, d.is_weekend, t.sales, day_tot.day_hours;
CREATE STATISTICS FOR dash_labour;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_labour
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain and row count, expect 0 dup keys, date range 2019-01-01 to 2020-12-31
SELECT COUNT(*) AS rows_, MIN(calendar_date) AS min_d, MAX(calendar_date) AS max_d,
       (SELECT COUNT(*) FROM (SELECT storenumber, calendar_date, shift_name FROM dash_labour GROUP BY 1,2,3 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_labour;
-- 2 ties to source to the cent, expect both sides equal (labour_cost 70225001.95, hours 3377504.00)
SELECT (SELECT SUM(labour_cost) FROM dash_labour) AS agg_cost, (SELECT SUM(labour_cost) FROM shift_schedules) AS src_cost,
       (SELECT SUM(scheduled_hours) FROM dash_labour) AS agg_hrs, (SELECT SUM(scheduled_hours) FROM shift_schedules) AS src_hrs;
-- 3 2020 labour cost, expect 35169013.40
SELECT DECIMAL(SUM(labour_cost), 14, 2) AS labour_2020 FROM dash_labour WHERE yyyymm / 100 = 2020;
-- 4 allocated_sales sanity: each store-day's two shifts should sum back to that day's traffic sales
SELECT FIRST 10 storenumber, calendar_date,
       DECIMAL(SUM(allocated_sales), 12, 2) AS day_alloc_sum
FROM dash_labour GROUP BY storenumber, calendar_date ORDER BY storenumber, calendar_date;
-- 5 heatmap shape sanity: 7 days x 2 shifts, no missing day_name
SELECT day_name, shift_name, COUNT(*) AS n, DECIMAL(AVG(scheduled_hours), 8, 2) AS avg_hrs FROM dash_labour GROUP BY day_name, shift_name ORDER BY day_name, shift_name;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_labour.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_labour.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 dup_keys=0, dates span 2019-01-01..2020-12-31; check 2 agg equals src exactly on both columns (70225001.95 / 3377504.00); check 3 35169013.40; check 4 each store-day's two-shift sum should equal (or come very close to, allowing for a store-day with a traffic row but zero scheduled shifts on one side) that day's `store_traffic.sales` value -- spot check a couple of rows against `store_traffic` directly; check 5 14 rows (7 day_name x 2 shift_name), no NULL day_name.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_labour.sql scripts/pos_perf/verify_dash_labour.sql
git commit -m "feat(pos-perf): dash_labour aggregate for the Workforce and Labour cockpit"
```

---

### Task 2: Shared supply input controls

**Files:**
- Create: `scripts/pos_perf/supply_controls.ps1`

**Interfaces:**
- Consumes: `inventory` (storeregion, storenumber, storename, category, supplier_name columns) from the already-live `inventory` table. Reuses the existing `/reports/pos_perf/controls/p_regions` control (same `Ontario|Western|Quebec|Atlantic` vocabulary) -- do not create a duplicate region control.
- Produces: three JRS input controls at `/reports/pos_perf/controls/sup_store`, `sup_category`, `sup_supplier` (new, type-7 multi-select query LOVs, following the exact pattern established in `scripts/pos_perf/churn_controls.ps1` -- read that file first, it is the freshest, most-reviewed example of this pattern in the repo). A `New-SupplyControls` creation function and an `Attach-SupplyControls -ReportUri <uri>` wrapper attaching `[p_regions, sup_store, sup_category, sup_supplier]` (in that order) to each Console tile.

- [ ] **Step 1: Read `scripts/pos_perf/churn_controls.ps1` in full** before writing this file -- it dot-sources `scripts/pos_perf/jrs_controls.ps1`'s shared helpers (`Test-JrsExists`, the idempotent create/update flow, `Attach-Controls`) and adds only a narrow `New-ChurnQueryControl`-style extension for two-column value/label LOVs. Reuse the same shared helpers; do not reimplement them.

- [ ] **Step 2: Write `supply_controls.ps1`** with a `New-SupplyControls` function creating three controls:

```
sup_store: label "Store", query "SELECT DISTINCT VARCHAR(storenumber) || ' - ' || storename AS sv, VARCHAR(storenumber) AS svv FROM inventory ORDER BY 1"
sup_category: label "Category", query "SELECT DISTINCT category AS sc, category AS scv FROM inventory ORDER BY 1"
sup_supplier: label "Supplier", query "SELECT DISTINCT supplier_name AS ss, supplier_name AS ssv FROM inventory ORDER BY 1"
```

Note `sup_store`'s value column (`svv`) is the plain store number as a string, not the combined display string -- WHERE clauses that filter by store must compare `storenumber = INT4($X{IN, ...})`-style against this numeric-as-string value, matching how `p_store` was handled in Phase 1's `pnl_worst_stores` drill (declare and compare consistently; do not introduce a mismatched type). Include an `Attach-SupplyControls -ReportUri <uri>` wrapper calling the shared `Attach-Controls` with the fixed list `@("/reports/pos_perf/controls/p_regions", "/reports/pos_perf/controls/sup_store", "/reports/pos_perf/controls/sup_category", "/reports/pos_perf/controls/sup_supplier")`.

- [ ] **Step 3: Run and verify**

```powershell
$env:JRS_ENV = "stage"
. .\scripts\pos_perf\supply_controls.ps1
New-SupplyControls
```

Expected: three `OK: created` (or `SKIP: exists` on rerun). GET each control and confirm `dataType.type` is `multiSelectQuery`; confirm the three LOV queries return real, non-empty distinct values (categories and supplier names should be readable business strings, not internal codes -- eyeball a sample).

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/supply_controls.ps1
git commit -m "feat(pos-perf): shared supply input controls (store, category, supplier)"
```

---

### Task 3: Dashboard 7 - Supply and Inventory (console, STAGE)

**Files:**
- Create: `report/pos_perf/sup_kpi.jrxml`
- Create: `report/pos_perf/sup_stock_status.jrxml`
- Create: `report/pos_perf/sup_gmroi.jrxml`
- Create: `report/pos_perf/sup_scorecard.jrxml`
- Create: `report/pos_perf/sup_shrink.jrxml`
- Create: `report/pos_perf/sup_dashboard.json`

**Interfaces:**
- Consumes: `inventory`, `purchase_orders`, `suppliers`, `shrinkage_log`, `store_pnl_monthly` (for COGS in the shrink-pct-of-COGS KPI); the four supply controls (Task 2). Parameter block on every tile: `p_regions COLLECTION`, `sup_store COLLECTION`, `sup_category COLLECTION`, `sup_supplier COLLECTION`. Guard every WHERE clause with the `$X{IN, ...}` idiom (see any Phase 1/2 `trs_*`/`chn_*` tile for the exact syntax) so a null/empty Collection is a no-op filter.
- Produces: dashboard `/reports/pos_perf/pos_supply_inventory` label "POS Supply and Inventory"; `sup_scorecard` rows hyperlink to `/reports/pos_perf/rpt_supplier_scorecard` (Task 6) passing a `p_quarter` parameter derived as `"All"` (literal string default, same fixed-scope drill convention as `trs_tax_province` -> `rpt_tax_remittance` in Phase 1 -- the report is a workable scorecard, not per-row scoped).

- [ ] **Step 1: sup_kpi (1600x130, filter params).** Five cells at x = 10, 326, 642, 958, 1274 (width 300, dividers `#D6E0EF`, same layout as every prior `*_kpi`/`*_kpi_strip` tile). Query:

```sql
SELECT DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN stock_status = 'Out of Stock' THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS oos_pct,
       DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN stock_status = 'Overstock' THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS overstock_pct,
       DECIMAL(AVG(days_of_supply), 8, 2) AS avg_days_of_supply,
       (SELECT DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN po.on_time = 'Y' THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2)
        FROM purchase_orders po WHERE ($X{IN, po.storenumber, sup_store})) AS on_time_pct,
       (SELECT DECIMAL(100.0 * FLOAT8(SUM(sl.shrink_value)) / FLOAT8(NULLIF((SELECT SUM(cogs) FROM store_pnl_monthly), 0)), 6, 4)
        FROM shrinkage_log sl WHERE ($X{IN, sl.storenumber, sup_store})) AS shrink_pct_cogs
FROM inventory
WHERE ($X{IN, storeregion, p_regions})
  AND ($X{IN, storenumber, sup_store})
  AND ($X{IN, category, sup_category})
  AND ($X{IN, supplier_name, sup_supplier})
```

Fields: `oos_pct`, `overstock_pct` BigDecimal `pattern="#,##0.0'%'"`; `avg_days_of_supply` BigDecimal `pattern="#,##0.0"`; `on_time_pct` BigDecimal `pattern="#,##0.0'%'"`; `shrink_pct_cogs` BigDecimal `pattern="#,##0.00'%'"`. Labels: "Out of Stock", "Overstock", "Avg Days of Supply", "Supplier On-Time", "Shrink pct of COGS". Expected at defaults: 12.1% / 5.0% / 27.8 / 85.0% / about 0.37%.

- [ ] **Step 2: sup_stock_status (1000x380, filter params).** 100 pct stacked bar, stock status share by category. Query:

```sql
SELECT category,
       stock_status,
       COUNT(*) AS n
FROM inventory
WHERE ($X{IN, storeregion, p_regions})
  AND ($X{IN, storenumber, sup_store})
  AND ($X{IN, category, sup_category})
  AND ($X{IN, supplier_name, sup_supplier})
GROUP BY category, stock_status
ORDER BY category
```

`chartType="stackedBar"`, `<dataset kind="category">` grouped by `category`, series = `stock_status`. `<plot>` with five `seriesColor` entries covering the five stock_status values, favourable-to-unfavourable ordering: `In Stock` `#5CB85C`, `Reorder` `#0550DC`, `Overstock` `#1DB6C0`, `Critical` `#D9534F` (near-favourable-red, one shade lighter than pure unfavourable to leave room for), `Out of Stock` pure `#D9534F`. Guard: every `(category, stock_status)` combination that has zero rows is simply absent from the query result (not a null value on an existing row), so the seriesColor null-registration risk does not apply here the way it does to a single-series chart with a nullable value column -- document this reasoning in the header comment rather than adding an unneeded guard.

- [ ] **Step 3: sup_gmroi (1000x380, filter params).** Horizontal bars, GMROI by category. Query:

```sql
SELECT category,
       DECIMAL(AVG(gmroi), 8, 2) AS gmroi
FROM inventory
WHERE ($X{IN, storeregion, p_regions})
  AND ($X{IN, storenumber, sup_store})
  AND ($X{IN, category, sup_category})
  AND ($X{IN, supplier_name, sup_supplier})
GROUP BY category
ORDER BY gmroi DESC
```

`<plot><seriesColor order="0" color="#0A4CAD"/></plot>`. Title "GMROI by Category", subtitle "Gross margin return on inventory investment".

- [ ] **Step 4: sup_scorecard (1000x380, filter params).** List/table, supplier on-time pct, fill rate, avg lead days, ranked, each row hyperlinked to the Supplier Scorecard report. Query:

```sql
SELECT s.supplier_name,
       DECIMAL(s.on_time_pct, 6, 2) AS on_time_pct,
       DECIMAL(s.avg_fill_rate_pct, 6, 2) AS avg_fill_rate_pct,
       s.lead_time_days,
       s.purchase_orders AS po_count
FROM suppliers s
WHERE ($X{IN, s.supplier_name, sup_supplier})
ORDER BY s.on_time_pct ASC
```

Note: this tile deliberately does NOT filter by `p_regions`/`sup_store`/`sup_category` in its WHERE (the `suppliers` table has no region/store/category columns of its own -- it is a supplier-level summary, not a transaction table) -- add a one-line header comment explaining this so a future reader does not "fix" it into a bug; the three parameters are still declared on this tile (per the established convention: declare every filter parameter on every filtered tile even if a specific tile's SQL cannot use all of them, matching the `chn_drivers` precedent from Phase 2). Sorted ascending (worst on-time first) so the list highlights suppliers needing attention. Header `#1F4E79` on white, zebra `#D6E0EF`. Each row's supplier-name cell carries a `<hyperlinkReference>` (flattened `<hyperlinkParameter>` form) to `/reports/pos_perf/rpt_supplier_scorecard` passing `p_quarter -> "All"` (literal String).

- [ ] **Step 5: sup_shrink (1000x380, filter params).** Stacked bar, shrink value by reason by month. Query:

```sql
SELECT event_year * 100 + event_month AS yyyymm,
       reason,
       DECIMAL(SUM(shrink_value), 12, 2) AS shrink_value
FROM shrinkage_log
WHERE ($X{IN, storenumber, sup_store})
  AND ($X{IN, category, sup_category})
GROUP BY event_year, event_month, reason
ORDER BY yyyymm
```

Note: `p_regions` and `sup_supplier` are NOT applicable to this tile (`shrinkage_log` has no region or supplier column) -- declare all four parameters per convention, use only the two that apply, document why in the header. `chartType="stackedBar"`, five `seriesColor` entries for the five reasons (Expiry `#0550DC`, Damage `#1DB6C0`, Theft `#D9534F`, Temperature Excursion `#0A4CAD`, Inventory Adjustment `#239CA8`).

- [ ] **Step 6: Write `sup_dashboard.json`** following the exact `trs_dashboard.json`/`chn_dashboard.json` shape (filters key drives the composer-generated strip; y-coordinates are the spec mockup's y minus 3, per Global Constraints -- spec had `sup_controls` at 0,0,40,3 then content starting at y=3/y=7/y=17):

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_supply_inventory",
  "label": "POS Supply and Inventory",
  "filters": ["p_regions", "sup_store", "sup_category", "sup_supplier"],
  "dashlets": [
    { "resource": "/reports/pos_perf/sup_kpi",           "label": "Key Metrics",        "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/sup_stock_status",  "label": "Stock Status",       "showTitleBar": false, "x": 0,  "y": 4,  "width": 20, "height": 10 },
    { "resource": "/reports/pos_perf/sup_gmroi",         "label": "GMROI by Category",  "showTitleBar": false, "x": 20, "y": 4,  "width": 20, "height": 10 },
    { "resource": "/reports/pos_perf/sup_scorecard",     "label": "Supplier Scorecard", "showTitleBar": false, "x": 0,  "y": 14, "width": 20, "height": 11 },
    { "resource": "/reports/pos_perf/sup_shrink",        "label": "Shrink by Reason",   "showTitleBar": false, "x": 20, "y": 14, "width": 20, "height": 11 }
  ]
}
```

- [ ] **Step 7: Lint, deploy, attach controls, verify, compose**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\supply_controls.ps1
foreach ($t in "sup_kpi","sup_stock_status","sup_gmroi","sup_scorecard","sup_shrink") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$t.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$t.jrxml" -TargetUri "/reports/pos_perf/$t" -Label $t -DataSourceUri /datasources/pos_data_avalanche -Overwrite
  Attach-SupplyControls -ReportUri "/reports/pos_perf/$t"
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$t" -Format pdf -OutFile "out\pos_perf\$t.pdf"
}
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\sup_dashboard.json -AutoGrid
```

GET-verify all five tiles carry all four controls after attach, before composing. Expected: five PDFs render; sup_kpi matches Step 1 defaults; recompose reports 5 dashlets.

- [ ] **Step 8: Commit**

```powershell
git add report/pos_perf/sup_kpi.jrxml report/pos_perf/sup_stock_status.jrxml report/pos_perf/sup_gmroi.jrxml report/pos_perf/sup_scorecard.jrxml report/pos_perf/sup_shrink.jrxml report/pos_perf/sup_dashboard.json
git commit -m "feat(pos-perf): Supply and Inventory console (STAGE)"
```

---

### Task 4: Dashboard 8 - Workforce and Labour (cockpit, STAGE)

**Files:**
- Create: `report/pos_perf/lab_kpi.jrxml`
- Create: `report/pos_perf/lab_heatmap.jrxml`
- Create: `report/pos_perf/lab_format.jrxml`
- Create: `report/pos_perf/lab_indexed.jrxml`
- Create: `report/pos_perf/lab_conversion.jrxml`
- Create: `report/pos_perf/lab_dashboard.json`

**Interfaces:**
- Consumes: `dash_labour` (Task 1), `employees`, `store_pnl_monthly` (for net sales and store_format), `store_traffic`, `stores` (for region, if `store_traffic` itself lacks a region column -- check and join if needed). NO parameters on any tile (Cockpit archetype, matching `pnl_dashboard.json`'s precedent of no `"filters"` key and no per-tile controls).
- Produces: dashboard `/reports/pos_perf/pos_workforce_labour` label "POS Workforce and Labour". No drill targets from this dashboard (the spec lists no drill for dashboard 8's tiles).

- [ ] **Step 1: lab_kpi (1600x130, no parameters).** Five cells at x = 10, 326, 642, 958, 1274. Query:

```sql
SELECT DECIMAL(SUM(labour_cost), 14, 2) AS labour_cost,
       DECIMAL(100.0 * FLOAT8(SUM(labour_cost)) / FLOAT8(NULLIF((SELECT SUM(net_sales) FROM store_pnl_monthly WHERE yr = 2020), 0)), 6, 2) AS labour_pct_sales,
       DECIMAL(FLOAT8(SUM(labour_cost)) / FLOAT8(NULLIF(SUM(scheduled_hours), 0)), 8, 2) AS cost_per_hour,
       (SELECT COUNT(*) FROM employees WHERE employment_status = 'Active') AS active_staff,
       DECIMAL(FLOAT8(SUM(allocated_sales)) / FLOAT8(NULLIF(SUM(scheduled_hours), 0)), 8, 2) AS sales_per_hour
FROM dash_labour
WHERE yyyymm / 100 = 2020
```

Fields: `labour_cost` BigDecimal `pattern="$#,##0"`; `labour_pct_sales` BigDecimal `pattern="#,##0.0'%'"`; `cost_per_hour`, `sales_per_hour` BigDecimal `pattern="$#,##0.00"`; `active_staff` Long. Labels: "2020 Labour Cost", "pct of Net Sales", "Cost per Hour", "Active Staff", "Sales per Labour Hour". Expected: about $35.2M / 8.4% / around $10.40/hr / 2,340 / a positive dollar figure reconciled at render time against `dash_labour`'s own totals.

- [ ] **Step 2: lab_heatmap (1600x460, no parameters).** Follow the Global Constraints' heatmap-technique guidance: attempt a `crosstab` with per-cell `conditionalStyle` background colour bucketed from `sales_per_hour` (rowGroup = `day_name` ordered by `dow_num`, columnGroup = `shift_name`, measure = average `allocated_sales / scheduled_hours`) as the primary approach -- this is the more reliable JR7-native technique given the waterfall precedent's outcome. Query:

```sql
SELECT day_name, dow_num, shift_name,
       DECIMAL(SUM(scheduled_hours), 10, 2) AS scheduled_hours,
       DECIMAL(FLOAT8(SUM(allocated_sales)) / FLOAT8(NULLIF(SUM(scheduled_hours), 0)), 8, 2) AS sales_per_hour
FROM dash_labour
GROUP BY day_name, dow_num, shift_name
ORDER BY dow_num, shift_name
```

Bucket `sales_per_hour` into 4-5 colour tiers (e.g. quartiles computed once against this same 14-row result, hardcoded as literal thresholds once you see the real numbers -- do not over-engineer a dynamic bucketing scheme for a 14-cell grid) using `conditionalStyle` on the crosstab cell, `#D6E0EF` (lowest) through `#0550DC` (highest) in the established series-blue family, with the numeric `scheduled_hours` value printed in each cell. Title "Scheduled Hours by Day and Shift", subtitle "Cell colour: sales per labour hour". If the crosstab approach proves awkward to style cell-by-cell in practice, the documented fallback is a `chartType="bar"` grouped bar chart (day on the category axis, one series per shift, bar height = sales_per_hour, which loses the "heatmap" visual but keeps the same data) -- pick whichever actually renders cleanly on this server and document the choice in the file's header comment, exactly as `pnl_waterfall.jrxml` documents its own technique choice.

- [ ] **Step 3: lab_format (1000x380, no parameters).** Horizontal bars, labour pct of sales by store format. Query:

```sql
SELECT p.store_format,
       DECIMAL(100.0 * FLOAT8(SUM(l.labour_cost)) / FLOAT8(NULLIF(SUM(p.net_sales), 0)), 6, 2) AS labour_pct
FROM store_pnl_monthly p
JOIN dash_labour l ON l.storenumber = p.storenumber AND l.yyyymm = p.yyyymm
WHERE p.yr = 2020
GROUP BY p.store_format
ORDER BY labour_pct DESC
```

`<plot><seriesColor order="0" color="#0550DC"/></plot>`. Title "Labour pct of Sales by Format".

- [ ] **Step 4: lab_indexed (1000x380, no parameters).** Two-line chart, monthly labour cost and net sales, both indexed to January 2019 = 100. Query (compute the index in SQL using a scalar subquery for the base-month values):

```sql
SELECT p.yyyymm,
       DECIMAL(100.0 * FLOAT8(SUM(p.net_sales)) / FLOAT8((SELECT SUM(net_sales) FROM store_pnl_monthly WHERE yyyymm = 201901)), 8, 2) AS sales_index,
       DECIMAL(100.0 * FLOAT8(SUM(l.labour_cost)) / FLOAT8((SELECT SUM(labour_cost) FROM dash_labour WHERE yyyymm = 201901)), 8, 2) AS labour_index
FROM store_pnl_monthly p
JOIN dash_labour l ON l.storenumber = p.storenumber AND l.yyyymm = p.yyyymm
GROUP BY p.yyyymm
ORDER BY p.yyyymm
```

Two-series line chart (Sales Index, Labour Index), `<plot><seriesColor order="0" color="#0550DC"/><seriesColor order="1" color="#239CA8"/></plot>`, both `showLines="true" showShapes="true"`. Title "Labour Cost and Net Sales, Indexed to Jan 2019 = 100".

- [ ] **Step 5: lab_conversion (1000x380, no parameters).** Horizontal bars, traffic conversion pct by region. Query (join `store_traffic` to `stores` for region if `store_traffic` has no region column -- confirmed this session that `store_traffic` has no region column, so this join is required):

```sql
SELECT s.home_region AS region,
       DECIMAL(AVG(t.conversion_pct), 6, 2) AS conversion_pct
FROM store_traffic t
JOIN stores s ON s.storenumber = t.storenumber
GROUP BY s.home_region
ORDER BY conversion_pct DESC
```

Note: `stores.home_region` was confirmed present on the `customers` table's join target in Phase 2 (`stores` itself was not directly queried for columns this session -- if `stores` uses a different column name than `home_region` for its own region field, e.g. plain `region`, check `iicolumns` for `stores` before writing this query and use the real name; the two Phase 1/2 conventions both call this field `region` on store-grain tables like `store_pnl_monthly.region`, so that is the more likely real name -- verify, do not guess). `<plot><seriesColor order="0" color="#1DB6C0"/></plot>`. Title "Traffic Conversion by Region".

- [ ] **Step 6: Write `lab_dashboard.json`** -- no `"filters"` key at all (Cockpit archetype), y-coordinates NOT shifted (no control tile was ever assumed for a Cockpit, unlike Console dashboards -- use the spec's raw mockup coordinates directly, matching `pnl_dashboard.json`'s own y=0 start for its KPI strip):

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_workforce_labour",
  "label": "POS Workforce and Labour",
  "dashlets": [
    { "resource": "/reports/pos_perf/lab_kpi",         "label": "Key Metrics",              "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/lab_heatmap",     "label": "Scheduled Hours Heatmap",  "showTitleBar": false, "x": 0,  "y": 4,  "width": 24, "height": 12 },
    { "resource": "/reports/pos_perf/lab_format",      "label": "Labour pct by Format",     "showTitleBar": false, "x": 24, "y": 4,  "width": 16, "height": 12 },
    { "resource": "/reports/pos_perf/lab_indexed",     "label": "Indexed Trend",            "showTitleBar": false, "x": 0,  "y": 16, "width": 20, "height": 10 },
    { "resource": "/reports/pos_perf/lab_conversion",  "label": "Conversion by Region",     "showTitleBar": false, "x": 20, "y": 16, "width": 20, "height": 10 }
  ]
}
```

- [ ] **Step 7: Lint, deploy, verify, compose (no controls to attach on this dashboard)**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
foreach ($t in "lab_kpi","lab_heatmap","lab_format","lab_indexed","lab_conversion") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$t.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$t.jrxml" -TargetUri "/reports/pos_perf/$t" -Label $t -DataSourceUri /datasources/pos_data_avalanche -Overwrite
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$t" -Format pdf -OutFile "out\pos_perf\$t.pdf"
}
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\lab_dashboard.json -AutoGrid
```

Expected: five PDFs render; lab_kpi matches Step 1 defaults; recompose reports 5 dashlets, no filter strip present.

- [ ] **Step 8: Commit**

```powershell
git add report/pos_perf/lab_kpi.jrxml report/pos_perf/lab_heatmap.jrxml report/pos_perf/lab_format.jrxml report/pos_perf/lab_indexed.jrxml report/pos_perf/lab_conversion.jrxml report/pos_perf/lab_dashboard.json
git commit -m "feat(pos-perf): Workforce and Labour cockpit (STAGE)"
```

---

### Task 5: Report - Inventory Reorder List

**Files:**
- Create: `report/pos_perf/rpt_inventory_reorder.jrxml`

**Interfaces:**
- Consumes: `inventory`. No drill source in this suite (the spec does not wire any dashboard tile to this report) -- standalone, scheduled/launched directly from JRS.
- Produces: report unit `/reports/pos_perf/rpt_inventory_reorder`, parameter `p_store STRING default "All"` (matches the spec's single "store" parameter; use the String "All"-or-exact-match idiom from `rpt_tax_remittance`, not a Collection, since this report has exactly one filter dimension).

- [ ] **Step 1: Write the report.** A4 landscape (`pageWidth="842" pageHeight="595"`, margins 30, columnWidth 782), logo top-left, centered title "Inventory Reorder List", subtitle `"Store: " + $P{p_store} + " -- PLUs at or below reorder point"`. Query:

```sql
SELECT storenumber, storename, plu, product_name, category, supplier_name,
       on_hand_qty, reorder_point, reorder_qty, lead_time_days,
       days_of_supply, stock_status
FROM inventory
WHERE on_hand_qty <= reorder_point
  AND ('All' = $P{p_store} OR VARCHAR(storenumber) = $P{p_store})
ORDER BY days_of_supply ASC, storenumber
```

Columns: Store | PLU | Product | Category | Supplier | On Hand | Reorder Point | Reorder Qty | Lead Days | Days of Supply | Status. Header `#1F4E79` on white, zebra `#D6E0EF` (matches `rpt_ar_aging`/`rpt_ap_aging`). Status column: red `#D9534F` bold when `stock_status = 'Out of Stock'` or `'Critical'`, plain otherwise (two overlapping textFields with `printWhenExpression`, the established Phase 1/2 conditional-colour pattern). `whenNoDataType="AllSectionsNoDetail"` (bake in from the start, per the Phase 1/2 lesson).

- [ ] **Step 2: Deploy and verify**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_inventory_reorder.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_inventory_reorder.jrxml -TargetUri /reports/pos_perf/rpt_inventory_reorder -Label "Inventory Reorder List" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_inventory_reorder -Format pdf -OutFile out\pos_perf\rpt_inventory_reorder.pdf
```

Reconcile the default (`p_store = "All"`) row count against a direct warehouse query (`SELECT COUNT(*) FROM inventory WHERE on_hand_qty <= reorder_point`) -- this is the union of `Reorder`, `Critical`, and `Out of Stock` stock_status rows (26,262 + 33,201 + 26,110 = 85,573), so this report is NOT capped (spec asks for a full reorder list, unlike the Phase 2 Churn Action List). If the page count is large (85K rows could be 2,000+ pages), that is expected and correct for an operational pick list -- do not cap it silently; if it seems genuinely impractical once rendered, note the concern in your report rather than unilaterally capping. Also render a single-store filtered run and confirm row count drops correctly.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/rpt_inventory_reorder.jrxml
git commit -m "feat(pos-perf): Inventory Reorder List report"
```

---

### Task 6: Report - Supplier Scorecard (drill target)

**Files:**
- Create: `report/pos_perf/rpt_supplier_scorecard.jrxml`

**Interfaces:**
- Consumes: `suppliers`, `purchase_orders`. Drilled from `sup_scorecard` (Task 3) with `p_quarter="All"`.
- Produces: report unit `/reports/pos_perf/rpt_supplier_scorecard`, parameter `p_quarter STRING default "All"` (values: `"All"` or `"YYYYQn"` e.g. `"2020Q3"` -- derive quarter from `purchase_orders.order_year`/`order_month` via `date_dim` join or direct arithmetic, since `purchase_orders` has no ANSIDATE-arithmetic risk here as `order_year`/`order_month` are already plain INTEGER columns, not derived from ANSIDATE math).

- [ ] **Step 1: Write the report.** A4 landscape, logo top-left, centered title "Supplier Scorecard", subtitle `"Quarter: " + $P{p_quarter}`. Query:

```sql
SELECT s.supplier_name, s.category_focus, s.payment_terms,
       DECIMAL(s.on_time_pct, 6, 2) AS lifetime_on_time_pct,
       DECIMAL(s.avg_fill_rate_pct, 6, 2) AS lifetime_fill_rate_pct,
       s.lead_time_days,
       DECIMAL(s.total_spend, 14, 2) AS lifetime_spend,
       s.purchase_orders AS lifetime_po_count,
       (SELECT COUNT(*) FROM purchase_orders po WHERE po.supplier_name = s.supplier_name
         AND ('All' = $P{p_quarter} OR (VARCHAR(po.order_year) || 'Q' || VARCHAR((po.order_month - 1) / 3 + 1)) = $P{p_quarter})) AS quarter_po_count,
       (SELECT DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN po.on_time = 'Y' THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2)
        FROM purchase_orders po WHERE po.supplier_name = s.supplier_name
         AND ('All' = $P{p_quarter} OR (VARCHAR(po.order_year) || 'Q' || VARCHAR((po.order_month - 1) / 3 + 1)) = $P{p_quarter})) AS quarter_on_time_pct
FROM suppliers s
ORDER BY lifetime_on_time_pct ASC
```

Columns: Supplier | Category Focus | Terms | Lifetime On-Time pct | Lifetime Fill Rate pct | Lead Days | Lifetime Spend | Lifetime PO Count | Quarter PO Count | Quarter On-Time pct. Header `#1F4E79` on white, zebra `#D6E0EF`. `whenNoDataType="AllSectionsNoDetail"`. Note: `quarter_po_count`/`quarter_on_time_pct` can be null/zero for a supplier with no activity in the selected quarter -- `blankWhenNull` on both cells, and print "no activity this quarter" style text via a `printWhenExpression` companion textField when the count is 0 (matching the null-handling rigor established in `rpt_churn_action_list`).

- [ ] **Step 2: Deploy and verify**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_supplier_scorecard.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_supplier_scorecard.jrxml -TargetUri /reports/pos_perf/rpt_supplier_scorecard -Label "Supplier Scorecard" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_supplier_scorecard -Format pdf -OutFile out\pos_perf\rpt_supplier_scorecard.pdf
```

Reconcile default run's row count against `SELECT COUNT(*) FROM suppliers` and the lifetime on-time pct total against a direct query; render one quarter-filtered run (e.g. `p_quarter=2020Q3`) and confirm the quarter columns change while lifetime columns stay fixed.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/rpt_supplier_scorecard.jrxml
git commit -m "feat(pos-perf): Supplier Scorecard report (drill target)"
```

---

### Task 7: Report - Weekly Flash

**Files:**
- Create: `report/pos_perf/rpt_weekly_flash.jrxml`

**Interfaces:**
- Consumes: `store_traffic`, `store_pnl_monthly`, `sales_targets`, `marketing_campaigns`, `promotions`, `date_dim` (for week-boundary and month-share calculations). No drill source -- standalone, scheduled weekly from JRS in production use.
- Produces: report unit `/reports/pos_perf/rpt_weekly_flash`, parameter `p_week_ending STRING default` (a real Sunday or Saturday date from the data range as `"yyyy-mm-dd"` -- pick a date in H2 2020 so promo/campaign data is likely present; verify against `marketing_campaigns`/`promotions` date ranges before hardcoding the default).

- [ ] **Step 1: Write the report.** A4 PORTRAIT (`pageWidth="595" pageHeight="842"`, margins 30, columnWidth 535), 2 pages by content (not an artificial page break -- let the natural band flow produce 2 pages), logo top-left, centered title "Weekly Flash", subtitle `"Week ending " + $P{p_week_ending}`.

Page 1 -- network KPIs vs prior week and vs plan. Query (compute the target week's Monday via `$P{p_week_ending}` minus 6 days, using `DATE($P{p_week_ending}) - 6` -- confirm this arithmetic works on an ANSIDATE-typed parameter the same way it worked on `date_dim.calendar_date` elsewhere this phase, since date MINUS an integer is a different operation from date DIVIDED BY an integer and was not itself flagged as broken by the Rewriter-error gotcha; if it does throw, fall back to a `date_dim` self-join using `jdn` integer arithmetic instead, which is guaranteed safe):

```sql
SELECT DECIMAL(SUM(t.sales), 14, 2) AS week_sales,
       DECIMAL(SUM(t.transactions), 10, 0) AS week_transactions,
       DECIMAL(AVG(t.conversion_pct), 6, 2) AS week_conversion_pct,
       DECIMAL((SELECT SUM(t2.sales) FROM store_traffic t2 WHERE t2.traffic_date BETWEEN DATE($P{p_week_ending}) - 13 AND DATE($P{p_week_ending}) - 7), 14, 2) AS prior_week_sales
FROM store_traffic t
WHERE t.traffic_date BETWEEN DATE($P{p_week_ending}) - 6 AND DATE($P{p_week_ending})
```

Plan comparison: a second query summing `sales_targets.target_sales` pro-rated per the Global Constraints' documented weekly-share derivation -- `SUM(target_sales * overlap_days / days_in_month)` where `overlap_days` is computed per `yyyymm` the report week touches. Write this as a subquery joining `sales_targets` to a small inline `date_dim`-derived day-count table for the report week (7 rows, one per day, each carrying its own `yyyymm`), then `GROUP BY yyyymm` to get overlap day counts per month, then join to `sales_targets`. Print both comparisons as favourable/unfavourable-coloured variance lines (`#5CB85C`/`#D9534F`), and print the pro-ration subtitle disclosure required by Global Constraints, e.g.: `"Weekly plan is the monthly target pro-rated by the number of report-week days falling in each month."`

Page 2 -- campaign section. Query:

```sql
SELECT campaign_name,
       DECIMAL(subsidy_cost, 12, 2) AS subsidy_cost,
       conversions,
       DECIMAL(FLOAT8(subsidy_cost) / FLOAT8(NULLIF(conversions, 0)), 10, 2) AS cost_per_conversion
FROM marketing_campaigns
WHERE start_date <= DATE($P{p_week_ending}) AND (end_date IS NULL OR end_date >= DATE($P{p_week_ending}) - 6)
ORDER BY conversions DESC
```

(Verify the real column names on `marketing_campaigns` via `iicolumns` before writing this -- they were not directly checked this session; `subsidy_cost`/`conversions`/`start_date`/`end_date`/`campaign_name` are the plan's best guess based on this suite's established naming conventions elsewhere, not a confirmed schema. If the real names differ, use them and note the correction in your report.) Table with header `#1F4E79` on white, zebra `#D6E0EF`. `whenNoDataType="AllSectionsNoDetail"` on both the campaign sub-dataset and the report as a whole.

- [ ] **Step 2: Deploy and verify**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_weekly_flash.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_weekly_flash.jrxml -TargetUri /reports/pos_perf/rpt_weekly_flash -Label "Weekly Flash" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_weekly_flash -Format pdf -OutFile out\pos_perf\rpt_weekly_flash.pdf
```

Reconcile the week's sales/transactions/conversion against a direct 7-day `store_traffic` query for the same date range; reconcile the pro-rated plan figure by hand for one simple case (a week fully inside one month) before trusting the month-boundary-spanning logic; confirm the PDF is 2 pages.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/rpt_weekly_flash.jrxml
git commit -m "feat(pos-perf): Weekly Flash report"
```

---

### Task 8: STAGE acceptance, docs, PROD go/no-go (deferred)

**Files:**
- Modify: `README.md` (extend the "POS performance dashboards" section)
- Modify: `RUNBOOK.md` (extend the pos_perf section with Phase 3's rebuild/redeploy/recompose recipe and PROD block)
- Modify: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-perf-dashboards.md`
- Modify: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-suite-blueprint.md`

**Interfaces:**
- Consumes: everything built in Tasks 1-7, all live on STAGE.
- Produces: docs a human can run the browser checks and the eventual PROD promotion from; nothing further depends on this task.

- [ ] **Step 1: Render every new unit at defaults and reconcile.** 10 dashboard tiles (`sup_*` x5, `lab_*` x5) + 3 reports (`rpt_inventory_reorder`, `rpt_supplier_scorecard`, `rpt_weekly_flash`) = 13 units. Re-export each report unit's jrxml from STAGE and diff against the committed git version (byte match) -- the same check Phase 1/2 ran, and specifically worth re-running here since Phase 2 uncovered an unexplained STAGE drift incident on one unit (see `RUNBOOK.md`'s Phase 2 drift-detection recipe -- apply the same recipe to all 13 Phase 3 units). Confirm `pos_supply_inventory` composes with 5 dashlets and 4 filters wired; confirm `pos_workforce_labour` composes with 5 dashlets and NO filters.

- [ ] **Step 2: Write the manual browser checklist addition** in `RUNBOOK.md` (append to the existing "Checks that need a human with a browser" list): filter-strip Apply on `pos_supply_inventory` (fallback: flip `sup_dashboard.json`'s `"filters"` removal + per-dashlet `dashletFilterShowPopup: true` + recompose, same fallback pattern as Phase 1/2); the `sup_scorecard` -> Supplier Scorecard drill click-test; a visual check of `lab_heatmap`'s chosen rendering technique (crosstab-with-conditional-style or the bar-chart fallback -- confirm it actually reads as a heatmap-like data view to a human, not just that it compiles); a page-count sanity check on `rpt_inventory_reorder`'s default (unfiltered) render, since it is intentionally uncapped and could be very large.

- [ ] **Step 3: Write the RUNBOOK PROD block** (deferred, user-run, following the exact Phase 1/2 shape, including the Phase 2-established Step -1 byte-diff precondition before promoting any unit): rebuild `dash_labour` against PROD's warehouse connection if needed, deploy the 10 `sup_*`/`lab_*` jrxml + 3 `rpt_*` jrxml with `-Env prod`, create the four supply controls on PROD via `New-SupplyControls` if not already present (note: `p_regions` is shared/inherited, do not recreate), recompose both dashboards.

- [ ] **Step 4: Update the memory files.** Append a "## Phase 3 (operations) executed <date>" section to `pos-perf-dashboards.md` with both dashboard URIs, manifest paths, the new aggregate, the acceptance figures from Task 1's verify script, the heatmap technique actually chosen (and why), and the outstanding browser checks -- same shape as the existing Phase 1/2 sections. Update `pos-suite-blueprint.md` to note Phase 3 executed.

- [ ] **Step 5: Commit**

```powershell
git add README.md RUNBOOK.md
git commit -m "docs(pos-perf): Phase 3 acceptance, runbook, and memory updates"
```
