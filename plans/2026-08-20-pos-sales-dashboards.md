# POS Sales Performance Dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy three Actian-branded POS dashboards (Executive Overview, Operations Console, Promo & Margin Story) to JasperReports Server PROD, fed by aggregate tables in the pos_data Avalanche warehouse and aligned with the Wobby semantic layer.

**Architecture:** Precomputed `dash_*` aggregate tables in the warehouse (built once via admiral sql.ps1; source is static). One JRS JDBC datasource over the Ingres driver. ~14 JRXML reports scaffolded/compiled/deployed via the jasper-deploy skill, composed into three dashboards from committed manifests, verified on STAGE, then promoted to PROD.

**Tech Stack:** Actian Avalanche (Ingres JDBC), JasperReports Server 10.0.0 (STAGE `localhost:8081/jasperserver-pro`, PROD `3.214.51.180:8080/jasperserver-pro`), PowerShell 5.1, jasper-deploy skill scripts (`.claude/skills/jasper-deploy/scripts` — alias `$jd` below), admiral skill scripts (`.claude/skills/admiral/scripts` — alias `$adm` below), Wobby Public API.

**Spec:** `specs/2026-08-20-pos-sales-dashboards-design.md` (mockups: https://claude.ai/code/artifact/3f310c6e-4e45-44bf-b178-f341178d7854)

## Global Constraints

- Repo is PUBLIC: no credentials in any committed file. Warehouse creds live in `.claude/skills/admiral/admiral.config.json` (`db_pos_data` block, gitignored); JRS creds in the jasper-deploy config. JRXMLs reference the JRS datasource URI only.
- Warehouse: `av-flm7ykoxlcvq.avstage.actiandatacloud.com:27839`, db `db`, user `robert.gorsuch`, schema `robert.gorsuch`. All `sql.ps1` calls pass `-DbHost "av-flm7ykoxlcvq.avstage.actiandatacloud.com" -Database db` plus `-DbUser/-DbPassword` read from the config's `db_pos_data` block.
- Wobby API: base `https://app.wobby.ai/api/public/v1`, Bearer key (session-provided, never committed). HARD rate limit 2 req/5 s per IP, 1-hour IP ban on violation: minimum 4 s between calls, never retry a 429.
- Brand: title centered + Actian logo top-left of title band (JRS repo `/images/actian_logo`); title `#1F4E79`, subtitle `#5B7DA6` (house report standard); chart categorical order `#0550DC #1DB6C0 #0A4CAD #239CA8`; choropleth sequential blues `#C8E4FF→#0A4CAD`; no "Foodmart"/"Wobby" strings in user-visible report text.
- New JRXMLs live under `report/pos_perf/` (the existing `report/pos/` set belongs to the old comprehensive dashboard — do not modify it). JRS folder `/reports/pos_perf`.
- Dashboard recompose requires deleting the existing dashboard first (house rule).
- All dashlet tiles: `showTitleBar:false`, `scaleToFit:width` in manifests.
- Acceptance reference numbers (Regular Sale, Jan 2019–Dec 2020). Task 2's margin-basis probe (`out/pos_perf/margin_basis_decision.md`) confirmed `sellingprice` is a per-unit price (net sales must extend by quantity: `SUM(sellingprice*quantity)`) while `cost` is already line-extended (total cost must NOT be re-multiplied by quantity: `SUM(cost)`, not `SUM(cost*quantity)`) — so the sales-side numbers below are unchanged from the original extended-basis figures, and total cost / gross margin are now pinned down for the first time: net sales $764,167,990.73; total cost $522,326,380.9364; gross margin $241,841,609.7936; gross margin % 31.65%; avg basket value $39.21; avg unit price $9.36; 19,487,389 transactions; 81,616,420 units; 330 stores; region sales ON $411.7M / Western $237.6M / QC $80.0M / Atlantic $34.8M; TPR $388.1M. (Rejected alternative: per-line, unextended net sales of $630,046,078.45 — `sellingprice` is not extended in the raw column.)

---

### Task 1: Environment prerequisites (allowlist, JDBC driver, FusionMaps, customizer jar)

**Files:**
- Create: `out/pos_perf/prereq_report.md` (working notes, gitignored `out/`)

**Interfaces:**
- Produces: a go/no-go note per prerequisite; the FusionMaps decision (`fusion` or `tilegrid`) consumed by Task 5.

- [ ] **Step 1: Allowlist both JRS instance IPs on the warehouse**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
# PROD JRS
& "$adm\resource.ps1" -Action allowlist-ip -ResourceType warehouse -ResourceId av-flm7ykoxlcvq -AllowIp "3.214.51.180/32" -AllowLabel "JRS PROD"
# STAGE JRS runs on this workstation; confirm the existing "Robert Gorsuch IP Address" entry still matches (curl ifconfig.me) and add the current IP if it rotated.
& "$adm\resource.ps1" -Action get -ResourceType warehouse -ResourceId av-flm7ykoxlcvq
```
Expected: allowlist shows `3.214.51.180/32` with status `applied`. (Check `resource.ps1`'s exact allowlist parameter names via its header comment first; adjust flags to match.)

- [ ] **Step 2: Verify the Ingres JDBC driver on STAGE and PROD**

STAGE (local filesystem): locate Tomcat webapp lib and check for `iijdbc.jar`:
```powershell
Get-ChildItem -Recurse -Filter "iijdbc*.jar" "C:\Jaspersoft*\apache-tomcat\webapps\jasperserver-pro\WEB-INF\lib" 2>$null
```
PROD (WinRM, same automation path used for the audit-config change): list `WEB-INF/lib` for `iijdbc*.jar` and the chart customizer jar. If missing on either: copy the local Actian client `iijdbc.jar` there and restart Tomcat (PROD restart is a state change — confirm with the user before restarting PROD).

- [ ] **Step 3: Verify FusionMaps availability**

Query STAGE for the Fusion license/pro charting (the Foodmart map report `foodmart_sales_units_map` deploys FusionMaps Pro — if it exists and runs on the target instance, Fusion is available):
```powershell
$jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\run_report_async.ps1" -ReportUri "/reports/foodmart/foodmart_sales_units_map" -Format pdf -OutFile out\pos_perf\fusion_probe.pdf
```
Expected: PDF renders on STAGE. Repeat against PROD (promote.ps1/config selects the env). Record decision: `fusion` if both render, else `tilegrid` (HTML5/SVG tile-grid report per the mockup).

- [ ] **Step 4: Record results and commit nothing** — `out/` is gitignored; summarize findings in the task report.

### Task 2: Margin-basis investigation, Wobby measure + metadata fixes

**Files:**
- Create: `scripts/pos_perf/margin_basis_probe.sql`
- Create: `out/pos_perf/margin_basis_decision.md`

**Interfaces:**
- Produces: `BASIS` decision (`unit` = prices/costs are per-unit → extended formulas `SUM(col*quantity)` are correct; `extended` = columns are line-extended → per-line formulas `SUM(col)` are correct). Consumed by Tasks 3 and 5–7 report SQL. Also: corrected Wobby measures and model description.

- [ ] **Step 1: Write the probe SQL**

```sql
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
```

- [ ] **Step 2: Run it and decide**

```powershell
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\margin_basis_probe.sql -DbHost av-flm7ykoxlcvq.avstage.actiandatacloud.com -Database db <creds>
```
Decision rule: if `avg_sp ≈ avg_reg` independent of quantity → columns are **unit** prices (extended formulas correct). If `avg_sp ≈ quantity × avg_reg` (and `avg_sp_per_unit ≈ avg_reg`) → columns are **extended** (per-line formulas correct). Apply the same test to cost (A and B may differ — record each independently; the margin formula uses each column on its own decided basis). Write `out/pos_perf/margin_basis_decision.md` with the evidence and the final formulas for: net_sales, total_cost, gross_margin, gross_margin_pct, avg_basket_value, avg_unit_price.

- [ ] **Step 3: Fix the Wobby semantic layer**

Export current environment (GET `/environment`), patch in memory: the affected measure `expression`s per the decision, and the model/analyst descriptions' date range (Apr 2019–Oct 2020 → January 2019 – December 2020). PUT `/environment` back. Respect the 4 s spacing; on 422 read the body; on 429 stop and wait out the ban. Re-GET (after 4 s) and diff to confirm the changes landed.

- [ ] **Step 4: Re-baseline acceptance numbers**

If the decision changed any headline formula, recompute the acceptance table (one `sql.ps1 query` with the final formulas) and update the Global Constraints acceptance line in THIS plan file. Commit:
```powershell
git add scripts/pos_perf/margin_basis_probe.sql plans/2026-08-20-pos-sales-dashboards.md
git commit -m "feat(pos-perf): margin basis decision + wobby measure fixes"
```

### Task 3: Aggregate tables in the warehouse

**Files:**
- Create: `scripts/pos_perf/build_dash_aggregates.sql`
- Create: `scripts/pos_perf/verify_dash_aggregates.sql`

**Interfaces:**
- Produces: tables `dash_monthly`, `dash_region`, `dash_province`, `dash_promo`, `dash_store` and view `dash_kpi` in schema `robert.gorsuch`. All report SQL in Tasks 5–7 reads ONLY these. Columns (additive components, both bases kept so reports are basis-agnostic): `sales_ext` (=SUM(sellingprice*quantity)), `sales_line` (=SUM(sellingprice)), `cost_ext`, `cost_line`, `qty`, `tx` (=COUNT(DISTINCT transactionuniqueid)), `line_items` (=COUNT(*)).

- [ ] **Step 1: Write the build script**

```sql
-- build_dash_aggregates.sql  (DROP-and-rebuild; source table is static)
DROP TABLE IF EXISTS dash_monthly;
CREATE TABLE dash_monthly AS
SELECT YEAR(DATE(saledate)) AS yr, MONTH(DATE(saledate)) AS mo,
       storeregion, promotiontype,
       CASE WHEN DATE(saledate) >= DATE('2020-03-01') THEN 'Pandemic' ELSE 'Pre-pandemic' END AS pandemic_period,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx, COUNT(*) AS line_items
FROM pos_sales_detail
WHERE transactiontype = 'Regular Sale'
GROUP BY 1,2,3,4,5;

DROP TABLE IF EXISTS dash_region;
CREATE TABLE dash_region AS
SELECT storeregion, COUNT(DISTINCT storenumber) AS stores,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx, COUNT(*) AS line_items
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1;

DROP TABLE IF EXISTS dash_province;
CREATE TABLE dash_province AS
SELECT storeprovince, COUNT(DISTINCT storenumber) AS stores,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1;

DROP TABLE IF EXISTS dash_promo;
CREATE TABLE dash_promo AS
SELECT promotiontype, storeregion, YEAR(DATE(saledate)) AS yr, MONTH(DATE(saledate)) AS mo,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(cost*quantity) AS cost_ext, SUM(cost) AS cost_line,
       SUM(quantity) AS qty, COUNT(*) AS line_items
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1,2,3,4;

DROP TABLE IF EXISTS dash_store;
CREATE TABLE dash_store AS
SELECT storenumber, storename, storeregion, storeprovince,
       SUM(sellingprice*quantity) AS sales_ext, SUM(sellingprice) AS sales_line,
       SUM(quantity) AS qty, COUNT(DISTINCT transactionuniqueid) AS tx
FROM pos_sales_detail WHERE transactiontype = 'Regular Sale' GROUP BY 1,2,3,4;

DROP VIEW IF EXISTS dash_kpi;
CREATE VIEW dash_kpi AS
SELECT SUM(sales_ext) AS sales_ext, SUM(sales_line) AS sales_line,
       SUM(cost_ext) AS cost_ext, SUM(cost_line) AS cost_line,
       SUM(qty) AS qty, SUM(tx) AS tx, SUM(line_items) AS line_items
FROM dash_monthly;
```
(Confirm `DROP TABLE IF EXISTS` / `DROP VIEW IF EXISTS` syntax against the Avalanche dialect via the admiral skill reference; substitute plain DROP + ignore-error if unsupported. `dash_kpi.tx` sums monthly distinct counts — a transaction never spans months, so the sum equals the global distinct count; verify in Step 3.)

- [ ] **Step 2: Run the build**

```powershell
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_aggregates.sql -DbHost av-flm7ykoxlcvq.avstage.actiandatacloud.com -Database db <creds>
```
Expected: all statements OK.

- [ ] **Step 3: Write + run the verification script**

```sql
-- verify_dash_aggregates.sql — every row must match the acceptance table
SELECT 'kpi' AS chk, sales_ext, tx, qty FROM dash_kpi;
SELECT 'region' AS chk, storeregion, sales_ext, stores FROM dash_region ORDER BY sales_ext DESC;
SELECT 'months' AS chk, COUNT(*) AS n FROM (SELECT DISTINCT yr, mo FROM dash_monthly) t;
SELECT 'tx_exact' AS chk, COUNT(DISTINCT transactionuniqueid) FROM pos_sales_detail WHERE transactiontype = 'Regular Sale';
```
Expected: kpi row = 764167990.73 / 19487389 / 81616420; regions ON 411.7M(163) W 237.6M(111) QC 80.0M(42) ATL 34.8M(14); months = 24; `tx_exact` equals `dash_kpi.tx`.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_aggregates.sql scripts/pos_perf/verify_dash_aggregates.sql
git commit -m "feat(pos-perf): dash_* aggregate tables + verification"
```

### Task 4: JRS datasource + smoke report on STAGE

**Files:**
- Create: `report/pos_perf/smoke_kpi.jrxml` (scaffolded)

**Interfaces:**
- Produces: JRS datasource `/datasources/pos_data_avalanche` (JDBC, `jdbc:ingres://av-flm7ykoxlcvq.avstage.actiandatacloud.com:27839/db`, driver `com.ingres.jdbc.IngresDriver`) and JRS folder `/reports/pos_perf`. All Task 5–7 reports set this datasource.

- [ ] **Step 1: Create folder + datasource on STAGE**

```powershell
& "$jd\create_datasource.ps1" -Uri "/datasources/pos_data_avalanche" -Label "POS Data (Avalanche)" -JdbcUrl "jdbc:ingres://av-flm7ykoxlcvq.avstage.actiandatacloud.com:27839/db" -DriverClass "com.ingres.jdbc.IngresDriver" -DbUser "robert.gorsuch" -DbPassword <from config>
```
(Exact flags per the script header; include the connection-test option if offered.)

- [ ] **Step 2: Scaffold, lint, deploy a one-row smoke report**

Query: `SELECT sales_ext, tx, qty FROM dash_kpi`. Scaffold with `scaffold_jrxml.py`, lint (`lint_jrxml.ps1` — house rule: lint before deploy), deploy (`deploy_report.ps1 -Overwrite`), run:
```powershell
& "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/smoke_kpi" -Format pdf -OutFile out\pos_perf\smoke.pdf
python "$jd\pdf_verify.py" out\pos_perf\smoke.pdf
```
Expected: PDF contains 764167990.73 (or re-baselined value). This proves driver + allowlist + datasource end-to-end.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/smoke_kpi.jrxml
git commit -m "feat(pos-perf): Avalanche datasource + smoke report"
```

### Task 5: Option A — Executive Overview reports + dashboard (STAGE)

**Files:**
- Create: `report/pos_perf/exec_map.jrxml`, `exec_margin_dial.jrxml`, `exec_yoy_dial.jrxml`, `exec_trend.jrxml`, `exec_region_bar.jrxml`, `exec_top_stores.jrxml`, `exec_promo_mix.jrxml`, `exec_kpi_strip.jrxml`, `exec_last_updated.jrxml`
- Create: `report/pos_perf/exec_dashboard.json` (manifest)

**Interfaces:**
- Consumes: `dash_*` tables (Task 3 column names), datasource URI (Task 4), FusionMaps decision (Task 1), BASIS formulas (Task 2 — the SQL below shows the extended-basis variant; substitute the decided formulas).
- Produces: dashboard `/reports/pos_perf/pos_executive_overview`.

- [ ] **Step 1: Scaffold the nine reports** with `scaffold_jrxml.py` (centered title + logo come from the scaffolder defaults). Per-tile spec — page px mirror the Foodmart standard:

| Report | Query (extended-basis shown) | Element | Page px |
|---|---|---|---|
| exec_map | `SELECT storeprovince, sales_ext, qty FROM dash_province ORDER BY sales_ext DESC` | FusionMaps "Canada" (ids per Fusion map spec) if `fusion`, else HTML5 tile-grid | 842×596 |
| exec_margin_dial | `SELECT (SUM(sales_ext)-SUM(cost_ext))/NULLIF(SUM(sales_ext),0)*100 AS v FROM dash_monthly` | JFreeChart meter, `shape="dial"`, square element, scale 0–40, overlay textField for the value | 400×260 |
| exec_yoy_dial | `SELECT (SUM(CASE WHEN yr=2020 THEN sales_ext END)/NULLIF(SUM(CASE WHEN yr=2019 THEN sales_ext END),0)-1)*100 AS v FROM dash_monthly` | same meter pattern, scale 0–40 | 400×260 |
| exec_trend | `SELECT yr, mo, SUM(sales_ext) AS v FROM dash_monthly GROUP BY 1,2 ORDER BY 1,2` | line chart, series `#0550DC`, labels −45°, interval marker on 2020-03..2020-12 via customizer | 1000×220 |
| exec_region_bar | `SELECT storeregion, sales_ext FROM dash_region ORDER BY sales_ext DESC` | bar (gradient customizer), direct value labels | 950×422 |
| exec_top_stores | `SELECT storename, storeregion, sales_ext FROM dash_store ORDER BY sales_ext DESC FETCH FIRST 6 ROWS ONLY` | ranked table (`$V{REPORT_COUNT}` #), `$#,##0` | 800×214 |
| exec_promo_mix | `SELECT promotiontype, SUM(sales_ext) AS v FROM dash_promo GROUP BY 1 ORDER BY 2 DESC` | 100% stacked bar, T=`#0550DC`, blank=`#1DB6C0`, direct % labels | 950×300 |
| exec_kpi_strip | `SELECT sales_ext, tx, qty, sales_ext/NULLIF(tx,0) AS basket, 330 AS stores FROM dash_kpi` | 5 textField cells with `#D6E0EF` dividers, `evaluationTime="Report"` | 1600×130 |
| exec_last_updated | `SELECT CURRENT_TIMESTAMP AS ts` (same Avalanche datasource) | "Last refreshed: … · Version 1.0" textFields | 600×96 |

- [ ] **Step 2: Lint + compile-check all nine** (`lint_jrxml.ps1`, `compile_jrxml.ps1`). Fix findings before deploy.

- [ ] **Step 3: Deploy all nine** to `/reports/pos_perf` with `deploy_report.ps1 -Overwrite`; run each to PDF via `run_report_async.ps1`; rasterize (`pdf_verify.py`) and check values against the acceptance table (dial 17.1%*/basis, YoY +19.8%, region values, top store St. Thomas $5.69M).

- [ ] **Step 4: Write the manifest** `exec_dashboard.json` — 40-unit grid, tiles at the Foodmart-standard coordinates: map (0,0,12,16), margin dial (12,0,8,9), yoy dial (20,0,8,9), last_updated (28,0,12,2), region bar (28,2,12,10), promo mix (28,12,12,11), trend (12,9,16,7), top stores (0,16,14,7), kpi strip (0,23,40,7); every tile `showTitleBar:false`, `scaleToFit:width`.

- [ ] **Step 5: Compose on STAGE** (`compose_dashboard.ps1`; delete `/reports/pos_perf/pos_executive_overview` first if it exists), open in the viewer, rasterize the dashboard run and compare against the Option A mockup.

- [ ] **Step 6: Commit**

```powershell
git add report/pos_perf/exec_*.jrxml report/pos_perf/exec_dashboard.json
git commit -m "feat(pos-perf): Executive Overview reports + dashboard (STAGE)"
```

### Task 6: Option B — Operations Console reports + input controls + dashboard (STAGE)

**Files:**
- Create: `report/pos_perf/ops_kpi_chips.jrxml`, `ops_sales_trend.jrxml`, `ops_margin_trend.jrxml`, `ops_region_bar.jrxml`, `ops_promo_panel.jrxml`, `ops_leaderboard.jrxml`
- Create: `report/pos_perf/ops_dashboard.json`

**Interfaces:**
- Consumes: `dash_monthly` / `dash_promo` / `dash_store` (Task 3), datasource (Task 4), BASIS (Task 2).
- Produces: dashboard `/reports/pos_perf/pos_operations_console`; shared input controls under `/reports/pos_perf/controls`.

- [ ] **Step 1: Create four shared input controls** (jasper-deploy input-control tooling; type codes per the house PowerShell/JRS notes): `p_from` + `p_to` (single-value date, defaults 2019-01-01 / 2020-12-31), `p_regions` (multi-select query control: `SELECT DISTINCT storeregion FROM dash_region ORDER BY 1`), `p_promo` (single-select: All/T/M/O/none), `p_period` (single-select: All/Pre-pandemic/Pandemic).

- [ ] **Step 2: Scaffold the six reports**, every query filtered the same way, e.g. sales trend:

```sql
SELECT yr, mo, SUM(sales_ext) AS v
FROM dash_monthly
WHERE (yr*100+mo) BETWEEN YEAR($P{p_from})*100+MONTH($P{p_from}) AND YEAR($P{p_to})*100+MONTH($P{p_to})
  AND $X{IN, storeregion, p_regions}
  AND ($P{p_promo} = 'All' OR promotiontype = $P{p_promo})
  AND ($P{p_period} = 'All' OR pandemic_period = $P{p_period})
GROUP BY 1,2 ORDER BY 1,2
```
Same WHERE block in all six (chips: aggregate without GROUP BY; margin trend: `(SUM(sales_ext)-SUM(cost_ext))/NULLIF(SUM(sales_ext),0)*100`; promo panel: group by promotiontype; leaderboard: `dash_store` has no month/promo grain — filter by region only and note that on the tile subtitle; region bar: group by storeregion).

- [ ] **Step 3: Lint, compile, deploy, and exercise controls**: run each report default, then once with `p_regions=Ontario` + `p_period=Pandemic` and confirm the numbers shrink accordingly (Ontario pandemic sales must be < $411.7M and > $0).

- [ ] **Step 4: Manifest + compose** `pos_operations_console`: filter controls in the dashboard's filter panel wired to all six dashlets; grid: chips (0,0,40,4), sales trend (0,4,20,10), margin trend (20,4,20,10), region bar (0,14,20,10), promo panel (20,14,20,10), leaderboard (0,24,40,8).

- [ ] **Step 5: Verify + commit**

```powershell
git add report/pos_perf/ops_*.jrxml report/pos_perf/ops_dashboard.json
git commit -m "feat(pos-perf): Operations Console reports + input controls + dashboard (STAGE)"
```

### Task 7: Option C — Promo & Margin Story reports + dashboard (STAGE)

**Files:**
- Create: `report/pos_perf/story_hero.jrxml`, `story_trend.jrxml`, `story_cards.jrxml`
- Create: `report/pos_perf/story_dashboard.json`

**Interfaces:**
- Consumes: `dash_monthly` / `dash_promo` / `dash_kpi`, datasource, BASIS.
- Produces: dashboard `/reports/pos_perf/pos_promo_story`.

- [ ] **Step 1: Scaffold three wide reports**:
  - `story_hero` (1600×260, Software Blue `#000032` band): headline textFields from `SELECT sales_ext, tx FROM dash_kpi` + 2019/2020 split from `dash_monthly`; copy per mockup ("$764M in net sales." / "+19.8% growth through a pandemic." — substitute re-baselined numbers).
  - `story_trend` (1600×420): monthly line with pandemic interval marker (2020-03 onward) and three point annotations (Dec 2019, Mar 2020, Dec 2020) via chart customizer.
  - `story_cards` (1600×300): three side-by-side panels — promo penetration 100% bar (`dash_promo`), margin-basis card (both computed values, amber styling on the deprecated basis; if Task 2 resolved the basis, restyle as "validated" note showing the adopted formula), basket economics (basket = sales/tx, units/tx, unit price = sales/qty from `dash_kpi`).

- [ ] **Step 2: Lint, compile, deploy, run-to-PDF, verify values.**

- [ ] **Step 3: Manifest + compose** `pos_promo_story` — hero (0,0,40,6), trend (0,6,40,12), cards (0,18,40,8).

- [ ] **Step 4: Commit**

```powershell
git add report/pos_perf/story_*.jrxml report/pos_perf/story_dashboard.json
git commit -m "feat(pos-perf): Promo & Margin Story reports + dashboard (STAGE)"
```

### Task 8: Promote to PROD + end-to-end verification

**Files:**
- Modify: none (promotion only)

**Interfaces:**
- Consumes: everything under `/reports/pos_perf` + `/datasources/pos_data_avalanche` on STAGE.

- [ ] **Step 1: Promote** datasource, folder, reports, input controls, dashboards STAGE→PROD via `promote.ps1` (or export/import per the skill's promotion flow). PROD datasource carries the same JDBC URL; credentials entered at promote time, never from a committed file.

- [ ] **Step 2: Verify on PROD**: run all three dashboards, rasterize, compare to STAGE output; exercise Option B controls once (Ontario + Pandemic). Confirm the PROD IP allowlist held (no connection errors).

- [ ] **Step 3: Commit any manifest/coordinate fixes made during verification**

```powershell
git add report/pos_perf/
git commit -m "feat(pos-perf): dashboards live on PROD"
```

### Task 9: Documentation + memory

**Files:**
- Modify: `README.md` (add pos_perf dashboards section), `RUNBOOK.md` (aggregate rebuild + redeploy workflow)
- Create: memory `pos-perf-dashboards.md` (URIs, layouts, basis decision, warehouse/aggregate pointers) + MEMORY.md index line

- [ ] **Step 1: Document** the three dashboard URIs, the aggregate rebuild command, the recompose workflow (delete-first), and the margin-basis decision in README/RUNBOOK.
- [ ] **Step 2: Save the memory file** with the final layout coordinates and per-report settings (Foodmart-standard style).
- [ ] **Step 3: Commit**

```powershell
git add README.md RUNBOOK.md
git commit -m "docs(pos-perf): dashboard runbook + README"
```
