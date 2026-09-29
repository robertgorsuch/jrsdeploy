# Runbook — Texas PostGIS Geocoder + Population Maps + JasperReports

Cumulative operational knowledge from building a statewide Texas address geocoder on PostGIS, population-density visualizations, and a JasperReports 7 report — plus the `jasper-deploy` skill and web wizard that automate the full JasperReports Server lifecycle.

> **Path conventions:** This runbook was written against a specific Windows development machine. Wherever you see `C:\Users\<you>\...` or `C:\Program Files\...`, substitute your own paths. Environment variables (`JAVA_HOME`, `PGPASSWORD`, `JR_LIB_DIR`) are the recommended way to avoid hard-coded paths in scripts.

---

## Contents

1. [What exists](#1-what-exists)
2. [Prerequisites and environment](#2-prerequisites-and-environment)
3. [Gotchas](#3-gotchas)
4. [Scripts (`scripts\`)](#4-scripts-scripts)
5. [Reports (`report\`)](#5-reports-report)
6. [Maps (`maps\`)](#6-maps-maps)
7. [Rebuild order from scratch](#7-rebuild-order-from-scratch)
8. [Useful geocode tests](#8-useful-geocode-tests)
9. [jasper-deploy skill](#9-jasper-deploy-skill)
10. [Self-service web wizard](#10-self-service-web-wizard)
11. [Troubleshooting quick reference](#11-troubleshooting-quick-reference)
12. [pos_perf: rebuild aggregates, redeploy a report, recompose a dashboard](#12-pos_perf-rebuild-aggregates-redeploy-a-report-recompose-a-dashboard)

---

## 1. What exists

**Geocoder** — Statewide TIGER geocoder in `postgis_34_sample`, all 254 Texas counties loaded:

| Table | Rows |
|---|---|
| `tiger_data.tx_edges` | 5,692,076 |
| `tiger_data.tx_featnames` | 5,060,971 |
| `tiger_data.tx_addr` | 2,664,841 |
| `tiger_data.tx_faces` | 1,924,566 |
| `tiger_data.tx_place` | 1,860 |

`geocode('1100 Congress Ave, Austin, TX 78701')` → rating 0 (exact match).

**Population data:**
- `tiger_data.tx_tabblock20` — 668,757 2020 census blocks (statewide, with `pop`). TX total: 29,145,505.
- `tiger_data.tx_bg` — 18,638 block groups
- `tiger_data.tx_tract` — 6,896 tracts

**Maps** (generated locally into `maps\`, open in a browser; not tracked in the repo): statewide heatmap (2 km grid), Houston heatmap (500 m), full block-detail heatmap (449k blocks), tract choropleth, block-group choropleth, and two geocode-pin maps.

**JasperReports** (in `report\`): a block-group density report in both 6.x and native JR 7 format, compiled (`.jasper`) and rendered (`output\tx_density_blockgroup_report.pdf`, 317 pages).

**jasper-deploy skill** (`plugins\jasper-deploy\skills\jasper-deploy\`): 45+ scripts automating the full JRS 10 lifecycle (reports, dashboards, data sources with live connection tests, single- and multi-table domains, themes, admin, environment promotion, usage reporting, diagnostics, lineage, embedding, smoke testing).

**Web wizard** (`webapp\jasper-wizard\`): Jakarta servlet WAR — a browser UI over the skill for business users.

---

## 2. Prerequisites and environment

### Software versions

| Tool | Version | Default location | Notes |
|---|---|---|---|
| PostgreSQL + PostGIS | 14 + 3.4 | `C:\Program Files\PostgreSQL\14\bin` | DB `postgis_34_sample`, user `postgres` |
| curl | Built-in | `C:\WINDOWS\system32\curl.exe` | **Use instead of wget** (see §3) |
| 7-Zip | Any | `C:\Program Files\7-Zip\7z.exe` | Unzip + `7z t` integrity checks |
| JDK | 11 | Set via `JAVA_HOME` | Runs JasperReports + javac |
| Maven | 3.9 | Set via `PATH` | Builds JasperReports from source |
| JasperReports 7.0.6 runtime | 7.0.6 | Set via `JR_LIB_DIR` (or `C:\Users\<you>\jasperreports-lib\`) | 37 jars (core, pdf, openpdf, PG JDBC driver, deps) |
| JasperReports 7.0.6 source | 7.0.6 | `C:\Users\<you>\jasperreports-7.0.6\` | Maven project extracted from `-project.zip` |
| JasperReports Server | 10 Pro | `http://localhost:8081/jasperserver-pro` | HTTP Basic — `superuser`/`superuser` |

### Environment variables

```bat
set JAVA_HOME=C:\path\to\jdk-11
set PGPASSWORD=<your postgres password>
set JR_LIB_DIR=C:\path\to\jasperreports-lib   :: used by jasper-deploy scripts; optional
```

### Data staging

Census TIGER data downloads stage to `C:\gisdata` by default (configurable in the loader scripts).

---

## 3. Gotchas

These are the expensive-to-rediscover lessons. Read this section before you start.

**G1 — Use `curl.exe`, not `wget`.**
`winget install wget` fails — its source (`eternallybored.org`) is unreachable in this environment. Use the built-in `curl.exe` with:
```
curl --location --fail --retry 3 --create-dirs -o "<host\path>" "<url>"
```
All loader scripts have been rewritten to use this pattern.

**G2 — Census downloads silently corrupt.**
`curl` exits 0 (HTTP 200) but bytes can be truncated or bad (killed PLACE + TRACT on first run). Always validate every download with `7z t` and retry. `load_tiger_TX.bat` has a `:getverified` subroutine; the PS1 loaders use a `Get-Verified` function.

**G3 — Cloudflare WAF cache.**
Cloudflare can cache a "Request Rejected" page (247-byte HTML, HTTP 200, `cf-cache-status: HIT`) for a specific Census URL. `--fail` won't catch it. Fix: re-request with a cache-buster (`?cb=<timestamp>`) and a browser User-Agent (`-A`).

**G4 — PowerShell mangles Maven `-D` args.**
`-Dmaven.test.skip=true` gets split into a bogus lifecycle phase. Pass Maven args after the `--%` stop-parsing token:
```powershell
mvn --% -f pom.xml -pl core,ext/pdf -am -Dmaven.test.skip=true -B install
```

**G5 — JasperReports 7 has a new `.jrxml` format** (Jackson-based, not backward-compatible with 6.x):
- No XML namespace
- Root element: `<jasperReport name=".." language="java" ..>`
- `<queryString>` → `<query>`
- `<reportElement>` removed — x/y/width/height are flattened onto `<element kind="..">`
- `textAlignment` → `hTextAlign` / `vTextAlign`
- `<variableExpression>` / `<groupExpression>` → `<expression>`

A 6.x `.jrxml` fails JR7's CLI loader. Open it in Jaspersoft Studio to auto-upgrade, or use the `_jr7` file in this repo.

**G6 — JR 7 PDF export is a separate module.**
The `jasperreports-pdf` module (OpenPDF) must be built and included. Core alone throws "Missing JasperReports PDF Extension". Build `ext/pdf` too (see §5).

**G7 — `usa_states` SRID.**
`tiger.usa_states` was SRID 0 (undefined), fixed to 4269 (NAD83, matching TIGER). It and two other former-`public` tables now live in schema `tiger`. The `public` schema holds only PostGIS/extension objects — do not move those.

**G8 — JRS SQL security validator.**
Report queries must begin with `SELECT`. A leading `WITH` (CTE) compiles locally but is rejected at fill time (`JSSecurityException` → generic 400). `deploy_report.ps1` lints and blocks this before deploy (`-SkipSqlLint` to bypass). Fix by pushing each CTE into a `FROM` subquery.

**G9 — Dashboards: import, don't PUT.**
A hand-built dashboard PUT to `/rest_v2/resources` stores (201) but renders blank. `compose_dashboard.ps1` exports real dashlets, injects the synthesized model, and imports a re-zipped archive (forward-slash entries required — the Java importer ignores back-slash paths).

**G10 — `resource.in.use` (403) on dashlet reports.**
A report that is a dashlet is modification/delete-locked. `deploy_report.ps1` updates in place to avoid this; `teardown_dashboard.ps1` deletes the dashboard first to release the lock.

**G11 — Input controls must be standalone repository resources.**
Embedded input controls are rejected. The control's name must equal the `$P{param}` it drives.

**G12 — PowerShell 5.1 URL and array quirks.**
- `?` is a legal variable-name char: build URLs as `"${base}?name="` not `"$base?name="` (the latter produces a 405).
- `ConvertTo-Json` unwraps single-element arrays to scalars (server 400s). Emit such arrays as hand-built JSON.

**G13 — JR7 chart plot properties are per-class.**
`line` uses `showLines`/`showShapes`; `bar`/`bar3d`/`stackedbar` use `showTickMarks`/`showTickLabels`; `area` (`JRDesignAreaPlot`) accepts neither pair (bare `<plot/>` only). The wrong pair throws `UnrecognizedPropertyException` at compile/fill. `scaffold_jrxml.py` emits the correct form; `lint_jrxml.ps1` catches the wrong form; `references/jr7-valid-elements.md` lists valid/rejected elements per construct.

---

## 4. Scripts (`scripts\`)

All scripts use absolute paths internally and are safe to run from any working directory. Run `.bat` files from `cmd.exe`; run `.ps1` files via `powershell -File`.

| Script | Purpose |
|---|---|
| `load_tiger_nation.bat` | One-time: load national STATE + COUNTY lookup tables. **Run this first.** |
| `load_tiger_TX.bat` | Full statewide TX loader (all layers, all 254 counties). Has the `:getverified` CRC-verify+retry fix. Long run. |
| `load_geocode_travis.bat` | Loads PLACE (statewide) + EDGES/FEATNAMES/ADDR for Travis County only. Fast demo. |
| `load_geocode_faces_zip.bat` | Loads Travis FACES + builds zip lookup tables (required for geocoding). |
| `load_metros.ps1` | Verified loader for 16 metro counties (faces/featnames/edges/addr). Idempotent. |
| `load_remaining.ps1` | Verified loader for all remaining counties. **Idempotent** — skips counties already in `tx_edges`. Recommended for a full statewide load. |
| `test_verify.bat` | Standalone test of the download-verify-retry subroutine. |

---

## 5. Reports (`report\`)

### Files

| File | Description |
|---|---|
| `tx_density_blockgroup_report.jrxml` | JasperReports 6.x format. Open in Jaspersoft Studio to auto-upgrade. |
| `tx_density_blockgroup_report_jr7.jrxml` | Native JR 7 format. Use this one. |
| `tx_density_blockgroup_report_jr7.jasper` | Pre-compiled report binary. |
| `postgis_34_sample.xml` | Jaspersoft Studio JDBC data adapter (requires the PostgreSQL driver on its classpath). |
| `CompileReport.java` | CLI compile harness. |
| `FillReport.java` | CLI fill/export harness. Reads `PGPASSWORD` from the environment. |
| `foodmart/` | Deployable KPI reports + `dashboard.json` manifest for the jasper-deploy skill. |

### Build the JasperReports 7.0.6 library (once)

```bat
set JAVA_HOME=C:\path\to\jdk-11

:: Build core + PDF extension
mvn --% -f C:\path\to\jasperreports-7.0.6\pom.xml -pl core,ext/pdf -am -Dmaven.test.skip=true -Dmaven.javadoc.skip=true -B install

:: Copy runtime jars to your lib directory
mvn --% -f C:\path\to\jasperreports-7.0.6\core\pom.xml dependency:copy-dependencies -DoutputDirectory=C:\path\to\jasperreports-lib -DincludeScope=runtime
mvn --% -f C:\path\to\jasperreports-7.0.6\ext\pdf\pom.xml dependency:copy-dependencies -DoutputDirectory=C:\path\to\jasperreports-lib -DincludeScope=runtime

:: Copy the built JARs into the lib directory
copy C:\path\to\jasperreports-7.0.6\core\target\jasperreports-7.0.6.jar C:\path\to\jasperreports-lib\
copy C:\path\to\jasperreports-7.0.6\ext\pdf\target\jasperreports-pdf-7.0.6.jar C:\path\to\jasperreports-lib\

:: Add the PostgreSQL JDBC driver
curl https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar -o C:\path\to\jasperreports-lib\postgresql-42.7.4.jar
```

### Compile and render to PDF

Run from the `report\` directory:

```bat
set CP=C:\path\to\jasperreports-lib\*
set PGPASSWORD=<your postgres password>

:: Compile the Java harnesses
"C:\path\to\jdk-11\bin\javac.exe" -cp "%CP%" CompileReport.java FillReport.java

:: Compile the JRXML
"C:\path\to\jdk-11\bin\java.exe" ^
  -Dnet.sf.jasperreports.compiler.class=net.sf.jasperreports.engine.design.JRJavacCompiler ^
  -cp "%CP%;." CompileReport tx_density_blockgroup_report_jr7.jrxml

:: Fill and export to PDF
"C:\path\to\jdk-11\bin\java.exe" -cp "%CP%;." FillReport ^
  tx_density_blockgroup_report_jr7.jasper ^
  ..\output\tx_density_blockgroup_report.pdf
```

---

## 6. Maps (`maps\`, local-only)

Self-contained HTML files using Leaflet + CDN resources, generated from the PostGIS database. Open directly in any browser — no web server required. **Not tracked in the repo** (generated output, ~23 MB); regenerate from the DB.

| File | Shows |
|---|---|
| `tx_population_heatmap.html` | Statewide population heatmap, 2 km grid (64,722 cells) |
| `tx_population_heatmap_blocks.html` | Full block-detail heatmap (449k blocks; loads slowly) |
| `houston_population_heatmap.html` | Houston metro, 500 m grid |
| `tx_density_choropleth.html` | Density choropleth by census tract (6,896) |
| `tx_density_choropleth_blockgroup.html` | Density choropleth by block group (18,638) |
| `geocode_result.html` | Single geocoded address pin (Austin example) |
| `geocode_houston.html` | Single geocoded address pin (Houston example) |

---

## 7. Rebuild order from scratch

1. Run `scripts\load_tiger_nation.bat` (national STATE + COUNTY lookups — required first).
2. Run `scripts\load_remaining.ps1` (verified statewide county load; or `load_tiger_TX.bat` for the original loader). Sweep the log for `DOWNLOAD FAILED (skipped)` and repair those files with the cache-buster + User-Agent trick (see G3).
3. Build the JasperReports 7.0.6 library (§5), compile the report, and fill it to PDF.
4. Regenerate maps as needed — queries are embedded in `report\` and data lives in `tiger_data.tx_*`.
5. To stand up the jasper-deploy skill: see §9. To deploy the web wizard: see §10.

---

## 8. Useful geocode tests

```sql
-- Exact match (rating 0)
SELECT g.rating, ST_X(g.geomout) lon, ST_Y(g.geomout) lat, pprint_addy(g.addy)
FROM geocode('1100 Congress Ave, Austin, TX 78701', 1) AS g;

-- Houston example
SELECT g.rating, ST_X(g.geomout) lon, ST_Y(g.geomout) lat, pprint_addy(g.addy)
FROM geocode('901 Bagby St, Houston, TX 77002', 1) AS g;

-- Check what's loaded
SELECT COUNT(*) FROM tiger_data.tx_edges;       -- ~5.7M
SELECT COUNT(*) FROM tiger_data.tx_tabblock20;  -- ~668K
SELECT SUM(pop) FROM tiger_data.tx_tabblock20;  -- 29,145,505
```

---

## 9. jasper-deploy skill

`plugins/jasper-deploy/skills/jasper-deploy/` scripts the full JasperReports lifecycle against JRS 10 Pro at `http://localhost:8081/jasperserver-pro` over REST v2. All scripts are JR 7.0.6-native and verified end-to-end.

### Configuration

Credentials and server URL resolve in this order:
1. Script parameters (`-Url`, `-User`, `-Pass`)
2. Environment variables (`JRS_URL`, `JRS_USER`, `JRS_PASS`)
3. `jrs.config.json` (gitignored; copy `jrs.config.example.json` to get started)

Named **environment profiles** live under `"environments"` in `jrs.config.json` and are selected with a script's `-Env` parameter or `$env:JRS_ENV` (e.g. `stage` / `prod`); profile keys shadow the top level and, while a profile is active, stale `JRS_URL`-style shell exports are ignored. `promote.ps1 -FromEnv stage -ToEnv prod` promotes between two profiles.

Default: `http://localhost:8081/jasperserver-pro`, `superuser` (password from `jrs.config.json`).

> ⚠️ Port 8080 is an unrelated Bearer-gated service — not JRS.

JR 7.0.6 runtime jars resolve via: `-LibDir` parameter → `$env:JR_LIB_DIR` → `jrs.config.json` `jrLibDir` → `C:\Users\<you>\jasperreports-lib\`.

### Script reference

| Script | Purpose |
|---|---|
| `scaffold_jrxml.py` | Introspect a SQL query → emit a JR7 tabular report. Flags: `--chart`, `--param`, `--group-by`, `--highlight`, `--drill`, `--crosstab`, `--subreport`, `--style-template`. |
| `compile_jrxml.ps1` | Compile `.jrxml` → `.jasper`. Fast JR7 validity check. |
| `lint_jrxml.ps1` | Static pre-deploy linter — catches strict-Jackson traps offline. **Run before every deploy.** Gate inside `deploy_report.ps1` (`-SkipLint` to bypass). |
| `create_datasource.ps1` | Create/update a JDBC datasource or non-JDBC type (`-Type jndi\|bean\|custom\|virtual\|aws`). `-Test` makes the JRS JVM open the live connection first (`/rest_v2/contexts`) and aborts with the driver's real error on failure. |
| `deploy_report.ps1` | PUT a report unit. `-Overwrite` updates in place. SQL-lint guard. `-Control` / `-QueryControl` / `-QueryMultiControl` attach input controls. |
| `verify_report.ps1` | Run a deployed report and assert HTTP + CSV row-count/contains + visual baseline diff. |
| `scaffold_style_template.py` | Emit a shared JR7 `.jrtx` style template from a color palette. |
| `scaffold_domain_schema.py` + `create_domain.ps1` | Introspect tables → Domain for Ad Hoc reporting: single-table, or multi-table with joins (repeat `--table`, wire with `--join`; emits the JRS 10 join-tree schema). |
| `manage_adhoc.ps1` | Ad hoc views: list / get / export / import / delete. |
| `scaffold_theme.py` + `deploy_theme.ps1` | Emit `overrides_custom.css` from a palette; deploy + activate per organization. |
| `create_mondrian.ps1` | Upload a Mondrian schema + create a `secureMondrianConnection`. |
| `manage_permissions.ps1` + `manage_attributes.ps1` | Repository ACLs and server/org/user attributes. |
| `manage_users.ps1` + `manage_roles.ps1` + `manage_organizations.ps1` | Identity and tenant CRUD. |
| `run_report_async.ps1` | Large fills via the async `reportExecutions` API. |
| `manage_options.ps1` + `manage_cache.ps1` | Saved input-control value sets; clear server caches. |
| `build_dashlets.ps1` + `compose_dashboard.ps1` | Manifest-driven: scaffold → lint → compile → deploy → verify dashlets, then compose and import the dashboard. |
| `export_resource.ps1` + `import_resource.ps1` | Export/import any resource for backup or promotion. |
| `promote.ps1` | Dev→prod promotion (export from source, import to target) between named environment profiles (`-FromEnv`/`-ToEnv`) or explicit `-To*` credentials. |
| `teardown_dashboard.ps1` | Delete a dashboard then its report tiles + `_controls`, in lock-safe order. |
| `extract_lineage.py` | Column-level lineage graph (reports → datasources → tables → columns via `sqlglot`). `--format openlineage` emits OpenLineage events. |
| `diff_resource.ps1` | Drift detection — diffs a live resource descriptor vs. committed local `.json`. |
| `reconcile.ps1` | Declarative desired-state applier. Plan-only by default; `-Apply` to execute. Schema: `references/environment.schema.json`. |
| `report_usage.ps1` | Usage/access-event reporting from the repository metadata DB (`:5433`): top resources, per-user, recent, per-resource; `-Csv`. |
| `get_thumbnail.ps1` | Fetch a report's server-side thumbnail image — the cheapest visual check. |
| `manage_diagnostic.ps1` | Diagnostic log collectors: start/stop/download-zip/delete a scoped server-log capture (support bundle). |
| `scaffold_visualize_embed.py` | Generate a ready-to-open Visualize.js embed page for a report or dashboard. |
| `doctor.ps1` | 10-point environment preflight — server/DB reachable, repo metadata DB, JRS→DB connectivity via `/contexts`, server settings + Visualize.js `domainWhitelist`, jars, config, Python deps. |
| `check_docs.ps1` | Doc-consistency guard — every `references/` link and capability-map script resolves. |
| `smoke_test.ps1` | **24-step end-to-end regression gate** (+ a `wizard-api` step when the web wizard is deployed). Run after any script change. |

### Quick start

```powershell
$skill = ".\plugins\jasper-deploy\skills\jasper-deploy\scripts"
$env:PGPASSWORD = "postgres"

# Preflight check
& $skill\doctor.ps1

# Build and deploy all Foodmart dashlets + compose the dashboard
& $skill\build_dashlets.ps1 -Manifest report\foodmart\dashboard.json -Compose

# Regression gate (run after any script change)
& $skill\smoke_test.ps1
```

### Skill-specific gotchas

These are in addition to the general gotchas in §3 and are also indexed by symptom in `references/gotchas.md`.

| # | Issue | Fix |
|---|---|---|
| S1 | Leading `WITH` (CTE) rejected at fill time | Push CTEs into `FROM` subqueries |
| S2 | Dashboard PUT renders blank | Use `compose_dashboard.ps1` (export/import path) |
| S3 | `resource.in.use` (403) on dashlet report | Delete the dashboard first; use `teardown_dashboard.ps1` |
| S4 | Input controls rejected | Must be standalone repo resources; name must match `$P{param}` |
| S5 | Subreport must reference a file resource | Use `…/rpt_files/Label_main_jrxml`, not a report unit |
| S6 | Ad hoc view PUT fails (`500 "bytes is null"`) | Use `manage_adhoc.ps1` import (same export/import pattern as dashboards) |
| S7 | `.jrtx` default style uses wrong attribute | Use `default="true"`, not 6.x `isDefault="true"` |
| S8 | AWS datasource `-Region` | Use endpoint host (`us-east-1.amazonaws.com`), not the bare code |
| S9 | `compose_dashboard.ps1 -WorkDir` | Pass absolute path; relative paths fail when CWD differs |
| S10 | SLF4J "no providers" on stderr aborts PS | `Invoke-JrCompile` absorbs it; don't wrap in `$ErrorActionPreference=Stop` |

### Reference files

`references/` contains the authoritative detail behind `SKILL.md`:

| File | Contents |
|---|---|
| `reports.md` | Report scaffolding, compilation, deployment patterns |
| `dashboards.md` | Dashboard model, dashlet wiring, import/export |
| `data-and-semantic-layer.md` | Datasources, Domains, Ad Hoc views |
| `admin-and-scheduling.md` | Users, roles, orgs, scheduling, permissions |
| `jr7-schema.md` | JR7 `.jrxml` schema reference |
| `jr7-valid-elements.md` | Valid/rejected element names per construct (source-cited) |
| `gotchas.md` | 60+ issues indexed by symptom → fix; JRS errors auto-print a pointer here |
| `dashboard-model.md` | Dashboard JSON model internals |
| `security-and-config.md` | Secrets management, env-only creds, `passwordCommand`, named environment profiles |
| `visualize-embedding.md` | Visualize.js embedding patterns + full 10.1 API surface |
| `ci-smoke.md` | CI integration for `smoke_test.ps1` |
| `manifest.schema.json` | Dashboard manifest JSON schema |
| `jrs.config.schema.json` | Server config JSON schema |
| `environment.schema.json` | Reconcile environment manifest schema |
| `jrs-rest-api.md` | Verified-vs-doc-only REST endpoint map + version deltas |
| `version-matrix.md` | Deep 9.0 → 10.0 → 10.1 delta (features, platforms, upgrade paths) |
| `upgrade-migration-playbook.md` | **Cross-version upgrade planning 4.7 → 10.1**: field-issue guiding input (sec 0), vendor EOL dates (sec 1b), upgrade ladder, platform cliffs, pain-point mitigations, pre-upgrade checklist |
| `version-archive/` | Per-era source depth: platform-evolution, upgrade-procedures, relnotes-install-deltas (every claim cited to its vendor PDF) |
| `authentication.md` | LDAP / CAS / token pre-auth / OAuth-OIDC setup |
| `server-hardening.md` | Keystore, CSRF, SSL, lockout + REST 401/403 checklist |
| `server-administration.md` | js-import/export, buildomatic, logging/audit, ehcache |
| `olap.md` | Mondrian schema anatomy, AGXML grants, XML/A |
| `domains-deep.md` | Domain internals: schema XML, DomEL, security files |
| `aws-telemetry-vpat.md` | AWS deployment, telemetry opt-out, VPAT/WCAG |

### Vendor documentation corpus (`docs\`, local-only)

`docs\` holds ~220 official JasperReports Server PDFs spanning **4.7 through
10.1.0** (upgrade/install guides, release notes, platform support, admin/user
guides, wiki technical articles) plus the vendor EOL policy extraction and the
field-reported upgrade-issues tracker. It is **gitignored and must stay that
way** — the PDFs are Cloud Software Group copyrighted material and cannot be
redistributed; only the distilled, cited summaries in `references/` are ours to
publish. The community site 403s scripted fetches (Cloudflare); recover or
extend the corpus via the Wayback CDX API
(`web.archive.org/web/<ts>id_/<url>` replay). Read PDFs with `pdftotext` or
`pypdf`.

### Plugin distribution

The repo doubles as a Claude Code plugin marketplace (`.claude-plugin/
marketplace.json` + `plugin.json`, marketplace name `jaspersoft-tools`,
plugin root = repo root, skills path `./.claude/skills/`). Consumers install
without cloning:

```
/plugin marketplace add robertgorsuch/AI-JasperReports-Generator
/plugin install jasper-deploy@jaspersoft-tools
/reload-plugins
```

Maintenance: bump `version` in `.claude-plugin/plugin.json` when script
interfaces change (semver contract in `CONTRIBUTING.md`); consumers pick up
changes with `/plugin update jasper-deploy`. Validate manifests with
`claude plugin validate .`. Do NOT install the plugin on a machine that works
in this repo — the project-level skill already loads.

### Contribution governance

`CONTRIBUTING.md` (in the skill root) defines the conventions, per-change-type
definition-of-done checklists, and the two test gates (offline:
`check_docs.ps1` + Pester; live: `smoke_test.ps1`). GitHub templates enforce
it: `.github/PULL_REQUEST_TEMPLATE.md` embeds the checklists;
`.github/ISSUE_TEMPLATE/` has tailored bug/feature forms; `CODE_OF_CONDUCT.md`
applies everywhere. Generated Office artifacts (`*.docx`/`*.pptx`) are
gitignored — regenerate them from tracked md/html sources with
`scripts/make_docx.ps1`; do not commit the binaries.

---

## 10. Self-service web wizard (`webapp\jasper-wizard\`)

A Jakarta servlet WAR (Actian-branded) that puts the `jasper-deploy` skill behind a browser UI for business users. No JRXML or REST knowledge needed.

**URL:** `http://localhost:8081/jasper-wizard/`

**Capabilities:** reports (SQL → chart/table, live query preview, input controls), dashboards, data sources, domains, themes, run & export (PDF/XLSX/CSV/DOCX/PPTX + async), scheduling, repository browse, ad hoc list/export, permissions, and a **Server Summary** (repository inventory + runtime characteristics).

### Architecture

- Read/preview/run operations proxy directly to JRS REST via `JrsClient` (auth added server-side; no browser credentials, no CORS).
- Create/deploy operations shell out to the verified skill scripts via `ScriptRunner`. Scripts are **bundled inside the WAR** (`WEB-INF/scripts`) because the Tomcat service runs as `NT AUTHORITY\LocalService` and cannot read the user profile.
- Child processes run from the container temp directory (writable). This is why the wizard passes an absolute `-WorkDir` to `compose_dashboard.ps1`.

> If you change a skill script's parameters or stdout shape, update the matching wizard handler.

### Build and deploy

```powershell
cd webapp\jasper-wizard
.\build.ps1               # compile + bundle scripts + WAR + hot-deploy to JRS Tomcat
.\build.ps1 -NoDeploy     # build only — produces target\jasper-wizard.war
```

The build compiles against Tomcat's bundled `servlet-api.jar` with JDK 11 (Jakarta Servlet `jakarta.servlet.*`, not `javax.*`). No Maven required.

### Configuration

All configuration is in `WEB-INF/web.xml` context-params:
- JRS URL, username, password
- PostgreSQL host, port, user, password
- Python executable path
- Script execution timeout

Edit `web.xml` and rebuild, or edit the exploded webapp in Tomcat's `webapps/` directory and restart the app.

> ⚠️ Security note: the wizard runs user-supplied SQL against the configured DB and publishes using stored admin credentials. Keep it behind the JRS login and a network boundary. Command args are passed as an argv array (no shell-injection surface), but SQL runs with the data source's privileges.

---

## 11. Troubleshooting quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `DOWNLOAD FAILED` in loader log | Corrupt ZIP from Census CDN | Re-run with cache-buster (`?cb=<timestamp>`) + browser User-Agent (`-A`) |
| `400` on report deploy | Strict-Jackson violation in `.jrxml` | Run `lint_jrxml.ps1`; check `references/jr7-valid-elements.md` |
| `400` with "leading WITH" message | CTE at top of report query | Rewrite as `FROM (SELECT ...)` subquery |
| `403 resource.in.use` | Report is a dashlet of a live dashboard | Delete the dashboard first; use `teardown_dashboard.ps1` |
| Dashboard renders blank after PUT | Hand-built dashboard model | Use `compose_dashboard.ps1` (export/import path) |
| `500 "bytes is null"` on ad hoc view PUT | Raw PUT not supported for adhocDataView | Use `manage_adhoc.ps1 import` |
| `JSSecurityException` at fill time | JRS SQL validator rejection | Ensure query starts with `SELECT`; no leading `WITH` |
| `Missing JasperReports PDF Extension` | Core jar without the `jasperreports-pdf` module | Build and include `ext/pdf` (see §5) |
| SLF4J "no providers" aborts PowerShell | `$ErrorActionPreference=Stop` + JR stderr | Use `Invoke-JrCompile` helper which absorbs stderr |
| `405` on JRS REST call | URL built with bare `$var?param=` | Use `${var}?param=` in PowerShell |
| `400` on array property | `ConvertTo-Json` unwraps single-element array | Emit as hand-built JSON string |

For deeper diagnosis, run `doctor.ps1` for environment preflight and check `references/gotchas.md` (indexed by symptom).

---

## 12. pos_perf: rebuild aggregates, redeploy a report, recompose a dashboard

Rebuild aggregates (idempotent, ~2 min):
    $adm = ".\.claude\skills\admiral\scripts"
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_aggregates.sql -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_aggregates.sql -ResourceId av-flm7ykoxlcvq

Redeploy one report after editing its jrxml:
    $env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\lint_jrxml.ps1" -Path report\pos_perf\exec_region_bar.jrxml
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_region_bar.jrxml -TargetUri /reports/pos_perf/exec_region_bar -Label "Net Sales by Region" -DataSourceUri /datasources/pos_data_avalanche -Overwrite
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/exec_region_bar -Format pdf -OutFile out\pos_perf\exec_region_bar.pdf

Rebuild the Treasury tender aggregate (Phase 1, feeds trs_tender_mix):
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_tender_monthly.sql -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_tender_monthly.sql -ResourceId av-flm7ykoxlcvq

Rebuild the two Phase 2 retention aggregates (feeds the six chn_* tiles and the
Churn Action List; dash_churn is customer grain and takes the longer of the two):
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_churn.sql   -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_churn.sql  -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_cohort.sql  -ResourceId av-flm7ykoxlcvq
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_cohort.sql -ResourceId av-flm7ykoxlcvq
Expected from verify_dash_churn: 3,184,743 rows, 0 duplicate keys, an exact
tie-out to the source, bands Critical 684,159 / High 1,447,344 / Watch 587,944
/ Low 465,296, Critical+High LTV at risk 20,807,163.28, and four regions and
four tiers with no NULLs. Expected from verify_dash_cohort: 36 rows, cohort
years 2019 and 2020, 0 duplicate keys, active_pct exactly 100.00 at month 0 for
both cohorts, 2019 settling around 26-28 pct and 2020 (a partial year, so it
stops at month 11) around 20-24 pct, and agg_rows = src_rows = 39,654,230.

Create the shared finance input controls (idempotent, skips what exists):
    $env:JRS_ENV = "stage"
    . .\scripts\pos_perf\jrs_controls.ps1
    New-FinanceControls
The helper is dot-sourced, so the environment binds at dot-source time --
there is no -Env switch on New-FinanceControls itself; use
`. .\scripts\pos_perf\jrs_controls.ps1 -Env prod` to target PROD. Controls
land under /reports/pos_perf/controls/ (p_asof, p_regions, p_franchisee,
p_store, p_yyyymm, p_version, p_province, plus their LOV/query companions).
A control already attached to a report unit is skipped with a WARNING; re-run
with -Force only if you really mean to replace it.

Create the shared churn input controls (same dot-source contract; the file
dot-sources jrs_controls.ps1 and reuses its idempotency machinery):
    $env:JRS_ENV = "stage"
    . .\scripts\pos_perf\churn_controls.ps1
    New-ChurnControls
    Attach-ChurnControls -ReportUri /reports/pos_perf/chn_kpi
`New-ChurnControls` creates exactly three controls -- chn_score_date (Score
date), chn_tier (Loyalty tier), chn_band (Risk band) -- all type 7
multiSelectQuery, plus their _query companions, under
/reports/pos_perf/controls/. It deliberately does NOT create `p_regions`: that
control already exists from the Phase 0 Ops Console work and is reused as-is.
`Attach-ChurnControls` attaches the fixed four-control set in strip order
(chn_score_date, p_regions, chn_tier, chn_band) to one report unit. Use
`. .\scripts\pos_perf\churn_controls.ps1 -Env prod` to target PROD.

Recompose a dashboard (delete first, the import will not overwrite companions):
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_executive_overview
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\exec_dashboard.json -AutoGrid

Redeploy the whole Retention and Churn console after editing any chn_* jrxml.
The teardown is not optional: a tile of a composed dashboard 403s with
resource.in.use. Five tiles get the controls back, chn_cohorts gets none:
    $env:JRS_ENV = "stage"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    $ds = "/datasources/pos_data_avalanche"
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_retention_churn
    foreach ($u in @("chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_cohorts","chn_actions")) {
        & "$jd\lint_jrxml.ps1"    -Path "report\pos_perf\$u.jrxml"
        & "$jd\deploy_report.ps1" -Jrxml "report\pos_perf\$u.jrxml" -TargetUri "/reports/pos_perf/$u" -Label $u -DataSourceUri $ds -Overwrite
    }
    . .\scripts\pos_perf\churn_controls.ps1
    foreach ($u in @("chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_actions")) { Attach-ChurnControls -ReportUri "/reports/pos_perf/$u" }
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\chn_dashboard.json -AutoGrid
The six tile labels ARE their unit names (chn_kpi, chn_bands, ...); only the
drill target carries a prose label, "Churn Action List". The manifest supplies
the human-readable dashlet captions (Key Metrics, Risk Bands, LTV at Risk by
Band, Top Churn Drivers, Cohort Retention, Recommended Actions) and the
composer resolves dashlets by URI, never by label, so a mismatched deploy label
will not break composition. Keep them as written anyway: an export names each
unit's jrxml payload after the LABEL, so changing one silently renames the file
the server-vs-git diff below is looking for.

Verify the Phase 2 build on STAGE without a browser -- render all seven units
and diff the server against git:
    New-Item -ItemType Directory -Force "out\pos_perf\phase2" | Out-Null
    foreach ($u in @("chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_cohorts","chn_actions","rpt_churn_action_list")) {
        & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$u" -Format pdf -OutFile "out\pos_perf\phase2\$u.pdf" -TimeoutSec 300
    }
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/pos_retention_churn    -Out out\pos_perf\phase2\exp_pos_retention_churn.zip
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/rpt_churn_action_list  -Out out\pos_perf\phase2\exp_rpt_churn_action_list.zip
The dashboard export carries each tile's jrxml as
resources/reports/pos_perf/<unit>_files/<unit>_main_jrxml.data; the report
export names its payload after the LABEL, not the unit, so the Churn Action
List lands as rpt_churn_action_list_files/Churn_Action_List_main_jrxml.data.
Compare each against report\pos_perf\<unit>.jrxml -- they should be byte
identical. A server copy that instead comes back with uuid attributes on every
element, reordered attributes, no XML comments, and an extra
`net.sf.jasperreports.viewer.zoom` property is a JRS re-serialization, i.e. the
unit on the server is NOT the file in git. That is not cosmetic drift to wave
through: redeploy from the committed jrxml and re-export until the bytes match.

Expected in chn_kpi.pdf: Scored Customers 3,184,743, Critical + High Risk
66.9%, LTV at Risk $20,807,163, Overdue vs Expected 32.5%, Avg Churn
Probability 0.524, footer "Customers scored as of 2020-12-31". Expected in
chn_actions.pdf: five rows, no "None" row, Loyalty bonus 265,021 / $7,808,187
at the top. To prove the filter plumbing without a browser, run chn_kpi with
explicit values (note the Hashtable form -- `-Parameters "k=v"` fails before
the run is even submitted):
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/chn_kpi -Format pdf `
        -OutFile out\pos_perf\phase2\chn_kpi_critical.pdf -Parameters @{ chn_band = "Critical"; chn_score_date = "2020-12-31" }
Expect Scored Customers 684,159 and LTV at Risk $4,995,666, which is exactly
the Critical row of the band distribution.

Re-attach input controls after ANY redeploy of a Treasury tile or a finance
report -- deploy_report.ps1 -Overwrite replaces the whole report unit and
drops inputControls:
    . .\scripts\pos_perf\jrs_controls.ps1
    $ctl = @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
    Attach-Controls -ReportUri /reports/pos_perf/trs_ar_aging -ControlUris $ctl
Then GET-verify it stuck:
    . ".\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1"; $jrs = Resolve-JrsConfig
    @((Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/trs_ar_aging").Body | ConvertFrom-Json | ForEach-Object inputControls).Count

Verify a whole build on STAGE without a browser -- render every tile and
report to PDF, then diff the server against git:
    foreach ($u in @("pnl_kpi_strip","pnl_waterfall","pnl_variance_region","pnl_contribution_trend","pnl_worst_stores","trs_kpi","trs_ar_aging","trs_dpo","trs_tender_mix","trs_tax_province","trs_liability","trs_lease_expiry","rpt_store_pnl_statement","rpt_ar_aging","rpt_ap_aging","rpt_tax_remittance")) {
        & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$u" -Format pdf -OutFile "out\pos_perf\phase1\$u.pdf" -TimeoutSec 300
    }
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/pos_treasury -Out out\pos_perf\phase1\exp_pos_treasury.zip
The export zip carries each tile's jrxml as
resources/reports/pos_perf/<unit>_files/*_main_jrxml.data, the composed layout
as <dash>_files/components.data (tile list, canvasColor, filter group), and
each report unit's attached controls in <unit>.xml -- enough to confirm that
what is on the server is what is in git.

Reconcile the finance KPIs against the semantic layer (one API GET, then any
number of offline re-runs):
    $cfg = Get-Content ".claude\skills\wobby\wobby.config.json" -Raw | ConvertFrom-Json
    $r = Invoke-WebRequest -Uri "$($cfg.baseUrl)/api/public/v1/environment" -Headers @{Authorization="Bearer $($cfg.apiKey)"} -Method Get -UseBasicParsing
    [IO.File]::WriteAllText("$PWD\out\pos_perf\wobby_env_phase1.json", $r.Content)
    python scripts\pos_perf\wobby_metric_crosscheck.py out\pos_perf\wobby_env_phase1.json
The config file is gitignored and the key never lands in a committed file. The
API allows 2 requests per 5 seconds -- fetch the export once and re-run the
script against the saved file.

Verify the Phase 3 build on STAGE without a browser -- render all 13 units
and diff the server against git:
    New-Item -ItemType Directory -Force "out\pos_perf\phase3" | Out-Null
    foreach ($u in @("sup_kpi","sup_stock_status","sup_gmroi","sup_scorecard","sup_shrink","lab_kpi","lab_heatmap","lab_format","lab_indexed","lab_conversion","rpt_inventory_reorder","rpt_supplier_scorecard","rpt_weekly_flash")) {
        & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$u" -Format pdf -OutFile "out\pos_perf\phase3\$u.pdf" -TimeoutSec 480
    }
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/pos_supply_inventory  -Out out\pos_perf\phase3\exp_pos_supply_inventory.zip
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/pos_workforce_labour -Out out\pos_perf\phase3\exp_pos_workforce_labour.zip
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/rpt_inventory_reorder  -Out out\pos_perf\phase3\exp_rpt_inventory_reorder.zip
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/rpt_supplier_scorecard -Out out\pos_perf\phase3\exp_rpt_supplier_scorecard.zip
    & "$jd\export_resource.ps1" -Uri /reports/pos_perf/rpt_weekly_flash       -Out out\pos_perf\phase3\exp_rpt_weekly_flash.zip
`rpt_inventory_reorder` is an unfiltered 85,573-row pick list (2,000+ pages) --
give it its own longer-timeout call if the loop above times out on it, same as
this session did (2-minute default timeout was not enough).

Run 2026-08-25: all 13 units render, and all 13 came back byte-identical to
git (server bytes == git bytes exactly, not just after whitespace
normalisation). `pos_supply_inventory` composed with 5 dashlets and the four
supply controls (p_regions, sup_store, sup_category, sup_supplier) attached to
all five tiles; `pos_workforce_labour` composed with 5 dashlets and no filter
strip, matching the console/cockpit archetype split from the plan. sup_kpi at
defaults: 12.1% out of stock, 5.0% overstock, 27.8 avg days of supply, 85.0%
supplier on-time, 0.37% shrink of COGS. lab_kpi at defaults: 2020 labour cost
about $35.2M, 8.4% of net sales. rpt_weekly_flash at its default week ending
2020-11-08: week sales $7,191,916.49 (-4.4% vs prior week, -15.1% vs the
pro-rated plan), 2 pages.

Verify the Phase 4 build on STAGE without a browser -- render all 12 units
(10 tiles + rpt_franchisee_fee_statement + the modified trs_kpi) and diff the
server against git:
    New-Item -ItemType Directory -Force "out\pos_perf\phase4" | Out-Null
    foreach ($u in @("net_map","net_sqft_format","net_income_scatter","net_lease","net_exposed","mkt_kpi","mkt_funnel","mkt_ecom_share","mkt_campaign_roi","mkt_partners","rpt_franchisee_fee_statement","trs_kpi")) {
        & "$jd\run_report_async.ps1" -ReportUri "/reports/pos_perf/$u" -Format pdf -OutFile "out\pos_perf\phase4\$u.pdf" -TimeoutSec 300
        & "$jd\export_resource.ps1" -Uri "/reports/pos_perf/$u" -Out "out\pos_perf\phase4\exp_$u.zip"
    }
Extract each zip's `*_main_jrxml.data` payload and compare its bytes against
`report\pos_perf\<u>.jrxml` -- same recipe as Phase 1/2/3.

Run 2026-08-25: all 12 units render, and all 12 came back byte-identical to
git (exact byte-length match, no whitespace normalisation needed). Dashboard
composes confirmed via a direct REST GET (`resources[].type -eq "reportUnit"`
on the dashboard's own resource descriptor, since dashboards do not expose a
top-level `inputControls` field the way report units do): `pos_store_network`
composed with exactly 5 dashlets (net_map, net_sqft_format,
net_income_scatter, net_lease, net_exposed) and no filter strip;
`pos_marketing_digital` composed with exactly 5 dashlets (mkt_kpi, mkt_funnel,
mkt_ecom_share, mkt_campaign_roi, mkt_partners) and no filter strip;
`pos_treasury` still has all 7 dashlets (trs_kpi, trs_ar_aging, trs_dpo,
trs_tender_mix, trs_tax_province, trs_liability, trs_lease_expiry) after Task
5's teardown/recompose, and all seven still carry their 3 controls
(p_asof, p_regions, p_franchisee) GET-verified attached -- Task 5's teardown
only rebuilt the dashboard wiring, it did not redeploy trs_ar_aging, trs_dpo,
trs_tender_mix or trs_tax_province, and none of them drifted.
`rpt_franchisee_fee_statement` carries its 2 controls (p_franchisee_id,
p_yyyymm) GET-verified attached.

mkt_kpi at defaults: E-Commerce Share 1.4%, Late Fulfilment 6.8%, Email Open
Rate 37.6%, Email Click Rate 12.1%, Promotion ROI 84.91x. trs_kpi AR
Outstanding unchanged at $5,399,130. rpt_franchisee_fee_statement at defaults
(franchisee 0, Stella Martin, through December 2020): 4 pages, Total Invoiced
$404,069.79 / Total Paid $347,395.84 / Total Balance $56,673.95, matching Task
5's own reconciliation against `franchise_fee_ledger` exactly.

`scripts/pos_perf/wobby_metric_crosscheck.py` was extended this phase with 9
more CHECKS entries -- `ecommerce_revenue_share_pct`,
`ecommerce_late_fulfillment_rate`, `avg_ecommerce_satisfaction_score`,
`email_open_rate`, `email_click_rate`, `email_conversion_rate`,
`promotion_roi`, `subsidy_cost_per_conversion`, `total_campaign_conversions`
-- following the file's existing pattern (a `tile_sql` / `wobby_sql` pair per
metric, run through `sql.ps1` and compared). Its `resolve()` helper also
needed a real fix, not just new data: the Phase 1-3 metrics all have a
literal `"<model>.<measure>"` `expression` field that has to be walked to the
measure's own SQL, but every Phase 4 growth metric's `expression` is already
a full compound SQL string (e.g. `email_engagement.emails_opened * 100.0 /
NULLIF(email_engagement.emails_sent, 0)`) with the anchor table named
separately in `anchor_model` -- treating the second shape like the first
produced a false `"measure ... missing on model X"` diagnostic on every new
check even though the VALUES agreed. `resolve()` now branches on whether
`expression` matches the simple `model.measure` shape before deciding how to
find the table and what to diff against `expect_expr`.

Run 2026-08-25 against the same one `/api/public/v1/environment` fetch (52
models, 112 metrics; saved to `out\pos_perf\wobby_env_phase4.json`, gitignored
like all `out/`): 19 of 20 checks clean (11 original + 8 of 9 new). The one
flagged check, `ecommerce_revenue_share_pct`, disagrees by 0.72 pct (tile 1.40
vs Wobby 1.39) with a documented cause, not a data error -- the tile's
denominator is `store_pnl_monthly.net_sales` (the store-month P&L rollup),
while Wobby's own metric definition sums `ecommerce_orders.total_order_value +
pos_sales_detail.total_sales` at the raw line-item level, a different revenue
base by construction. `promotion_roi` (the SAME source table and expression
as `mkt_kpi.promo_roi`, unfiltered) matched exactly at 84.91, confirming
`mkt_campaign_roi`'s $1,000 subsidy floor is a display-ranking choice on that
one chart, not a redefinition of the network-wide metric.

### Checks that need a human with a browser

An agent cannot do these: dashboards do not render to PDF, and the filter strip
and drill links are viewer behaviour. STAGE base is
http://localhost:8081/jasperserver-pro; dashboards open at
`/dashboard/viewer.html#%2Freports%2Fpos_perf%2F<name>`.

1. **Treasury filter strip.** Open pos_treasury. Confirm a strip renders with
   As of month / Regions / Franchisee and an Apply button. Set Regions=Quebec,
   As of month=202006, press Apply. Expect AR Outstanding to fall from
   $5,399,130 to $93,477, the AP Outstanding chip to blank (there are no unpaid
   supplier invoices before 2020-11-03), Tax Collected YTD to drop to
   $1,008,049, and the footer to read "invoices through 2020-06". If the strip
   does not render or Apply is inert, fall back to per-dashlet popups: drop the
   `filters` key from report/pos_perf/trs_dashboard.json, add
   `"dashletFilterShowPopup": true` as ops_dashboard.json does, then teardown
   and recompose.
2. **Drill click-tests.** From pos_store_pnl click a store name in the Lowest
   Four-Wall Margin tile (expect the Store P and L Statement for that store at
   202012). From pos_treasury click a bar in Receivables Aging, Days to Pay by
   Terms, and Tax Collected by Province (expect the AR, AP and Tax Remittance
   reports). Watch one thing in particular: set Regions=Quebec on the strip
   before clicking the AR bar. `p_regions` and `p_franchisee` cross the drill
   URL as a java.util.Collection; if the target opens with "Regions: Quebec" in
   its subtitle the collection survived, if it opens with "Regions: all" it was
   dropped silently rather than erroring.
3. **Navy eyeball.** Open pos_executive_overview and pos_promo_story. Confirm
   the canvas is #000032 with no white gutters and that axis text, legends and
   item labels are legible. Known and accepted: the Actian logo image has a
   baked-in white plate and reads as a white box, and JFreeChart meter tick
   labels are pure blue with no override.
4. **Spike cleanup.** /reports/pos_perf/spike_filter_test is deliberately still
   standing so check 1 can be cross-checked against a minimal case. Once check
   1 passes, delete it:
       & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/spike_filter_test
5. **Retention and Churn filter strip.** Open pos_retention_churn. Confirm a
   strip renders with Score date / Regions / Loyalty tier / Risk band and an
   Apply button. All four are multi-selects. Set Risk band=Critical and Score
   date=2020-12-31, press Apply. Expect the Key Metrics strip to go to Scored
   Customers 684,159, Critical + High Risk 100.0%, LTV at Risk $4,995,666,
   Overdue 62.8%, Avg prob 0.789 -- the exact figures the parameterized
   chn_kpi run produces headlessly, so any other number means the strip is not
   reaching the tile. Clear Risk band, set Regions=Ontario and Loyalty
   tier=Gold, Apply: expect 256,992 / 17.8% / $901,174. Cohort Retention must
   not change under any of this; it is lifetime scoped on purpose.

   Fallback if the strip does not render or Apply is inert: the same shape
   Phase 1 uses -- drop the `filters` key from report/pos_perf/chn_dashboard.json,
   add `"dashletFilterShowPopup": true` as ops_dashboard.json does, then
   teardown and recompose. It works here, but read the two differences before
   reaching for it. (a) In popup mode a tile's filter widgets come from its own
   ATTACHED input controls, not from the manifest, so the reader has to set the
   same four values five separate times -- once each on chn_kpi, chn_bands,
   chn_ltv_band, chn_drivers and chn_actions -- and there is no single Apply
   that moves the board. That is a real downgrade in this suite, not the
   near-equivalent it was on the Ops Console. (b) chn_cohorts has no attached
   controls, so it gets no popup at all; correct, but it means the fallback
   silently removes the only visual cue that the tile is deliberately
   unfiltered. If you take the fallback, say so on the tile.

   Do NOT try the narrower "fix" of leaving the strip up and dropping
   chn_cohorts out of the filter wiring. gen_dashboard.py hands the whole
   `filters` array to every report dashlet and wires every control to every
   report dashlet's @applyParams with no check that the tile declares the name;
   the wiring is blind by design and the manifest has no per-dashlet opt-out.
   That is why chn_cohorts declares all four parameters and reads none of them.
6. **Churn Action List drill click-test, and the Collection-to-String
   derivation.** This is the one Phase 2 behaviour that has been proven at the
   SQL and render level but never in a viewer. On pos_retention_churn, first
   press Apply on the strip with Score date=2020-12-31 selected, THEN click an
   Action cell in Recommended Actions (any row). Expect the Churn Action List
   to open with "as of 2020-12-31" in its subtitle and 500 detail rows.

   What is actually under test: the console's controls are Collections, but the
   target report's two parameters are Strings. chn_actions bridges that with a
   `p_score_date` default expression that takes `.iterator().next()` off
   `chn_score_date`, and the hyperlink passes THAT derived String. A headless
   parameterized run exercises the same expression, but only a real Apply
   click proves the derivation survives the round trip through the filter
   strip and into the drill URL. If the target opens on a different date, or
   errors on a class cast, the derivation did not survive; if it opens showing
   the default 2020-12-31 when the strip is set to some other score date, the
   strip value never reached the tile.

   Expected and NOT a defect: the target always opens on p_region="All", even
   when the strip has a single region selected. chn_actions passes the literal
   string "All", the same convention Phase 1 used for trs_tax_province into
   rpt_tax_remittance -- the target is a workable ranked list, not a per-action
   drill, so it does not inherit a filter the reader would have to undo.
7. **Top Churn Drivers subtitle.** Visual read only, no clicking. The tile's
   subtitle says "Among customers in the Critical band, regardless of the risk
   band filter". It means it: the tile is pinned to Critical and its numbers do
   not move when the strip's Risk band changes. Confirm that the sentence sits
   close enough to the chart, and reads plainly enough next to a Risk band
   widget that is set to something else, that a viewer reads it as a stated
   scope rather than as a filter that failed to apply. If it does not, the fix
   is wording or placement on chn_drivers.jrxml, not a change to what the tile
   counts -- ranking drivers across all four bands would just rank the
   population, which is the question chn_bands already answers.
8. **Supply and Inventory filter strip.** Open pos_supply_inventory. Confirm a
   strip renders with Regions / Store / Category / Supplier and an Apply
   button. Set Category to a single value and press Apply; expect the Stock
   Status, GMROI and Shrink by Reason tiles to narrow to that category while
   Supplier Scorecard (which has no category column of its own -- see the
   header comment on sup_scorecard.jrxml) does not move. Fallback if the strip
   does not render or Apply is inert: drop the `filters` key from
   report/pos_perf/sup_dashboard.json, add `"dashletFilterShowPopup": true`,
   teardown and recompose -- the same downgrade Phase 1/2 document (one Apply
   becomes five separate popups).
9. **Supplier Scorecard drill click-test.** From pos_supply_inventory click a
   supplier name in the Supplier Scorecard tile. Expect the paginated Supplier
   Scorecard report to open with "Quarter: All" in its subtitle -- this drill
   always opens unscoped by design, the same fixed-scope convention Phase 1
   used for trs_tax_province -> rpt_tax_remittance.
10. **Workforce and Labour heatmap read.** Open pos_workforce_labour. Confirm
    the Scheduled Hours Heatmap tile reads as a heatmap to a human -- a 7x2
    grid of cells shaded from light (`#D6E0EF`) to dark blue (`#0550DC`) by
    sales-per-labour-hour, each cell printing its scheduled-hours number, not
    just a compiled crosstab that happens to render. If it does not read as a
    heatmap, the documented fallback in the file's header comment is a grouped
    bar chart (day on the category axis, one series per shift) -- switch to it
    only if the crosstab genuinely fails the eyeball test, not for polish.
11. **Inventory Reorder List page-count sanity check.** Open
    /reports/pos_perf/rpt_inventory_reorder at its default (`p_store="All"`)
    and confirm it opens and paginates sensibly rather than hanging or timing
    out in the viewer -- it is deliberately uncapped at 85,573 rows / 2,000+
    pages (a real operational pick list, not a top-N sample). If it is
    genuinely impractical to open in the viewer, the fix is a per-store
    default or a documented cap, not a silent one; raise it rather than
    unilaterally capping the report.
12. **Store Network map read.** Open pos_store_network. Confirm the
    `net_map` tile reads as a real map to a human -- roughly 330 points
    tracing recognisable Canadian regional clusters (Vancouver,
    Calgary/Edmonton, Winnipeg, Ontario/Quebec, Maritimes, Newfoundland,
    Yukon), amber-ringed markers standing out for the 2+-competitor stores,
    bubble size varying legibly with sales per square foot -- not just that
    it compiles. This tile is a JFreeChart `chartType="bubble"` substitute
    for the community `jr:map` component (confirmed absent from this STAGE
    server's classpath, see net_map.jrxml's header comment); if it does NOT
    read as a map to a human eye, the fallback is not silent -- raise it as a
    concern rather than shipping a scatter plot that happens to be geographic
    by coincidence of axis choice.
13. **Top Campaign ROI drill click-test.** From pos_marketing_digital click
    any bar in the Top Campaign ROI tile. Expect the Weekly Flash report to
    open at its default week ending 2020-11-08 -- this is expected and NOT a
    bug regardless of which campaign bar was clicked. rpt_weekly_flash
    declares exactly one parameter, `p_week_ending`, with no per-campaign
    parameter; the drill cannot scope to the clicked campaign without
    changing that report's contract, which is out of scope (documented at
    length in mkt_campaign_roi.jrxml's header comment).
14. **AR Outstanding drill click-test.** From pos_treasury click the AR
    Outstanding chip in the Key Metrics tile. Expect the Franchisee Fee
    Statement report to open for franchisee id 0 (Stella Martin), through
    December 2020 -- this is expected and NOT a bug: the drill always opens
    unscoped to franchisee 0, not to any particular franchisee tied to the
    chip's own network-wide total (documented in trs_kpi.jrxml's header
    comment as a fixed-scope deviation, the same convention Phase 1/2/3 use
    for their own unscoped drills).
15. **Top Campaign ROI page-count sanity check.** Visual read only, no
    clicking. Open pos_marketing_digital and look at the Top Campaign ROI
    tile's 15 bars against its subtitle ("Top 15 of 75 promotions with
    subsidy $1,000 or more..."). Confirm 15 feels like the right cut for a
    dashlet this size -- bars legible, labels not crowded -- rather than a
    number that happened to be convenient. If a future revision wants more
    of the 75 eligible promotions visible, the fix is a drill to a paginated
    ranked list, not raising the cap on an already-dense bar chart.

### PROD promotion EXECUTED 2026-08-27 (all four phases + Phase 0 fix)

Run by the agent on 2026-08-27 on the user's explicit instruction, as one
sequential pass over the four blocks below (the blocks are kept verbatim as
the re-promotion recipe). What was done and verified:

1. Preflight: STAGE exports of all 10 dashboards + 9 reports byte-diffed
   against git. One drift: `rpt_franchisee_fee_statement` on STAGE was a JRS
   re-serialization (uuid attrs, viewer.zoom, comments gone). Redeployed from
   git on STAGE, controls re-attached, pos_treasury recomposed, re-export
   byte-identical. PROD datasource `/datasources/pos_data_avalanche` confirmed
   to point at the same warehouse as STAGE (av-flm7ykoxlcvq), so Step 0
   aggregates were a no-op everywhere.
2. Controls: New-FinanceControls, New-ChurnControls, New-SupplyControls,
   New-FranchiseeControl on PROD; all 14 controls GET 200 (p_regions
   pre-existed, untouched).
3. Teardown x10, deploy all 60 units from git (Phase 1's 28 incl. the 12 navy
   tiles + ops_region_bar + Phase 2's 7 + Phase 3's 13 + Phase 4's 11),
   Attach-Controls per the four Step 4 lists, GET-verify: 0 count mismatches.
4. Compose all 10 dashboards, smoke 10 PDFs: every expected figure in the
   four Step 7 lists matched (pnl_kpi_strip, trs_kpi, chn_kpi, 14-page churn
   list "Top 500 of 1,357,153", sup_kpi, lab_kpi $35,169,013, mkt_kpi,
   net_exposed 4 rows, franchisee statement 4 pages $404,069.79).
5. Final export of PROD: all 65 report units byte-identical to git (the five
   untouched ops_* tiles included).
6. Found and fixed: the accepted STAGE boards carried designer-level settings
   the manifests could not express (scaleToFit "container" on P&L / Store
   Network / Treasury tiles, export+print buttons on P&L / Promo Story /
   Marketing, autoRefresh on P&L / Promo Story, right-aligned filter buttons
   on Treasury). gen_dashboard.py now honours manifest keys `autoRefresh`,
   `showExportButton`, `showPrintButton`, `filterButtonsPosition`,
   `filterFloating` and per-dashlet `scaleToFit`; the five manifests were
   synced from the pre-recompose STAGE exports and those boards recomposed on
   PROD (and Treasury on STAGE, which step 1 had reverted). Component-level
   compare against the accepted STAGE state: identical except a transient
   `hovered:false` flag the designer had saved on three filter controls.
   pos_retention_churn / pos_supply_inventory on PROD have a docked filter
   strip (`floating:false`, today's gen_dashboard default); STAGE still has
   the older floating strip on those two -- recompose STAGE to align.

Still open after this run: the browser checks 1-15 above now apply to PROD
(http://3.214.51.180:8080/jasperserver-pro) as well as STAGE;
`/reports/pos_perf/spike_filter_test` is still standing on STAGE pending
check 1. The `Invoke-JrsGet` helper returns `.Code` rather than throwing on a
404, so existence checks must test `.Code -eq "200"`; and `deploy_report.ps1`
reports success via Write-Host, which `2>&1` does not capture under PS 5.1
-- capture with `*>&1` or verify by GET.

### INCIDENT 2026-08-28: promote.ps1 -WhatIf wrote to PROD (restore procedure)

What happened: an agent ran
`promote.ps1 -Manifest report/pos_perf -FromEnv stage -ToEnv prod -WhatIf`
expecting a read-only plan. `-WhatIf` was silently reset to `$false` (the
script dot-sourced `ensure_controls.ps1`, whose `param()` block re-bound the
variable -- gotcha G60). Effects on PROD, measured read-only afterwards with
`verify_suite.ps1 -Env prod -ByteDiff` and a STAGE-vs-PROD attachment diff:
- all 10 `/reports/pos_perf/pos_*` dashboards deleted (teardown phase);
- all 56 tiles re-created from git (`PUT ?overwrite=true`), bodies sha256-identical
  to `report/pos_perf/*.jrxml`;
- the 22 tiles of the four filter boards (chn_*, ops_*, sup_*, trs_*) lost their
  input-control attachments (G61); the 34 unfiltered tiles never had any;
- the first recompose (pos_retention_churn) reported "finished" but created
  nothing (broken filter dependency), which is where the run stopped;
- input-control resources under `/reports/pos_perf/controls` are intact;
- STAGE untouched (`verify_suite -Env stage`: 87/87).

Fixes shipped in jasper-deploy 1.2.1 (see its CHANGELOG): param-less
`_controls_common.ps1` + dot-source guard test, `deploy_report -Overwrite`
carries attachments over, promote attach phase uses live state,
`import_resource` prints import warnings.

Restore (PROD write -- run by a human, one command, idempotent):

    .\scripts\pos_perf\restore_prod_pos.ps1            # plan: 22 "would attach", 10 "would compose"
    .\scripts\pos_perf\restore_prod_pos.ps1 -Apply     # phase 1 re-attach from STAGE, phase 2 recompose, phase 3 verify

Expected end state: `verify_suite.ps1 -Manifest report/pos_perf -Env prod`
reports 0 FAIL; then run browser checks 5-15 against PROD as before.
The plan mode was validated against PROD on 2026-08-28 (read-only) and the
attach + compose mechanics were proven on STAGE the same day.

Policy reminder (already stated above, now also in agent memory): no agent
points a write-capable script at PROD, dry-run flags included, unless the
user explicitly asks for that exact run and the dry-run path has been proven
on STAGE with the write helpers stubbed.

Since jasper-deploy 1.3.0 (2026-09-28) that policy is also code, ported from
jrsctl's plan/confirm/journal model (spec
`specs/2026-09-28-jasper-deploy-safety-model-design.md`):

- `promote.ps1`, `compose_dashboard.ps1`, `teardown_dashboard.ps1` and
  `deploy_report.ps1 -Overwrite` plan by default and write only with `-Apply`.
  Plan mode is enforced inside `Invoke-JrsPut`/`Invoke-JrsDelete`/`Invoke-JrsRest`
  (G64), so the G60 clobber can only fail safe.
- Any write to a `prod*` profile or its URL is refused with `PROD GUARD` unless
  the human running it sets `$env:JRS_ALLOW_PROD_WRITE = '1'` in that shell (G65).
  Agents never set it.
- Every `-Apply` run is journaled under `plugins/.../out/runs/<runId>` with
  backups and per-step compensations; `recover_run.ps1 -RunId <id> -Rollback -Apply`
  undoes it, and `promote.ps1 -Apply` rolls itself back on failure (exit 3/4).
- "Proven on STAGE with the write helpers stubbed" is now
  `tests/harness.Tests.ps1`: the real scripts run against `tests/mock_jrs.py`
  replaying a STAGE recording, and the test asserts zero PUT/POST/DELETE in plan
  mode. Re-record with `record_server.ps1 -Manifest <suite> -Env stage` when the
  suite changes.

### PROD promotion of the Phase 1 finance suite (recipe; executed 2026-08-27, see above)

Not run by any agent -- auto-mode denies PROD writes. PROD is
http://3.214.51.180:8080/jasperserver-pro. Run these one line at a time.

Note: PROD still has an outstanding Phase 0 fix -- the `exec_region_bar` +
`ops_region_bar` redeploy and the two Phase 0 dashboard recomposes
(`pos_executive_overview`, `pos_operations_console`) -- that was deferred to
the user in an earlier task and never applied. Run it before or alongside
this Phase 1 promotion; the exact commands are in
`plans\2026-08-23-pos-suite-phase1.md`, Task 1 Step 3.

Step 1, shared controls:
    . .\scripts\pos_perf\jrs_controls.ps1 -Env prod
    New-FinanceControls
Note: `New-FinanceControls` creates only the six finance-specific controls
(p_asof, p_franchisee, p_store, p_yyyymm, p_version, p_province); it does not
create `p_regions`. `p_regions` already exists on PROD from the earlier Ops
Console promotion. Before Step 4 attaches it to nine report units, verify
`/reports/pos_perf/controls/p_regions` exists on PROD (a GET, or check the
Step 5 counts after attaching).

Step 2, tear the four dashboards down (tiles of a live dashboard 403 with
resource.in.use on redeploy; a 404 on the two new boards is expected):
    $env:JRS_ENV = "prod"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_store_pnl
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_treasury
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_executive_overview
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_promo_story

Step 3, deploy all 28 report units. Labels must match the ones live on STAGE
or the manifests will not resolve:
    $ds = "/datasources/pos_data_avalanche"
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_map.jrxml               -TargetUri /reports/pos_perf/exec_map               -Label "Net Sales by Province"         -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_margin_dial.jrxml       -TargetUri /reports/pos_perf/exec_margin_dial       -Label "Gross Margin"                  -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_yoy_dial.jrxml          -TargetUri /reports/pos_perf/exec_yoy_dial          -Label "YoY Growth"                    -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_last_updated.jrxml      -TargetUri /reports/pos_perf/exec_last_updated      -Label "Last Refreshed"                -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_region_bar.jrxml        -TargetUri /reports/pos_perf/exec_region_bar        -Label "Net Sales by Region"           -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_promo_mix.jrxml         -TargetUri /reports/pos_perf/exec_promo_mix         -Label "Promotion Mix"                 -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_trend.jrxml             -TargetUri /reports/pos_perf/exec_trend             -Label "Net Sales Trend"               -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_top_stores.jrxml        -TargetUri /reports/pos_perf/exec_top_stores        -Label "Top Stores"                    -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\exec_kpi_strip.jrxml         -TargetUri /reports/pos_perf/exec_kpi_strip         -Label "Key Metrics"                   -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\story_hero.jrxml             -TargetUri /reports/pos_perf/story_hero             -Label "Promo and Margin Story"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\story_trend.jrxml            -TargetUri /reports/pos_perf/story_trend            -Label "Margin Trend"                  -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\story_cards.jrxml            -TargetUri /reports/pos_perf/story_cards            -Label "Decision Cards"                -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\pnl_kpi_strip.jrxml          -TargetUri /reports/pos_perf/pnl_kpi_strip          -Label "pnl_kpi_strip"                 -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\pnl_waterfall.jrxml          -TargetUri /reports/pos_perf/pnl_waterfall          -Label "pnl_waterfall"                 -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\pnl_variance_region.jrxml    -TargetUri /reports/pos_perf/pnl_variance_region    -Label "pnl_variance_region"           -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\pnl_contribution_trend.jrxml -TargetUri /reports/pos_perf/pnl_contribution_trend -Label "pnl_contribution_trend"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\pnl_worst_stores.jrxml       -TargetUri /reports/pos_perf/pnl_worst_stores       -Label "pnl_worst_stores"              -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_kpi.jrxml                -TargetUri /reports/pos_perf/trs_kpi                -Label "trs_kpi"                       -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_ar_aging.jrxml           -TargetUri /reports/pos_perf/trs_ar_aging           -Label "trs_ar_aging"                  -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_dpo.jrxml                -TargetUri /reports/pos_perf/trs_dpo                -Label "trs_dpo"                       -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_tender_mix.jrxml         -TargetUri /reports/pos_perf/trs_tender_mix         -Label "trs_tender_mix"                -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_tax_province.jrxml       -TargetUri /reports/pos_perf/trs_tax_province       -Label "trs_tax_province"              -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_liability.jrxml          -TargetUri /reports/pos_perf/trs_liability          -Label "trs_liability"                 -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_lease_expiry.jrxml       -TargetUri /reports/pos_perf/trs_lease_expiry       -Label "trs_lease_expiry"              -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_store_pnl_statement.jrxml -TargetUri /reports/pos_perf/rpt_store_pnl_statement -Label "Store P and L Statement"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_ar_aging.jrxml            -TargetUri /reports/pos_perf/rpt_ar_aging            -Label "Franchise Receivables Aging"    -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_ap_aging.jrxml            -TargetUri /reports/pos_perf/rpt_ap_aging            -Label "Payables Aging and Payment Run" -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_tax_remittance.jrxml      -TargetUri /reports/pos_perf/rpt_tax_remittance      -Label "Sales Tax Remittance"           -DataSourceUri $ds -Overwrite -Backup

Step 4, re-attach the controls the redeploy just dropped. The 5 pnl_* tiles and
the 12 navy tiles take none. This attaches `p_regions` to nine units -- confirm
it exists on PROD first (see the note under Step 1; `New-FinanceControls`
does not create it):
    . .\scripts\pos_perf\jrs_controls.ps1 -Env prod
    $ctl = @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
    foreach ($r in @("trs_kpi","trs_ar_aging","trs_dpo","trs_tender_mix","trs_tax_province","trs_liability","trs_lease_expiry")) { Attach-Controls -ReportUri "/reports/pos_perf/$r" -ControlUris $ctl }
    Attach-Controls -ReportUri /reports/pos_perf/rpt_store_pnl_statement -ControlUris @("/reports/pos_perf/controls/p_store","/reports/pos_perf/controls/p_yyyymm","/reports/pos_perf/controls/p_version")
    Attach-Controls -ReportUri /reports/pos_perf/rpt_ar_aging            -ControlUris $ctl
    Attach-Controls -ReportUri /reports/pos_perf/rpt_ap_aging            -ControlUris @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions")
    Attach-Controls -ReportUri /reports/pos_perf/rpt_tax_remittance      -ControlUris @("/reports/pos_perf/controls/p_province","/reports/pos_perf/controls/p_yyyymm")

Step 5, GET-verify the counts (3 for each trs_*, 3 / 3 / 2 / 2 for the four
reports; any zero means step 4 did not stick):
    . ".\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1"; $jrs = Resolve-JrsConfig
    foreach ($r in @("trs_kpi","trs_ar_aging","trs_dpo","trs_tender_mix","trs_tax_province","trs_liability","trs_lease_expiry","rpt_store_pnl_statement","rpt_ar_aging","rpt_ap_aging","rpt_tax_remittance")) { "{0,-26} {1}" -f $r, @(((Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/$r").Body | ConvertFrom-Json).inputControls).Count }

Step 6, compose the four dashboards:
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\exec_dashboard.json  -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\story_dashboard.json -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\pnl_dashboard.json   -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\trs_dashboard.json   -AutoGrid

Step 7, smoke it, then put the shell back on STAGE (this last line is part of
the procedure, not an afterthought):
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/pnl_kpi_strip -Format pdf -OutFile out\pos_perf\prod_pnl_kpi_strip.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/trs_kpi       -Format pdf -OutFile out\pos_perf\prod_trs_kpi.pdf
    $env:JRS_ENV = "stage"
Expected in prod_pnl_kpi_strip.pdf: Net Sales 2020 $416,459,364, Plan
Attainment 100.3%, Gross Margin 33.7%, Four-Wall EBITDA 2020 $63,257,428,
Labour 9.8%, Loss-Making Stores 18. Expected in prod_trs_kpi.pdf: AR
Outstanding $5,399,130, AP Outstanding $30,337,409, Cashless Share 89.8%, Tax
Collected YTD $15,524,541, Gift + Loyalty Liability $9,062,284. Different
numbers mean PROD is pointed at a different warehouse.

Gotchas: dashboards do not run to PDF (verify the tiles); compose labels are
not XML-escaped (use "and", never "&"); Ops Console filters are per-dashlet
popups (dashletFilterShowPopup true) while Franchise Treasury uses a
dashboard-level filter strip (the manifest's `filters` key); deploy_report.ps1
-Overwrite drops attached inputControls, so re-run Attach-Controls after every
redeploy; a tile of a composed dashboard 403s with resource.in.use, so tear the
dashboard down first; PROD lacks the chart customizer jar, so tiles use plain
seriesColor (every Phase 1 unit was authored without one); STAGE-to-PROD
export/import fails with import.decode.failed (per-server key), so promote by
deploying jrxml to PROD with -Env prod and recomposing there.

### PROD promotion of the Phase 2 retention suite (recipe; executed 2026-08-27, see above)

Not run by any agent -- auto-mode denies PROD writes. PROD is
http://3.214.51.180:8080/jasperserver-pro. Run these one line at a time. This
block promotes the six chn_* tiles, the Churn Action List, the three churn
controls and the pos_retention_churn dashboard. It is independent of the Phase
1 block above and can be run before it, after it, or on its own; the only thing
the two share is `p_regions`, which neither of them creates.

Step -1, the STAGE-vs-git byte-diff precondition. Phase 2 had an unexplained
STAGE drift incident (a report unit's XML got re-serialized on the server,
differing from git -- since fixed and documented, but root cause unknown), so
re-run the same server-vs-git byte-diff check documented under "Verify the
Phase 2 build on STAGE without a browser" above against all seven Phase 2
units (chn_kpi, chn_bands, chn_ltv_band, chn_drivers, chn_cohorts, chn_actions,
rpt_churn_action_list) before promoting any of them to PROD. Export each unit,
compare its payload against the committed jrxml in report\pos_perf, and
confirm bytes match -- reuse the exact export/compare recipe already given
there, do not invent new syntax. If any unit shows a diff, stop and
investigate rather than promoting a drifted copy.

Step 0, the aggregates. Both Phase 2 dashboards read `dash_churn` and
`dash_cohort` on the pos_data warehouse through
`/datasources/pos_data_avalanche`. If PROD's datasource of that name points at
the SAME warehouse STAGE uses (av-flm7ykoxlcvq), the tables are already there
and this step is a no-op -- check by running the two verify scripts and
comparing against the figures in the Phase 2 rebuild recipe above. If PROD
points somewhere else, build them there first, against that ResourceId:
    $adm = ".\.claude\skills\admiral\scripts"
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_churn.sql   -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_churn.sql  -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_cohort.sql  -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_cohort.sql -ResourceId <prod-warehouse-id>
Both builds depend on tables the churn model produces (customer_churn_scores,
customer_ipt_stats, customer_month, customers). If those are absent on the
other warehouse this is a bigger job than a promotion and should stop here.

Step 1, the churn controls:
    . .\scripts\pos_perf\churn_controls.ps1 -Env prod
    New-ChurnControls
`New-ChurnControls` creates only the three churn-specific controls
(chn_score_date, chn_tier, chn_band) and their _query companions. It does NOT
create `p_regions`, and must not: `p_regions` already exists on PROD from the
earlier Ops Console promotion and is shared with the Phase 1 Treasury controls.
Recreating it would replace a control nine other report units already point at.
Before Step 4 attaches it to five more units, verify
`/reports/pos_perf/controls/p_regions` exists on PROD -- a GET, or just read
the Step 5 counts.

Step 2, tear the dashboard down (tiles of a live dashboard 403 with
resource.in.use on redeploy; a 404 on a first promotion is expected and means
nothing is there yet):
    $env:JRS_ENV = "prod"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_retention_churn

Step 3, deploy the seven report units. The six tile labels are their own unit
names; only the drill target has a prose label:
    $ds = "/datasources/pos_data_avalanche"
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_kpi.jrxml               -TargetUri /reports/pos_perf/chn_kpi               -Label "chn_kpi"            -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_bands.jrxml             -TargetUri /reports/pos_perf/chn_bands             -Label "chn_bands"          -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_ltv_band.jrxml          -TargetUri /reports/pos_perf/chn_ltv_band          -Label "chn_ltv_band"       -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_drivers.jrxml           -TargetUri /reports/pos_perf/chn_drivers           -Label "chn_drivers"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_cohorts.jrxml           -TargetUri /reports/pos_perf/chn_cohorts           -Label "chn_cohorts"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\chn_actions.jrxml           -TargetUri /reports/pos_perf/chn_actions           -Label "chn_actions"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_churn_action_list.jrxml -TargetUri /reports/pos_perf/rpt_churn_action_list -Label "Churn Action List"  -DataSourceUri $ds -Overwrite -Backup

Step 4, attach the four console controls. Five tiles take all four, in strip
order; chn_cohorts takes NONE (it declares the four parameters and reads none
of them, so nothing needs to populate them) and rpt_churn_action_list takes
none either (its two String parameters arrive on the drill URL and otherwise
fall back to their defaults):
    . .\scripts\pos_perf\churn_controls.ps1 -Env prod
    foreach ($u in @("chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_actions")) { Attach-ChurnControls -ReportUri "/reports/pos_perf/$u" }

Step 5, GET-verify the counts (4 for each of the five, 0 for chn_cohorts and
rpt_churn_action_list; any zero among the five means step 4 did not stick, and
any non-zero on the last two means something was attached that should not be):
    . ".\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1"; $jrs = Resolve-JrsConfig
    foreach ($r in @("chn_kpi","chn_bands","chn_ltv_band","chn_drivers","chn_cohorts","chn_actions","rpt_churn_action_list")) { $b = (Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/$r").Body | ConvertFrom-Json; "{0,-24} {1}" -f $r, @($b.inputControls | Where-Object { $_ }).Count }
The `Where-Object { $_ }` is not decoration: PowerShell 5.1 counts a bare
`@($null)` as 1, so a unit with no controls reports 1 without it.

Step 6, compose the dashboard:
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\chn_dashboard.json -AutoGrid

Step 7, smoke it, then put the shell back on STAGE (this last line is part of
the procedure, not an afterthought):
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/chn_kpi               -Format pdf -OutFile out\pos_perf\prod_chn_kpi.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_churn_action_list -Format pdf -OutFile out\pos_perf\prod_rpt_churn_action_list.pdf
    $env:JRS_ENV = "stage"
Expected in prod_chn_kpi.pdf: Scored Customers 3,184,743, Critical + High Risk
66.9%, LTV at Risk $20,807,163, Overdue vs Expected 32.5%, Avg Churn
Probability 0.524, footer "Customers scored as of 2020-12-31". Expected in
prod_rpt_churn_action_list.pdf: 14 pages, 500 detail rows, the coverage line
reading "Top 500 of 1,357,153". Different numbers mean PROD is pointed at a
different warehouse, or at a re-run of the churn model with a later cutoff.

Step 8, then run browser checks 5, 6 and 7 above against the PROD URL. Do not
call the promotion done on the strength of the PDFs: the filter strip, the
drill click and the chn_drivers subtitle are the three things a PDF cannot see,
and none of them has been confirmed in a viewer on either server.

Phase 2 gotchas, on top of the Phase 1 list above: the four console controls
are ALL multiSelectQuery (type 7), so every one of them arrives at a tile as a
java.util.Collection, including the score date -- a tile that needs a scalar
date derives it with `.iterator().next()` in a parameter default rather than
taking a second control, so do not "fix" a Collection parameter into a String
in a jrxml without also fixing the control; gen_dashboard.py wires every filter
to every report dashlet with no per-dashlet opt-out, which is why chn_cohorts
declares four parameters it never reads; the report export names its jrxml
payload after the report LABEL, not the unit, so the Churn Action List's
payload is Churn_Action_List_main_jrxml.data; and `lint_jrxml.ps1` does NOT
catch a `--` inside an XML comment (it is invalid XML and fails at compile with
an opaque error) -- this bit three separate times during Phase 2, so when a
lint-clean jrxml fails to deploy, grep the comments for a double hyphen before
looking anywhere else; and `COUNT(DISTINCT col)` inside a derived table that
also uses `FIRST n` throws `ERROR [5000B]: Rewriter error` on X100 -- compute
the distinct count and the FIRST-n cap in separate subqueries/steps instead of
combining them in one derived table.

### PROD promotion of the Phase 3 operations suite (recipe; executed 2026-08-27, see above)

Not run by any agent -- auto-mode denies PROD writes. PROD is
http://3.214.51.180:8080/jasperserver-pro. Run these one line at a time. This
block promotes the 5 sup_* tiles, the 5 lab_* tiles, the 3 standalone reports
(Inventory Reorder List, Supplier Scorecard, Weekly Flash), the three supply
controls, `dash_labour`, and both dashboards. It is independent of the Phase
1/2 blocks above and can be run before, after, or on its own; the only thing
it shares with them is `p_regions`, which it does not create.

Step -1, the STAGE-vs-git byte-diff precondition (see "Verify the Phase 3
build on STAGE without a browser" above). Run 2026-08-25: all 13 units came
back byte-identical to git. Re-run it before promoting anything -- do not
promote a drifted copy.

Step 0, the aggregate. Only `pos_workforce_labour` reads a new table
(`dash_labour`, store x calendar-date x shift grain); the five sup_* tiles
read `inventory`, `purchase_orders`, `suppliers` and `shrinkage_log` directly,
matching the Phase 1 AR/AP precedent of no new aggregate for a small enough
table. If PROD's `/datasources/pos_data_avalanche` points at the SAME
warehouse STAGE uses (av-flm7ykoxlcvq), `dash_labour` is already there and
this step is a no-op -- check with the verify script and compare against the
Phase 3 acceptance figures above. If PROD points somewhere else, build it
there first:
    $adm = ".\.claude\skills\admiral\scripts"
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_labour.sql  -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_labour.sql -ResourceId <prod-warehouse-id>
This depends on `shift_schedules`, `date_dim` and `store_traffic` already
existing on that warehouse; if they are absent this is a bigger job than a
promotion and should stop here.

Step 1, the supply controls:
    . .\scripts\pos_perf\supply_controls.ps1 -Env prod
    New-SupplyControls
`New-SupplyControls` creates only the three supply-specific controls
(sup_store, sup_category, sup_supplier) and their _query companions. It does
NOT create `p_regions`, and must not -- `p_regions` already exists on PROD
from the earlier Ops Console promotion and is shared with the Phase 1 Treasury
and Phase 2 churn controls. Before Step 4 attaches it to five tiles, verify
`/reports/pos_perf/controls/p_regions` exists on PROD (a GET, or just read the
Step 5 counts).

Step 2, tear the supply dashboard down (a tile of a live dashboard 403s with
resource.in.use on redeploy; a 404 on a first promotion is expected and means
nothing is there yet). `pos_workforce_labour` has no attached controls to
worry about, but still tear it down before redeploying its tiles for the same
resource.in.use reason:
    $env:JRS_ENV = "prod"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_supply_inventory
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_workforce_labour

Step 3, deploy all 13 report units. Labels must match what is live on STAGE or
the manifests will not resolve -- the 10 tile labels are their own unit names,
the 3 standalone reports carry prose labels:
    $ds = "/datasources/pos_data_avalanche"
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\sup_kpi.jrxml               -TargetUri /reports/pos_perf/sup_kpi               -Label "sup_kpi"               -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\sup_stock_status.jrxml      -TargetUri /reports/pos_perf/sup_stock_status      -Label "sup_stock_status"      -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\sup_gmroi.jrxml             -TargetUri /reports/pos_perf/sup_gmroi             -Label "sup_gmroi"             -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\sup_scorecard.jrxml         -TargetUri /reports/pos_perf/sup_scorecard         -Label "sup_scorecard"         -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\sup_shrink.jrxml            -TargetUri /reports/pos_perf/sup_shrink            -Label "sup_shrink"            -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\lab_kpi.jrxml               -TargetUri /reports/pos_perf/lab_kpi               -Label "lab_kpi"               -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\lab_heatmap.jrxml           -TargetUri /reports/pos_perf/lab_heatmap           -Label "lab_heatmap"           -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\lab_format.jrxml            -TargetUri /reports/pos_perf/lab_format            -Label "lab_format"            -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\lab_indexed.jrxml           -TargetUri /reports/pos_perf/lab_indexed           -Label "lab_indexed"           -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\lab_conversion.jrxml        -TargetUri /reports/pos_perf/lab_conversion        -Label "lab_conversion"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_inventory_reorder.jrxml -TargetUri /reports/pos_perf/rpt_inventory_reorder -Label "Inventory Reorder List" -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_supplier_scorecard.jrxml -TargetUri /reports/pos_perf/rpt_supplier_scorecard -Label "Supplier Scorecard"   -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_weekly_flash.jrxml       -TargetUri /reports/pos_perf/rpt_weekly_flash       -Label "Weekly Flash"          -DataSourceUri $ds -Overwrite -Backup

Step 4, re-attach the controls the redeploy just dropped. Only the five sup_*
tiles take any; the five lab_* tiles and the three standalone reports take
none (Inventory Reorder List, Supplier Scorecard and Weekly Flash use plain
String parameters with defaults, not attached JRS input controls):
    . .\scripts\pos_perf\supply_controls.ps1 -Env prod
    foreach ($u in @("sup_kpi","sup_stock_status","sup_gmroi","sup_scorecard","sup_shrink")) { Attach-SupplyControls -ReportUri "/reports/pos_perf/$u" }

Step 5, GET-verify the counts (4 for each sup_* tile; any zero means step 4
did not stick):
    . ".\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1"; $jrs = Resolve-JrsConfig
    foreach ($r in @("sup_kpi","sup_stock_status","sup_gmroi","sup_scorecard","sup_shrink")) { $b = (Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/$r").Body | ConvertFrom-Json; "{0,-18} {1}" -f $r, @($b.inputControls | Where-Object { $_ }).Count }

Step 6, compose the two dashboards:
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\sup_dashboard.json -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\lab_dashboard.json -AutoGrid

Step 7, smoke it, then put the shell back on STAGE (this last line is part of
the procedure, not an afterthought):
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/sup_kpi -Format pdf -OutFile out\pos_perf\prod_sup_kpi.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/lab_kpi -Format pdf -OutFile out\pos_perf\prod_lab_kpi.pdf
    $env:JRS_ENV = "stage"
Expected in prod_sup_kpi.pdf: Out of Stock 12.1%, Overstock 5.0%, Avg Days of
Supply 27.8, Supplier On-Time 85.0%, Shrink pct of COGS about 0.37%. Expected
in prod_lab_kpi.pdf: 2020 Labour Cost about $35.2M, about 8.4% of Net Sales,
Active Staff 2,340. Different numbers mean PROD is pointed at a different
warehouse.

Step 8, then run browser checks 8, 9, 10 and 11 above against the PROD URL
before calling the promotion done -- the filter strip, the drill click and the
heatmap eyeball are not provable from a PDF.

Phase 3 gotchas, on top of the Phase 1/2 lists above: `sup_scorecard` and
`sup_shrink` each declare all four supply parameters but only use the ones
their source table actually has a column for (`suppliers` has no region,
store or category column; `shrinkage_log` has no region or supplier column) --
this is intentional per-tile scoping, not a bug to "fix" into a WHERE clause
that would return zero rows; a WITH clause used as a derived table inside a
FROM clause fails on this X100 install with `ERROR [42500]: Table 'with' does
not exist or is not owned by you`, even though a top-level `WITH ... SELECT`
statement works fine in this suite's standalone .sql build scripts -- rewrite
as nested derived-table subqueries instead; and the JR7 design validator caps
`title.height + pageHeader.height + columnHeader.height + columnFooter.height
+ pageFooter.height` at `pageHeight - topMargin - bottomMargin` -- on
rpt_weekly_flash's 842px portrait page with 30px margins and a 20px
columnHeader, that is a hard 762px ceiling on the title band, discovered via
`compile_jrxml.ps1` (not `lint_jrxml.ps1`, which does not catch it) failing
with `JRValidationException: ... do not fit the page height`.

### PROD promotion of the Phase 4 growth suite (recipe; executed 2026-08-27, see above)

Not run by any agent -- auto-mode denies PROD writes. PROD is
http://3.214.51.180:8080/jasperserver-pro. Run these one line at a time. This
block promotes the 5 net_* tiles, the 5 mkt_* tiles, the new
`rpt_franchisee_fee_statement` report, the redeployed `trs_kpi` (its three
controls are re-attached, not new), the one new control (`p_franchisee_id`),
and all three touched dashboards. This is the LAST phase in the roadmap: once
this block is run and its Step 7/8 checks pass, all 10 dashboards and all 9
reports scoped in `specs/2026-08-23-pos-suite-design.md` are live on PROD (the
unnumbered, optional Retention Story deck was never in scope and the user
chose not to build it).

Step -1, the STAGE-vs-git byte-diff precondition (see "Verify the Phase 4
build on STAGE without a browser" above). Run 2026-08-25: all 12 units came
back byte-identical to git. Re-run it before promoting anything -- do not
promote a drifted copy.

Step 0, the aggregates. `pos_store_network` reads `stores`,
`competitor_locations`, `fsa_demographics` and `store_assets` directly -- no
new aggregate, same precedent as the Phase 1 AR/AP tiles and the Phase 3
sup_* tiles. `pos_marketing_digital` reads two new aggregates, `dash_email`
(campaign x send-month grain, 114 rows) and `dash_ecom_monthly` (month x
delivery-partner grain, 96 rows). If PROD's `/datasources/pos_data_avalanche`
points at the SAME warehouse STAGE uses (av-flm7ykoxlcvq), both tables are
already there and this step is a no-op -- check with the two verify scripts
and compare against the Phase 4 acceptance figures below. If PROD points
somewhere else, build them there first:
    $adm = ".\.claude\skills\admiral\scripts"
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_email.sql          -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_email.sql          -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\build_dash_ecom_monthly.sql     -ResourceId <prod-warehouse-id>
    & "$adm\sql.ps1" -Action run-file -SqlFile scripts\pos_perf\verify_dash_ecom_monthly.sql    -ResourceId <prod-warehouse-id>
Both builds depend on `email_engagement`, `marketing_campaigns` and
`ecommerce_orders` already existing on that warehouse; if those are absent
this is a bigger job than a promotion and should stop here.

Step 1, the one new control:
    . .\scripts\pos_perf\franchisee_control.ps1 -Env prod
    New-FranchiseeControl
`New-FranchiseeControl` creates only `/reports/pos_perf/controls/p_franchisee_id`
(type 4, singleSelectQuery, value/label split fv=franchisee_id/fl=owner_name).
It does not touch `p_asof`, `p_regions`, `p_franchisee` or `p_yyyymm` --
verify those four already exist on PROD from the Phase 1 finance promotion
(New-FinanceControls) before Step 4 re-attaches three of them to trs_kpi and
one of them to rpt_franchisee_fee_statement.

Step 2, tear the three touched dashboards down (a tile of a live dashboard
403s with resource.in.use on redeploy; a 404 on the two new boards is
expected and means nothing is there yet):
    $env:JRS_ENV = "prod"; $jd = ".\.claude\skills\jasper-deploy\scripts"
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_store_network
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_marketing_digital
    & "$jd\teardown_dashboard.ps1" -Uri /reports/pos_perf/pos_treasury

Step 3, deploy all 12 report units. Labels must match what is live on STAGE
or the manifests will not resolve -- the 10 tile labels are their own unit
names, the new report carries a prose label, trs_kpi keeps its existing label:
    $ds = "/datasources/pos_data_avalanche"
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\net_map.jrxml               -TargetUri /reports/pos_perf/net_map               -Label "net_map"               -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\net_sqft_format.jrxml       -TargetUri /reports/pos_perf/net_sqft_format       -Label "net_sqft_format"       -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\net_income_scatter.jrxml    -TargetUri /reports/pos_perf/net_income_scatter    -Label "net_income_scatter"    -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\net_lease.jrxml             -TargetUri /reports/pos_perf/net_lease             -Label "net_lease"             -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\net_exposed.jrxml           -TargetUri /reports/pos_perf/net_exposed           -Label "net_exposed"           -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\mkt_kpi.jrxml               -TargetUri /reports/pos_perf/mkt_kpi               -Label "mkt_kpi"               -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\mkt_funnel.jrxml            -TargetUri /reports/pos_perf/mkt_funnel            -Label "mkt_funnel"            -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\mkt_ecom_share.jrxml        -TargetUri /reports/pos_perf/mkt_ecom_share        -Label "mkt_ecom_share"        -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\mkt_campaign_roi.jrxml      -TargetUri /reports/pos_perf/mkt_campaign_roi      -Label "mkt_campaign_roi"      -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\mkt_partners.jrxml          -TargetUri /reports/pos_perf/mkt_partners          -Label "mkt_partners"          -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\rpt_franchisee_fee_statement.jrxml -TargetUri /reports/pos_perf/rpt_franchisee_fee_statement -Label "Franchisee Fee Statement" -DataSourceUri $ds -Overwrite -Backup
    & "$jd\deploy_report.ps1" -Jrxml report\pos_perf\trs_kpi.jrxml               -TargetUri /reports/pos_perf/trs_kpi               -Label "trs_kpi"               -DataSourceUri $ds -Overwrite -Backup

Step 4, re-attach the controls the redeploy just dropped. The 5 net_* and 5
mkt_* tiles take none (Cockpit archetype, no parameters). trs_kpi takes its
original three (this redeploy did not change its controls, only added a
hyperlink); rpt_franchisee_fee_statement takes the two new franchisee/as-of
controls:
    . .\scripts\pos_perf\jrs_controls.ps1 -Env prod
    $ctl = @("/reports/pos_perf/controls/p_asof","/reports/pos_perf/controls/p_regions","/reports/pos_perf/controls/p_franchisee")
    Attach-Controls -ReportUri /reports/pos_perf/trs_kpi -ControlUris $ctl
    Attach-Controls -ReportUri /reports/pos_perf/rpt_franchisee_fee_statement -ControlUris @("/reports/pos_perf/controls/p_franchisee_id","/reports/pos_perf/controls/p_yyyymm")

Step 5, GET-verify the counts (3 for trs_kpi, 2 for
rpt_franchisee_fee_statement, 0 for all 10 net_*/mkt_* tiles; any mismatch
means step 4 did not stick):
    . ".\.claude\skills\jasper-deploy\scripts\_jrs_common.ps1"; $jrs = Resolve-JrsConfig
    foreach ($r in @("trs_kpi","rpt_franchisee_fee_statement","net_map","net_sqft_format","net_income_scatter","net_lease","net_exposed","mkt_kpi","mkt_funnel","mkt_ecom_share","mkt_campaign_roi","mkt_partners")) { $b = (Invoke-JrsGet -Jrs $jrs -Uri "/reports/pos_perf/$r").Body | ConvertFrom-Json; "{0,-28} {1}" -f $r, @($b.inputControls | Where-Object { $_ }).Count }

Step 6, compose the three dashboards (pos_treasury needs all seven trs_* tile
URIs, the same manifest Phase 1/5 already use; teardown in Step 2 removed the
composition, not the six untouched tiles themselves):
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\net_dashboard.json -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\mkt_dashboard.json -AutoGrid
    & "$jd\compose_dashboard.ps1" -Manifest report\pos_perf\trs_dashboard.json -AutoGrid

Step 7, smoke it, then put the shell back on STAGE (this last line is part of
the procedure, not an afterthought):
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/mkt_kpi                      -Format pdf -OutFile out\pos_perf\prod_mkt_kpi.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/net_exposed                  -Format pdf -OutFile out\pos_perf\prod_net_exposed.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/rpt_franchisee_fee_statement -Format pdf -OutFile out\pos_perf\prod_rpt_franchisee_fee_statement.pdf
    & "$jd\run_report_async.ps1" -ReportUri /reports/pos_perf/trs_kpi                      -Format pdf -OutFile out\pos_perf\prod_trs_kpi.pdf
    $env:JRS_ENV = "stage"
Expected in prod_mkt_kpi.pdf: E-Commerce Share 1.4%, Late Fulfilment 6.8%,
Email Open Rate 37.6%, Email Click Rate 12.1%, Promotion ROI 84.91x. Expected
in prod_net_exposed.pdf: 4 rows (131 Hanover, 274 Cambridge-Dundas, 312
Winnipeg-Kenaston, 82 Mississauga Dixie and Dundas). Expected in
prod_rpt_franchisee_fee_statement.pdf at its defaults (franchisee 0, Stella
Martin, through December 2020): 4 pages, Total Invoiced $404,069.79 / Total
Paid $347,395.84 / Total Balance $56,673.95. Expected in prod_trs_kpi.pdf: AR
Outstanding $5,399,130 (unchanged from Phase 1). Different numbers mean PROD
is pointed at a different warehouse.

Step 8, then run browser checks 12, 13, 14 and 15 above against the PROD URL
before calling the promotion done -- the map eyeball and both drill
click-tests are not provable from a PDF.

Phase 4 gotchas, on top of the Phase 1/2/3 lists above: the community
Map/List/Table component (`jasperreports-components`, which would provide a
native `jr:map`) is confirmed absent from both this repo's local `JR_LIB_DIR`
and this STAGE server's classpath (two independent `400 "JRXML.content is
invalid"` responses on two different jrxml shapes) -- `net_map` ships as a
JFreeChart `chartType="bubble"` instead; `chartType="xyScatter"` is not a
valid `ChartTypeEnum` value in this JR 7.0.6 build, the real value is
`"scatter"` (net_income_scatter uses it, plus `showLines="false"
showShapes="true"` on the plot, since a bare scatter plot connects points
with a line by default); `JRDesignXyzSeries`/`JRDesignXySeries` use
lower-case-v property names (`xvalueExpression`, not `XValueExpression`); a
JFreeChart bubble renderer treats its z value as bubble AREA in the same
data-space units as the x/y axes, not auto-scaled pixels -- net_map divides
`sales_per_sqft` by 1000 in `zvalueExpression` to keep bubbles legible rather
than one solid rectangle; `<hyperlinkReference><expression>` is not a valid
JRXML element in this JR 7.0.6 build (the brief's literal text for the
trs_kpi drill was wrong) -- the correct, already-established convention is
`linkType="ReportExecution"` plus a `<hyperlinkParameter name="_report">`
child; and a `DECIMAL(n, 2)` cast on a ratio of two small numbers can
overflow when the denominator gets close to zero (mkt_campaign_roi's `roi`
cast needed widening from `DECIMAL(8,2)` to `DECIMAL(16,2)` because a few
promotions carry a $0.01 marketing_subsidy against a six/seven-figure
promo_margin) -- a subsidy floor fixes which rows RANK first, it does not
substitute for a cast wide enough to survive whatever ratio the unfiltered
data can produce.
