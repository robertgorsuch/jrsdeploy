# POS Sales Performance Dashboards — Design

Date: 2026-08-20
Status: Design approved in session; spec + plan pending user review
Mockups: https://claude.ai/code/artifact/3f310c6e-4e45-44bf-b178-f341178d7854

## Goal

Design, build, and deploy three Actian-branded dashboards to JasperReports
Server PROD, driven by the `pos_data` Avalanche warehouse
(`av-flm7ykoxlcvq.avstage.actiandatacloud.com`, database `db`, table
`robert.gorsuch.pos_sales_detail`, 63.6M rows) and aligned with the Wobby
(Actian AI Analyst) semantic layer:

- **Option A — Executive Overview**: Foodmart-standard tile layout —
  province choropleth, gross-margin + YoY dials, 24-month annotated trend,
  region bars, top-stores table, promo mix, full-width KPI strip.
- **Option B — Operations Console**: input-control filter rail (date range,
  region, promo type, pandemic period) driving KPI chips, monthly sales and
  margin small multiples, region bars, promo mix, store leaderboard.
- **Option C — Promo & Margin Story**: hero band with headline numbers, one
  large annotated trend with pandemic shading, three decision cards (promo
  penetration, margin basis, basket economics).

All mockup numbers were queried live and are the acceptance reference:
$764.2M net sales / 19.5M transactions / 330 stores / Jan 2019–Dec 2020,
Regular Sale only.

## Architecture

### Data layer — precomputed aggregates

Direct dashlet queries against the 63.6M-row fact are too slow for
interactive use on an AU-1 warehouse. Build small `dash_*` aggregate tables
in schema `robert.gorsuch`, created and refreshed by one SQL script run via
the admiral skill (`sql.ps1 run-file`):

| Table | Grain | Feeds |
|---|---|---|
| `dash_monthly` | year, month, region, promotiontype, pandemic period | A/B/C trends, B filters |
| `dash_region` | region | A/B region bars |
| `dash_province` | province | A choropleth |
| `dash_promo` | promotiontype, region, month | A/C promo mix, B promo panel |
| `dash_store` | store, region | A top stores, B leaderboard |
| `dash_kpi` | one-row rollup view over `dash_monthly` (B's filtered chips query `dash_monthly` directly) | KPI strips/chips |

Each table carries the measure columns needed (net sales, cost, quantity,
transactions, line items) so ratios (margin %, avg basket) are computed in
the report SQL from additive components — never pre-averaged.
`DATE(saledate)` is materialized during the build, resolving the VARCHAR
date problem once. Source table is static (Jan 2019–Dec 2020), so refresh
is on-demand, not scheduled.

### Semantic alignment with Wobby

- Measure SQL in every JRXML derives from the Wobby model's measure
  expressions (export cached; re-export at build time).
- **Margin-basis decision is empirical, before any margin tile ships**:
  profile multi-quantity lines to determine whether `sellingprice` / `cost`
  are unit or extended values (e.g., compare `sellingprice*quantity` and
  `sellingprice` against `pricebookregularprice*quantity` on qty>1 lines).
  Fix the affected Wobby measures via `PUT /environment` (respecting the
  2-req/5s rate limit) and use the corrected basis in both systems.
- Fix the Wobby model description's wrong date range (says Apr 2019–Oct
  2020; data is Jan 2019–Dec 2020).

### JRS artifacts

- **Datasource**: one JDBC datasource, `jdbc:ingres://av-flm7ykoxlcvq...:27839/db`,
  Ingres driver, credentials from the gitignored admiral config. Named e.g.
  `/datasources/pos_data_avalanche`.
- **Reports** (~14 JRXMLs under `report/pos/`): A = 8 tiles (map, 2 dials,
  trend, region bar, top-stores table, promo mix, KPI strip); B = 6
  (KPI chips strip, sales trend, margin trend, region bar, promo panel,
  leaderboard) — all parameterized on date range, region(s), promo type,
  pandemic period with cascading JRS input controls; C = 3 (hero band,
  annotated trend, decision cards row).
- Reuse existing house patterns: JFreeChart meter dials (square element +
  overlay textField), gradient-bar chart customizer jar, KPI strip with
  divider cells, centered titles + Actian logo top-left
  (repo:/images/actian_logo), brand palette (chart series #0550DC #1DB6C0
  #0A4CAD #239CA8; sequential blues for the choropleth).
- **Choropleth**: FusionMaps Canada if licensed on the target instance;
  fallback is an HTML5/SVG tile-grid report matching the mockup. Verified
  in phase 1, decided before report build.
- **Dashboards**: three dashboards composed from committed manifests via
  `compose_dashboard` (delete-before-recompose per house rule):
  `pos_executive_overview`, `pos_operations_console`, `pos_promo_story`.
- **Pandemic shading / annotations** on trends implemented with JFreeChart
  customizers (interval markers + point labels).

### Environments and deployment

- Build and verify everything on STAGE (`localhost:8081/jasperserver-pro`)
  first; promote to PROD (`3.214.51.180:8080/jasperserver-pro`) via the
  jasper-deploy promotion flow.
- **Prerequisites verified in phase 1, not discovered late**:
  1. Actian/Ingres JDBC driver jar present on STAGE and PROD classpaths
     (`WEB-INF/lib`); install + restart Tomcat if missing.
  2. Warehouse IP allowlist must admit both JRS instances (PROD
     3.214.51.180 is not currently allowlisted); add via admiral
     `resource.ps1 allowlist-ip`.
  3. FusionMaps availability on STAGE/PROD.
  4. Chart customizer jar present on PROD (`WEB-INF/lib`).

### Testing / acceptance

- Aggregate tables cross-checked against the session's verified totals
  (row 1 acceptance numbers above; region sums = $764.1M; 163+111+42+14
  stores).
- Every report run-to-PDF on STAGE and rasterized (pypdfium2) for visual
  verification against the mockups; input controls exercised with at least
  one non-default combination per control.
- Dashboards verified in the JRS viewer, then promoted and re-verified on
  PROD.
- Version stamp tile ("Last refreshed" live `now()` pattern) on A only,
  matching the Foodmart standard.

## Security

- Repo is public: warehouse and JRS credentials live only in the gitignored
  admiral/jasper-deploy configs; JRXMLs reference the JRS datasource, never
  raw credentials; specs and manifests carry no secrets.

## Out of scope

- Wobby-side dashboards or new AI analysts; real-time refresh; return-rate
  analytics (Regular Return profiling is a follow-up); the wobby skill
  build (separate approved spec, `2026-08-20-wobby-skill-design.md`).
