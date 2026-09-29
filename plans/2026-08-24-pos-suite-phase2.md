# POS Dashboard Suite - Phase 2 (Customers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy to STAGE the Retention and Churn console (dashboard 6) and its Churn Action List report, fed by the churn model's scored output that already lives in the warehouse.

**Architecture:** Two new aggregates: `dash_churn` (customer grain, a join of the existing `customer_churn_scores` + `customers` + `customer_ipt_stats`, no new modeling) and `dash_cohort` (small `cohort_year x months_since_first` rollup of `customer_month`). Hand-authored JR7 JRXMLs under `report/pos_perf/` following the `trs_*` console idiom exactly (dashboard-level filter strip via the manifest `"filters"` key built in Phase 1 Task 2, `Attach-Controls` helper, `chn_*` naming). The Churn Action List report follows the `rpt_ar_aging` list-report pattern, capped and ranked (an unranked "High + Critical" list would be 2.1M rows).

**Tech Stack:** Actian Avalanche X100 (Ingres JDBC, `av-flm7ykoxlcvq`, schema `robert.gorsuch`), JasperReports Server 10.0.0 Pro (STAGE `http://localhost:8081/jasperserver-pro`), PowerShell 5.1, jasper-deploy skill, admiral skill.

**Spec:** `specs/2026-08-23-pos-suite-design.md` (dashboard 6 and the Churn Action List report). Phases 3-4 get their own plans after this one ships.

## Global Constraints

- Repo is PUBLIC. No credentials, hostnames-with-passwords, or API keys in any committed file. JRS creds come from `.claude/skills/jasper-deploy/jrs.config.json` (gitignored); warehouse creds from `.claude/skills/admiral/admiral.config.json`.
- Environment selection: `$env:JRS_ENV = "stage"` before any `$jd` script. **Never run a `$jd` script against `prod` in this plan.** PROD promotion is a separate go/no-go the user runs later, same as Phase 1 (RUNBOOK.md section 12 pattern) — Task 6 documents the block, nobody executes it.
- Warehouse calls: `& "$adm\sql.ps1" -Action run-file -SqlFile <file> -ResourceId av-flm7ykoxlcvq`. `run-file` splits on EVERY `;` and tracks `'`/`"` state with no comment awareness: **no `;`, `'`, or `"` inside any SQL comment**. Wrap every ratio in `FLOAT8(...)`. Use `FIRST n`, not `LIMIT`. Views: `DROP VIEW IF EXISTS`; tables: `DROP TABLE IF EXISTS ... ; CREATE TABLE ... AS SELECT ...; CREATE STATISTICS FOR <table>;`.
- Ingres X100 gotcha confirmed this session: dividing or doing arithmetic directly on an `ANSIDATE` column (e.g. `first_purchase_date / 10000`) throws `Rewriter error`. Use `EXTRACT(YEAR FROM <date_col>)` instead — confirmed working.
- JRXML is JR7-native: `<query language="SQL">`, `<element kind="staticText|textField|line|rectangle|image|chart">`, `<text>`/`<expression>` children, `<element kind="chart" chartType="bar|stackedBar|line|area|pie|meter">` with `<dataset kind="category">` and `<plot><seriesColor order="n" color="#hex"/></plot>`. Charts in the `title` band need `evaluationTime="Report"`. Never mix JR6 legacy syntax into a JR7 file. `<seriesColor order="n">` binds by series REGISTRATION order — a null value on the first row does not register, shifting/inverting colours. Guard every chart series with a zero default (`BigDecimal.ZERO` expression guard, or a SQL-side `COALESCE(SUM(...), 0)`).
- Brand, light theme (this whole phase is light — Console archetype, no navy): Actian logo top-left (`"repo:/images/actian_logo"`, 44x44 at 0,0), title centered `forecolor="#1F4E79"` 16pt bold, subtitle `#5B7DA6` 9pt; KPI label `fontSize="13.0" forecolor="#5B7DA6"`, KPI value `fontSize="26.0" bold forecolor="#1F4E79"`, dividers `#D6E0EF`; table header `#1F4E79` on white, zebra `#D6E0EF`; series order `#0550DC`, `#1DB6C0`, `#0A4CAD`, `#239CA8`; favourable/unfavourable `#5CB85C` / `#D9534F`.
- No "Foodmart", "Wobby", datasource URIs, SQL, table or column names in user-visible text. Dashboard labels contain no `&` (compose does not XML-escape). Current-year rule does not apply: this data is dated 2019-2020 and the tiles say so.
- Dashboards: 40-unit grid, every dashlet `showTitleBar:false`. **The filter strip is synthesized by the composer from the manifest's top-level `"filters"` array — it is NOT a dashlet.** Confirmed from the shipped `report/pos_perf/trs_dashboard.json`: `trs_kpi` sits at `y=0` (not `y=3`), i.e. every tile's y-coordinate is the spec mockup's y minus 3 (the mockup reserved 3 rows for an explicit control tile that the composer now generates itself). Delete the dashboard (`teardown_dashboard.ps1 -Uri ...`) before every recompose. Dashboards cannot be run to PDF (verify the tiles' report units instead, then eyeball the viewer URL `.../dashboard/viewer.html#%2Freports%2Fpos_perf%2F<name>`).
- Page sizes by tile shape (pageWidth x pageHeight, margins 10 unless stated): 40x4 KPI strip 1600x130; 40x3 control strip 1600x100 (unused this phase — no explicit control tile); 13x11 or 14x11 chart 600x420; 20x12 list 800x440. **New this phase** (derived by the same w-bucket rule, height scaled from the h12 buckets): 21x10 chart 1000x380 (from the 20-22-wide 1000x440 bucket, h10/h12 scaling); 19x10 list 800x380 (from the 20-wide 800x440 list bucket, same scaling).
- `deploy_report.ps1 -Overwrite` DROPS a report unit's attached inputControls — re-attach via `. .\scripts\pos_perf\jrs_controls.ps1` (or a phase-2 equivalent, see Task 3) and GET-verify after every redeploy. A tile already composed into a dashboard 403s `resource.in.use` on redeploy — teardown the dashboard first, redeploy, re-attach, recompose.
- Acceptance references (from the queries run to ground this plan, warehouse state as of 2026-08-24): `customer_churn_scores` 3,184,743 rows, single `score_date` 2020-12-31; risk bands Critical 684,159 / High 1,447,344 / Watch 587,944 / Low 465,296 (Critical+High = 66.92 pct of scored customers); `lifecycle_status` Active 1,153,026 / Churned 755,879 / Lapsing 145,965 / New 40,562 / One-time 1,089,311; `recommended_action` None 1,803,218 / Win-back offer 908,339 / Loyalty bonus 265,021 / Second-buy nudge 207,268 / Delivery recovery 535 / Service follow-up 362; expected LTV at risk (Critical+High) 20,807,163.28; avg churn_probability 0.5239; pct with `overdue_ratio > 1` (i.e. already overdue vs their own expected cadence) 32.50 pct; cohort customers by first-purchase year: 2019 = 2,370,749, 2020 = 814,198; 2019-cohort active share by months-since-first settles around 26-28 pct from month 3 onward (month 0 = 100 pct by definition); 2020-cohort active share (partial year, fewer months of data) runs lower, around 20-24 pct.
- Categorical values used in SQL: `risk_band` = `Critical` | `High` | `Watch` | `Low`; `lifecycle_status` (on `customer_churn_scores`, distinct from the similarly-named column on `customers`/`customer_ipt_stats`) = `Active` | `Churned` | `Lapsing` | `New` | `One-time`; `recommended_action` = `None` | `Win-back offer` | `Loyalty bonus` | `Delivery recovery` | `Service follow-up` | `Second-buy nudge`; `home_region` = `Ontario` | `Western` | `Quebec` | `Atlantic` (same vocabulary as Phase 1's `region`); `loyalty_tier` = `Bronze` | `Silver` | `Gold` | `Platinum`; `customer_month.active_flag` = `Y` | `N`.

---

### Task 1: dash_churn aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_churn.sql`
- Create: `scripts/pos_perf/verify_dash_churn.sql`

**Interfaces:**
- Consumes: `customer_churn_scores` (customer_id, score_date, model_version, churn_probability, risk_band, expected_ltv_at_risk, bgnbd_p_alive, overdue_ratio, lifecycle_status, driver_1, driver_2, driver_3, recommended_action); `customers` (customer_id, home_region, loyalty_tier, home_store_number); `customer_ipt_stats` (customer_id, expected_next_purchase).
- Produces: table `dash_churn(customer_id VARCHAR(20), region VARCHAR(20), loyalty_tier VARCHAR(8), storenumber INTEGER, score_date ANSIDATE, risk_band VARCHAR(8), churn_probability DECIMAL(6,4), expected_ltv_at_risk DECIMAL(12,2), overdue_ratio DECIMAL(8,4), lifecycle_status VARCHAR(8), driver_1 VARCHAR(32), driver_2 VARCHAR(32), driver_3 VARCHAR(32), recommended_action VARCHAR(20), expected_next_purchase ANSIDATE)`, one row per scored customer (3,184,743 rows). Tasks 4 and 5 read it.

- [ ] **Step 1: Write the build script**

```sql
-- dash_churn: customer_churn_scores joined to customers (region, tier, store)
-- and customer_ipt_stats (expected next purchase). Customer grain, one row
-- per scored customer -- no further pre-aggregation needed, X100 is columnar
-- and 3.18M rows scans fine for live GROUP BY in dashboard tiles.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_churn;
CREATE TABLE dash_churn AS
SELECT s.customer_id,
       c.home_region AS region,
       c.loyalty_tier,
       c.home_store_number AS storenumber,
       s.score_date,
       s.risk_band,
       s.churn_probability,
       s.expected_ltv_at_risk,
       s.overdue_ratio,
       s.lifecycle_status,
       s.driver_1,
       s.driver_2,
       s.driver_3,
       s.recommended_action,
       i.expected_next_purchase
FROM customer_churn_scores s
JOIN customers c ON c.customer_id = s.customer_id
LEFT JOIN customer_ipt_stats i ON i.customer_id = s.customer_id;
CREATE STATISTICS FOR dash_churn;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_churn
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain and row count, expect 3184743, 0 dup keys
SELECT COUNT(*) AS rows_, COUNT(DISTINCT customer_id) AS distinct_customers,
       (SELECT COUNT(*) FROM (SELECT customer_id FROM dash_churn GROUP BY customer_id HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_churn;
-- 2 ties to source to the row, expect all four equal to 3184743
SELECT (SELECT COUNT(*) FROM dash_churn) AS agg_n,
       (SELECT COUNT(*) FROM customer_churn_scores) AS src_n,
       (SELECT COUNT(*) FROM dash_churn WHERE region IS NULL) AS null_region,
       (SELECT COUNT(*) FROM dash_churn WHERE loyalty_tier IS NULL) AS null_tier;
-- 3 risk band distribution, expect Critical 684159 / High 1447344 / Watch 587944 / Low 465296
SELECT risk_band, COUNT(*) AS n FROM dash_churn GROUP BY risk_band ORDER BY risk_band;
-- 4 LTV at risk for Critical+High, expect 20807163.28
SELECT DECIMAL(SUM(expected_ltv_at_risk), 14, 2) AS ltv_at_risk FROM dash_churn WHERE risk_band IN ('Critical', 'High');
-- 5 region and tier vocab, expect 4 regions and 4 tiers, no unexpected values
SELECT region, COUNT(*) AS n FROM dash_churn GROUP BY region ORDER BY region;
SELECT loyalty_tier, COUNT(*) AS n FROM dash_churn GROUP BY loyalty_tier ORDER BY loyalty_tier;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_churn.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_churn.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 rows_=3184743, dup_keys=0; check 2 agg_n=src_n=3184743, null_region=0, null_tier=0; check 3 the four band counts above; check 4 20807163.28; check 5 exactly Ontario/Western/Quebec/Atlantic and Bronze/Silver/Gold/Platinum, no NULLs or stray values.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_churn.sql scripts/pos_perf/verify_dash_churn.sql
git commit -m "feat(pos-perf): dash_churn aggregate for the Retention and Churn console"
```

---

### Task 2: dash_cohort aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_cohort.sql`
- Create: `scripts/pos_perf/verify_dash_cohort.sql`

**Interfaces:**
- Consumes: `customer_month` (customer_id, months_since_first, active_flag); `customers` (customer_id, first_purchase_date).
- Produces: table `dash_cohort(cohort_year INTEGER, months_since_first INTEGER, customers INTEGER, active_customers INTEGER, active_pct DECIMAL(6,2))`, one row per cohort year x months-since-first (small, ~48 rows for the 2019/2020 cohorts x ~24 months). Task 4 reads it. `customer_month` itself is too large (one row per customer per active month) to scan live in a dashboard tile -- this pre-aggregation is required, not optional.

- [ ] **Step 1: Write the build script**

```sql
-- dash_cohort: customer_month rolled up to cohort_year x months_since_first,
-- active share per cell. cohort_year comes from customers.first_purchase_date.
-- NOTE: EXTRACT(YEAR FROM date_col) works on ANSIDATE; date_col / 10000 does
-- not (Rewriter error). NOTE: no semicolons or apostrophes inside comments.
DROP TABLE IF EXISTS dash_cohort;
CREATE TABLE dash_cohort AS
SELECT EXTRACT(YEAR FROM c.first_purchase_date) AS cohort_year,
       cm.months_since_first,
       INT4(COUNT(*)) AS customers,
       INT4(SUM(CASE WHEN cm.active_flag = 'Y' THEN 1 ELSE 0 END)) AS active_customers,
       DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN cm.active_flag = 'Y' THEN 1 ELSE 0 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS active_pct
FROM customer_month cm
JOIN customers c ON c.customer_id = cm.customer_id
GROUP BY 1, 2;
CREATE STATISTICS FOR dash_cohort;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_cohort
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain, expect 0 dup keys, cohort years 2019 and 2020 only
SELECT COUNT(*) AS rows_, MIN(cohort_year) AS min_yr, MAX(cohort_year) AS max_yr,
       (SELECT COUNT(*) FROM (SELECT cohort_year, months_since_first FROM dash_cohort GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_cohort;
-- 2 month-0 active_pct must be 100.00 for both cohorts (everyone is active in their first month by definition)
SELECT cohort_year, active_pct FROM dash_cohort WHERE months_since_first = 0 ORDER BY cohort_year;
-- 3 sample the curve at months 3, 6, 9, 12 -- expect 2019 settling around 26-28, 2020 lower (partial year)
SELECT FIRST 20 cohort_year, months_since_first, active_pct, customers FROM dash_cohort
WHERE months_since_first IN (3, 6, 9, 12) ORDER BY cohort_year, months_since_first;
-- 4 ties to source row count
SELECT (SELECT SUM(customers) FROM dash_cohort) AS agg_rows, (SELECT COUNT(*) FROM customer_month) AS src_rows;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_cohort.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_cohort.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 min_yr=2019, max_yr=2020, dup_keys=0; check 2 both years exactly 100.00 at month 0; check 3 2019 curve settling 26-28 pct, 2020 curve around 20-24 pct (matches the acceptance reference); check 4 agg_rows equals src_rows exactly.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_cohort.sql scripts/pos_perf/verify_dash_cohort.sql
git commit -m "feat(pos-perf): dash_cohort aggregate for the Retention and Churn console"
```

---

### Task 3: Shared churn input controls

**Files:**
- Create: `scripts/pos_perf/churn_controls.ps1`

**Interfaces:**
- Consumes: `dash_churn` (region, loyalty_tier, risk_band, score_date columns) from Task 1. Reuses the existing `/reports/pos_perf/controls/p_regions` control from Phase 1/Phase 0 (same `Ontario|Western|Quebec|Atlantic` vocabulary -- do not create a duplicate region control).
- Produces: four JRS input controls at `/reports/pos_perf/controls/chn_score_date`, `chn_tier`, `chn_band` (new, type-3 multi-select LOV Collection params, following the `p_regions`/`p_franchisee` pattern from Phase 1's `jrs_controls.ps1`), plus reuse of the existing `p_regions`. A `Attach-Controls` function (same shape as Phase 1's, importable via dot-source) that Task 4 calls to attach `[chn_score_date, p_regions, chn_tier, chn_band]` to each `chn_*` report unit.

- [ ] **Step 1: Read the Phase 1 controls helper for the exact pattern**

Read `scripts/pos_perf/jrs_controls.ps1` in full before writing this file -- it defines `New-FinanceControls` (creates LOV + query resources + input control resources) and `Attach-Controls` (PUTs an ordered `inputControls` array onto a report unit, `-Force` to replace, GET-verify after). Reuse its helper functions (`Test-JrsExists`, the JSON body builders) rather than reimplementing them; only the SQL/label/URI specifics differ for the churn controls.

- [ ] **Step 2: Write `churn_controls.ps1`** with a `New-ChurnControls` function creating three input controls (Collection type, query-based LOV, `alwaysPromptControls: false`, `controlsLayout: popupScreen` per the dashboard-level filter-strip convention from Phase 1 Task 2/6):

```
chn_score_date: label "Score date", query "SELECT DISTINCT VARCHAR(score_date) AS ds, VARCHAR(score_date) AS dsv FROM dash_churn ORDER BY 1" (single value 2020-12-31 today -- the control still works correctly when the churn model is re-run with a later cutoff and dash_churn is rebuilt, since it derives from the live table)
chn_tier: label "Loyalty tier", query "SELECT DISTINCT loyalty_tier AS lt, loyalty_tier AS ltv FROM dash_churn ORDER BY 1"
chn_band: label "Risk band", query "SELECT DISTINCT risk_band AS rb, risk_band AS rbv FROM dash_churn WHERE risk_band IN ('Critical','High','Watch','Low') ORDER BY DECODE(risk_band, 'Critical', 1, 'High', 2, 'Watch', 3, 'Low', 4)"
```

Follow `New-FinanceControls`'s exact resource-creation sequence (query resource, then LOV data type resource referencing it, then input control resource referencing the LOV) and its idempotency guard (`Test-JrsExists` before create, skip-with-warning if present, per the Phase 1 fix-round-1 hardening). Include an `Attach-ChurnControls -ReportUri <uri>` wrapper that calls the shared `Attach-Controls` with the fixed list `@("/reports/pos_perf/controls/chn_score_date", "/reports/pos_perf/controls/p_regions", "/reports/pos_perf/controls/chn_tier", "/reports/pos_perf/controls/chn_band")`.

- [ ] **Step 3: Run and verify**

```powershell
$env:JRS_ENV = "stage"
. .\scripts\pos_perf\churn_controls.ps1
New-ChurnControls
```

Expected: three `OK: created` lines (or `SKIP: exists` on a rerun), no errors. GET each control URI and confirm `dataType.type` is `multiSelectQuery` (Collection) and the query resource returns the expected distinct values (chn_tier: Bronze/Silver/Gold/Platinum; chn_band: Critical/High/Watch/Low in that risk order; chn_score_date: one row, 2020-12-31).

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/churn_controls.ps1
git commit -m "feat(pos-perf): shared churn input controls (score date, tier, band)"
```

---

### Task 4: Dashboard 6 - Retention and Churn (console, STAGE)

**Files:**
- Create: `report/pos_perf/chn_kpi.jrxml`
- Create: `report/pos_perf/chn_bands.jrxml`
- Create: `report/pos_perf/chn_ltv_band.jrxml`
- Create: `report/pos_perf/chn_drivers.jrxml`
- Create: `report/pos_perf/chn_cohorts.jrxml`
- Create: `report/pos_perf/chn_actions.jrxml`
- Create: `report/pos_perf/chn_dashboard.json`

**Interfaces:**
- Consumes: `dash_churn` (Task 1), `dash_cohort` (Task 2), the four churn input controls (Task 3). Parameter block on every tile except `chn_cohorts` (which has no per-customer filters, only score date is meaningful and cohort curves are lifetime by design -- matches how Phase 1's `trs_liability`/`trs_lease_expiry` legitimately ignored some filters): `p_score_date STRING default "2020-12-31"`, `p_regions COLLECTION` (java.util.Collection of String), `p_tiers COLLECTION`, `p_bands COLLECTION`. Guard every WHERE clause with the Phase 1 `$X{IN, ...}` idiom so a null/empty Collection is a no-op filter (see `trs_kpi.jrxml` for the exact syntax).
- Produces: dashboard `/reports/pos_perf/pos_retention_churn` label "POS Retention and Churn"; `chn_actions` rows hyperlink to `/reports/pos_perf/rpt_churn_action_list` (Task 5) passing `p_region="All"` and `p_score_date=$P{p_score_date}` (same fixed-scope drill convention Phase 1 used for `trs_tax_province` -> `rpt_tax_remittance`; the report is a workable action list, not per-action-row scoped).

- [ ] **Step 1: chn_kpi (1600x130, filter params).** Five cells at x = 10, 326, 642, 958, 1274 (width 300, dividers `#D6E0EF` at x=316/632/948/1264, same layout as `pnl_kpi_strip`/`trs_kpi`). Query:

```sql
SELECT COUNT(*) AS scored_customers,
       DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN risk_band IN ('Critical', 'High') THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS critical_high_pct,
       DECIMAL(SUM(CASE WHEN risk_band IN ('Critical', 'High') THEN expected_ltv_at_risk ELSE 0 END), 14, 2) AS ltv_at_risk,
       DECIMAL(100.0 * FLOAT8(COUNT(CASE WHEN overdue_ratio > 1 THEN 1 END)) / FLOAT8(NULLIF(COUNT(*), 0)), 6, 2) AS pct_overdue,
       DECIMAL(AVG(churn_probability), 6, 4) AS avg_churn_prob
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND ($X{IN, region, p_regions})
  AND ($X{IN, loyalty_tier, p_tiers})
  AND ($X{IN, risk_band, p_bands})
```

Fields: `scored_customers` Long; `ltv_at_risk` BigDecimal `pattern="$#,##0"`; `critical_high_pct`, `pct_overdue` BigDecimal `pattern="#,##0.0'%'"`; `avg_churn_prob` BigDecimal `pattern="#,##0.000"`. Labels: "Scored Customers", "Critical + High Risk", "LTV at Risk", "Overdue vs Expected", "Avg Churn Probability". Expected at defaults (no filters): 3,184,743 / 66.9% / $20,807,163 / 32.5% / 0.524.

- [ ] **Step 2: chn_bands (600x420, filter params).** Horizontal bar chart, customers by risk band sorted worst-first (Critical top). Query:

```sql
SELECT risk_band,
       CASE risk_band WHEN 'Critical' THEN 1 WHEN 'High' THEN 2 WHEN 'Watch' THEN 3 ELSE 4 END AS band_order,
       COUNT(*) AS customers
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND ($X{IN, region, p_regions})
  AND ($X{IN, loyalty_tier, p_tiers})
  AND ($X{IN, risk_band, p_bands})
GROUP BY risk_band
ORDER BY band_order
```

Chart in the `title` band, `evaluationTime="Report"`, `chartType="bar"`, `orientation="Horizontal"`, `<dataset kind="category">` grouped by `risk_band` ordered by the query's own ORDER BY (JR7 preserves row order in a category dataset unless a comparator overrides it). `<plot><seriesColor order="0" color="#D9534F"/></plot>` (single series -- band-count bars use the unfavourable red since every band here represents at-risk customers; Critical/High get the visual weight by being tallest, not by colour, since it is one series). Title "Customers by Risk Band", subtitle "Score date $P{p_score_date}".

- [ ] **Step 3: chn_ltv_band (600x420, filter params).** Horizontal bars, LTV at risk summed by band, same ordering as Step 2. Query:

```sql
SELECT risk_band,
       CASE risk_band WHEN 'Critical' THEN 1 WHEN 'High' THEN 2 WHEN 'Watch' THEN 3 ELSE 4 END AS band_order,
       DECIMAL(SUM(expected_ltv_at_risk), 14, 2) AS ltv_at_risk
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND ($X{IN, region, p_regions})
  AND ($X{IN, loyalty_tier, p_tiers})
  AND ($X{IN, risk_band, p_bands})
GROUP BY risk_band
ORDER BY band_order
```

Same chart shape as Step 2, `<plot><seriesColor order="0" color="#0550DC"/></plot>` (brand blue -- this is a magnitude tile, not a favourable/unfavourable one). Title "LTV at Risk by Band", value axis `pattern="$#,##0"`.

- [ ] **Step 4: chn_drivers (600x420, filter params).** Horizontal bars, top `driver_1` values among Critical-band customers only (fixed to Critical regardless of `p_bands`, per the spec's literal "top driver_1 values among Critical" -- the tile answers one specific question, it does not become a general driver browser). Query:

```sql
SELECT driver_1,
       COUNT(*) AS n
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND risk_band = 'Critical'
  AND ($X{IN, region, p_regions})
  AND ($X{IN, loyalty_tier, p_tiers})
GROUP BY driver_1
ORDER BY n DESC
```

Note: `p_bands` is deliberately NOT applied to this tile's WHERE (it always shows Critical) -- add a one-line comment in the JRXML header explaining this, so a future reader does not "fix" it into a bug. `<plot><seriesColor order="0" color="#0A4CAD"/></plot>`. Title "Top Churn Drivers (Critical)", subtitle "Among customers in the Critical band".

- [ ] **Step 5: chn_cohorts (1000x380, NO filter params -- lifetime by design).** Two-line chart, active share by months-since-first, one line per cohort year. Query:

```sql
SELECT cohort_year, months_since_first, active_pct
FROM dash_cohort
WHERE months_since_first BETWEEN 0 AND 18
ORDER BY cohort_year, months_since_first
```

`<dataset kind="category">` with `cohort_year` as the series field (two series: 2019, 2020) and `months_since_first` as the category. `chartType="line"`. `<plot><seriesColor order="0" color="#0550DC"/><seriesColor order="1" color="#1DB6C0"/></plot>`, both `showLines="true" showShapes="true"`. Title "Active Share by Months Since First Purchase", subtitle "2019 vs 2020 acquisition cohorts". Guard: this query cannot return a null `active_pct` (the `NULLIF` in Task 2's build already protects the divide, and every cell has at least one customer), so no zero-default guard is needed here -- document that reasoning in a header comment rather than adding a defensive guard nothing exercises.

- [ ] **Step 6: chn_actions (800x380, filter params).** List/crosstab-style table, recommended action x count x LTV, excluding `None` (an action row with no action is not actionable), each row hyperlinked to the Churn Action List report. Query:

```sql
SELECT recommended_action,
       COUNT(*) AS customers,
       DECIMAL(SUM(expected_ltv_at_risk), 14, 2) AS ltv_at_risk
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND recommended_action <> 'None'
  AND ($X{IN, region, p_regions})
  AND ($X{IN, loyalty_tier, p_tiers})
  AND ($X{IN, risk_band, p_bands})
GROUP BY recommended_action
ORDER BY ltv_at_risk DESC
```

Detail band with three columns (Action, Customers, LTV at Risk), header `#1F4E79` on white, zebra `#D6E0EF`, matching `pnl_worst_stores`'s list-tile pattern. Every row's Action cell carries a `<hyperlinkReference>` with `linkType="ReportExecution" linkTarget="Blank"`, flattened `<hyperlinkParameter>` form (as in `pnl_worst_stores.jrxml`/`trs_ar_aging.jrxml`): `_report -> "/reports/pos_perf/rpt_churn_action_list"`, `p_region -> "All"` (literal string, not a parameter reference -- the drill always opens the full ranked list), `p_score_date -> $P{p_score_date}`. Title "Recommended Actions", subtitle "Customers and LTV at risk by action, ranked".

- [ ] **Step 7: Write `chn_dashboard.json`** following the exact `trs_dashboard.json` shape (filters key drives the composer-generated strip; y-coordinates are the spec mockup's y minus 3, per Global Constraints):

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_retention_churn",
  "label": "POS Retention and Churn",
  "filters": ["chn_score_date", "p_regions", "chn_tier", "chn_band"],
  "dashlets": [
    { "resource": "/reports/pos_perf/chn_kpi",     "label": "Key Metrics",           "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/chn_bands",     "label": "Risk Bands",           "showTitleBar": false, "x": 0,  "y": 4,  "width": 14, "height": 11 },
    { "resource": "/reports/pos_perf/chn_ltv_band",  "label": "LTV at Risk by Band",  "showTitleBar": false, "x": 14, "y": 4,  "width": 13, "height": 11 },
    { "resource": "/reports/pos_perf/chn_drivers",   "label": "Top Churn Drivers",    "showTitleBar": false, "x": 27, "y": 4,  "width": 13, "height": 11 },
    { "resource": "/reports/pos_perf/chn_cohorts",   "label": "Cohort Retention",     "showTitleBar": false, "x": 0,  "y": 15, "width": 21, "height": 10 },
    { "resource": "/reports/pos_perf/chn_actions",   "label": "Recommended Actions",  "showTitleBar": false, "x": 21, "y": 15, "width": 19, "height": 10 }
  ]
}
```

- [ ] **Step 8: Lint, deploy, attach controls, verify, compose**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\churn_controls.ps1
foreach ($t in "chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_actions") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$t.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$t.jrxml" -TargetUri "/reports/pos_perf/$t" -Label $t -DataSourceUri /datasources/pos_data_avalanche -Overwrite
  Attach-ChurnControls -ReportUri "/reports/pos_perf/$t"
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$t" -Format pdf -OutFile "out\pos_perf\$t.pdf"
}
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\chn_cohorts.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_cohorts.jrxml -TargetUri /reports/pos_perf/chn_cohorts -Label chn_cohorts -DataSourceUri /datasources/pos_data_avalanche -Overwrite
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/chn_cohorts -Format pdf -OutFile out\pos_perf\chn_cohorts.pdf
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\chn_dashboard.json -AutoGrid
```

Note: `chn_cohorts` takes NO controls (Step 5), so it is deployed separately without `Attach-ChurnControls`. GET-verify each of the five filtered tiles carries all four controls after attach, before composing. Expected: six PDFs render; KPI strip matches the Step 1 defaults; bands chart shows Critical tallest; recompose reports 6 dashlets.

- [ ] **Step 9: Commit**

```powershell
git add report/pos_perf/chn_kpi.jrxml report/pos_perf/chn_bands.jrxml report/pos_perf/chn_ltv_band.jrxml report/pos_perf/chn_drivers.jrxml report/pos_perf/chn_cohorts.jrxml report/pos_perf/chn_actions.jrxml report/pos_perf/chn_dashboard.json
git commit -m "feat(pos-perf): Retention and Churn console (STAGE)"
```

---

### Task 5: Report - Churn Action List (drill target)

**Files:**
- Create: `report/pos_perf/rpt_churn_action_list.jrxml`

**Interfaces:**
- Consumes: `dash_churn` (Task 1). Drilled from `chn_actions` (Task 4) with `p_region="All"`, `p_score_date=$P{p_score_date}`.
- Produces: report unit `/reports/pos_perf/rpt_churn_action_list`, parameters `p_region STRING default "All"`, `p_score_date STRING default "2020-12-31"`. No further tasks depend on it.

- [ ] **Step 1: Write the report.** A4 landscape (842x595 rotated, `pageWidth="1000" pageHeight="700"` -- wider than standard A4 landscape to fit the driver/action columns without truncation, margins 30), logo top-left, centered title "Churn Action List", subtitle "$P{p_region}, score date $P{p_score_date}". Query, capped and ranked (spec says "High + Critical customers" with no further scope -- unranked that is 2,131,503 rows, so cap to a workable list, same precedent as Phase 1's AP payment-run roll-up):

```sql
SELECT customer_id, region, storenumber, risk_band,
       DECIMAL(expected_ltv_at_risk, 12, 2) AS ltv_at_risk,
       DECIMAL(churn_probability, 6, 4) AS churn_probability,
       driver_1, driver_2,
       recommended_action,
       expected_next_purchase
FROM dash_churn
WHERE score_date = DATE($P{p_score_date})
  AND risk_band IN ('Critical', 'High')
  AND recommended_action <> 'None'
  AND ('All' = $P{p_region} OR region = $P{p_region})
ORDER BY expected_ltv_at_risk DESC
FIRST 500
```

Columns: Store | Region | Risk | LTV at Risk | Churn Prob. | Top Driver | Second Driver | Recommended Action | Expected Next Purchase. Header `#1F4E79` on white, zebra `#D6E0EF` (matches `rpt_ar_aging`/`rpt_ap_aging`). Risk column cell: red `#D9534F` bold when `risk_band = 'Critical'`, plain `#1F4E79` when `High` (two overlapping textFields with `printWhenExpression`, the Phase 1 `rpt_store_pnl_statement` pattern for conditional colour on a String field). Footer/subtitle line making the cap explicit: `"Top 500 of " + <total count via a summary variable> + " High and Critical customers by LTV at risk"` -- add a summary query variable or a second lightweight query (`SELECT COUNT(*) FROM dash_churn WHERE ...` same predicate, no `FIRST`) bound as an independent dataset for that one number, so the disclosure is truthful even though the detail band is capped. `whenNoDataType="AllSectionsNoDetail"` (Phase 1 final-review finding -- bake this in from the start rather than adding it in a fix round).

- [ ] **Step 2: Deploy and verify**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_churn_action_list.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_churn_action_list.jrxml -TargetUri /reports/pos_perf/rpt_churn_action_list -Label "Churn Action List" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_churn_action_list -Format pdf -OutFile out\pos_perf\rpt_churn_action_list.pdf
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_churn_action_list -Format pdf -OutFile out\pos_perf\rpt_churn_action_list_quebec.pdf -Parameters "p_region=Quebec"
```

Expected: default run shows exactly 500 detail rows, sorted descending by LTV at risk, top row's LTV matching a manual `SELECT MAX(expected_ltv_at_risk) FROM dash_churn WHERE risk_band IN ('Critical','High')` check; Quebec-filtered run shows fewer rows, all region = Quebec; zero-row check (a region/score-date combination outside the model's coverage, e.g. p_score_date far outside 2020-12-31) renders headers not a blank page.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/rpt_churn_action_list.jrxml
git commit -m "feat(pos-perf): Churn Action List report (drill target)"
```

---

### Task 6: STAGE acceptance, docs, PROD go/no-go (deferred)

**Files:**
- Modify: `README.md` (extend the "POS performance dashboards" section)
- Modify: `RUNBOOK.md` (extend section 12 with the Phase 2 rebuild/redeploy/recompose recipe and PROD block)
- Modify: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-perf-dashboards.md`

**Interfaces:**
- Consumes: everything built in Tasks 1-5, all live on STAGE.
- Produces: docs a human can run the browser checks and the eventual PROD promotion from; nothing further depends on this task.

- [ ] **Step 1: Render every new unit at defaults and reconcile.** `chn_kpi`, `chn_bands`, `chn_ltv_band`, `chn_drivers`, `chn_cohorts`, `chn_actions`, `rpt_churn_action_list` -- 7 units. Re-verify STAGE bytes match the committed jrxml (export each report unit's jrxml and diff against git, same check Phase 1's Task 11 ran) and that `pos_retention_churn` composes with all 6 dashlets.

- [ ] **Step 2: Write the manual browser checklist addition** in `RUNBOOK.md` section 12 (append to the existing "Checks that need a human with a browser" list): filter-strip Apply on `pos_retention_churn` (fallback: flip `chn_dashboard.json` `"filters"` removal + per-dashlet `dashletFilterShowPopup: true` + recompose, same fallback pattern as Phase 1); the `chn_actions` -> Churn Action List drill click-test; a visual check that `chn_drivers`' subtitle ("Among customers in the Critical band") reads correctly next to the dashboard's own band filter (the tile intentionally ignores `p_bands` -- confirm this does not read as broken to a viewer).

- [ ] **Step 3: Write the RUNBOOK PROD block** (deferred, user-run, following the exact Phase 1 section-12 shape): rebuild `dash_churn`/`dash_cohort` against PROD's warehouse connection if it differs, deploy the 6 `chn_*` jrxml + `rpt_churn_action_list.jrxml` with `-Env prod`, re-attach the four churn controls (create them on PROD first via `New-ChurnControls` if the PROD JRS instance does not share the STAGE controls folder), recompose `pos_retention_churn`. Note explicitly that `p_regions` is shared with the already-promoted Ops Console / Treasury controls -- do not recreate it.

- [ ] **Step 4: Update the memory file.** Append a "## Phase 2 (customers) executed <date>" section to `pos-perf-dashboards.md` with the dashboard URI, manifest path, the two new aggregates, the acceptance figures from Task 1/2's verify scripts, and the outstanding browser checks -- same shape as the Phase 1 update already in that file.

- [ ] **Step 5: Commit**

```powershell
git add README.md RUNBOOK.md
git commit -m "docs(pos-perf): Phase 2 acceptance, runbook, and memory updates"
```
