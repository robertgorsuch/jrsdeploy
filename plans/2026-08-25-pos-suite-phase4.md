# POS Dashboard Suite - Phase 4 (Growth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy to STAGE the Store Network map cockpit (dashboard 9), the Marketing and Digital cockpit (dashboard 10), and the Franchisee Fee Statement report, fed by two new aggregates (`dash_email`, `dash_ecom_monthly`) plus tables that already exist and reconcile. This is the last phase in the suite roadmap; the Retention Story deck is explicitly OUT of scope for this plan (user decision, 2026-08-25 -- the spec lists it as optional "if wanted" and the user chose to leave it out and ship exactly the required growth scope).

**Architecture:** Two new small aggregates read `email_engagement` (1,770,334 rows) and `ecommerce_orders` (261,177 rows), both of which already join cleanly to their dimension tables (verified this session: every `email_engagement` row joins to `marketing_campaigns`; every `stores` row joins to `fsa_demographics` on `postal_fsa = fsa`). Dashboard 9 is a Map-led Cockpit (no filter strip, one FusionMaps/JRMap anchor tile, matching the archetype's "no filters, one anchor visual" definition); dashboard 10 is a Cockpit (no filter strip, matching `lab_dashboard.json`'s precedent). The Franchisee Fee Statement is a Statement-pattern report (single-entity ledger, matching `rpt_store_pnl_statement`'s shape) reading `franchise_fee_ledger` directly -- no new aggregate, 7,706 rows is well under the "no tile scans a 100K+ row table" threshold that motivates precomputed aggregates elsewhere in this suite.

**Tech Stack:** Actian Avalanche X100 (Ingres JDBC, `av-flm7ykoxlcvq`, schema `robert.gorsuch`), JasperReports Server 10.0.0 Pro (STAGE `http://localhost:8081/jasperserver-pro`), PowerShell 5.1, jasper-deploy skill, admiral skill.

**Spec:** `specs/2026-08-23-pos-suite-design.md` (dashboards 9 and 10, and the Franchisee Fee Statement report -- the "Phase 4 Growth" row of the phasing table). The Retention Story deck mentioned in the same spec row is deliberately not built by this plan.

## Global Constraints

- Repo is PUBLIC. No credentials, hostnames-with-passwords, or API keys in any committed file. JRS creds from `.claude/skills/jasper-deploy/jrs.config.json` (gitignored); warehouse creds from `.claude/skills/admiral/admiral.config.json`. The tracked mirror of any `.claude/skills/jasper-deploy/...` reference file is `plugins/jasper-deploy/skills/jasper-deploy/...`; edit the tracked path, not the symlink.
- Environment selection: `$env:JRS_ENV = "stage"` before any `$jd` script. **Never run a `$jd` script against `prod` in this plan.** PROD promotion is a separate go/no-go the user runs later (RUNBOOK.md pattern established for Phases 1-3); the last task documents the block, nobody executes it.
- Warehouse calls: `& "$adm\sql.ps1" -Action run-file -SqlFile <file> -ResourceId av-flm7ykoxlcvq`. `run-file` splits on EVERY `;` and tracks `'`/`"` state with no comment awareness: **no `;`, `'`, or `"` inside any SQL comment**. Wrap every ratio in `FLOAT8(...)`. Use `FIRST n`, not `LIMIT`. Views: `DROP VIEW IF EXISTS`; tables: `DROP TABLE IF EXISTS ... ; CREATE TABLE ... AS SELECT ...; CREATE STATISTICS FOR <table>;`.
- Confirmed X100/JR7 gotchas from Phases 1-3 (all durably referenced in `RUNBOOK.md`): arithmetic directly on an `ANSIDATE` column throws `Rewriter error` (use `EXTRACT(YEAR FROM ...)` / join to `date_dim` instead); a literal `--` inside a JRXML `<!-- -->` comment passes `lint_jrxml.ps1` but fails at deploy/compile with an opaque error -- grep every comment for a double hyphen before writing SQL descriptions or header comments; `COUNT(DISTINCT col)` inside a derived table that also uses `FIRST n` throws `Rewriter error` (split into separate steps); a `WITH` clause used as a derived table inside a `FROM` clause fails with `Table 'with' does not exist` even though a top-level `WITH ... SELECT` statement works fine (use nested nested derived-table subqueries instead of a nested CTE); the JR7 design validator caps `title.height + pageHeader.height + columnHeader.height + columnFooter.height + pageFooter.height` at `pageHeight - topMargin - bottomMargin` -- `lint_jrxml.ps1` does not catch this, `compile_jrxml.ps1` does, with `JRValidationException: ... do not fit the page height`. **Always run `compile_jrxml.ps1` locally before `deploy_report.ps1`** -- it is faster than a server round trip and gives a precise error for both of the above XML-validity classes, whereas Pro FusionMaps components fail server-side only with an opaque `400 "JRXML.content is invalid"` (see Task 3).
- JRXML is JR7-native: `<query language="SQL">`, `<element kind="staticText|textField|line|rectangle|image|chart">`, `<text>`/`<expression>` children, `<element kind="chart" chartType="bar|stackedBar|line|area|pie|meter">` with `<dataset kind="category">` and `<plot><seriesColor order="n" color="#hex"/></plot>`. Charts in the `title` band need `evaluationTime="Report"`. The one exception this phase is `exec_map.jrxml`'s FusionMaps pattern, which is deliberately JR6 legacy `<jasperReport xmlns="...">` syntax with `<reportElement>`/`<queryString>`/`<field>` -- Pro map components have no JR7 terse form. Never mix JR6 legacy syntax into a JR7 file, and never introduce JR6 syntax into a file that does not already need it. `<seriesColor order="n">` binds by series REGISTRATION order -- a null value on the first row does not register, shifting/inverting colours. Guard every chart series with a zero default.
- Brand, light theme (both dashboards this phase are light Cockpits, no navy): Actian logo top-left (`"repo:/images/actian_logo"`, 44x44 at 0,0), title centered `forecolor="#1F4E79"` 16pt bold, subtitle `#5B7DA6` 9pt; KPI label `fontSize="13.0" forecolor="#5B7DA6"`, KPI value `fontSize="26.0" bold forecolor="#1F4E79"`, dividers `#D6E0EF`; table header `#1F4E79` on white, zebra `#D6E0EF`; series order `#0550DC`, `#1DB6C0`, `#0A4CAD`, `#239CA8`; favourable/unfavourable `#5CB85C` / `#D9534F`.
- No "Foodmart", "Wobby", datasource URIs, SQL, table or column names in user-visible text. Dashboard labels contain no `&` (compose does not XML-escape). Current-year rule does not apply: this data is dated 2019-2020 and the tiles say so.
- Dashboards: 40-unit grid, every dashlet `showTitleBar:false`. Both dashboard 9 and dashboard 10 are Cockpits: NO `"filters"` key in either manifest, no controls attached to any tile -- matches `pnl_dashboard.json` and `lab_dashboard.json`'s precedent exactly. Delete the dashboard (`teardown_dashboard.ps1 -Uri ...`) before every recompose. Dashboards cannot be run to PDF -- verify tiles individually.
- Page sizes by tile shape (pageWidth x pageHeight, margins 10 unless stated, 40px per grid unit horizontally): 40x4 KPI strip 1600x130; 22x17 map tile 880x680; 18x9 chart 720x360; 18x8 chart 720x320; 20x9 chart/list 800x360; 14x11 chart 560x440; 26x11 chart 1040x440; 20x11 chart/table 800x440.
- `deploy_report.ps1 -Overwrite` DROPS a report unit's attached inputControls -- re-attach and GET-verify after every redeploy. A tile already composed into a dashboard 403s `resource.in.use` on redeploy -- teardown the dashboard first, redeploy, recompose. Neither dashboard 9 nor 10 has attached controls, so there is nothing to re-attach for their tiles; the Franchisee Fee Statement report DOES take attached controls (Task 5) and needs the usual re-attach-and-verify after every redeploy.
- Acceptance references (from the queries run to ground this plan, warehouse state as of 2026-08-25): `email_engagement` 1,770,334 rows, 2019-01-01 to 2020-12-31, every row joins to `marketing_campaigns` on `campaign_id` (0 orphans); lifetime rates open 37.65 pct, click 12.10 pct, convert 4.71 pct. `ecommerce_orders` 261,177 rows, 2019-01-01 to 2020-12-31; channel Delivery 87,026 / Pickup 174,151; `delivery_partner` is blank on every Pickup row and one of `SnowRoute Express` (29,215) / `Maple Courier Co` (29,205) / `UrbanSled Delivery` (28,606) on every Delivery row; avg `satisfaction_score` 3.87 on both channels; `fulfilled_late = 'Y'` rate about 6.84-6.85 pct on both channels. `franchise_fee_ledger` 7,706 rows, 169 distinct `franchisee_id`, `yyyymm` 201901-202012; `status` Paid 7,134 rows / \$0.00 balance, Open 317 rows / \$3,761,263.58, Overdue 255 rows / \$1,637,866.53; `franchisee_id = 0` is `owner_name = 'Stella Martin'`. `store_assets` 330 rows, `lease_expiry` spans 2023-12-31 to 2030-11-04 (by year: 2023 x4, 2024 x169, 2028 x154, 2029 x2, 2030 x1). `competitor_locations` 679 rows; 26 distinct `storenumber` values have 2 or more competitors within `distance_km <= 2`. `stores` joins 330/330 to `fsa_demographics` on `postal_fsa = fsa` (clean, no orphans). Lifetime sales-per-square-foot by `store_format` (from `stores.total_sales / stores.square_feet`): Standalone 1187.56, Shopping Mall 1078.18, Strip Plaza 1172.12, Urban Storefront 1195.88.
- Categorical values used in SQL: `channel` (ecommerce_orders) = `Delivery` | `Pickup`; `delivery_partner` = `SnowRoute Express` | `Maple Courier Co` | `UrbanSled Delivery` | blank (Pickup orders only -- coalesce to the literal string `'Pickup'` in `dash_ecom_monthly` so the dimension has no blank/NULL member); `status` (franchise_fee_ledger) = `Paid` | `Open` | `Overdue`; `store_format` = `Standalone` | `Strip Plaza` | `Urban Storefront` | `Shopping Mall`; `region` = `Ontario` | `Western` | `Quebec` | `Atlantic`. `date_dim` provides `calendar_date`, `yyyymm`, `yr`, `mo` -- join on `calendar_date` for any daily-grain table needing calendar attributes (not needed by this phase's own SQL, but `email_engagement.send_date` and `ecommerce_orders.order_date` are both plain SQL dates, not the `pos_sales_detail` VARCHAR-date trap from earlier phases, so no `date_dim` join is required for either new aggregate).

---

### Task 1: dash_email aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_email.sql`
- Create: `scripts/pos_perf/verify_dash_email.sql`

**Interfaces:**
- Consumes: `email_engagement` (campaign_id, customer_id, send_date, opened_flag, clicked_flag, converted_flag); `marketing_campaigns` (campaign_id, campaign_name) for a readable label.
- Produces: table `dash_email(campaign_id INTEGER, campaign_name VARCHAR(100), send_yyyymm INTEGER, sent INTEGER, opened INTEGER, clicked INTEGER, converted INTEGER)`, one row per (campaign_id, send month). Task 4 (mkt_funnel, mkt_kpi) reads it.

- [ ] **Step 1: Write the build script**

```sql
-- dash_email: email_engagement rolled to campaign x send-month, with the
-- campaign name carried for a readable tile label. Every row already joins
-- cleanly to marketing_campaigns (verified 2026-08-25, 0 orphans), so this
-- is a plain inner join, not a left join with a fallback label.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_email;
CREATE TABLE dash_email AS
SELECT e.campaign_id, m.campaign_name,
       EXTRACT(YEAR FROM e.send_date) * 100 + EXTRACT(MONTH FROM e.send_date) AS send_yyyymm,
       COUNT(*) AS sent,
       COUNT(CASE WHEN e.opened_flag = 'Y' THEN 1 END) AS opened,
       COUNT(CASE WHEN e.clicked_flag = 'Y' THEN 1 END) AS clicked,
       COUNT(CASE WHEN e.converted_flag = 'Y' THEN 1 END) AS converted
FROM email_engagement e
JOIN marketing_campaigns m ON m.campaign_id = e.campaign_id
GROUP BY e.campaign_id, m.campaign_name, EXTRACT(YEAR FROM e.send_date) * 100 + EXTRACT(MONTH FROM e.send_date);
CREATE STATISTICS FOR dash_email;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_email
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 row count and grain, expect 0 dup keys
SELECT COUNT(*) AS rows_,
       (SELECT COUNT(*) FROM (SELECT campaign_id, send_yyyymm FROM dash_email GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_email;
-- 2 ties to source exactly, expect sent 1770334
SELECT (SELECT SUM(sent) FROM dash_email) AS agg_sent, (SELECT COUNT(*) FROM email_engagement) AS src_sent;
-- 3 network lifetime rates, expect open 37.65 click 12.10 convert 4.71 (pct)
SELECT DECIMAL(100.0 * FLOAT8(SUM(opened)) / FLOAT8(SUM(sent)), 6, 2) AS open_pct,
       DECIMAL(100.0 * FLOAT8(SUM(clicked)) / FLOAT8(SUM(sent)), 6, 2) AS click_pct,
       DECIMAL(100.0 * FLOAT8(SUM(converted)) / FLOAT8(SUM(sent)), 6, 2) AS convert_pct
FROM dash_email;
-- 4 no NULL campaign_name, expect 0
SELECT COUNT(*) AS null_names FROM dash_email WHERE campaign_name IS NULL;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_email.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_email.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 dup_keys=0; check 2 agg_sent = src_sent = 1770334 exactly; check 3 open_pct 37.65, click_pct 12.10, convert_pct 4.71; check 4 null_names=0.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_email.sql scripts/pos_perf/verify_dash_email.sql
git commit -m "feat(pos-perf): dash_email aggregate for the Marketing and Digital cockpit"
```

---

### Task 2: dash_ecom_monthly aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_ecom_monthly.sql`
- Create: `scripts/pos_perf/verify_dash_ecom_monthly.sql`

**Interfaces:**
- Consumes: `ecommerce_orders` (order_id, order_date, channel, delivery_partner, order_value, fulfilled_late, satisfaction_score).
- Produces: table `dash_ecom_monthly(yyyymm INTEGER, delivery_partner VARCHAR(20), orders INTEGER, order_value DECIMAL(14,2), late_orders INTEGER, avg_satisfaction DECIMAL(6,2))`, one row per (month, delivery_partner), `delivery_partner` coalesced to the literal `'Pickup'` for every Pickup-channel row so the dimension has no blank member. Task 4 (mkt_kpi, mkt_ecom_share, mkt_partners) reads it.

- [ ] **Step 1: Write the build script**

```sql
-- dash_ecom_monthly: ecommerce_orders rolled to month x delivery_partner.
-- delivery_partner is blank on every Pickup-channel row (confirmed
-- 2026-08-25) -- coalesced to the literal Pickup here so mkt_ecom_share can
-- sum across the whole dimension with no blank/NULL member, while
-- mkt_partners (delivery-specific) filters delivery_partner <> Pickup.
-- NOTE: sql.ps1 run-file splits on EVERY semicolon, even inside comments --
-- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_ecom_monthly;
CREATE TABLE dash_ecom_monthly AS
SELECT EXTRACT(YEAR FROM order_date) * 100 + EXTRACT(MONTH FROM order_date) AS yyyymm,
       CASE WHEN TRIM(delivery_partner) = '' OR delivery_partner IS NULL THEN 'Pickup' ELSE delivery_partner END AS delivery_partner,
       COUNT(*) AS orders,
       DECIMAL(SUM(order_value), 14, 2) AS order_value,
       COUNT(CASE WHEN fulfilled_late = 'Y' THEN 1 END) AS late_orders,
       DECIMAL(AVG(satisfaction_score), 6, 2) AS avg_satisfaction
FROM ecommerce_orders
GROUP BY EXTRACT(YEAR FROM order_date) * 100 + EXTRACT(MONTH FROM order_date),
         CASE WHEN TRIM(delivery_partner) = '' OR delivery_partner IS NULL THEN 'Pickup' ELSE delivery_partner END;
CREATE STATISTICS FOR dash_ecom_monthly;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_ecom_monthly
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 row count and grain, expect 0 dup keys, 4 distinct delivery_partner values
SELECT COUNT(*) AS rows_,
       (SELECT COUNT(*) FROM (SELECT yyyymm, delivery_partner FROM dash_ecom_monthly GROUP BY 1,2 HAVING COUNT(*) > 1) d) AS dup_keys,
       (SELECT COUNT(DISTINCT delivery_partner) FROM dash_ecom_monthly) AS n_partners
FROM dash_ecom_monthly;
-- 2 ties to source exactly, expect orders 261177
SELECT (SELECT SUM(orders) FROM dash_ecom_monthly) AS agg_orders, (SELECT COUNT(*) FROM ecommerce_orders) AS src_orders;
-- 3 Pickup bucket equals the blank-delivery_partner source rows, expect 174151
SELECT (SELECT SUM(orders) FROM dash_ecom_monthly WHERE delivery_partner = 'Pickup') AS agg_pickup,
       (SELECT COUNT(*) FROM ecommerce_orders WHERE TRIM(delivery_partner) = '' OR delivery_partner IS NULL) AS src_pickup;
-- 4 network avg satisfaction and late pct, expect about 3.87 and 6.8-6.9 pct
SELECT DECIMAL(SUM(avg_satisfaction * orders) / SUM(orders), 6, 2) AS wtd_avg_satisfaction,
       DECIMAL(100.0 * FLOAT8(SUM(late_orders)) / FLOAT8(SUM(orders)), 6, 2) AS late_pct
FROM dash_ecom_monthly;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_ecom_monthly.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_ecom_monthly.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 dup_keys=0, n_partners=4 (Pickup + 3 real partners); check 2 agg_orders = src_orders = 261177; check 3 agg_pickup = src_pickup = 174151; check 4 wtd_avg_satisfaction about 3.87, late_pct about 6.8-6.9.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_ecom_monthly.sql scripts/pos_perf/verify_dash_ecom_monthly.sql
git commit -m "feat(pos-perf): dash_ecom_monthly aggregate for the Marketing and Digital cockpit"
```

---

### Task 3: Dashboard 9 - Store Network (map-led cockpit, STAGE)

**Files:**
- Create: `report/pos_perf/net_map.jrxml`
- Create: `report/pos_perf/net_sqft_format.jrxml`
- Create: `report/pos_perf/net_income_scatter.jrxml`
- Create: `report/pos_perf/net_lease.jrxml`
- Create: `report/pos_perf/net_exposed.jrxml`
- Create: `report/pos_perf/net_dashboard.json`

**Interfaces:**
- Consumes: `stores` (storenumber, storename, latitude, longitude, square_feet, store_format, total_sales, postal_fsa); `competitor_locations` (storenumber, distance_km); `fsa_demographics` (fsa, median_income); `store_assets` (storenumber, lease_expiry). No parameters on any tile (Cockpit archetype, no filter strip, matching `lab_dashboard.json`'s precedent).
- Produces: dashboard `/reports/pos_perf/pos_store_network` label "POS Store Network". No drill targets (the spec lists none for dashboard 9's tiles).

- [ ] **Step 1: net_map (880x680, no parameters).** **Discovery task -- resolve empirically, do not assume; budget at most two redeploy cycles before settling on whichever technique actually renders store markers, matching the waterfall/heatmap precedent from Phases 1 and 3.**

  Try, in order:
  1. **Primary: the community `jr:map` component** (`xmlns:jr="http://jasperreports.sourceforge.net/jasperreports/components"`, `<jr:map>` with `<jr:mapOptions>` + a `<jr:markerDataset>`/`<jr:marker>` per store using REAL `latitude`/`longitude` from `stores` -- not the Pro `fm:map` used by `exec_map.jrxml`, which is a province choropleth keyed to FusionMaps' own "Canada" entity ids, not a lat/long point-marker surface). This is a JR7-native, **locally compilable** community component (no Pro-only `400 "JRXML.content is invalid"` risk -- `compile_jrxml.ps1` will give a precise Jackson error if a property name is wrong, per the debugging strategy in `plugins/jasper-deploy/skills/jasper-deploy/references/fusion-pro-gotchas.md`), which is why it is the first thing to try rather than extending `exec_map.jrxml`'s Pro `fm:map` (whose `<c:markerData/>` child element is present in that file only as an unpopulated placeholder -- nothing in this repo has ever exercised it, and FusionMaps markers are normally calibrated to percentage x/y positions on the specific map image, not raw lat/long, which is a worse fit for 330 real store coordinates).
  2. **Fallback if `jr:map` does not render acceptably in the viewer or in PDF export** (check both, per the spec's HTML5/Pro verification rule): a JFreeChart `chartType="xyScatter"` plotting `longitude` on x and `latitude` on y, bubble size from `sales_per_sqft`, colour split by the 2km-competitor-ring flag -- loses the basemap but keeps every data dimension the spec asks for (store markers sized by sales per sq ft, a visual break-out for 2+ competitors within 2km).
  3. **Final fallback:** a ranked table (store, region, sales_per_sqft, competitors_2km), matching `sup_scorecard.jrxml`'s table styling -- loses the geographic read entirely; use only if both 1 and 2 fail to compile or render.

  Document whichever technique ships in the file's header comment, exactly matching the rigor of `pnl_waterfall.jrxml`'s and `lab_heatmap.jrxml`'s header comments (what was tried, why it did or did not work, what shipped).

  Query (same for all three techniques -- only the presentation element differs):

```sql
SELECT s.storenumber, s.storename, s.latitude, s.longitude, s.region,
       DECIMAL(FLOAT8(s.total_sales) / FLOAT8(NULLIF(s.square_feet, 0)), 10, 2) AS sales_per_sqft,
       (SELECT COUNT(*) FROM competitor_locations c WHERE c.storenumber = s.storenumber AND c.distance_km <= 2) AS competitors_2km
FROM stores s
```

  Fields: `storenumber` Integer, `storename`/`region` String, `latitude`/`longitude` BigDecimal, `sales_per_sqft` BigDecimal, `competitors_2km` Long (a bare `COUNT(*)` scalar subquery maps to `java.lang.Long` in this codebase's established convention -- see `chn_kpi.jrxml`'s `scored_customers` field). A marker/point qualifies for the "ring" treatment (spec: "ring when 2+ competitors within 2 km") when `competitors_2km >= 2` -- 26 of 330 stores qualify (verified 2026-08-25). Title "Store Network", subtitle "Marker size = sales per square foot; ringed markers have 2 or more competitors within 2 km".

- [ ] **Step 2: net_sqft_format (720x360, no parameters).** Horizontal bars, sales per sq ft by format, reading `stores` directly (no aggregate needed, matching the spec's direct-read list). Query:

```sql
SELECT store_format,
       DECIMAL(AVG(FLOAT8(total_sales) / FLOAT8(NULLIF(square_feet, 0))), 8, 2) AS sales_per_sqft
FROM stores
GROUP BY store_format
ORDER BY sales_per_sqft DESC
```

`<plot><seriesColor order="0" color="#0550DC"/></plot>`. Title "Sales per Square Foot by Format". Expected at defaults: Urban Storefront 1195.88 (highest), Standalone 1187.56, Strip Plaza 1172.12, Shopping Mall 1078.18 (lowest) -- verified 2026-08-25.

- [ ] **Step 3: net_income_scatter (720x320, no parameters).** `chartType="xyScatter"`, trade-area median income (x) vs store lifetime sales (y), one point per store. Query:

```sql
SELECT f.median_income, s.total_sales, s.storenumber
FROM stores s
JOIN fsa_demographics f ON f.fsa = s.postal_fsa
```

`<dataset kind="xy"><series><xValueExpression>$F{median_income}</xValueExpression><yValueExpression>$F{total_sales}</yValueExpression></series></dataset>`, single series, `<plot><seriesColor order="0" color="#1DB6C0"/></plot>`, `showLegend="false"`. All 330 stores match (verified 2026-08-25, 0 orphans on the `postal_fsa = fsa` join). Title "Trade-Area Income vs Store Sales", subtitle "Each point is one store".

- [ ] **Step 4: net_lease (800x360, no parameters).** Bars, store count by lease expiry year. Query:

```sql
SELECT EXTRACT(YEAR FROM lease_expiry) AS expiry_year, COUNT(*) AS stores
FROM store_assets
GROUP BY EXTRACT(YEAR FROM lease_expiry)
ORDER BY expiry_year
```

`<plot><seriesColor order="0" color="#0A4CAD"/></plot>`. Title "Lease Expiries by Year". Expected at defaults: 2023 x4, 2024 x169, 2028 x154, 2029 x2, 2030 x1 (verified 2026-08-25 -- 2024 and 2028 are the two years needing real attention, 2023 and 2029-2030 are edge cases).

- [ ] **Step 5: net_exposed (800x440, no parameters).** List/table, stores with 3+ competitors within 2km AND below their format's average sales per sq ft. Query (the format-average threshold is computed in the same query via a scalar correlated subquery per row, not a separate derived table, since `stores` has only 330 rows and this is a one-time render, not a hot path):

```sql
SELECT s.storenumber, s.storename, s.region, s.store_format,
       DECIMAL(FLOAT8(s.total_sales) / FLOAT8(NULLIF(s.square_feet, 0)), 8, 2) AS sales_per_sqft,
       (SELECT COUNT(*) FROM competitor_locations c WHERE c.storenumber = s.storenumber AND c.distance_km <= 2) AS competitors_2km
FROM stores s
WHERE (SELECT COUNT(*) FROM competitor_locations c WHERE c.storenumber = s.storenumber AND c.distance_km <= 2) >= 3
  AND FLOAT8(s.total_sales) / FLOAT8(NULLIF(s.square_feet, 0)) <
      (SELECT AVG(FLOAT8(s2.total_sales) / FLOAT8(NULLIF(s2.square_feet, 0))) FROM stores s2 WHERE s2.store_format = s.store_format)
ORDER BY competitors_2km DESC, sales_per_sqft ASC
```

Header `#1F4E79` on white, zebra `#D6E0EF` (matches `sup_scorecard.jrxml`). `whenNoDataType` is not applicable to a dashboard tile (only to standalone reports elsewhere in this suite) -- if the query returns zero rows, the tile renders an empty table, which is acceptable and correct (it would mean no store meets both exposure criteria). Title "Stores Needing a Decision", subtitle "3 or more competitors within 2 km and below-format sales per square foot".

- [ ] **Step 6: Write `net_dashboard.json`.** No `"filters"` key (Cockpit archetype):

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_store_network",
  "label": "POS Store Network",
  "dashlets": [
    { "resource": "/reports/pos_perf/net_map",            "label": "Store Network",             "showTitleBar": false, "x": 0,  "y": 0,  "width": 22, "height": 17 },
    { "resource": "/reports/pos_perf/net_sqft_format",     "label": "Sales per Sq Ft by Format",  "showTitleBar": false, "x": 22, "y": 0,  "width": 18, "height": 9 },
    { "resource": "/reports/pos_perf/net_income_scatter",  "label": "Income vs Store Sales",      "showTitleBar": false, "x": 22, "y": 9,  "width": 18, "height": 8 },
    { "resource": "/reports/pos_perf/net_lease",           "label": "Lease Expiries",             "showTitleBar": false, "x": 0,  "y": 17, "width": 20, "height": 9 },
    { "resource": "/reports/pos_perf/net_exposed",         "label": "Stores Needing a Decision",  "showTitleBar": false, "x": 20, "y": 17, "width": 20, "height": 9 }
  ]
}
```

- [ ] **Step 7: Lint, compile, deploy, verify, compose**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
foreach ($t in "net_map","net_sqft_format","net_income_scatter","net_lease","net_exposed") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$t.jrxml"
  & ".\plugins\jasper-deploy\skills\jasper-deploy\scripts\compile_jrxml.ps1" -Jrxml "report\pos_perf\$t.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$t.jrxml" -TargetUri "/reports/pos_perf/$t" -Label $t -DataSourceUri /datasources/pos_data_avalanche -Overwrite
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$t" -Format pdf -OutFile "out\pos_perf\$t.pdf"
}
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\net_dashboard.json -AutoGrid
```

`net_map` is Pro-component-uncertain (Step 1) or community-component (if `jr:map` ships) -- either way `compile_jrxml.ps1` catches XML-validity and community-component errors locally; a Pro `fm:map` variant (only if both other techniques fail) can ONLY be verified by the server deploy + run-to-PDF round trip, per the fusion-pro-gotchas debugging strategy. Expected: five PDFs render; net_sqft_format and net_lease match Step 2/4 defaults exactly; recompose reports 5 dashlets, no filter strip present.

- [ ] **Step 8: Commit**

```powershell
git add report/pos_perf/net_map.jrxml report/pos_perf/net_sqft_format.jrxml report/pos_perf/net_income_scatter.jrxml report/pos_perf/net_lease.jrxml report/pos_perf/net_exposed.jrxml report/pos_perf/net_dashboard.json
git commit -m "feat(pos-perf): Store Network cockpit (STAGE)"
```

---

### Task 4: Dashboard 10 - Marketing and Digital (cockpit, STAGE)

**Files:**
- Create: `report/pos_perf/mkt_kpi.jrxml`
- Create: `report/pos_perf/mkt_funnel.jrxml`
- Create: `report/pos_perf/mkt_ecom_share.jrxml`
- Create: `report/pos_perf/mkt_campaign_roi.jrxml`
- Create: `report/pos_perf/mkt_partners.jrxml`
- Create: `report/pos_perf/mkt_dashboard.json`

**Interfaces:**
- Consumes: `dash_email` (Task 1), `dash_ecom_monthly` (Task 2), `promotions`, `marketing_campaigns`, `store_pnl_monthly` (for net sales, the e-commerce-share denominator). No parameters on any tile (Cockpit archetype).
- Produces: dashboard `/reports/pos_perf/pos_marketing_digital` label "POS Marketing and Digital". `mkt_campaign_roi` rows hyperlink to `/reports/pos_perf/rpt_weekly_flash` (documented fixed-scope drill, see Step 4 -- it does NOT scope the target to the clicked campaign, matching the "fixed default, not a per-row filter" convention already used by `trs_tax_province -> rpt_tax_remittance` and `sup_scorecard -> rpt_supplier_scorecard`).

- [ ] **Step 1: mkt_kpi (1600x130, no parameters).** Five cells at x = 10, 326, 642, 958, 1274. Query:

```sql
SELECT DECIMAL(100.0 * FLOAT8((SELECT SUM(order_value) FROM dash_ecom_monthly)) / FLOAT8(NULLIF((SELECT SUM(net_sales) FROM store_pnl_monthly), 0)), 6, 2) AS ecom_share_pct,
       DECIMAL(100.0 * FLOAT8((SELECT SUM(late_orders) FROM dash_ecom_monthly)) / FLOAT8(NULLIF((SELECT SUM(orders) FROM dash_ecom_monthly), 0)), 6, 2) AS late_pct,
       DECIMAL(100.0 * FLOAT8((SELECT SUM(opened) FROM dash_email)) / FLOAT8(NULLIF((SELECT SUM(sent) FROM dash_email), 0)), 6, 2) AS open_pct,
       DECIMAL(100.0 * FLOAT8((SELECT SUM(clicked) FROM dash_email)) / FLOAT8(NULLIF((SELECT SUM(sent) FROM dash_email), 0)), 6, 2) AS click_pct,
       DECIMAL(FLOAT8((SELECT SUM(promo_margin) FROM promotions)) / FLOAT8(NULLIF((SELECT SUM(marketing_subsidy) FROM promotions), 0)), 8, 2) AS promo_roi
FROM (SELECT 1 AS x) dual
```

Fields: `ecom_share_pct`, `late_pct`, `open_pct`, `click_pct` BigDecimal `pattern="#,##0.0'%'"`; `promo_roi` BigDecimal `pattern="#,##0.00'x'"` (verified 2026-08-25: network `promo_roi` is 84.91 -- lifetime `promo_margin` \$99,159,330.53 over lifetime `marketing_subsidy` \$1,167,803.60 -- a ratio around 85, not a percent, so the `'x'` suffix reads as "85 dollars of margin per dollar of subsidy" rather than implying a percentage). Labels: "E-Commerce Share", "Late Fulfilment", "Email Open Rate", "Email Click Rate", "Promotion ROI".

- [ ] **Step 2: mkt_funnel (560x440, no parameters).** Horizontal bars, email funnel as pct of sent (sent is always 100 pct, shown as context, not as a bar). Query:

```sql
SELECT 'Opened' AS stage, DECIMAL(100.0 * FLOAT8(SUM(opened)) / FLOAT8(NULLIF(SUM(sent), 0)), 6, 2) AS pct_of_sent FROM dash_email
UNION ALL
SELECT 'Clicked', DECIMAL(100.0 * FLOAT8(SUM(clicked)) / FLOAT8(NULLIF(SUM(sent), 0)), 6, 2) FROM dash_email
UNION ALL
SELECT 'Converted', DECIMAL(100.0 * FLOAT8(SUM(converted)) / FLOAT8(NULLIF(SUM(sent), 0)), 6, 2) FROM dash_email
```

`<plot orientation="Horizontal"><seriesColor order="0" color="#0550DC"/></plot>`. Category order must render Opened/Clicked/Converted top-to-bottom in that funnel order, not alphabetically or by value -- if the chart's default category sort reorders them, add an explicit `sortOrder` field (e.g. a leading integer prefix stripped in the label expression) rather than accepting a scrambled funnel. Title "Email Funnel". Expected at defaults: Opened 37.65, Clicked 12.10, Converted 4.71 (verified 2026-08-25).

- [ ] **Step 3: mkt_ecom_share (1040x440, no parameters).** Area chart, e-commerce share of net sales by month. Query:

```sql
SELECT e.yyyymm,
       DECIMAL(100.0 * FLOAT8(SUM(e.order_value)) / FLOAT8(NULLIF((SELECT SUM(p.net_sales) FROM store_pnl_monthly p WHERE p.yyyymm = e.yyyymm), 0)), 6, 2) AS ecom_share_pct
FROM dash_ecom_monthly e
GROUP BY e.yyyymm
ORDER BY e.yyyymm
```

`chartType="area"`, `<plot><seriesColor order="0" color="#1DB6C0"/></plot>`. Title "E-Commerce Share of Net Sales, Monthly". If any month has `store_pnl_monthly` coverage gaps (a store opening mid-period), `NULLIF` already guards the zero-denominator case; a genuinely missing month simply does not appear in the chart (the `GROUP BY` is driven by `dash_ecom_monthly`, which spans the full 2019-01 to 2020-12 range per Task 2's acceptance check).

- [ ] **Step 4: mkt_campaign_roi (800x440, no parameters).** Horizontal bars, campaign ROI ranked, with a drill. Query:

```sql
SELECT campaign_name,
       DECIMAL(FLOAT8(promo_margin) / FLOAT8(NULLIF(marketing_subsidy, 0)), 8, 2) AS roi,
       DECIMAL(marketing_subsidy, 12, 2) AS subsidy,
       DECIMAL(FLOAT8(marketing_subsidy) / FLOAT8(NULLIF(total_transactions, 0)), 10, 2) AS subsidy_per_conversion
FROM promotions
WHERE marketing_subsidy > 0
ORDER BY roi DESC
FETCH FIRST 15 ROWS ONLY
```

`<plot orientation="Horizontal"><seriesColor order="0" color="#0A4CAD"/></plot>`. Bar label shows `subsidy_per_conversion` per the spec ("subsidy cost per conversion as label"). Title "Top Campaign ROI", subtitle "Top 15 of 104 promotions with subsidy spend, ranked by margin per dollar of subsidy" -- 104 of 115 `promotions` rows have `marketing_subsidy > 0` (verified 2026-08-25), so the cap is disclosed IN THE TILE, not silent, matching `rpt_inventory_reorder`'s own disclosure discipline in reverse (that report discloses it is deliberately uncapped; this tile discloses it is deliberately capped, and by how much).

  **Drill (documented fixed-scope deviation).** The spec says "drill to Campaign section of Weekly Flash," but `rpt_weekly_flash` (Task 7 of the Phase 3 plan) has no per-campaign parameter -- its only parameter is `p_week_ending`, and its page-2 campaign table lists every campaign active in that one week, not a single campaign. There is no way to scope the target to the clicked campaign without changing `rpt_weekly_flash`'s contract, which is out of scope for this task. Ship the drill as specified (jumps the reader to the Weekly Flash report, landing on its campaign section) but pass a FIXED `p_week_ending` -- the same literal default the report already uses (`"2020-11-08"`) -- rather than attempting to derive a per-campaign week that the target cannot use anyway. Each row's `campaign_name` cell carries a `<hyperlinkReference>` (flattened `<hyperlinkParameter>` form, matching every other cross-report drill in this suite) to `/reports/pos_perf/rpt_weekly_flash` passing `p_week_ending -> "2020-11-08"` (literal String). This is a real limitation, not a bug: note it in the file's header comment so a future reader does not "fix" it into a per-campaign filter that `rpt_weekly_flash` cannot honour.

- [ ] **Step 5: mkt_partners (800x440, no parameters).** Table, delivery partner late rate and satisfaction (Delivery-channel partners only -- excludes the `'Pickup'` bucket Task 2 coalesced in, since a pickup order has no delivery partner to score). Query:

```sql
SELECT delivery_partner,
       DECIMAL(SUM(orders), 10, 0) AS orders,
       DECIMAL(100.0 * FLOAT8(SUM(late_orders)) / FLOAT8(NULLIF(SUM(orders), 0)), 6, 2) AS late_pct,
       DECIMAL(SUM(avg_satisfaction * orders) / SUM(orders), 6, 2) AS avg_satisfaction
FROM dash_ecom_monthly
WHERE delivery_partner <> 'Pickup'
GROUP BY delivery_partner
ORDER BY late_pct ASC
```

Header `#1F4E79` on white, zebra `#D6E0EF`. Title "Delivery Partner Performance". Expected at defaults: 3 rows (SnowRoute Express, Maple Courier Co, UrbanSled Delivery), late pct and avg_satisfaction close to the network-wide 6.84 pct / 3.87 figures verified in Task 2 since delivery volume splits close to evenly across the three partners.

- [ ] **Step 6: Write `mkt_dashboard.json`.** No `"filters"` key:

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_marketing_digital",
  "label": "POS Marketing and Digital",
  "dashlets": [
    { "resource": "/reports/pos_perf/mkt_kpi",           "label": "Key Metrics",              "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/mkt_funnel",        "label": "Email Funnel",             "showTitleBar": false, "x": 0,  "y": 4,  "width": 14, "height": 11 },
    { "resource": "/reports/pos_perf/mkt_ecom_share",    "label": "E-Commerce Share",         "showTitleBar": false, "x": 14, "y": 4,  "width": 26, "height": 11 },
    { "resource": "/reports/pos_perf/mkt_campaign_roi",  "label": "Top Campaign ROI",         "showTitleBar": false, "x": 0,  "y": 15, "width": 20, "height": 11 },
    { "resource": "/reports/pos_perf/mkt_partners",      "label": "Delivery Partners",        "showTitleBar": false, "x": 20, "y": 15, "width": 20, "height": 11 }
  ]
}
```

- [ ] **Step 7: Lint, compile, deploy, verify, compose**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
foreach ($t in "mkt_kpi","mkt_funnel","mkt_ecom_share","mkt_campaign_roi","mkt_partners") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$t.jrxml"
  & ".\plugins\jasper-deploy\skills\jasper-deploy\scripts\compile_jrxml.ps1" -Jrxml "report\pos_perf\$t.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$t.jrxml" -TargetUri "/reports/pos_perf/$t" -Label $t -DataSourceUri /datasources/pos_data_avalanche -Overwrite
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$t" -Format pdf -OutFile "out\pos_perf\$t.pdf"
}
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\mkt_dashboard.json -AutoGrid
```

Expected: five PDFs render; mkt_funnel matches Step 2 defaults; mkt_partners returns exactly 3 rows; recompose reports 5 dashlets, no filter strip present.

- [ ] **Step 8: Commit**

```powershell
git add report/pos_perf/mkt_kpi.jrxml report/pos_perf/mkt_funnel.jrxml report/pos_perf/mkt_ecom_share.jrxml report/pos_perf/mkt_campaign_roi.jrxml report/pos_perf/mkt_partners.jrxml report/pos_perf/mkt_dashboard.json
git commit -m "feat(pos-perf): Marketing and Digital cockpit (STAGE)"
```

---

### Task 5: Report - Franchisee Fee Statement (Statement pattern, drill target)

**Files:**
- Create: `report/pos_perf/rpt_franchisee_fee_statement.jrxml`
- Create: `scripts/pos_perf/franchisee_control.ps1`
- Modify: `report/pos_perf/trs_kpi.jrxml` (add a hyperlink on the AR Outstanding chip)

**Interfaces:**
- Consumes: `franchise_fee_ledger` (all columns), `store_pnl_monthly` (net_sales, for the "tied to store_pnl" context line the spec asks for). `scripts/pos_perf/franchisee_control.ps1` creates ONE new single-select control, `/reports/pos_perf/controls/p_franchisee_id` (LOV `franchisee_id` / `owner_name` from `franchise_fee_ledger`, distinct) -- this is deliberately NOT the existing `/reports/pos_perf/controls/p_franchisee`, which is a multi-select `java.util.Collection` control built for the Treasury console's filter strip (type 7, confirmed 2026-08-25) and cannot back a single-entity Statement report. The new control follows the exact `p_store` precedent (`/reports/pos_perf/controls/p_store`, confirmed type 4 singleSelectQuery) -- read that control's definition via a GET before writing this file, do not reinvent the shape.
- Produces: report unit `/reports/pos_perf/rpt_franchisee_fee_statement`, parameters `p_franchisee_id STRING default "0"` (LOV value is the franchisee_id as a string, matching the `p_store` precedent where the LOV value column is the plain numeric id) and `p_yyyymm STRING default "202012"` (reuses the EXISTING `/reports/pos_perf/controls/p_yyyymm` control from Phase 1, do not create a duplicate).

- [ ] **Step 1: Read `/reports/pos_perf/controls/p_store`'s definition** (a GET, shown in this plan's Interfaces section above) and `scripts/pos_perf/jrs_controls.ps1`'s shared helpers before writing `franchisee_control.ps1` -- reuse `Test-JrsExists`, the idempotent create/update flow, and `Attach-Controls`; do not reimplement them.

- [ ] **Step 2: Write `franchisee_control.ps1`** with a `New-FranchiseeControl` function creating one control:

```
p_franchisee_id: label "Franchisee", type singleSelectQuery,
  query "SELECT DISTINCT VARCHAR(franchisee_id) AS fv, owner_name AS fl FROM franchise_fee_ledger ORDER BY 2"
  (value column fv = the id as a string; visible/label column fl = owner_name, matching the
  Store control's own value/label split where storenumber is both -- here they differ, so
  confirm the control's valueColumn is fv, not fl, after creating it)
```

- [ ] **Step 3: Run and verify**

```powershell
$env:JRS_ENV = "stage"
. .\scripts\pos_perf\franchisee_control.ps1
New-FranchiseeControl
```

Expected: `OK: created` (or `SKIP: exists` on rerun). GET the control and confirm `dataType.type` is `singleSelectQuery` and `valueColumn` is `fv`; confirm the LOV returns 169 distinct owner names (franchisee_id 0 = Stella Martin, verified 2026-08-25).

- [ ] **Step 4: Write the report.** A4 landscape (`pageWidth="842" pageHeight="595"`, margins 30, columnWidth 782), logo top-left, centered title "Franchisee Fee Statement", subtitle reading the franchisee's own name and the as-of month (evaluationTime="Report", same pattern `rpt_store_pnl_statement.jrxml` uses for its subtitle).

  **`p_yyyymm` semantics (documented design choice).** Unlike `rpt_store_pnl_statement`, which shows exactly one month, this report shows the franchisee's running statement history UP TO AND INCLUDING the chosen month -- an "as-of" cutoff, the same convention `trs_ar_aging`/`rpt_ar_aging` already use with `p_asof`. A single-month view would hide exactly the aging/overdue pattern a fee statement exists to show (a franchisee who has been Overdue for three months needs those three months visible together, not filtered to the latest one). This is why `p_yyyymm` is attached at all -- a first draft of this query that only filtered `f.yyyymm = INT4($P{p_yyyymm})` would leave a declared, attached parameter meaningless once the cutoff moved earlier than the invoice's own month; catch that before deploying, not after. Query:

```sql
SELECT f.invoice_number, f.yyyymm, f.month_start, f.invoice_date, f.due_date, f.paid_date,
       DECIMAL(f.royalty_fee, 12, 2) AS royalty_fee,
       DECIMAL(f.marketing_fee, 12, 2) AS marketing_fee,
       DECIMAL(f.total_invoiced, 12, 2) AS total_invoiced,
       DECIMAL(f.amount_paid, 12, 2) AS amount_paid,
       DECIMAL(f.balance, 12, 2) AS balance,
       f.status, f.days_paid_late, f.days_overdue, f.aging_bucket,
       DECIMAL(f.fee_pct_of_sales, 8, 4) AS fee_pct_of_sales,
       f.owner_name, f.storename, f.region,
       (SELECT DECIMAL(SUM(p.net_sales), 14, 2) FROM store_pnl_monthly p WHERE p.storenumber = f.storenumber AND p.yyyymm = f.yyyymm) AS store_net_sales
FROM franchise_fee_ledger f
WHERE f.franchisee_id = INT4($P{p_franchisee_id})
  AND f.yyyymm <= INT4($P{p_yyyymm})
ORDER BY f.yyyymm
```

Columns: Month | Invoice Date | Due Date | Paid Date | Royalty Fee | Marketing Fee | Total Invoiced | Amount Paid | Balance | Status | Days Overdue. Header `#1F4E79` on white, zebra `#D6E0EF` (matches `rpt_ar_aging`/`rpt_ap_aging`). Status column: red `#D9534F` bold when `status = 'Overdue'`, plain otherwise (two overlapping textFields with `printWhenExpression`, the established Phase 1/2/3 conditional-colour pattern). `whenNoDataType="AllSectionsNoDetail"` (bake in from the start). Summary band: total invoiced / total paid / total balance across the returned rows, plus a one-line disclosure sentence naming the `fee_pct_of_sales` basis and the as-of cutoff (matching this suite's established visible-methodology-disclosure pattern, e.g. `rpt_churn_action_list`'s and `rpt_weekly_flash`'s own disclosure lines) -- something like `"Royalty and marketing fees as a percent of that store-month's net sales; statement as of " + $P{p_yyyymm} + "."` (no source-identifying table names in user-visible text -- see Global Constraints). Expected at the default `franchisee_id=0`, `p_yyyymm="202012"` (the full 24-month history, since 202012 is the last month in the dataset): reconcile row count and totals against `SELECT COUNT(*), SUM(total_invoiced), SUM(balance) FROM franchise_fee_ledger WHERE franchisee_id = 0` directly (no `yyyymm` filter needed for that specific reconciliation query, since the default cutoff already covers the whole dataset).

- [ ] **Step 5: Deploy, attach control, verify**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_franchisee_fee_statement.jrxml
& ".\plugins\jasper-deploy\skills\jasper-deploy\scripts\compile_jrxml.ps1" -Jrxml report\pos_perf\rpt_franchisee_fee_statement.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_franchisee_fee_statement.jrxml -TargetUri /reports/pos_perf/rpt_franchisee_fee_statement -Label "Franchisee Fee Statement" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
. .\scripts\pos_perf\franchisee_control.ps1
. .\scripts\pos_perf\jrs_controls.ps1
Attach-Controls -ReportUri /reports/pos_perf/rpt_franchisee_fee_statement -ControlUris @("/reports/pos_perf/controls/p_franchisee_id","/reports/pos_perf/controls/p_yyyymm")
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_franchisee_fee_statement -Format pdf -OutFile out\pos_perf\rpt_franchisee_fee_statement.pdf
```

GET-verify both controls stuck. Confirm the default run reconciles per Step 4's expected figures; render a second franchisee AND an earlier `p_yyyymm` cutoff (e.g. `202006`) to confirm both parameters actually filter -- the row count should drop on the earlier cutoff, not just change franchisee.

- [ ] **Step 6: Add the trs_kpi drill (documented fixed-scope deviation).** `trs_kpi.jrxml`'s AR Outstanding chip has no hyperlink today (confirmed 2026-08-25 -- this is new, not a redeploy of an existing link). The spec says "trs_kpi AR chip -> Franchisee Fee Statement," but `trs_kpi` is a network-wide aggregate (one AR total across all 169 franchisees) with no per-franchisee row to drill FROM -- there is no natural "click this value for this franchisee" the way `pnl_worst_stores` or `sup_scorecard` rows work. Add the hyperlink anyway, per spec, but have it open the report at its OWN default (`p_franchisee_id` and `p_yyyymm` both omitted from the hyperlink, so the report's `defaultValueExpression`s apply) rather than fabricating a franchisee id the chip has no way to know. Document this reasoning in a header-comment addition to `trs_kpi.jrxml` (the file does not currently have deviation notes; add one, matching the header-comment discipline every other file in this suite uses) so a future reader does not assume the chip is supposed to be franchisee-scoped and try to "fix" it.

```powershell
# in trs_kpi.jrxml, on the existing AR Outstanding textField element (the one
# at x=0 y=24 width=316 height=42 bound to $F{ar_balance}):
#   add <hyperlinkReference><expression>"/reports/pos_perf/rpt_franchisee_fee_statement"</expression></hyperlinkReference>
# (flattened hyperlink form, no hyperlinkParameter children -- opens at report defaults)
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\trs_kpi.jrxml
& ".\plugins\jasper-deploy\skills\jasper-deploy\scripts\compile_jrxml.ps1" -Jrxml report\pos_perf\trs_kpi.jrxml
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_treasury
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_kpi.jrxml -TargetUri /reports/pos_perf/trs_kpi -Label "trs_kpi" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
. .\scripts\pos_perf\jrs_controls.ps1
Attach-Controls -ReportUri /reports/pos_perf/trs_kpi -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/trs_kpi -Format pdf -OutFile out\pos_perf\trs_kpi_with_drill.pdf
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\trs_dashboard.json -AutoGrid
```

GET-verify `trs_kpi`'s three controls (p_asof, p_regions, p_franchisee) re-attached after the redeploy -- `-Overwrite` drops them every time, per the standing gotcha. Recompose `pos_treasury` since teardown removed it. Confirm `trs_kpi_with_drill.pdf` renders identically to the pre-existing figures (AR Outstanding \$5,399,130 at defaults, per RUNBOOK's Phase 1 acceptance record) -- the hyperlink addition must not change the tile's numbers.

- [ ] **Step 7: Commit**

```powershell
git add report/pos_perf/rpt_franchisee_fee_statement.jrxml scripts/pos_perf/franchisee_control.ps1 report/pos_perf/trs_kpi.jrxml
git commit -m "feat(pos-perf): Franchisee Fee Statement report (drill target) and trs_kpi AR-chip drill"
```

---

### Task 6: STAGE acceptance, docs, PROD go/no-go (deferred)

**Files:**
- Modify: `README.md` (extend the "POS performance dashboards" section)
- Modify: `RUNBOOK.md` (extend the pos_perf section with Phase 4's rebuild/redeploy/recompose recipe and PROD block)
- Modify: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-perf-dashboards.md`
- Modify: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-suite-blueprint.md`

**Interfaces:**
- Consumes: everything built in Tasks 1-5, all live on STAGE.
- Produces: docs a human can run the browser checks and the eventual PROD promotion from; nothing further depends on this task. This is the LAST phase in the roadmap -- once this task's acceptance passes, the suite as scoped in `specs/2026-08-23-pos-suite-design.md` is complete: all 10 dashboards (the 3 pre-existing plus the 7 numbered dashboards 4-10, all of which this plan finishes) and all 9 paginated reports. The Retention Story deck was never one of the 7 numbered dashboards -- it was an unnumbered, explicitly optional addition the spec itself hedges on ("if wanted"), and the user chose not to build it (2026-08-25) -- so skipping it does not leave the numbered suite incomplete. This task's docs update should say the suite is complete rather than leaving an open "next phase" pointer the way Phases 1-3's docs did.

- [ ] **Step 1: Render every new unit at defaults and reconcile.** 10 dashboard tiles (`net_*` x5, `mkt_*` x5) + 1 report (`rpt_franchisee_fee_statement`) + 1 modified tile (`trs_kpi`) = 12 units. Re-export each report unit's jrxml from STAGE and diff against the committed git version (byte match) -- the same check every prior phase ran; apply it to all 12 Phase 4 units plus a re-check of the 4 already-modified Treasury units this phase touches indirectly (teardown/recompose of `pos_treasury` in Task 5 Step 6 does not redeploy `trs_ar_aging`/`trs_dpo`/`trs_tender_mix`/`trs_tax_province`, but confirm they still compose correctly after the teardown). Confirm `pos_store_network` composes with 5 dashlets and no filters; confirm `pos_marketing_digital` composes with 5 dashlets and no filters; confirm `pos_treasury` recomposes with all 7 dashlets after Task 5's teardown.

- [ ] **Step 1a: Wobby metric cross-check.** Follow the exact recipe RUNBOOK.md documents under "Reconcile the finance KPIs against the semantic layer" (one API GET, then offline re-runs): fetch `/api/public/v1/environment` and run `scripts/pos_perf/wobby_metric_crosscheck.py` against it. The spec's semantic-alignment table maps this phase's tiles to `ecommerce_revenue_share_pct`, `ecommerce_late_fulfillment_rate`, `avg_ecommerce_satisfaction_score`, `email_open_rate`, `email_click_rate`, `email_conversion_rate`, `promotion_roi`, `subsidy_cost_per_conversion`, `total_campaign_conversions` -- check whether `wobby_metric_crosscheck.py` already covers these (it was written for Phase 1's finance metrics) and extend its metric list if not, following its existing pattern rather than writing a second script. Any metric that disagrees by more than 0.5 pct needs an explanation (a different as-of date, a different denominator) before Task 6 can call this phase accepted, matching Phase 1's own bar ("11/11 checked metrics agree exactly").

- [ ] **Step 2: Write the manual browser checklist addition** in `RUNBOOK.md` (append to the existing "Checks that need a human with a browser" list, items 12+): a visual check of `net_map`'s shipped technique (does it read as a real map with store markers to a human, not just that it compiles -- and if it fell back to the xyScatter or table technique, does the fallback still communicate "which stores are exposed" clearly); the `mkt_campaign_roi` -> Weekly Flash drill click-test (expected and NOT a bug: the target always opens the fixed 2020-11-08 week regardless of which campaign row was clicked, per Task 4's documented deviation); the `trs_kpi` AR-chip -> Franchisee Fee Statement drill click-test (expected and NOT a bug: always opens franchisee id 0 / Stella Martin, not scoped to any particular franchisee, per Task 5's documented deviation); a page-count/readability sanity check on `mkt_campaign_roi`'s 15-row cap (does 15 feel like the right cut, or should a future revision paginate further).

- [ ] **Step 3: Write the RUNBOOK PROD block** (deferred, user-run, following the exact Phase 1-3 shape, including the Phase 2-established Step -1 byte-diff precondition before promoting any unit): deploy the 10 `net_*`/`mkt_*` jrxml + 1 `rpt_franchisee_fee_statement` jrxml with `-Env prod`, redeploy `trs_kpi` with `-Env prod` and re-attach its three existing controls, create the one new franchisee control on PROD via `New-FranchiseeControl` if not already present, recompose all three touched dashboards (`pos_store_network`, `pos_marketing_digital`, `pos_treasury`).

- [ ] **Step 4: Update the memory files.** Append a "## Phase 4 (growth) executed \<date\>" section to `pos-perf-dashboards.md` with both dashboard URIs, manifest paths, the two new aggregates, the acceptance figures from Tasks 1-2's verify scripts, which `net_map` technique actually shipped (and why), and the outstanding browser checks -- same shape as the existing Phase 1-3 sections. Update `pos-suite-blueprint.md` to note Phase 4 executed and that the growth-scope suite (per the approved spec, Retention Story deck excluded by user decision) is now complete -- no further phase is planned unless the user asks for one.

- [ ] **Step 5: Commit**

```powershell
git add README.md RUNBOOK.md
git commit -m "docs(pos-perf): Phase 4 acceptance, runbook, and memory updates"
```
