# POS Dashboard Suite - Phase 0 + Phase 1 (Finance) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out the three shipped POS dashboards (PROD fix, docs, filter spike), then build and deploy to STAGE the two finance dashboards (Store Profit and Budget, Franchise Treasury), the navy re-skin of Executive Overview and Promo Story, and the four finance paginated reports, all fed by `robert.gorsuch` tables that already reconcile.

**Architecture:** One new aggregate (`dash_tender_monthly`) plus direct reads of the sub-110K-row finance tables. Hand-authored JR7 JRXMLs under `report/pos_perf/` (template `smoke_kpi.jrxml`, chart idiom from `exec_region_bar.jrxml`, parameter idiom from `ops_kpi_chips.jrxml`), shared input controls under `/reports/pos_perf/controls`, dashboards composed from committed manifests by `compose_dashboard.ps1`, verified by run-to-PDF + rasterize. Paginated reports are separate report units that dashboard tiles hyperlink into.

**Tech Stack:** Actian Avalanche X100 (Ingres JDBC, `av-flm7ykoxlcvq.avstage.actiandatacloud.com:27839`, db `db`, schema `robert.gorsuch`), JasperReports Server 10.0.0 Pro (STAGE `http://localhost:8081/jasperserver-pro`), PowerShell 5.1, jasper-deploy skill (`$jd = ".\.claude\skills\jasper-deploy\scripts"`), admiral skill (`$adm = ".\.claude\skills\admiral\scripts"`), Python 3 + pypdfium2 for PDF rasterizing, Wobby public API for the metric cross-check.

**Spec:** `specs/2026-08-23-pos-suite-design.md` (blueprint with mockups: https://claude.ai/code/artifact/c4d67c80-1890-4bad-9988-6c133d75230e). Phases 2-4 get their own plans after this one ships.

## Global Constraints

- Repo is PUBLIC. No credentials, hostnames-with-passwords, or API keys in any committed file. JRS creds come from `.claude/skills/jasper-deploy/jrs.config.json` (gitignored; keys `serverUrl`, `user`, `password`, `environments.stage.serverUrl`, `environments.prod.*`); warehouse creds from `.claude/skills/admiral/admiral.config.json`.
- Environment selection: `$env:JRS_ENV = "stage"` before any `$jd` script. Never run a `$jd` script against `prod` in this plan except in Task 1 Step 3, and only the user runs those.
- Warehouse calls: `& "$adm\sql.ps1" -Action run-file -SqlFile <file> -ResourceId av-flm7ykoxlcvq` (or `-DbHost av-flm7ykoxlcvq.avstage.actiandatacloud.com -Database db`). `run-file` splits on EVERY `;` and tracks `'`/`"` state with no comment awareness: **no `;`, `'`, or `"` inside any SQL comment**. Wrap every ratio in `FLOAT8(...)` (DECIMAL/DECIMAL truncates scale). Use `FIRST n`, not `LIMIT`. Views: `DROP VIEW IF EXISTS`; tables: `DROP TABLE IF EXISTS ... ; CREATE TABLE ... AS SELECT ...; CREATE STATISTICS FOR <table>;`.
- JRXML is JR7-native: `<query language="SQL">`, `<element kind="staticText|textField|line|rectangle|image|chart">`, `<text>`/`<expression>` children, `<element kind="chart" chartType="bar|stackedBar|line|area|pie|meter">` with `<dataset kind="category">` and `<plot><seriesColor order="n" color="#hex"/></plot>`. Charts in the `title` band need `evaluationTime="Report"`. Never mix JR6 legacy syntax into a JR7 file.
- Brand, light theme: Actian logo top-left (`"repo:/images/actian_logo"`, 44x44 at 0,0), title centered `forecolor="#1F4E79"` 16pt bold, subtitle `#5B7DA6` 9pt; KPI label `fontSize="13.0" forecolor="#5B7DA6"`, KPI value `fontSize="26.0" bold forecolor="#1F4E79"`, dividers `#D6E0EF`; table header `#1F4E79` on white, zebra `#D6E0EF`; series order `#0550DC`, `#1DB6C0`, `#0A4CAD`, `#239CA8`; favourable/unfavourable `#5CB85C` / `#D9534F`.
- Brand, navy theme (Tasks 7): page rectangle `mode="Opaque" backcolor="#000032" forecolor="#000032"`, tile border `#26305A`, text `#FFFFFF`, captions `#8AC6F8`, eyebrow `#3C91FF`, series `#3C91FF` then `#2EC0CB`, every teal series `showLabels="true"`.
- No "Foodmart", "Wobby", datasource URIs, SQL, table or column names in user-visible text. Dashboard labels contain no `&` (compose does not XML-escape). Current-year rule does not apply here: the finance data is dated 2019-2020 and the tiles say so.
- Dashboards: 40-unit grid, every dashlet `showTitleBar:false`; delete the dashboard (`teardown_dashboard.ps1 -Uri ...`) before every recompose; dashboards cannot be run to PDF (verify the tiles' report units instead, then eyeball the viewer URL `.../dashboard/viewer.html#%2Freports%2Fpos_perf%2F<name>`).
- Page sizes by tile shape (pageWidth x pageHeight, margins 10 unless stated): 40x4 KPI strip 1600x130; 40x3 control strip 1600x100; 22x12 or 20x12 chart 1000x440; 18x12 chart 800x440; 20x12 list 800x440; 13x11, 14x11, 13x12, 14x12 chart 600x420.
- Acceptance references (from verify scripts and task reports): `store_pnl_monthly` 7,891 rows / 330 stores; 2020 net sales 416.5M, 2019 347.7M; trading-month P&L as pct of sales: COGS 68.3, GM 31.7, loaded labour 10.4, occupancy 5.1, utilities 1.1, shrink 0.25, card fees 1.2, other 2.2, franchise fees 6.3, four-wall EBITDA 12.4, contribution 6.1; four-wall by format Standalone 14.2 / Strip Plaza 13.4 / Urban Storefront 12.1 / Shopping Mall 9.3; 2020 actual vs Original budget +13.0 pct, vs Reforecast +0.07 pct; AR: 317 Open 3.76M + 255 Overdue 1.64M (1.27M aged 60+), invoiced 47,971,634.88; AP: 3,211 Open 29.3M + 203 Overdue 1.08M, DPO 26.2 / 39.6 / 52.9 on Net 30/45/60, 80 pct on time, 793,522 discounts; card fees 7,607,921.36; cashless 77.9 to 89.9 pct at 2020-03; tax 28.1M (11.7M GST + 16.4M provincial), taxable share 30.6 pct; gift card closing 1,694,634.25; loyalty closing 7.37M CAD; NBV 156.6M; lease expiries 2024 = 169 stores.
- Categorical values used in SQL: `budget_version` = `Original` | `Reforecast Q2 2020`; `trading_status` = `Trading` | `Closed` | `No sales`; `status` = `Paid` | `Open` | `Overdue`; `aging_bucket` = `Paid` | `Current` | `1-30 days` | `31-60 days` | `60+ days`; `payment_terms` = `Net 30` | `Net 45` | `Net 60`; `tender_group` = `Cash` | `Card` | `Stored Value`; `tender_type` = `Cash`, `Debit`, `Credit Visa`, `Credit Mastercard`, `Credit Amex`, `Mobile Wallet`, `Gift Card`, `Loyalty Points`; `region` = `Ontario` | `Western` | `Quebec` | `Atlantic`; liability tables are `gift_card_liability_monthly` and `loyalty_liability_monthly` (the spec's short names are the Wobby model names).

---

### Task 1: Phase 0 close-out - PROD region-bar fix (user-run) and Task 9 docs

**Files:**
- Modify: `README.md` (new section "POS performance dashboards")
- Modify: `RUNBOOK.md` (new section "pos_perf: rebuild aggregates, redeploy, recompose")
- Create: `C:\Users\rgorsuch\.claude\projects\C--Users-rgorsuch-tx-geocoder\memory\pos-perf-dashboards.md` + one index line in `MEMORY.md`

**Interfaces:**
- Consumes: the six PROD commands recorded in `.superpowers/sdd/2026-08-20-pos-sales-dashboards/task-8-fix-report.md`.
- Produces: docs that every later task's runbook step links to; PROD dashboards 1-2 rendering the fixed region bars.

- [ ] **Step 1: Write the README section** (append to `README.md`, keep ASCII):

```markdown
## POS performance dashboards (report/pos_perf)

Three dashboards on JasperReports Server, fed by `robert.gorsuch` on the
pos_data Avalanche warehouse through `/datasources/pos_data_avalanche`:

| Dashboard | URI | Manifest |
|---|---|---|
| POS Executive Overview | /reports/pos_perf/pos_executive_overview | report/pos_perf/exec_dashboard.json |
| POS Operations Console | /reports/pos_perf/pos_operations_console | report/pos_perf/ops_dashboard.json |
| POS Promo and Margin Story | /reports/pos_perf/pos_promo_story | report/pos_perf/story_dashboard.json |

Tiles read the precomputed `dash_*` aggregates built by
`scripts/pos_perf/build_dash_aggregates.sql` (verify with
`verify_dash_aggregates.sql`). Margin basis: extended sales minus extended
cost per line, 31.65 pct network (see out/pos_perf/margin_basis_decision.md
in a local build). Design: specs/2026-08-20-pos-sales-dashboards-design.md;
suite roadmap: specs/2026-08-23-pos-suite-design.md.
```

- [ ] **Step 2: Write the RUNBOOK section** (append to `RUNBOOK.md`):

```markdown
## pos_perf: rebuild aggregates, redeploy a report, recompose a dashboard

Rebuild aggregates (idempotent, ~2 min):
    $adm = ".\.claude\skills\admiral\scripts"
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_aggregates.sql -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_aggregates.sql -ResourceId av-flm7ykoxlcvq

Redeploy one report after editing its jrxml:
    $env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\lint_jrxml.ps1" -Path report\pos_perf\exec_region_bar.jrxml
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_region_bar.jrxml -TargetUri /reports/pos_perf/exec_region_bar -Label "Net Sales by Region" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/exec_region_bar -Format pdf -OutFile out\pos_perf\exec_region_bar.pdf

Recompose a dashboard (delete first, the import will not overwrite companions):
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_executive_overview
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\exec_dashboard.json -AutoGrid

Gotchas: dashboards do not run to PDF (verify the tiles); compose labels are
not XML-escaped (use "and", never "&"); Ops Console filters are per-dashlet
popups (dashletFilterShowPopup true); PROD lacks the chart customizer jar, so
tiles use plain seriesColor; STAGE-to-PROD export/import fails with
import.decode.failed (per-server key), so promote by deploying jrxml to PROD
with -Env prod and recomposing there.
```

- [ ] **Step 3: PROD region-bar fix - the USER runs these** (auto-mode denies PROD writes). Hand the user this block to run with the `!` prefix, one line at a time, and wait for the paste-back before continuing:

```powershell
$env:JRS_ENV = "prod"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_executive_overview
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_region_bar.jrxml -TargetUri /reports/pos_perf/exec_region_bar -Label "Net Sales by Region" -DataSourceUri /datasources/pos_data_avalanche -Overwrite -Backup
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_operations_console
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\ops_region_bar.jrxml -TargetUri /reports/pos_perf/ops_region_bar -Label "Net Sales by Region" -DataSourceUri /datasources/pos_data_avalanche -Overwrite -Backup
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/exec_region_bar -Format pdf -OutFile out\pos_perf\prod_exec_region_bar.pdf
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\exec_dashboard.json -AutoGrid
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\ops_dashboard.json
$env:JRS_ENV = "stage"
```

Expected: two `DELETE ... -> 204`, two `OK: deployed`, a PDF with four blue bars (Ontario tallest), two `compose ... imported`. If the user declines, record "PROD fix deferred" in the task report and continue; nothing later depends on it.

- [ ] **Step 4: Write the memory file** `pos-perf-dashboards.md` (frontmatter `type: project`) with: the three URIs and manifests, the tile grid of each (copy from the three manifests), margin basis 31.65 pct, aggregate rebuild command, the four gotchas from Step 2, PROD status from Step 3. Add to `MEMORY.md`: `- [POS perf dashboards](pos-perf-dashboards.md) - 3 STAGE/PROD dashboards, manifests, rebuild/recompose commands, PROD promote = redeploy jrxml (export/import fails)`.

- [ ] **Step 5: Commit**

```powershell
git add README.md RUNBOOK.md
git commit -m "docs(pos-perf): dashboard runbook + README (Task 9 close-out)"
```

---

### Task 2: Filter spike - control-strip dashlet in gen_dashboard.py (time-boxed)

**Files:**
- Modify: `.claude/skills/jasper-deploy/scripts/gen_dashboard.py` (functions `build_components`, `build_wiring`, manifest handling around lines 297-303)
- Create: `report/pos_perf/spike_filter_dashboard.json` (throwaway manifest, deleted at the end)
- Create: `.superpowers/sdd/2026-08-23-pos-suite/spike-filter-report.md`

**Interfaces:**
- Consumes: `gen_dashboard.py` manifest keys `dashletFilterShowPopup`, `wiring`; existing controls `/reports/pos_perf/controls/p_regions`, `p_from`, `p_to`; report units `ops_sales_trend`, `ops_region_bar`.
- Produces: EITHER a new manifest key `"filters": ["p_from","p_to","p_regions"]` that emits a filter-group dashlet wired to all report dashlets, OR a written verdict "fallback: popups" that Tasks 5-6 follow. Tasks 5-6 read the verdict file before writing their manifests.

- [ ] **Step 1: Capture the target model.** In the STAGE designer (user's browser, or ask the user), open `pos_operations_console`, drag "Filter Group" from the palette onto the canvas at the top, add the `p_regions` control, save as `/reports/pos_perf/spike_ops_filtered`. Then export it:

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
& "$jd\export_resource.ps1" -Uri /reports/pos_perf/spike_ops_filtered -Out out\pos_perf\spike_export.zip
Expand-Archive out\pos_perf\spike_export.zip out\pos_perf\spike_export -Force
Get-ChildItem out\pos_perf\spike_export -Recurse -File | Select-Object FullName
```

Expected: `components.data`, `layout`, `wiring.data` under `resources/reports/pos_perf/spike_ops_filtered_files/`. If the designer has no Filter Group palette item on this server build, stop here and go to Step 5 with verdict "fallback".

- [ ] **Step 2: Diff against what gen_dashboard.py emits.** Compose the same six tiles from `ops_dashboard.json` into a scratch name and diff the three companion files:

```powershell
python - <<'EOF'
import json,difflib,pathlib
exp = pathlib.Path("out/pos_perf/spike_export/resources/reports/pos_perf/spike_ops_filtered_files")
comp = json.loads((exp/"components.data").read_text())
wire = json.loads((exp/"wiring.data").read_text())
print([c["type"] for c in comp])
print(json.dumps([c for c in comp if c["type"] in ("filterGroup","inputControl")], indent=1)[:4000])
print(json.dumps(wire, indent=1)[:4000])
EOF
```

Record verbatim in the spike report: the `filterGroup` component JSON, each `inputControl` component JSON (note the `resource`/`uri` field naming and any `exposeOutputsToFilterManager: true` on the report dashlets), the `layout` entry for the filter group, and every wiring event whose producer is the filter group or an input control.

- [ ] **Step 3: Implement `filters` in gen_dashboard.py.** Add, next to `build_components`:

```python
def build_filter_components(filters, ctl_folder="/reports/pos_perf/controls"):
    """One filterGroup + one inputControl component per control name.
    Field names must match the designer export captured in the spike report;
    adjust the keys below to that export, not the other way round."""
    comps = []
    ics = []
    for i, name in enumerate(filters):
        cid = f"ic_{name}"
        ics.append(cid)
        comps.append({
            "id": cid, "type": "inputControl", "name": name,
            "resource": f"{ctl_folder}/{name}", "label": name,
            "parameters": [], "outputParameters": [name],
        })
    comps.append({
        "id": "FilterGroup", "type": "filterGroup", "name": "Filters",
        "items": ics, "applyButton": True, "resetButton": True,
    })
    return comps
```

Wire it in `build_components(dashlets, dashlet_filter_popup=False, filters=None)`: when `filters` is non-empty, set `"exposeOutputsToFilterManager": True` on every reportUnit dashlet and append `build_filter_components(filters)` to the component list. In `build_layout` add a full-width row `{"id":"FilterGroup","x":0,"y":0,"width":40,"height":3}` and shift every dashlet `y` by 3 when `filters` is set. In `build_wiring` add one event per control: producer `ic_<name>:@applyParams`, consumers `<cid>:@applyParams` for every report dashlet. In the manifest loader pass `m.get("filters")` through. Keep `dashletFilterShowPopup` behaviour unchanged when `filters` is absent.

- [ ] **Step 4: Compose the two-tile test board and exercise it.**

`report/pos_perf/spike_filter_dashboard.json`:
```json
{
  "folder": "/reports/pos_perf",
  "name": "spike_filter_test",
  "label": "Spike Filter Test",
  "filters": ["p_from", "p_to", "p_regions"],
  "dashlets": [
    { "resource": "/reports/pos_perf/ops_sales_trend", "label": "Net Sales Trend", "showTitleBar": false, "x": 0, "y": 0, "width": 20, "height": 10 },
    { "resource": "/reports/pos_perf/ops_region_bar", "label": "Net Sales by Region", "showTitleBar": false, "x": 20, "y": 0, "width": 20, "height": 10 }
  ]
}
```

```powershell
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\spike_filter_dashboard.json
```

Open `http://localhost:8081/jasperserver-pro/dashboard/viewer.html#%2Freports%2Fpos_perf%2Fspike_filter_test` (user's browser or Chrome tool). Pick Regions = Ontario, Apply. PASS = the region bar shows one bar and the trend drops below the all-region line. FAIL = tiles unchanged or the dashboard renders blank.

- [ ] **Step 5: Record the verdict and clean up.** Write `.superpowers/sdd/2026-08-23-pos-suite/spike-filter-report.md` with: verdict `CONTROL_STRIP` or `FALLBACK_POPUPS`, the captured JSON, what changed in `gen_dashboard.py`, screenshots path. Then:

```powershell
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/spike_filter_test
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/spike_ops_filtered
Remove-Item report\pos_perf\spike_filter_dashboard.json
```

Time box: one working session. On `FALLBACK_POPUPS`, revert `gen_dashboard.py` (`git checkout -- .claude/skills/jasper-deploy/scripts/gen_dashboard.py`) so the console manifests in Tasks 5-6 use `"dashletFilterShowPopup": true` and omit the control-strip tile.

- [ ] **Step 6: Commit** (only if CONTROL_STRIP):

```powershell
git add .claude/skills/jasper-deploy/scripts/gen_dashboard.py .superpowers/sdd/2026-08-23-pos-suite/spike-filter-report.md
git commit -m "feat(jasper-deploy): dashboard-level filter group from manifest 'filters' key"
```

---

### Task 3: dash_tender_monthly aggregate

**Files:**
- Create: `scripts/pos_perf/build_dash_tender_monthly.sql`
- Create: `scripts/pos_perf/verify_dash_tender_monthly.sql`

**Interfaces:**
- Consumes: `tender_summary_daily` (storenumber, province, region, sale_date, yyyymm, tender_type, tender_group, amount, est_transactions, fee_pct, processing_fee).
- Produces: table `dash_tender_monthly(storenumber, region, province, yyyymm, yr, mo, tender_group, tender_type, amount DECIMAL(14,2), est_transactions INT, processing_fee DECIMAL(12,2))`, one row per store x month x tender_type. Task 6 reads it.

- [ ] **Step 1: Write the build script**

```sql
-- dash_tender_monthly: tender_summary_daily rolled to store x month x tender type
-- NOTE: sql.ps1 run-file splits statements on EVERY semicolon, even inside
-- comments -- never put a semicolon or an apostrophe in a comment in this file
DROP TABLE IF EXISTS dash_tender_monthly;
CREATE TABLE dash_tender_monthly AS
SELECT storenumber, region, province, yyyymm,
       yyyymm / 100 AS yr, MOD(yyyymm, 100) AS mo,
       tender_group, tender_type,
       DECIMAL(SUM(amount), 14, 2) AS amount,
       INT4(SUM(est_transactions)) AS est_transactions,
       DECIMAL(SUM(processing_fee), 12, 2) AS processing_fee
FROM tender_summary_daily
GROUP BY storenumber, region, province, yyyymm, tender_group, tender_type;
CREATE STATISTICS FOR dash_tender_monthly;
```

- [ ] **Step 2: Write the verify script**

```sql
-- verify dash_tender_monthly
-- NOTE: no semicolons or apostrophes inside comments in this file
-- 1 grain
SELECT COUNT(*) AS rows_, COUNT(DISTINCT storenumber) AS stores, MIN(yyyymm) AS min_m, MAX(yyyymm) AS max_m,
       (SELECT COUNT(*) FROM (SELECT storenumber, yyyymm, tender_type FROM dash_tender_monthly GROUP BY 1,2,3 HAVING COUNT(*) > 1) d) AS dup_keys
FROM dash_tender_monthly;
-- 2 ties to source to the cent
SELECT (SELECT SUM(amount) FROM dash_tender_monthly) AS agg_amount,
       (SELECT SUM(amount) FROM tender_summary_daily) AS src_amount,
       (SELECT SUM(processing_fee) FROM dash_tender_monthly) AS agg_fee,
       (SELECT SUM(processing_fee) FROM tender_summary_daily) AS src_fee;
-- 3 cashless share pre vs pandemic, expect about 77.9 then 89.9
SELECT CASE WHEN yyyymm >= 202003 THEN 'Pandemic' ELSE 'Pre-pandemic' END AS period,
       DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN tender_group <> 'Cash' THEN amount ELSE 0 END)) / FLOAT8(SUM(amount)), 6, 2) AS cashless_pct
FROM dash_tender_monthly GROUP BY 1 ORDER BY 1;
-- 4 monthly mix eyeball, first 12 rows
SELECT FIRST 12 yyyymm, tender_group, DECIMAL(SUM(amount), 14, 2) AS amount FROM dash_tender_monthly GROUP BY 1,2 ORDER BY 1,2;
```

- [ ] **Step 3: Run both**

```powershell
$adm = ".\.claude\skills\admiral\scripts"
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_tender_monthly.sql -ResourceId av-flm7ykoxlcvq
& "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_tender_monthly.sql -ResourceId av-flm7ykoxlcvq
```

Expected: check 1 `dup_keys = 0`, 330 stores, 201901..202012; check 2 agg = src to the cent for both columns (src fee total 7,607,921.36); check 3 Pre-pandemic about 77.9, Pandemic about 89.9.

- [ ] **Step 4: Commit**

```powershell
git add scripts/pos_perf/build_dash_tender_monthly.sql scripts/pos_perf/verify_dash_tender_monthly.sql
git commit -m "feat(pos-perf): dash_tender_monthly aggregate for the Treasury board"
```

---

### Task 4: Shared input controls for the finance boards

**Files:**
- Create: `scripts/pos_perf/jrs_controls.ps1`

**Interfaces:**
- Consumes: `_jrs_common.ps1` (`Resolve-JrsConfig -Env`, `Invoke-JrsPut -Jrs -Uri -ContentType -JsonFile -Overwrite`, `Invoke-JrsGet -Jrs -Uri`, `Assert-JrsOk -Response -Operation`); existing `/reports/pos_perf/controls/p_regions`.
- Produces: controls `/reports/pos_perf/controls/p_asof` (type 3 LOV of month ends), `p_franchisee` (type 7 query), `p_store` (type 4 query), `p_yyyymm` (type 3 LOV), `p_version` (type 3 LOV: `Original`, `Reforecast Q2 2020`), `p_province` (type 3 LOV); and the function `Attach-Controls -ReportUri <uri> -ControlUris <string[]>` used by Tasks 5, 6, 8-10.

- [ ] **Step 1: Write the script**

```powershell
# scripts/pos_perf/jrs_controls.ps1 -- create the shared finance controls once
# under /reports/pos_perf/controls and attach any subset to a report unit.
# Usage:
#   . .\scripts\pos_perf\jrs_controls.ps1
#   New-FinanceControls                      # idempotent PUT -Overwrite
#   Attach-Controls -ReportUri /reports/pos_perf/trs_ar_aging -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions")
param([string]$Env = $env:JRS_ENV)
. (Join-Path $PSScriptRoot "..\..\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1")
$script:jrs = Resolve-JrsConfig -Env $Env
$script:ctl = "/reports/pos_perf/controls"
$script:ds  = "/datasources/pos_data_avalanche"

function Put-Json([string]$Uri, [string]$ContentType, [string]$Json) {
    $f = [IO.Path]::GetTempFileName()
    $Json | Set-Content $f -Encoding utf8
    try { $r = Invoke-JrsPut -Jrs $script:jrs -Uri $Uri -Overwrite -ContentType $ContentType -JsonFile $f }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
    Assert-JrsOk -Response $r -Operation "PUT $Uri" | Out-Null
    Write-Host "OK: $Uri"
}

function New-LovControl([string]$Name, [string]$Label, [string[]]$Items) {
    # Items are "label=value" pairs. JSON is built by hand: PS 5.1 unwraps 1-element arrays.
    $itemJson = ($Items | ForEach-Object { $kv = $_.Split("=", 2); "{`"label`":`"$($kv[0])`",`"value`":`"$($kv[1])`"}" }) -join ","
    Put-Json "$script:ctl/${Name}_lov" "application/repository.listOfValues+json" "{`"label`":`"$Label values`",`"items`":[$itemJson]}"
    Put-Json "$script:ctl/$Name" "application/repository.inputControl+json" ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":3," +
        "`"listOfValues`":{`"listOfValuesReference`":{`"uri`":`"$script:ctl/${Name}_lov`",`"version`":0}}}")
}

function New-QueryControl([string]$Name, [string]$Label, [string]$ValueCol, [string]$Sql, [int]$Type) {
    Put-Json "$script:ctl/${Name}_query" "application/repository.query+json" ("{`"label`":`"$Name query`",`"language`":`"sql`",`"value`":`"$($Sql -replace '"','\"')`"," +
        "`"dataSource`":{`"dataSourceReference`":{`"uri`":`"$script:ds`",`"version`":0}}}")
    Put-Json "$script:ctl/$Name" "application/repository.inputControl+json" ("{`"label`":`"$Label`",`"mandatory`":false,`"readOnly`":false,`"visible`":true,`"type`":$Type," +
        "`"valueColumn`":`"$ValueCol`",`"visibleColumns`":[`"$ValueCol`"]," +
        "`"query`":{`"queryReference`":{`"uri`":`"$script:ctl/${Name}_query`",`"version`":0}}}")
}

function New-FinanceControls {
    $months = @()
    foreach ($y in 2019, 2020) { foreach ($m in 1..12) { $ym = "{0}{1:00}" -f $y, $m; $months += "$ym=$ym" } }
    New-LovControl -Name "p_yyyymm"  -Label "Month"          -Items $months
    New-LovControl -Name "p_asof"    -Label "As of month"    -Items $months
    New-LovControl -Name "p_version" -Label "Budget version" -Items @("Original=Original", "Reforecast Q2 2020=Reforecast Q2 2020")
    New-LovControl -Name "p_province" -Label "Province" -Items @("All=All","ON=ON","QC=QC","BC=BC","AB=AB","SK=SK","MB=MB","NB=NB","NL=NL","NS=NS","PE=PE","YT=YT","NT=NT")
    New-QueryControl -Name "p_franchisee" -Label "Franchisee" -ValueCol "franchisee_id" -Sql "SELECT DISTINCT franchisee_id FROM franchisees ORDER BY 1" -Type 7
    New-QueryControl -Name "p_store" -Label "Store" -ValueCol "storenumber" -Sql "SELECT DISTINCT storenumber FROM stores ORDER BY 1" -Type 4
}

function Attach-Controls([string]$ReportUri, [string[]]$ControlUris) {
    $cur = Invoke-JrsGet -Jrs $script:jrs -Uri $ReportUri
    Assert-JrsOk -Response $cur -Operation "GET $ReportUri" | Out-Null
    $ru = $cur.Body | ConvertFrom-Json
    $refs = @($ControlUris | ForEach-Object { [ordered]@{ inputControlReference = [ordered]@{ uri = $_ } } })
    $ru | Add-Member -NotePropertyName inputControls -NotePropertyValue $refs -Force
    $ru | Add-Member -NotePropertyName controlsLayout -NotePropertyValue "popupScreen" -Force
    $json = $ru | ConvertTo-Json -Depth 12
    if ($refs.Count -eq 1) { $json = $json -replace '"inputControls":\s*\{', '"inputControls": [{' -replace '(\}\s*),\s*"controlsLayout"', '$1],"controlsLayout"' }
    Put-Json $ReportUri "application/repository.reportUnit+json" $json
}
```

Note on the last `if`: PowerShell 5.1 `ConvertTo-Json` unwraps a one-element array into an object; the two regexes restore the array. Test both branches in Step 2.

- [ ] **Step 2: Run it against STAGE and check**

```powershell
$env:JRS_ENV = "stage"
. .\scripts\pos_perf\jrs_controls.ps1
New-FinanceControls
$jrs = Resolve-JrsConfig -Env stage
(Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/controls/p_franchisee").Body
(Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/controls/p_version_lov").Body
```

Expected: twelve `OK:` lines; the GET bodies show `"type":7` with `valueColumn":"franchisee_id"` and a two-item LOV. Then attach a single control to the smoke report and read it back:

```powershell
Attach-Controls -ReportUri /reports/pos_perf/smoke_kpi -ControlUris @("/reports/pos_perf/controls/p_asof")
(Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/smoke_kpi").Body | Select-String inputControls
```

Expected: `"inputControls":[{"inputControlReference":{"uri":"/reports/pos_perf/controls/p_asof"...`. If the single-element regex did not fire, fix the pattern before continuing (the server answers 400 "ArrayList from String value" when it is wrong).

- [ ] **Step 3: Commit**

```powershell
git add scripts/pos_perf/jrs_controls.ps1
git commit -m "feat(pos-perf): shared finance input controls + Attach-Controls helper"
```

---

### Task 5: Dashboard 4 - Store Profit and Budget (cockpit, STAGE)

**Files:**
- Create: `report/pos_perf/pnl_kpi_strip.jrxml`, `pnl_waterfall.jrxml`, `pnl_variance_region.jrxml`, `pnl_contribution_trend.jrxml`, `pnl_worst_stores.jrxml`
- Create: `report/pos_perf/pnl_dashboard.json`

**Interfaces:**
- Consumes: `store_pnl_monthly`, `store_budget_vs_actual`, `store_budget_monthly`, `sales_targets` (columns per Global Constraints and the schema notes in Task 3 of the spec); template `report/pos_perf/smoke_kpi.jrxml`; KPI cell styling from `ops_kpi_chips.jrxml`.
- Produces: dashboard `/reports/pos_perf/pos_store_pnl` label "POS Store Profit and Budget"; `pnl_worst_stores` rows hyperlink to `/reports/pos_perf/rpt_store_pnl_statement` (Task 8) passing `p_store` and `p_yyyymm`.

- [ ] **Step 1: pnl_kpi_strip (1600x130, no parameters).** Five cells at x = 10, 326, 642, 958, 1274 (width 300, dividers `#D6E0EF` at x=316/632/948/1264 as in ops_kpi_chips). Query:

```sql
SELECT DECIMAL(SUM(p.net_sales), 14, 2) AS net_sales,
       DECIMAL(100.0 * FLOAT8(SUM(p.net_sales)) / FLOAT8(NULLIF(SUM(t.target_sales), 0)), 6, 2) AS plan_attainment_pct,
       DECIMAL(100.0 * FLOAT8(SUM(p.gross_margin)) / FLOAT8(NULLIF(SUM(p.net_sales), 0)), 6, 2) AS gm_pct,
       DECIMAL(SUM(p.four_wall_ebitda), 14, 2) AS four_wall_ebitda,
       DECIMAL(100.0 * FLOAT8(SUM(b.actual_four_wall_ebitda) - SUM(b.budget_four_wall_ebitda)) / FLOAT8(NULLIF(SUM(b.budget_four_wall_ebitda), 0)), 6, 2) AS ebitda_var_vs_budget_pct,
       DECIMAL(100.0 * FLOAT8(SUM(p.labour_cost + p.labour_burden)) / FLOAT8(NULLIF(SUM(p.net_sales), 0)), 6, 2) AS labour_pct,
       (SELECT COUNT(*) FROM (SELECT storenumber FROM store_pnl_monthly WHERE yr = 2020 AND trading_status = 'Trading' GROUP BY storenumber HAVING SUM(four_wall_ebitda) < 0) x) AS loss_stores
FROM store_pnl_monthly p
LEFT JOIN sales_targets t ON t.storenumber = p.storenumber AND t.yyyymm = p.yyyymm
LEFT JOIN store_budget_vs_actual b ON b.storenumber = p.storenumber AND b.yyyymm = p.yyyymm AND b.budget_version = 'Original'
WHERE p.yr = 2020
```

Fields: `net_sales`, `four_wall_ebitda` BigDecimal `pattern="$#,##0"`; `plan_attainment_pct`, `gm_pct`, `ebitda_var_vs_budget_pct`, `labour_pct` BigDecimal `pattern="#,##0.0'%'"`; `loss_stores` Long. Labels: "Net Sales 2020", "Plan Attainment", "Gross Margin", "Four-Wall EBITDA 2020", "Labour % of Sales", with a 9pt `#5B7DA6` sub-line under EBITDA showing `"vs budget " + ($F{ebitda_var_vs_budget_pct} >= 0 ? "+" : "") + $F{ebitda_var_vs_budget_pct} + "%"` and under Loss stores "stores with negative 2020 EBITDA". Sub-line and value `forecolor` for the variance: `$F{ebitda_var_vs_budget_pct} >= 0 ? "#5CB85C" : "#D9534F"` via `<propertyExpression name="net.sf.jasperreports.style.forecolor">` is not JR7-valid; use two overlapping textFields with `<printWhenExpression>` (one green, one red). Expected values: net sales 416.5M, attainment about 100.2, GM about 31.7, EBITDA variance about +13 (Original budget was blind to the pandemic), labour about 10.4, loss stores between 30 and 60.

- [ ] **Step 2: pnl_waterfall (1000x440) as JFreeChart stacked bar.** The waterfall is a `stackedBar` with an invisible base series. Query returns the seven steps with running base:

```sql
SELECT step_order, step_label, DECIMAL(base_amt, 14, 2) AS base_amt, DECIMAL(bar_amt, 14, 2) AS bar_amt, bar_kind FROM (
  SELECT 1 AS step_order, 'Net sales' AS step_label, 0 AS base_amt, SUM(net_sales) AS bar_amt, 'total' AS bar_kind FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 2, 'COGS', SUM(net_sales) - SUM(cogs), SUM(cogs), 'down' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 3, 'Shrink', SUM(gross_margin) - SUM(shrinkage_cost), SUM(shrinkage_cost), 'down' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 4, 'Labour', SUM(gross_margin) - SUM(shrinkage_cost) - SUM(labour_cost + labour_burden), SUM(labour_cost + labour_burden), 'down' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 5, 'Occupancy + utilities', SUM(gross_margin) - SUM(shrinkage_cost) - SUM(labour_cost + labour_burden) - SUM(occupancy_cost + utilities_cost), SUM(occupancy_cost + utilities_cost), 'down' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 6, 'Other opex', SUM(four_wall_ebitda) - SUM(promo_subsidy_income), SUM(delivery_partner_cost + card_processing_fees + other_opex), 'down' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 7, 'Promo subsidy', SUM(four_wall_ebitda) - SUM(promo_subsidy_income), SUM(promo_subsidy_income), 'up' FROM store_pnl_monthly WHERE yr = 2020
  UNION ALL SELECT 8, 'Four-wall EBITDA', 0, SUM(four_wall_ebitda), 'total' FROM store_pnl_monthly WHERE yr = 2020
) w ORDER BY step_order
```

Chart element (title band, `evaluationTime="Report"`), three value series so colour follows kind; the base series is white-on-white with no border:

```xml
<element kind="chart" chartType="stackedBar" x="0" y="60" width="960" height="340" evaluationTime="Report">
  <dataset kind="category">
    <series>
      <seriesExpression><![CDATA["base"]]></seriesExpression>
      <categoryExpression><![CDATA[$F{step_label}]]></categoryExpression>
      <valueExpression><![CDATA[$F{base_amt}]]></valueExpression>
    </series>
    <series>
      <seriesExpression><![CDATA["Total"]]></seriesExpression>
      <categoryExpression><![CDATA[$F{step_label}]]></categoryExpression>
      <valueExpression><![CDATA["total".equals($F{bar_kind}) ? $F{bar_amt} : java.math.BigDecimal.ZERO]]></valueExpression>
    </series>
    <series>
      <seriesExpression><![CDATA["Cost"]]></seriesExpression>
      <categoryExpression><![CDATA[$F{step_label}]]></categoryExpression>
      <valueExpression><![CDATA["down".equals($F{bar_kind}) ? $F{bar_amt} : java.math.BigDecimal.ZERO]]></valueExpression>
    </series>
    <series>
      <seriesExpression><![CDATA["Income"]]></seriesExpression>
      <categoryExpression><![CDATA[$F{step_label}]]></categoryExpression>
      <valueExpression><![CDATA["up".equals($F{bar_kind}) ? $F{bar_amt} : java.math.BigDecimal.ZERO]]></valueExpression>
    </series>
  </dataset>
  <plot showTickMarks="true" showTickLabels="true" showLabels="false">
    <seriesColor order="0" color="#FFFFFF"/>
    <seriesColor order="1" color="#0550DC"/>
    <seriesColor order="2" color="#239CA8"/>
    <seriesColor order="3" color="#1DB6C0"/>
  </plot>
</element>
```

Hide the legend (`showLegend="false"` on the element) and add a 9pt caption line under the title: "2020, all stores, CAD. Cost steps in teal, income in light teal." Sanity: the last bar top equals net sales minus all costs plus subsidy; check numerically in the query output that `base_amt + bar_amt` of step 7 equals step 8 `bar_amt`.

- [ ] **Step 3: pnl_variance_region (800x440) diverging bars.** JFreeChart `bar` with two series so sign selects colour:

```sql
SELECT region, DECIMAL(SUM(actual_four_wall_ebitda) - SUM(budget_four_wall_ebitda), 14, 2) AS variance_cad
FROM store_budget_vs_actual WHERE yr = 2020 AND budget_version = 'Original'
GROUP BY region ORDER BY 2 DESC
```

Series "Favourable" value `$F{variance_cad}.signum() >= 0 ? $F{variance_cad} : null`, colour `#0550DC`; series "Unfavourable" value `$F{variance_cad}.signum() < 0 ? $F{variance_cad} : null`, colour `#239CA8`; `showLabels="true"`, legend on. Title "Four-wall EBITDA vs Original budget by region, 2020 (CAD)". Expected: all four regions favourable (2020 beat the pandemic-blind budget by about 13 pct); the tile still works if a region flips sign.

- [ ] **Step 4: pnl_contribution_trend (1000x440) three lines.**

```sql
SELECT p.yyyymm, CAST(p.yyyymm AS VARCHAR(6)) AS ym,
       DECIMAL(100.0 * FLOAT8(SUM(p.store_contribution)) / FLOAT8(NULLIF(SUM(p.net_sales), 0)), 6, 2) AS actual_pct,
       DECIMAL(100.0 * FLOAT8(SUM(o.budget_store_contribution)) / FLOAT8(NULLIF(SUM(o.budget_net_sales), 0)), 6, 2) AS original_pct,
       DECIMAL(100.0 * FLOAT8(SUM(r.budget_store_contribution)) / FLOAT8(NULLIF(SUM(r.budget_net_sales), 0)), 6, 2) AS reforecast_pct
FROM store_pnl_monthly p
LEFT JOIN store_budget_monthly o ON o.storenumber = p.storenumber AND o.yyyymm = p.yyyymm AND o.budget_version = 'Original'
LEFT JOIN store_budget_monthly r ON r.storenumber = p.storenumber AND r.yyyymm = p.yyyymm AND r.budget_version = 'Reforecast Q2 2020'
WHERE p.trading_status = 'Trading'
GROUP BY p.yyyymm ORDER BY p.yyyymm
```

`chartType="line"`, three series "Actual" `#0550DC`, "Original budget" `#1DB6C0`, "Reforecast" `#0A4CAD`, category `$F{ym}`, labels rotated -45 (`<plot labelRotation="-45.0" ...>` per `exec_trend.jrxml`), legend on. The reforecast series is null before 202004; JFreeChart leaves the gap, which is the intended reading.

- [ ] **Step 5: pnl_worst_stores (800x440) ranked list with drill.**

```sql
SELECT FIRST 6 storenumber, storename, store_format, region,
       DECIMAL(100.0 * FLOAT8(SUM(four_wall_ebitda)) / FLOAT8(NULLIF(SUM(net_sales), 0)), 6, 2) AS fw_margin_pct,
       DECIMAL(SUM(net_sales), 14, 2) AS net_sales
FROM store_pnl_monthly WHERE yr = 2020 AND trading_status = 'Trading'
GROUP BY storenumber, storename, store_format, region ORDER BY fw_margin_pct ASC
```

Layout as `exec_top_stores.jrxml` (rank via `$V{REPORT_COUNT}`, header row `#1F4E79`/white, columns Store, Format, Region, Net Sales `$#,##0`, Four-wall %). On the store-name textField add the drill: `linkType="ReportExecution" linkTarget="Blank"` with `<hyperlinkParameter name="_report"><expression><![CDATA["/reports/pos_perf/rpt_store_pnl_statement"]]></expression></hyperlinkParameter>`, `<hyperlinkParameter name="p_store"><expression><![CDATA[$F{storenumber}]]></expression></hyperlinkParameter>`, `<hyperlinkParameter name="p_yyyymm"><expression><![CDATA["202012"]]></expression></hyperlinkParameter>`. Confirm the exact JR7 attribute names in `.claude/skills/jasper-deploy/references/jr7-valid-elements.md` (search "hyperlink"); `lint_jrxml.ps1` rejects a wrong one. Until Task 8 deploys the target, the link 404s; that is expected.

- [ ] **Step 6: Lint, compile, deploy, run all five**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
foreach ($r in "pnl_kpi_strip","pnl_waterfall","pnl_variance_region","pnl_contribution_trend","pnl_worst_stores") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$r.jrxml"
  & "$jd\compile_jrxml.ps1" -Jrxml "report\pos_perf\$r.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$r.jrxml" -TargetUri "/reports/pos_perf/$r" -Label $r -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$r" -Format pdf -OutFile "out\pos_perf\$r.pdf"
  python -c "import pypdfium2 as p; p.PdfDocument(r'out\pos_perf\$r.pdf')[0].render(scale=2).to_pil().save(r'out\pos_perf\$r.png')"
}
```

Look at each PNG: KPI values match the acceptance references; waterfall ends at a positive EBITDA bar; four region bars; three lines with the reforecast starting 2020-04; six rows with negative margins.

- [ ] **Step 7: Manifest and compose**

`report/pos_perf/pnl_dashboard.json`:
```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_store_pnl",
  "label": "POS Store Profit and Budget",
  "dashlets": [
    { "resource": "/reports/pos_perf/pnl_kpi_strip",          "label": "Key Metrics",                "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/pnl_waterfall",          "label": "Net Sales to EBITDA",        "showTitleBar": false, "x": 0,  "y": 4,  "width": 22, "height": 12 },
    { "resource": "/reports/pos_perf/pnl_variance_region",    "label": "Variance vs Budget",         "showTitleBar": false, "x": 22, "y": 4,  "width": 18, "height": 12 },
    { "resource": "/reports/pos_perf/pnl_contribution_trend", "label": "Contribution Margin Trend",  "showTitleBar": false, "x": 0,  "y": 16, "width": 20, "height": 12 },
    { "resource": "/reports/pos_perf/pnl_worst_stores",       "label": "Lowest Four-Wall Margin",    "showTitleBar": false, "x": 20, "y": 16, "width": 20, "height": 12 }
  ]
}
```

```powershell
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\pnl_dashboard.json
```

Open `http://localhost:8081/jasperserver-pro/dashboard/viewer.html#%2Freports%2Fpos_perf%2Fpos_store_pnl`; all five tiles render, none blank.

- [ ] **Step 8: Commit**

```powershell
git add report/pos_perf/pnl_*.jrxml report/pos_perf/pnl_dashboard.json
git commit -m "feat(pos-perf): Store Profit and Budget cockpit (STAGE)"
```

---

### Task 6: Dashboard 5 - Franchise Treasury (console, STAGE)

**Files:**
- Create: `report/pos_perf/trs_kpi.jrxml`, `trs_ar_aging.jrxml`, `trs_dpo.jrxml`, `trs_tender_mix.jrxml`, `trs_tax_province.jrxml`, `trs_liability.jrxml`, `trs_lease_expiry.jrxml`
- Create: `report/pos_perf/trs_dashboard.json`

**Interfaces:**
- Consumes: `franchise_fee_ledger`, `ap_invoices`, `dash_tender_monthly` (Task 3), `tax_collected_monthly`, `gift_card_liability_monthly`, `loyalty_liability_monthly`, `store_assets`; controls `p_asof`, `p_regions`, `p_franchisee` (Task 4); spike verdict (Task 2).
- Produces: dashboard `/reports/pos_perf/pos_treasury` label "POS Franchise Treasury"; each tile carries the same three parameters.

- [ ] **Step 1: Parameter block for all seven JRXMLs** (copy verbatim into each; `p_asof` is a yyyymm string from the LOV):

```xml
<parameter name="p_asof" class="java.lang.String">
  <defaultValueExpression><![CDATA["202012"]]></defaultValueExpression>
</parameter>
<parameter name="p_regions" class="java.util.Collection"/>
<parameter name="p_franchisee" class="java.util.Collection"/>
```

Every query uses the same WHERE fragment on tables that have both columns: `yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions} AND $X{IN, franchisee_id, p_franchisee}`; `ap_invoices` has no franchisee column (drop that clause, use `invoice_yyyymm`); tender, tax, liability and assets tiles use only the clauses whose columns exist (liability tables: `yyyymm` only). Balances are "as of" the ledger date 2020-12-31; `p_asof` is an invoice-month cutoff. Say so in each tile subtitle: "Ledger as of 2020-12-31, invoices through <month>".

- [ ] **Step 2: trs_kpi (1600x130, five chips)**

```sql
SELECT (SELECT DECIMAL(SUM(balance), 14, 2) FROM franchise_fee_ledger WHERE status <> 'Paid' AND yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions} AND $X{IN, franchisee_id, p_franchisee}) AS ar_balance,
       (SELECT DECIMAL(SUM(balance), 14, 2) FROM franchise_fee_ledger WHERE aging_bucket = '60+ days' AND yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions} AND $X{IN, franchisee_id, p_franchisee}) AS ar_aged_60,
       (SELECT DECIMAL(SUM(balance), 14, 2) FROM ap_invoices WHERE status <> 'Paid' AND invoice_yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}) AS ap_balance,
       (SELECT DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN payer_profile IN ('Early','On time') THEN 1 ELSE 0 END)) / FLOAT8(COUNT(*)), 6, 1) FROM ap_invoices WHERE status = 'Paid' AND invoice_yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}) AS ap_on_time_pct,
       (SELECT DECIMAL(100.0 * FLOAT8(SUM(CASE WHEN tender_group <> 'Cash' THEN amount ELSE 0 END)) / FLOAT8(NULLIF(SUM(amount), 0)), 6, 1) FROM dash_tender_monthly WHERE yyyymm = INT4($P{p_asof}) AND $X{IN, region, p_regions}) AS cashless_pct,
       (SELECT DECIMAL(SUM(total_tax_collected), 14, 2) FROM tax_collected_monthly WHERE yr = INT4($P{p_asof}) / 100 AND yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}) AS tax_ytd,
       (SELECT DECIMAL(g.closing_liability + l.closing_liability_cad, 14, 2) FROM gift_card_liability_monthly g, loyalty_liability_monthly l WHERE g.yyyymm = INT4($P{p_asof}) AND l.yyyymm = INT4($P{p_asof})) AS liability_total
```

Chips: "AR Outstanding" `$#,##0` sub-line `"$" + aged_60 + " aged 60+"`; "AP Outstanding" sub-line `on_time_pct + "% paid on time"`; "Cashless Share" `#,##0.0'%'`; "Tax Collected YTD"; "Gift + Loyalty Liability". Defaults expected: AR 5.4M / 1.27M, AP 30.4M / 80, cashless 89.9 for 202012, tax 2020 about 15M (28.1M is lifetime), liability 9.06M.

- [ ] **Step 3: The six charts.** All `600x420`, title band with the parameter block above, charts `evaluationTime="Report"`, series colours in the fixed order.

trs_ar_aging (`bar`, one series `#0550DC`, showLabels):
```sql
SELECT aging_bucket, DECIMAL(SUM(balance), 14, 2) AS balance,
       CASE aging_bucket WHEN 'Current' THEN 1 WHEN '1-30 days' THEN 2 WHEN '31-60 days' THEN 3 ELSE 4 END AS ord
FROM franchise_fee_ledger WHERE status <> 'Paid' AND yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions} AND $X{IN, franchisee_id, p_franchisee}
GROUP BY aging_bucket ORDER BY ord
```

trs_dpo (`bar`, `<plot orientation="Horizontal" ...>`, one series):
```sql
SELECT payment_terms, DECIMAL(AVG(FLOAT8(days_to_pay)), 6, 1) AS dpo_days
FROM ap_invoices WHERE status = 'Paid' AND invoice_yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}
GROUP BY payment_terms ORDER BY payment_terms
```
Expected 26.2 / 39.6 / 52.9 at defaults.

trs_tender_mix (`stackedBar`, four series Cash `#0550DC`, Card `#1DB6C0`, Stored Value `#0A4CAD`; percent computed in SQL so the bars are 100 pct):
```sql
SELECT yyyymm, CAST(yyyymm AS VARCHAR(6)) AS ym, tender_group,
       DECIMAL(100.0 * FLOAT8(SUM(amount)) / FLOAT8(NULLIF((SELECT SUM(amount) FROM dash_tender_monthly i WHERE i.yyyymm = o.yyyymm AND $X{IN, region, p_regions}), 0)), 6, 2) AS share_pct
FROM dash_tender_monthly o WHERE yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}
GROUP BY yyyymm, tender_group ORDER BY yyyymm, tender_group
```
Series expression `$F{tender_group}`, category `$F{ym}`, value `$F{share_pct}`, labels rotated -45. Expected: Cash share steps from about 22 to 10 at 202003.

trs_tax_province (`bar` horizontal, one series):
```sql
SELECT province, DECIMAL(SUM(total_tax_collected), 14, 2) AS tax_collected
FROM tax_collected_monthly WHERE yr = INT4($P{p_asof}) / 100 AND yyyymm <= INT4($P{p_asof}) AND $X{IN, region, p_regions}
GROUP BY province ORDER BY 2 DESC
```

trs_liability (`line`, two series Gift cards `#0550DC`, Loyalty `#1DB6C0`):
```sql
SELECT g.yyyymm, CAST(g.yyyymm AS VARCHAR(6)) AS ym, g.closing_liability AS gift_liability, l.closing_liability_cad AS loyalty_liability
FROM gift_card_liability_monthly g JOIN loyalty_liability_monthly l ON l.yyyymm = g.yyyymm
WHERE g.yyyymm <= INT4($P{p_asof}) ORDER BY g.yyyymm
```
Expected end points 1,694,634.25 and 7.37M. Region and franchisee controls do not apply to this tile; say "network" in its subtitle.

trs_lease_expiry (`bar`, one series, showLabels):
```sql
SELECT YEAR(lease_expiry) AS expiry_year, COUNT(*) AS stores
FROM store_assets WHERE $X{IN, region, p_regions} AND $X{IN, franchisee_id, p_franchisee}
GROUP BY YEAR(lease_expiry) ORDER BY 1
```
Expected: 2024 = 169 at defaults, a second cluster at 2028.

- [ ] **Step 4: Deploy the seven, attach controls, run each with and without filters**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\jrs_controls.ps1
$ctl = @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
foreach ($r in "trs_kpi","trs_ar_aging","trs_dpo","trs_tender_mix","trs_tax_province","trs_liability","trs_lease_expiry") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$r.jrxml"
  & "$jd\compile_jrxml.ps1" -Jrxml "report\pos_perf\$r.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$r.jrxml" -TargetUri "/reports/pos_perf/$r" -Label $r -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
  Attach-Controls -ReportUri "/reports/pos_perf/$r" -ControlUris $ctl
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$r" -Format pdf -OutFile "out\pos_perf\$r.pdf"
  python -c "import pypdfium2 as p; p.PdfDocument(r'out\pos_perf\$r.pdf')[0].render(scale=2).to_pil().save(r'out\pos_perf\$r.png')"
}
```

Then one filtered run through the REST report-execution URL (`run_report_async.ps1` accepts `-Params @{ p_asof = "202006"; p_regions = "Ontario" }` if the script exposes it; otherwise call `$jrs.ServerUrl/rest_v2/reports/reports/pos_perf/trs_kpi.pdf?p_asof=202006&p_regions=Ontario` with `curl.exe -u` using the config creds). Expected: AR and tax numbers shrink; cashless for 202006 near 89.

- [ ] **Step 5: Manifest and compose.** Read `.superpowers/sdd/2026-08-23-pos-suite/spike-filter-report.md`. If verdict `CONTROL_STRIP`:

```json
{
  "folder": "/reports/pos_perf",
  "name": "pos_treasury",
  "label": "POS Franchise Treasury",
  "filters": ["p_asof", "p_regions", "p_franchisee"],
  "dashlets": [
    { "resource": "/reports/pos_perf/trs_kpi",          "label": "Key Metrics",                "showTitleBar": false, "x": 0,  "y": 0,  "width": 40, "height": 4 },
    { "resource": "/reports/pos_perf/trs_ar_aging",     "label": "Receivables Aging",          "showTitleBar": false, "x": 0,  "y": 4,  "width": 13, "height": 11 },
    { "resource": "/reports/pos_perf/trs_dpo",          "label": "Days to Pay by Terms",       "showTitleBar": false, "x": 13, "y": 4,  "width": 13, "height": 11 },
    { "resource": "/reports/pos_perf/trs_tender_mix",   "label": "Tender Mix",                 "showTitleBar": false, "x": 26, "y": 4,  "width": 14, "height": 11 },
    { "resource": "/reports/pos_perf/trs_tax_province", "label": "Tax Collected by Province",  "showTitleBar": false, "x": 0,  "y": 15, "width": 13, "height": 12 },
    { "resource": "/reports/pos_perf/trs_liability",    "label": "Gift Card and Loyalty Liability", "showTitleBar": false, "x": 13, "y": 15, "width": 13, "height": 12 },
    { "resource": "/reports/pos_perf/trs_lease_expiry", "label": "Lease Expiries",             "showTitleBar": false, "x": 26, "y": 15, "width": 14, "height": 12 }
  ]
}
```

(gen_dashboard.py shifts every tile down 3 rows for the strip.) If verdict `FALLBACK_POPUPS`: drop the `filters` key, add `"dashletFilterShowPopup": true`.

```powershell
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\trs_dashboard.json
```

Open the viewer for `pos_treasury`; set Regions = Quebec, Apply (strip) or via the KPI tile popup (fallback); AR balance drops to a fraction of 5.4M.

- [ ] **Step 6: Commit**

```powershell
git add report/pos_perf/trs_*.jrxml report/pos_perf/trs_dashboard.json
git commit -m "feat(pos-perf): Franchise Treasury console (STAGE)"
```

---

### Task 7: Navy re-skin of Executive Overview and Promo Story

**Files:**
- Modify: `report/pos_perf/exec_kpi_strip.jrxml`, `exec_last_updated.jrxml`, `exec_map.jrxml`, `exec_margin_dial.jrxml`, `exec_promo_mix.jrxml`, `exec_region_bar.jrxml`, `exec_top_stores.jrxml`, `exec_trend.jrxml`, `exec_yoy_dial.jrxml`, `story_hero.jrxml`, `story_trend.jrxml`, `story_cards.jrxml`

**Interfaces:**
- Consumes: the light versions (kept in git history; tag the pre-change commit `pos-perf-light-v1` first).
- Produces: the same twelve report units on STAGE in navy; no layout or query changes; dashboards 1 and 3 recomposed.

- [ ] **Step 1: Tag the light baseline**

```powershell
git tag pos-perf-light-v1
```

- [ ] **Step 2: Add a page background to every file.** Directly after the `<query>` / `<field>` block and before `<title>`, insert (height = pageHeight of that file):

```xml
<background height="422">
  <element kind="rectangle" x="0" y="0" width="950" height="422" mode="Opaque" backcolor="#000032" forecolor="#000032"/>
</background>
```

Adjust width/height to each file's page size (`exec_map` 842x596; dials 400x260; region bar 950x422; promo mix 950x300; trend 1000x220; top stores 800x214; KPI strip 1600x130; last_updated 600x96; story_hero already has a full-band rectangle, skip it; story_trend 1600x420; story_cards 1600x300). Widths must cover the margins: use pageWidth and set `x` to `-leftMargin` (for margin 20: `x="-20" width="950"`); lint will flag negative x if the schema forbids it, in which case set `leftMargin="0"`/`rightMargin="0"` and widen `columnWidth` to `pageWidth` as `story_hero.jrxml` does.

- [ ] **Step 3: Recolour text and series with sed-style replacements** (PowerShell, per file):

```powershell
$files = Get-ChildItem report\pos_perf\exec_*.jrxml, report\pos_perf\story_*.jrxml
foreach ($f in $files) {
  $t = Get-Content $f.FullName -Raw
  $t = $t -replace 'forecolor="#1F4E79"', 'forecolor="#FFFFFF"'
  $t = $t -replace 'forecolor="#5B7DA6"', 'forecolor="#8AC6F8"'
  $t = $t -replace 'forecolor="#34495E"', 'forecolor="#8AC6F8"'
  $t = $t -replace 'forecolor="#000000"', 'forecolor="#FFFFFF"'
  $t = $t -replace 'forecolor="#666666"', 'forecolor="#8AC6F8"'
  $t = $t -replace 'forecolor="#D6E0EF"', 'forecolor="#26305A"'
  $t = $t -replace 'color="#0550DC"', 'color="#3C91FF"'
  $t = $t -replace 'color="#1DB6C0"', 'color="#2EC0CB"'
  $t = $t -replace 'color="#0A4CAD"', 'color="#71B7F4"'
  $t = $t -replace 'color="#239CA8"', 'color="#239CA8"'
  Set-Content $f.FullName $t -Encoding utf8
}
```

Then by hand: table header rows in `exec_top_stores` (`backcolor="#1F4E79"` becomes `#26305A`, zebra `#D6E0EF` becomes `#0B1230`); the map's sequential ramp in `exec_map` becomes `#1B2C52`, `#2E5BA8`, `#3C91FF`, `#8AC6F8` and its label colour stays white; dial ranges unchanged; any `stackedBar`/`line` plot whose series includes teal gets `showLabels="true"`. Chart plot background: add `backcolor="#000032"` on the chart element and `<plot backcolor="#000032" ...>` so JFreeChart does not paint a white plot area; axis label colour via `<categoryAxisLabelColor>`-style attributes is not JR7-valid, so keep axis text default and confirm legibility in the PNG (JFreeChart draws axis text black; if unreadable, set `showTickLabels="false"` on dials/trend and rely on direct labels).

- [ ] **Step 4: Lint, deploy, run, compare side by side**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
$labels = @{ exec_kpi_strip="Key Metrics"; exec_last_updated="Last Refreshed"; exec_map="Net Sales by Province"; exec_margin_dial="Gross Margin"; exec_promo_mix="Promotion Mix"; exec_region_bar="Net Sales by Region"; exec_top_stores="Top Stores"; exec_trend="Net Sales Trend"; exec_yoy_dial="YoY Growth"; story_hero="Promo and Margin Story"; story_trend="Margin Trend"; story_cards="Decision Cards" }
foreach ($r in $labels.Keys) {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$r.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$r.jrxml" -TargetUri "/reports/pos_perf/$r" -Label $labels[$r] -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$r" -Format pdf -OutFile "out\pos_perf\navy_$r.pdf"
  python -c "import pypdfium2 as p; p.PdfDocument(r'out\pos_perf\navy_$r.pdf')[0].render(scale=2).to_pil().save(r'out\pos_perf\navy_$r.png')"
}
```

Check every PNG: navy ground edge to edge (no white margin strip), white titles, teal series labelled, dials readable. Build the side-by-side: `python -c` with Pillow to paste the light PNG from `git show pos-perf-light-v1` renders (or the PNGs already in `out/pos_perf/`) next to the navy one into `out\pos_perf\navy_compare.png`.

- [ ] **Step 5: Recompose dashboards 1 and 3**

```powershell
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_executive_overview
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\exec_dashboard.json
& "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_promo_story
& "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\story_dashboard.json
```

The dashboard canvas itself stays white between tiles (`canvasColor` in `gen_dashboard.py` `DashboardProperties`); add a manifest key `"canvasColor": "#000032"` and pass it through `build_components` (`props["canvasColor"] = m.get("canvasColor", "#ffffff")`) so the gutters match. Include that one-line change in this task.

- [ ] **Step 6: Commit**

```powershell
git add report/pos_perf/exec_*.jrxml report/pos_perf/story_*.jrxml report/pos_perf/exec_dashboard.json report/pos_perf/story_dashboard.json .claude/skills/jasper-deploy/scripts/gen_dashboard.py
git commit -m "feat(pos-perf): navy theme for Executive Overview and Promo Story"
```

---

### Task 8: Report - Store P&L Statement (Statement pattern, drill target)

**Files:**
- Create: `report/pos_perf/rpt_store_pnl_statement.jrxml`

**Interfaces:**
- Consumes: `store_pnl_monthly`, `store_budget_vs_actual`; controls `p_store` (type 4 query), `p_yyyymm`, `p_version` (Task 4).
- Produces: `/reports/pos_perf/rpt_store_pnl_statement` label "Store P and L Statement"; parameters `p_store` (String), `p_yyyymm` (String), `p_version` (String, default `Original`). Task 5's list links here.

- [ ] **Step 1: Parameters and queries.** A4 landscape (`pageWidth="842" pageHeight="595"` margins 30). Parameters:

```xml
<parameter name="p_store" class="java.lang.String"><defaultValueExpression><![CDATA["1017"]]></defaultValueExpression></parameter>
<parameter name="p_yyyymm" class="java.lang.String"><defaultValueExpression><![CDATA["202012"]]></defaultValueExpression></parameter>
<parameter name="p_version" class="java.lang.String"><defaultValueExpression><![CDATA["Original"]]></defaultValueExpression></parameter>
```

Check the real default store number first (`SELECT MIN(storenumber) FROM stores`) and use it. Main query, one row per P&L line in statement order:

```sql
SELECT line_order, line_label, DECIMAL(actual_amt, 14, 2) AS actual_amt, DECIMAL(budget_amt, 14, 2) AS budget_amt,
       DECIMAL(actual_amt - budget_amt, 14, 2) AS variance_amt,
       DECIMAL(100.0 * FLOAT8(actual_amt - budget_amt) / FLOAT8(NULLIF(budget_amt, 0)), 8, 1) AS variance_pct, is_total
FROM (
  SELECT 1 AS line_order, 'Net sales' AS line_label, actual_net_sales AS actual_amt, budget_net_sales AS budget_amt, 0 AS is_total FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 2, 'Cost of goods sold', -(actual_net_sales - actual_gross_margin), -(budget_net_sales - budget_gross_margin), 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 3, 'Gross margin', actual_gross_margin, budget_gross_margin, 1 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 4, 'Labour (loaded)', -actual_labour_cost, -budget_labour_cost, 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 5, 'Occupancy', -actual_occupancy_cost, -budget_occupancy_cost, 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 6, 'Utilities', -actual_utilities_cost, -budget_utilities_cost, 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 7, 'Shrinkage', -actual_shrinkage_cost, -budget_shrinkage_cost, 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 8, 'Other store opex', -(actual_total_store_opex - actual_labour_cost - actual_occupancy_cost - actual_utilities_cost - actual_shrinkage_cost), -(budget_total_store_opex - budget_labour_cost - budget_occupancy_cost - budget_utilities_cost - budget_shrinkage_cost), 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 9, 'Four-wall EBITDA', actual_four_wall_ebitda, budget_four_wall_ebitda, 1 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 10, 'Franchise fees', -actual_franchise_fees, -budget_franchise_fees, 0 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
  UNION ALL SELECT 11, 'Store contribution', actual_store_contribution, budget_store_contribution, 1 FROM store_budget_vs_actual WHERE storenumber = INT4($P{p_store}) AND yyyymm = INT4($P{p_yyyymm}) AND budget_version = $P{p_version}
) s ORDER BY line_order
```

Note `actual_labour_cost` in `store_budget_vs_actual` is the loaded figure (labour + burden) as built; confirm with `SELECT actual_labour_cost, (SELECT labour_cost + labour_burden FROM store_pnl_monthly p WHERE p.storenumber = b.storenumber AND p.yyyymm = b.yyyymm) FROM store_budget_vs_actual b WHERE storenumber = 1017 AND yyyymm = 202012 AND budget_version = 'Original'` before relying on line 4. Costs are negative so the variance sign is always favourable-positive.

- [ ] **Step 2: Layout.** Title band: logo, centered "Store P and L Statement", subtitle `$P{p_store} + " " + storename + " - " + month + " - vs " + $P{p_version}` (fetch storename with a second field via a subquery column `(SELECT storename FROM stores WHERE storenumber = INT4($P{p_store})) AS storename` on every row). Column header band: Line | Actual | Budget | Variance | Var % | (bar). Detail band 18px: label bold when `$F{is_total} == 1`, amounts `$#,##0;($#,##0)`, variance forecolor by sign via two overlapping textFields with `printWhenExpression`, and an inline bar: a `rectangle` whose width expression is `(int) Math.min(120, Math.abs($F{variance_pct}.doubleValue()) * 2)` anchored at x=620 (JR7 supports `<propertyExpression>` for width? It does not; instead draw the bar with a `textField` of repeated block characters is ugly. Use a tiny `bar` chart per row is heavy. Chosen approach: a rectangle of fixed 120 width in `#D6E0EF` behind, and a foreground rectangle whose width is set with `<property name="net.sf.jasperreports.export.pdf.tag.td"/>`... not available either). Final choice: render the inline bar as a one-series horizontal `bar` chart in the **summary** band listing all lines (variance pct by line, `#0550DC`/`#239CA8` sign split as in Task 5 Step 3) to the right of the table, 300x260, instead of per-row rectangles. Summary band also carries the 12-month EBITDA strip: second dataset via `<subDataset>` is JR7-valid; query `SELECT yyyymm, CAST(yyyymm AS VARCHAR(6)) AS ym, four_wall_ebitda FROM store_pnl_monthly WHERE storenumber = INT4($P{p_store}) AND yyyymm BETWEEN INT4($P{p_yyyymm}) - 100 AND INT4($P{p_yyyymm}) ORDER BY yyyymm` as a `line` chart 500x160 with `<datasetRun>` passing `p_store`, `p_yyyymm`. Rank chips: a textField `"#" + rank + " of " + n + " in region on four-wall margin"` from a third scalar subquery column in the main query: `(SELECT COUNT(*) + 1 FROM store_pnl_monthly q WHERE q.yyyymm = INT4($P{p_yyyymm}) AND q.region = (SELECT region FROM stores WHERE storenumber = INT4($P{p_store})) AND q.four_wall_margin_pct > (SELECT four_wall_margin_pct FROM store_pnl_monthly r WHERE r.storenumber = INT4($P{p_store}) AND r.yyyymm = INT4($P{p_yyyymm}))) AS region_rank`.

- [ ] **Step 3: Deploy with controls, run default and one drill parameter set**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\jrs_controls.ps1
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_store_pnl_statement.jrxml
& "$jd\compile_jrxml.ps1" -Jrxml report\pos_perf\rpt_store_pnl_statement.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_store_pnl_statement.jrxml -TargetUri /reports/pos_perf/rpt_store_pnl_statement -Label "Store P and L Statement" -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
Attach-Controls -ReportUri /reports/pos_perf/rpt_store_pnl_statement -ControlUris @("/reports/pos_perf/controls/p_store","/reports/pos_perf/controls/p_yyyymm","/reports/pos_perf/controls/p_version")
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_store_pnl_statement -Format pdf -OutFile out\pos_perf\rpt_store_pnl_statement.pdf
python -c "import pypdfium2 as p; p.PdfDocument(r'out\pos_perf\rpt_store_pnl_statement.pdf')[0].render(scale=2).to_pil().save(r'out\pos_perf\rpt_store_pnl_statement.png')"
```

Expected: eleven lines, Gross margin = Net sales + COGS line, Four-wall EBITDA = Gross margin + lines 4-8, Store contribution = EBITDA + Franchise fees (all to the cent), 12-point line, rank sentence. Then open dashboard 4 and click a store in the worst-stores list: the statement opens in a new tab for that store and 202012.

- [ ] **Step 4: Commit**

```powershell
git add report/pos_perf/rpt_store_pnl_statement.jrxml
git commit -m "feat(pos-perf): Store P and L Statement report (drill target)"
```

---

### Task 9: Reports - AR Aging and AP Aging and Payment Run

**Files:**
- Create: `report/pos_perf/rpt_ar_aging.jrxml`, `report/pos_perf/rpt_ap_aging.jrxml`

**Interfaces:**
- Consumes: `franchise_fee_ledger`, `ap_invoices`, `suppliers`; controls `p_asof`, `p_regions`, `p_franchisee` (AR); `p_asof`, `p_regions` (AP).
- Produces: `/reports/pos_perf/rpt_ar_aging` "Franchise Receivables Aging", `/reports/pos_perf/rpt_ap_aging` "Payables Aging and Payment Run". Treasury tiles `trs_ar_aging` / `trs_dpo` link to them (add the `linkType="ReportExecution"` hyperlink to those two tiles' chart titles in this task, passing `p_asof` and `p_regions`, and redeploy them).

- [ ] **Step 1: rpt_ar_aging.** A4 landscape, grouped by franchisee (`<group name="franchisee">` with header showing `owner_name`, footer with subtotals per bucket). Query:

```sql
SELECT f.franchisee_id, f.owner_name, f.storenumber, f.storename, f.region, f.invoice_number, f.yyyymm, f.due_date, f.status, f.aging_bucket,
       f.total_invoiced, f.amount_paid, f.balance, f.days_overdue,
       CASE f.aging_bucket WHEN 'Current' THEN 1 WHEN '1-30 days' THEN 2 WHEN '31-60 days' THEN 3 ELSE 4 END AS bucket_ord
FROM franchise_fee_ledger f
WHERE f.status <> 'Paid' AND f.yyyymm <= INT4($P{p_asof}) AND $X{IN, f.region, p_regions} AND $X{IN, f.franchisee_id, p_franchisee}
ORDER BY f.franchisee_id, bucket_ord DESC, f.due_date
```

Columns: Store | Invoice | Month | Due | Bucket | Invoiced | Paid | Balance | Days overdue. Group footer: `SUM($F{balance})` per group via `<variable name="grp_balance" calculation="Sum" resetType="Group" resetGroup="franchisee">`. Summary band: bucket matrix as a `<crosstab>` (rows franchisee_id, columns aging_bucket, measure SUM(balance)) plus a total line "Aged 60+ days: $..." from a `<variable>` with `<expression>` `"60+ days".equals($F{aging_bucket}) ? $F{balance} : java.math.BigDecimal.ZERO`. Expected totals at defaults: 572 rows (317 Open + 255 Overdue), balance 5.4M, aged 60+ 1.27M.

- [ ] **Step 2: rpt_ap_aging.** Same page, grouped by supplier, plus a "payment run" section: invoices due within 14 days of the as-of month end with an available early-pay discount.

```sql
SELECT a.supplier_name, a.invoice_number, a.po_number, a.storenumber, a.region, a.invoice_date, a.due_date, a.payment_terms, a.status, a.aging_bucket,
       a.amount, a.amount_paid, a.balance, a.days_overdue, s.payment_terms AS supplier_terms,
       CASE a.aging_bucket WHEN 'Current' THEN 1 WHEN '1-30 days' THEN 2 WHEN '31-60 days' THEN 3 ELSE 4 END AS bucket_ord
FROM ap_invoices a LEFT JOIN suppliers s ON s.supplier_name = a.supplier_name
WHERE a.status <> 'Paid' AND a.invoice_yyyymm <= INT4($P{p_asof}) AND $X{IN, a.region, p_regions}
ORDER BY a.supplier_name, bucket_ord DESC, a.due_date
```

Summary: crosstab supplier x bucket on SUM(balance); DPO line per terms from a `<subDataset>` with the Task 6 trs_dpo query; discounts line "Early-pay discounts taken to date: $793,522" via subDataset `SELECT DECIMAL(SUM(discount_taken), 14, 2) AS d FROM ap_invoices WHERE status = 'Paid' AND invoice_yyyymm <= INT4($P{p_asof})`. Expected at defaults: 3,414 rows, balance 30.4M.

- [ ] **Step 3: Deploy both with controls, run, and add the drill links to trs_ar_aging / trs_dpo**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\jrs_controls.ps1
foreach ($r in "rpt_ar_aging","rpt_ap_aging") {
  & "$jd\lint_jrxml.ps1" -Path "report\pos_perf\$r.jrxml"
  & "$jd\compile_jrxml.ps1" -Jrxml "report\pos_perf\$r.jrxml"
  & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$r.jrxml" -TargetUri "/reports/pos_perf/$r" -Label $r -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
  & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$r" -Format pdf -OutFile "out\pos_perf\$r.pdf"
}
Attach-Controls -ReportUri /reports/pos_perf/rpt_ar_aging -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
Attach-Controls -ReportUri /reports/pos_perf/rpt_ap_aging -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions")
```

Then in `trs_ar_aging.jrxml` and `trs_dpo.jrxml` make the title staticText a textField with `linkType="ReportExecution" linkTarget="Blank"` and `hyperlinkParameter`s `_report` (`"/reports/pos_perf/rpt_ar_aging"` / `rpt_ap_aging`), `p_asof` (`$P{p_asof}`), `p_regions` (`$P{p_regions}`); redeploy those two tiles with `-Overwrite`, re-attach their controls, teardown and recompose `pos_treasury`. Click-through opens the report with the same as-of month.

- [ ] **Step 4: Commit**

```powershell
git add report/pos_perf/rpt_ar_aging.jrxml report/pos_perf/rpt_ap_aging.jrxml report/pos_perf/trs_ar_aging.jrxml report/pos_perf/trs_dpo.jrxml
git commit -m "feat(pos-perf): AR aging + AP aging/payment run reports with treasury drill"
```

---

### Task 10: Report - Sales Tax Remittance

**Files:**
- Create: `report/pos_perf/rpt_tax_remittance.jrxml`

**Interfaces:**
- Consumes: `tax_collected_monthly`, `provincial_tax_rates` (province, province_name, effective_from, provincial_tax_name, gst_pct, provincial_pct, combined_pct); controls `p_province` (LOV with `All`), `p_yyyymm`.
- Produces: `/reports/pos_perf/rpt_tax_remittance` "Sales Tax Remittance"; `trs_tax_province` title links here with `p_yyyymm = $P{p_asof}` and `p_province = "All"`.

- [ ] **Step 1: Query and layout.** A4 portrait, grouped by province.

```sql
SELECT t.province, r.province_name, t.provincial_tax_name, t.yyyymm, t.storenumber, t.region,
       t.taxable_sales, t.zero_rated_sales, t.net_sales, t.taxable_share_pct, t.gst_pct, t.provincial_pct, t.combined_pct,
       t.gst_collected, t.provincial_tax_collected, t.total_tax_collected
FROM tax_collected_monthly t
LEFT JOIN provincial_tax_rates r ON r.province = t.province AND r.effective_from = (SELECT MAX(effective_from) FROM provincial_tax_rates x WHERE x.province = t.province AND x.effective_from <= t.month_start)
WHERE t.yyyymm = INT4($P{p_yyyymm}) AND ($P{p_province} = 'All' OR t.province = $P{p_province})
ORDER BY t.province, t.storenumber
```

Group header per province: province_name, tax name, "GST x.x pct + provincial y.y pct = z.z pct". Detail: Store | Net sales | Taxable | Zero-rated | GST | Provincial | Total. Group footer: sums; a note line when `$F{province} == "MB" && $F{yyyymm} >= 201907`: "RST reduced to 7 pct from 2019-07-01". Summary: grand totals and "Taxable share of net sales: x pct". Expected at defaults (202012, All): 12 province groups, total tax about 1.2M for the month; lifetime 28.1M is the reference for a year-sum sanity query, not this page.

- [ ] **Step 2: Deploy with controls, run, link from trs_tax_province**

```powershell
$env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
. .\scripts\pos_perf\jrs_controls.ps1
& "$jd\lint_jrxml.ps1" -Path report\pos_perf\rpt_tax_remittance.jrxml
& "$jd\compile_jrxml.ps1" -Jrxml report\pos_perf\rpt_tax_remittance.jrxml
& "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_tax_remittance.jrxml -TargetUri /reports/pos_perf/rpt_tax_remittance -Label "Sales Tax Remittance" -DataSourceUri /datasources/pos_data_avalanche -Overwrite -SkipLint
Attach-Controls -ReportUri /reports/pos_perf/rpt_tax_remittance -ControlUris @("/reports/pos_perf/controls/p_province","/reports/pos_perf/controls/p_yyyymm")
& "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_tax_remittance -Format pdf -OutFile out\pos_perf\rpt_tax_remittance.pdf
```

Add the hyperlink to `trs_tax_province.jrxml` (same pattern as Task 9 Step 3, parameters `_report`, `p_yyyymm` = `$P{p_asof}`, `p_province` = `"All"`), redeploy the tile, re-attach controls, teardown and recompose `pos_treasury`.

- [ ] **Step 3: Commit**

```powershell
git add report/pos_perf/rpt_tax_remittance.jrxml report/pos_perf/trs_tax_province.jrxml
git commit -m "feat(pos-perf): Sales Tax Remittance report with treasury drill"
```

---

### Task 11: Wobby cross-check, STAGE acceptance, docs, PROD go/no-go

**Files:**
- Create: `scripts/pos_perf/wobby_metric_crosscheck.py`
- Create: `.superpowers/sdd/2026-08-23-pos-suite/phase1-acceptance.md`
- Modify: `README.md`, `RUNBOOK.md` (add dashboards 4-5 and the four reports to the Task 1 sections)
- Modify: memory `pos-perf-dashboards.md`

**Interfaces:**
- Consumes: Wobby GET `/api/public/v1/environment` (key from `.claude/skills/wobby/wobby.config.json`, never committed; 2 requests per 5 s), the metric expressions listed in the spec's "Semantic alignment" section; the KPI values from Tasks 5-6 PDFs.
- Produces: an acceptance table, the PROD command list for the user, updated docs and memory.

- [ ] **Step 1: Cross-check script.** Wobby metrics are expressions over models, not a query API, so the check is: for each dashboard KPI, run the equivalent SQL (the exact expression the metric names) through `sql.ps1` and compare with the tile value. Script reads the environment export once, resolves each metric's expression text, prints it next to the SQL used by the tile, and the two numbers:

```python
# scripts/pos_perf/wobby_metric_crosscheck.py
# Usage: python scripts/pos_perf/wobby_metric_crosscheck.py out/pos_perf/wobby_env.json
# The env json comes from ONE GET of https://app.wobby.ai/api/public/v1/environment
# (Bearer key from .claude/skills/wobby/wobby.config.json, rate limit 2 req / 5 s).
import json, subprocess, sys
env = json.load(open(sys.argv[1]))
metrics = {m["name"]: m for m in env["metrics"]}
CHECKS = [
  # (wobby metric, tile, SQL the tile uses for the same number)
  ("four_wall_ebitda", "pnl_kpi_strip.four_wall_ebitda", "SELECT DECIMAL(SUM(four_wall_ebitda),14,2) FROM store_pnl_monthly WHERE yr = 2020"),
  ("contribution_margin_pct", "pnl_contribution_trend.actual_pct(202012)", "SELECT DECIMAL(100.0*FLOAT8(SUM(store_contribution))/FLOAT8(SUM(net_sales)),6,2) FROM store_pnl_monthly WHERE yyyymm = 202012 AND trading_status = 'Trading'"),
  ("sales_plan_attainment_pct", "pnl_kpi_strip.plan_attainment_pct", "SELECT DECIMAL(100.0*FLOAT8(SUM(actual_sales))/FLOAT8(SUM(target_sales)),6,2) FROM sales_targets WHERE yr = 2020"),
  ("ar_outstanding", "trs_kpi.ar_balance", "SELECT DECIMAL(SUM(balance),14,2) FROM franchise_fee_ledger WHERE status <> 'Paid'"),
  ("ap_outstanding", "trs_kpi.ap_balance", "SELECT DECIMAL(SUM(balance),14,2) FROM ap_invoices WHERE status <> 'Paid'"),
  ("avg_days_to_pay", "trs_dpo (all terms)", "SELECT DECIMAL(AVG(FLOAT8(days_to_pay)),6,1) FROM ap_invoices WHERE status = 'Paid'"),
  ("cashless_share_pct", "trs_kpi.cashless_pct(202012)", "SELECT DECIMAL(100.0*FLOAT8(SUM(CASE WHEN tender_group <> 'Cash' THEN amount ELSE 0 END))/FLOAT8(SUM(amount)),6,1) FROM dash_tender_monthly WHERE yyyymm = 202012"),
  ("tax_collected", "trs_tax_province (2020)", "SELECT DECIMAL(SUM(total_tax_collected),14,2) FROM tax_collected_monthly WHERE yr = 2020"),
  ("gift_card_liability_cad", "trs_liability.gift(202012)", "SELECT closing_liability FROM gift_card_liability_monthly WHERE yyyymm = 202012"),
  ("loyalty_liability_cad", "trs_liability.loyalty(202012)", "SELECT closing_liability_cad FROM loyalty_liability_monthly WHERE yyyymm = 202012"),
  ("total_net_book_value", "(spec 9, reference only)", "SELECT DECIMAL(SUM(net_book_value),14,2) FROM store_assets"),
]
for name, tile, sql in CHECKS:
    m = metrics.get(name)
    expr = m.get("expression") or m.get("formula") or "" if m else "MISSING IN WOBBY"
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
        f'& ".\\.claude\\skills\\admiral\\scripts\\sql.ps1" -Action query -ResourceId av-flm7ykoxlcvq -Sql "{sql}"'],
        capture_output=True, text=True).stdout.strip().splitlines()[-1]
    print(f"{name:32} | {tile:40} | wobby: {expr[:60]:60} | sql: {out}")
```

Run it; paste the table into `phase1-acceptance.md` next to the tile values read from the PDFs (Task 5 Step 6, Task 6 Step 4). Every pair must agree within 0.5 pct or carry a one-line explanation (e.g. "tile is 2020 only, metric is lifetime").

- [ ] **Step 2: Acceptance walk-through on STAGE.** For each of `pos_store_pnl`, `pos_treasury`, `pos_executive_overview` (navy), `pos_promo_story` (navy): open the viewer URL, take a full-board screenshot (Chrome tool if connected; otherwise the user, or `msedge --headless=new --screenshot` against the viewer URL after logging in is not possible, so ask the user), save under `out/pos_perf/phase1_<name>.png`, and record in `phase1-acceptance.md`: tiles rendered / blank, filter check (Treasury: Quebec + 202006), drill check (worst store -> statement; AR tile -> AR aging; DPO -> AP aging; tax -> remittance), PDF check for the four reports.

- [ ] **Step 3: Docs and memory.** Append to the README table the two new dashboards and the four reports with URIs and manifests; append to the RUNBOOK the control-creation command (`. .\scripts\pos_perf\jrs_controls.ps1; New-FinanceControls`) and the tender aggregate rebuild; update memory `pos-perf-dashboards.md` with the Phase 1 URIs, the spike verdict, and the navy status; update `pos-suite-blueprint.md` line "Phase 1 shipped to STAGE <date>".

- [ ] **Step 4: PROD go/no-go list for the user.** Write the exact PROD sequence (same shape as Task 1 Step 3: `$env:JRS_ENV = "prod"`, `New-FinanceControls` with `-Env prod`, `deploy_report.ps1 ... -Overwrite -Backup` for each of the 12 navy + 5 pnl + 7 trs + 4 rpt units, `Attach-Controls` per console tile and report, `teardown_dashboard.ps1` + `compose_dashboard.ps1 -Env prod` for the four dashboards) into `phase1-acceptance.md` under "PROD promotion (user-run)". Do not run it.

- [ ] **Step 5: Commit**

```powershell
git add scripts/pos_perf/wobby_metric_crosscheck.py README.md RUNBOOK.md .superpowers/sdd/2026-08-23-pos-suite/phase1-acceptance.md
git commit -m "docs(pos-perf): Phase 1 acceptance, Wobby cross-check, runbook updates"
```

---

## Self-review notes (done while writing)

- Spec coverage, Phase 0 + 1: Task 8/9 close-out (T1), filter spike (T2), dash_tender_monthly (T3), controls contract (T4), dashboard 4 (T5), dashboard 5 (T6), navy re-skin (T7), Store P&L Statement (T8), AR Aging + AP Aging (T9), Tax Remittance (T10), Wobby alignment + acceptance + PROD go/no-go (T11). Spec items deferred to later plans: dashboards 6-10, the other five reports, dash_churn/cohort/labour/email/ecom.
- Deviations from the spec, stated: (1) waterfall is JFreeChart stacked-bar, not HTML5, because Jaspersoft HTML5 charts offer no waterfall type; (2) `p_asof` is a month LOV, not a free date, because Ingres date arithmetic inside `$P{}` expressions is untested here and the ledgers are as-of 2020-12-31 anyway; (3) the Statement's inline variance bars are a summary-band bar chart, not per-row rectangles, because JR7 has no width expression on rectangles.
- Names used consistently: controls `p_asof`, `p_regions`, `p_franchisee`, `p_store`, `p_yyyymm`, `p_version`, `p_province`; helper `Attach-Controls -ReportUri -ControlUris`; dashboards `pos_store_pnl`, `pos_treasury`; reports `rpt_store_pnl_statement`, `rpt_ar_aging`, `rpt_ap_aging`, `rpt_tax_remittance`; manifest key `filters` (Task 2) and `canvasColor` (Task 7).
