---
name: jasper-deploy
description: >-
  Design, compile, and deploy JasperReports artifacts to JasperReports Server
  over REST v2. Use for scaffolding a report from SQL, generating or editing a
  JR7 .jrxml, compiling/deploying/verifying reports, composing dashboards,
  managing datasources, Domains, ad hoc views, OLAP/Mondrian, themes, input
  controls, schedules, permissions, users/roles/orgs, or promoting resources
  between STAGE/PROD environments. Also for JRS administration: external
  authentication (LDAP/CAS/OAuth), server hardening, js-import/js-export and
  buildomatic, Visualize.js embedding, and version-delta / upgrade-migration
  planning for any JasperReports Server release 4.7 through 10.1.
---

# JasperReports design / compile / deploy

Automates the design → compile → deploy pipeline for JasperReports against a
PostgreSQL database and a JasperReports Server 10.x REST v2 endpoint. Everything
is **JasperReports 7.0.6 native** — the jrxml schema is NOT 6.x compatible (see
`references/jr7-schema.md`).

This file is a lean index: each capability lists its script, the minimal
invocation, and a pointer to the reference file holding the full flags, verified
notes, and gotchas. **Read the linked reference before doing non-trivial work in
that area** — the deep detail lives there, not here.

## New environment? Start here
1. If a **`LOCAL.md`** file exists next to this SKILL.md (gitignored,
   machine-specific), **read it first** — it overrides anything here with the
   facts of the local install (server URL/port, install paths, local doc
   corpus, quirks).
2. Copy `jrs.config.example.json` → `jrs.config.json` in the skill root and
   fill in the server URL, user, password (or `passwordCommand`), and
   `jrLibDir`.
3. Run **`doctor.ps1`** — it preflight-checks the whole toolchain (PowerShell,
   JDK, psql, curl, Python, JR7 jars, server reachability) and tells you what
   is missing.

## Conventions (apply everywhere)
- **`$skill`** = the `scripts/` subdirectory of this skill. Set it from the base
  directory given at the top of this skill's context:
  `$skill = "<skill-base-dir>/scripts"` (or, from this repo's root,
  `./plugins/jasper-deploy/skills/jasper-deploy/scripts`). Forward slashes work on Windows and
  macOS/Linux alike, so all examples here use `/`.
- **Server:** resolved from config (below), REST v2, HTTP Basic. Never hardcode
  the URL or credentials in docs or scripts — read them from `jrs.config.json`
  (the repo is public). Examples below use `$cfg` for exactly this reason.
- **Credentials** resolve in order: script params → env vars
  `JRS_URL`/`JRS_USER`/`JRS_PASS` → `jrs.config.json` in the skill root (copy
  `jrs.config.example.json`, fill in, gitignored).
- **DB:** PostgreSQL, defaults `localhost:5432` / `postgis_34_sample` /
  `postgres` (the sample DB the examples use — substitute your own);
  `$env:PGPASSWORD` must be set before any `scaffold_*.py` (they introspect via
  psql).

## Toolchain (prerequisites)
- **Shell:** the scripts are PowerShell and run on **Windows PowerShell 5.1** *or*
  **PowerShell 7 (`pwsh`)** on Windows/macOS/Linux. On macOS install with
  `brew install powershell`, then run scripts with `pwsh scripts/<name>.ps1`.
  See "Cross-platform (macOS/Linux)" below.
- JR7 runtime jars: a local directory of JasperReports 7.0.6 jars (incl. the
  PostgreSQL JDBC driver and the `jasperreports-pdf` export module). Resolves via
  `-LibDir` → `$env:JR_LIB_DIR` → `jrs.config.json` `jrLibDir` (required — scripts
  error with guidance if unset).
- JDK 11+ on PATH — single-file source launch, no `javac` step.
- `psql` 14 and `curl` 8.x on PATH.
- Python 3 on PATH (`python` on Windows, `python3` on macOS/Linux — the scripts
  pick the right one automatically) with `sqlglot` + `pypdfium2` for lineage and
  visual baselines.

## Capability map (script → reference)
| Want to… | Script(s) | Reference |
|---|---|---|
| Scaffold a report from SQL (themes, charts, params, groups, drill, crosstab) | `scaffold_jrxml.py` | `references/reports.md` |
| Shared style template (.jrtx) | `scaffold_style_template.py` | `references/reports.md` |
| Compile / locally preview a jrxml | `compile_jrxml.ps1`, `RenderPng` | `references/reports.md` |
| Deploy a report (+ input controls) | `deploy_report.ps1` | `references/admin-and-scheduling.md` |
| Run / export / verify a deployed report | `verify_report.ps1`, `run_report_async.ps1`, curl | `references/reports.md`, `references/admin-and-scheduling.md` |
| CSV-backed report / upload a file resource | `upload_file.ps1` | `references/reports.md` |
| Bulk-deploy a folder of samples | `deploy_jr_samples.ps1` | `references/reports.md` |
| Charts / spider / barcodes / HTML5 / FusionMaps | (jrxml + jars) | `references/reports.md` |
| KPI dial (gauge) tile — the reliable JFreeChart meter form | `scaffold_kpi_dial.py` | `references/fusion-pro-gotchas.md`, `references/dashboard-model.md` |
| Visual-regression check of a report PDF (baseline PNG diff) | `pdf_verify.py` (called by `verify_report.ps1`) | `references/reports.md` |
| Create a datasource (JDBC or jndi/bean/custom/virtual/aws; `-Test` opens the live connection first) | `create_datasource.ps1` | `references/data-and-semantic-layer.md` |
| Report thumbnail image (cheap visual check, no export) | `get_thumbnail.ps1` | `references/reports.md` |
| Diagnostic log collector (support bundle for a failing report) | `manage_diagnostic.ps1` | `references/admin-and-scheduling.md` |
| Compose a dashboard from a manifest | `build_dashlets.ps1 -Compose` (descriptor synthesis: `gen_dashboard.py`) | `references/dashboards.md` |
| Verify a deployed dashboard suite without a browser (exists / render / server-vs-git jrxml byte-diff / controls vs manifest `filters`; read-only, exit 1 on FAIL) | `verify_suite.ps1 -Manifest <path|dir|glob> -Env stage|prod [-Render] [-ByteDiff]` | `references/ci-smoke.md` |
| Promote a whole dashboard suite from manifests (teardown -> controls -> tiles -> attach -> recompose). **Plans by default; `-Apply` writes** under a journaled run with backups; a failed apply rolls itself back (exit 3/4) | `promote.ps1 -Manifest [-Apply]` | `references/dashboards.md` |
| Ensure input controls declaratively from a JSON spec / manifest `controls` key (idempotent, `-WhatIf`) | `ensure_controls.ps1` (+ `fixtures/controls.example.json`) | `references/dashboards.md` |
| Recompose = replace (one delete+import transaction; backup by default; **plans without `-Apply`**; result object) | `compose_dashboard.ps1 -Replace [-Apply]` | `references/dashboard-model.md` |
| List / show / roll back a journaled run (promote, compose, teardown, deploy -Overwrite): replays the `reimport` / `delete` compensations newest-first | `recover_run.ps1 -List`, `-RunId <id\|latest> [-Rollback [-Apply]]` | `references/ci-smoke.md` |
| Prove a plan-mode run writes nothing: record a suite's GETs from STAGE, replay them through the mock server (tests/mock_jrs.py) and assert zero PUT/POST/DELETE (tests/harness.Tests.ps1) | `record_server.ps1 -Manifest -Env stage` | `references/ci-smoke.md` |
| Lint a dashboard manifest (.json): `filterFloating` pinned, dashlets under `folder`, duplicate names | `lint_jrxml.ps1 -Manifest` | `references/manifest.schema.json` |
| Scaffold SQL for an Actian X100 datasource (refuses ordered/correlated aggregates, `;` in comments) | `scaffold_jrxml.py --dialect x100 [--check-only]` | `references/x100-sql.md` |
| Re-sync a manifest IN PLACE from a designer-edited live dashboard (presentation keys, filter docking, diff, `-WhatIf`) | `sync_manifest_from_dashboard.ps1 -Manifest` (+ `sync_manifest.py --merge`) | `references/dashboard-model.md` |
| Export/import/promote/teardown a dashboard or resource (teardown plans without `-Apply`; backs up before every delete) | `export_resource.ps1`, `import_resource.ps1`, `promote.ps1`, `teardown_dashboard.ps1 [-Apply]` | `references/dashboards.md` |
| Promote between named environments (STAGE→PROD, `-FromEnv`/`-ToEnv`) | `promote.ps1` | `references/security-and-config.md` |
| Domain (semantic layer) — single-table or multi-table with joins | `scaffold_domain_schema.py` + `create_domain.ps1` | `references/data-and-semantic-layer.md` |
| Hand-author/debug Domain internals (schema XML, joins, derived tables, DomEL calc fields/filters, security file, locale bundles) | — | `references/domains-deep.md` |
| Ad hoc view list/inspect/export/import | `manage_adhoc.ps1` | `references/data-and-semantic-layer.md` |
| OLAP / Mondrian schema + connection | `create_mondrian.ps1` | `references/data-and-semantic-layer.md` |
| Hand-author/debug a Mondrian schema, XML/A, AGXML grants, MDX, OLAP engine tuning/cache flush | `create_mondrian.ps1` | `references/olap.md` |
| UI theme (CSS) | `scaffold_theme.py` + `deploy_theme.ps1` | `references/data-and-semantic-layer.md` |
| Schedule a job / set a data alert | `schedule_job.ps1`, `manage_alert.ps1` | `references/admin-and-scheduling.md` |
| Saved report options / clear a cache | `manage_options.ps1`, `manage_cache.ps1` | `references/admin-and-scheduling.md` |
| Usage / access-event report (most-run, who-ran-what, last-accessed) | `report_usage.ps1` | `references/admin-and-scheduling.md` |
| Generate a Visualize.js embed page for a report/dashboard/ad hoc view | `scaffold_visualize_embed.py` | `references/visualize-embedding.md` |
| Permissions / attributes / users / roles / orgs | `manage_permissions.ps1`, `manage_attributes.ps1`, `manage_users.ps1`, `manage_roles.ps1`, `manage_organizations.ps1` | `references/admin-and-scheduling.md` |
| jrxml schema (JR7 vs 6.x) | — | `references/jr7-schema.md` |
| REST v2 endpoint map (verified vs doc-only) | — | `references/jrs-rest-api.md` |
| Dashboard model shapes (descriptor + companions) | — | `references/dashboard-model.md` |
| Lint a jrxml/.jrtx/.jrdax before deploy | `lint_jrxml.ps1` | `references/jr7-valid-elements.md` |
| Extract metadata + column-level lineage (read-only; OpenLineage out) | `extract_lineage.py` | `references/catalog-connector-pdd.md` |
| Detect live-vs-committed resource drift | `diff_resource.ps1` | `references/admin-and-scheduling.md` |
| Apply a whole environment from one manifest (plan by default, `-Apply`) | `reconcile.ps1` | `references/environment.schema.json` |
| Preflight: toolchain, server, chart-customizer jar SHA, real repo-DB port from context.xml, every env profile version | `doctor.ps1` (`jrsWebappDir` in jrs.config.json) | `references/server-administration.md` |
| Doc/link consistency + junction/duplication guard (CI) | `check_docs.ps1` | — |
| Troubleshoot a deploy/fill error by symptom (index; detail lives in jr7-schema / jrs-rest-api / data-and-semantic-layer / x100-sql) | — | `references/gotchas.md` |
| What changed 9.0 → 10.0 → 10.1 (features, platforms, upgrade paths, promote compatibility) | — | `references/version-matrix.md` |
| Plan an upgrade/migration from ANY version 4.7+ (START at sec 0 field-reported issues, then upgrade ladder, platform cliffs, EOL dates, mitigations, checklist) | — | `references/upgrade-migration-playbook.md` |
| Per-era source depth: platform support 4.7→10.1, upgrade-guide procedures 5.6→10.1, relnotes/install/deprecation timeline | — | `references/version-archive/{platform-evolution,upgrade-procedures,relnotes-install-deltas}.md` |
| Set up external authentication (LDAP, CAS, token pre-auth, OAuth/OIDC) or map external users to orgs/roles | — | `references/authentication.md` |
| Harden the server / debug security-related REST 401s (keystore, CSRF, domain whitelist, SSL, lockout) | — | `references/server-hardening.md` |
| Back up / promote via js-import, js-export, buildomatic; tune logging, audit, caches, themes, org attributes | — | `references/server-administration.md` |
| AWS deployment, telemetry/data-collection opt-out, accessibility (VPAT/WCAG) questions | — | `references/aws-telemetry-vpat.md` |
| Valid JR7 elements per construct (strict-Jackson) | — | `references/jr7-valid-elements.md` |
| Secrets / config / portability (env, passwordCommand, no plaintext) | — | `references/security-and-config.md` |
| Sample DBs / email test / CI / Visualize.js embed | — | `references/{seed-data,smtp-testing,ci-smoke,visualize-embedding}.md` |
| REST surface snapshot + manifest/config JSON schemas | — | `references/application.wadl`, `manifest.schema.json`, `jrs.config.schema.json` |

## The core happy path (report → deploy → run)
```powershell
$env:PGPASSWORD = "postgres"
# 1. Scaffold a JR7 jrxml from a query (see references/reports.md for every flag)
python $skill\scaffold_jrxml.py --name county_summary --title "County Edge Summary" `
    --query "SELECT c.name AS county, count(*)::int AS edge_count FROM ... GROUP BY 1 ORDER BY 2 DESC" `
    --out report\county_summary.jrxml
# 2. (optional) Compile to validate JR7-clean before deploying
& $skill\compile_jrxml.ps1 -Jrxml report\county_summary.jrxml
# 3. (one-time) Create the datasource the report will use
& $skill\create_datasource.ps1 -Uri /datasources/postgis_34_sample -Label "PostGIS" `
    -Database postgis_34_sample -DbUser postgres -DbPassword postgres
# 4. Deploy (JRS compiles server-side; 201 Created)
& $skill\deploy_report.ps1 -Jrxml report\county_summary.jrxml `
    -TargetUri /reports/geocoder/county_summary -Label "County Edge Summary" `
    -DataSourceUri /datasources/postgis_34_sample
# 5. Run to PDF to verify (200 + %PDF-)
#    curl.exe on Windows PowerShell 5.1 (`curl` is an Invoke-WebRequest alias there);
#    plain `curl` under pwsh 7 on macOS/Linux. Scripts use Get-JrsCurl to pick.
#    Pull the URL and password from jrs.config.json (do not hardcode them):
$cfg = Get-Content plugins/jasper-deploy/skills/jasper-deploy/jrs.config.json | ConvertFrom-Json
curl.exe -s -u "$($cfg.user):$($cfg.pass)" -o out.pdf `
    "$($cfg.url)/rest_v2/reports/reports/geocoder/county_summary.pdf"
```
Re-deploy with **`-Overwrite`** (`?overwrite=true`; NOTE this re-creates the
unit -- version resets to 0 -- and it still 403s under a live dashboard's lock,
so recompose the dashboard with `-Replace` first; existing input-control
attachments are carried over automatically since 1.2.1). Full scaffold flags (templates, charts, `--param/--group-by/--highlight/
--drill/--crosstab/--subreport`, style templates, CSV adapters, visualization
components) are in `references/reports.md`; deploy input-control options
(`-Control`, `-QueryControl`, cascading) are in `references/admin-and-scheduling.md`.

## Compose a dashboard (one command)
```powershell
$env:PGPASSWORD = "postgres"
& $skill\build_dashlets.ps1 -Manifest report\foodmart\dashboard.json -Compose
```
Scaffolds → compiles → deploys → verifies each report tile, then composes them
into a rendering dashboard via export-inject-import (NOT a raw PUT). Manifest
schema, mixed text/image tiles, the why-import-not-PUT rule, `resource.in.use`
handling, and designer-authored dashboards are in `references/dashboards.md`.

## Critical cross-cutting gotchas (do not relearn these)
- **JR7, not 6.x.** A 6.x jrxml fails the JR7 loader; the strict Jackson parser
  rejects unknown elements at *fill time* as a generic `400`, not a clean compile
  error. This bites `.jrtx` (`default="true"`, not `isDefault`) and `.jrdax`
  adapters (limited element set). See `references/jr7-schema.md` + `reports.md`.
- **Lint before deploy (now automatic).** `deploy_report.ps1` runs `lint_jrxml.ps1`
  as a pre-deploy gate (`-SkipLint` to bypass); it catches the strict-Jackson 400s a
  clean compile misses (isDefault, `.jrdax` JR6 elements, pie `seriesColors`/`seriesOrder`,
  leading-`WITH` SQL, line/area plot props, title-band `evaluationTime`). Chart plot
  props are per-class: `line` = showLines/showShapes; `bar`/`bar3d`/`stackedbar` =
  showTickMarks/showTickLabels; **`area` (`JRDesignAreaPlot`) accepts NEITHER** —
  bare `<plot/>` only. Valid names per construct: `references/jr7-valid-elements.md`;
  symptom→fix index: `references/gotchas.md`. When a JRS call still fails, `Assert-JrsOk`
  appends a `gotchas.md` pointer (via `Get-GotchaHint`). `deploy_report.ps1 -Overwrite`
  and `compose_dashboard.ps1` export the current version first by default (`-NoBackup`
  to skip; the step is then irreversible for `recover_run.ps1`).
- **Safety model (1.3.0, ported from jrsctl).** `promote.ps1`, `compose_dashboard.ps1`,
  `teardown_dashboard.ps1` and `deploy_report.ps1 -Overwrite` **plan by default and
  write only with `-Apply`** (`-WhatIf`/`-DryRun` remain as names for the default).
  The gate is enforced *below* the scripts: `Invoke-JrsPut`/`Invoke-JrsDelete`/non-GET
  `Invoke-JrsRest` throw `PLAN MODE` while a plan runs (G64), so a clobbered switch
  can only fail safe. Any write to a `prod*` profile (or its URL) throws `PROD GUARD`
  unless a human sets `$env:JRS_ALLOW_PROD_WRITE = '1'` for that one run (G65).
  Every `-Apply` run is journaled under `out/runs/<runId>` with a `reimport`/`delete`
  compensation per mutating step; `promote.ps1 -Apply` rolls itself back on failure
  (exit 3 = rolled back, 4 = incomplete, 2 = nothing mutated) and
  `recover_run.ps1 -RunId <id> -Rollback -Apply` undoes any run later. Callers that
  ARE the deploy command (`build_dashlets.ps1`, `reconcile.ps1 -Apply`,
  `smoke_test.ps1`, the wizard) pass `-Apply` through.
- **Report queries must begin with `SELECT`.** A leading `WITH` (CTE) is rejected
  by the JRS SQL security validator at fill time (`JSSecurityException`) — a
  generic `400` that a clean local compile does NOT catch. `deploy_report.ps1`
  lints and blocks it (`-SkipSqlLint` overrides); `scaffold_jrxml.py` warns.
  **Fix:** push each CTE into a nested `FROM` subquery so the statement starts with
  `SELECT` (`WITH a AS (...) SELECT ... FROM a` → `SELECT ... FROM (...) a`); verify
  the rewrite in psql first — output must be identical. Window functions are fine.
- **Don't PUT dashboards or ad hoc views.** A hand-built model PUT to
  `/rest_v2/resources` stores (201) but renders **blank** (dashboard) or `500`s
  (`"bytes is null"`, ad hoc). Always go through the export-inject-**import** path
  (`compose_dashboard.ps1` / `manage_adhoc.ps1`). See `references/dashboards.md`.
- **Field `class` must match the JDBC column type** or fill fails — the scaffolder
  handles this; keep `<field class>` in sync if you hand-edit the SQL.
- **PowerShell 5.1:** `?` is a variable-name char (build URLs with `${base}`
  braces); pass JSON bodies to curl from a **file** (`--data "@req.json"`), not
  inline (`-d`), which gets quotes mangled → `400 serialization.error`. (These
  hold under pwsh 7 too, so the file-based curl bodies are also what make the
  scripts portable to macOS/Linux.)
- **Never dot-source a script that has a `param()` block.** Dot-sourcing re-runs
  that block in YOUR scope and resets `$WhatIf`, `$Env`, ... to defaults (this is
  how a `promote.ps1 -WhatIf` wrote to PROD on 2026-08-28, gotcha G60). Shared
  functions live only in param-less files: `_jrs_common.ps1`,
  `_controls_common.ps1` (input-control spec/ensure helpers) and `_jrs_run.ps1`
  (run journal, rollback plan/executor, `Export-JrsBackup`; dot-sourced by
  `_jrs_common.ps1`). `tests/dotsource.Tests.ps1` enforces this.
- **Existence checks:** `Invoke-JrsGet` returns `.Code` and never throws on 404;
  use `Test-JrsResource` / `Assert-JrsResource` (`_jrs_common.ps1`). Deploy scripts
  now emit a result object on the pipeline (Write-Host lines are NOT captured by
  `2>&1` under PS 5.1) - capture the object, or verify by GET.
- **Cross-platform:** scripts call `Get-JrsCurl` / `Get-JrsPython` / `Get-JrsNull`
  (in `_jrs_common.ps1`) instead of hardcoding `curl.exe` / `python` / `NUL`, and
  use `/` path separators — so the same scripts run on Windows and under pwsh 7 on
  macOS/Linux. Keep that convention when adding or editing a script.

## After editing any script: smoke test
```powershell
$env:PGPASSWORD = "postgres"
& $skill\smoke_test.ps1
```
First runs **offline prechecks** (`check_docs.ps1` doc-consistency + the `tests/`
Pester unit suite), then the full 24-step server lifecycle under a throwaway
`/reports/_smoke` (+ `/themes`):
scaffold → **lint** → compile → deploy (+input control) → verify → run-to-PDF → schedule job
(CRUD) → alert (CRUD) → compose dashboard (report + text tile) → style template →
single-table Domain → multi-table Domain (join) → jndi datasource → UI theme →
AWS datasource → cascading query input controls → permissions set/clear → server
attribute CRUD → Mondrian schema + connection → Visualize.js embed scaffold →
datasource `-Test` (live `/contexts` connection) → report thumbnail → diagnostic
collector lifecycle → teardown, asserting each step (+ a `wizard-api` step that
joins in only when the jasper-wizard WAR is deployed next to JRS). **If you change a script's params or
stdout shape, also check the web wizard handler** that calls it
(`references/admin-and-scheduling.md` → Web wizard).

## Docs & references
- Live WADL (never version-drifts): `<server>/rest_v2/application.wadl?detail=true`.
- `references/jrs-rest-api.md` — distilled, verified-vs-doc-only endpoint map
  (covers `reports`, `reportExecutions`, `inputControls`, `options`, `jobs`,
  `alerts`, `queryExecutor`, `caches`, non-JDBC datasources, and a verified
  Visualize.js cross-origin embedding recipe).
- The distilled **[doc-only] references ship with this skill and stand alone** —
  no PDF corpus needed to use them: `version-matrix.md` (deep 9.0→10.1),
  `upgrade-migration-playbook.md` (4.7→10.1 upgrade ladder + mitigations),
  `version-archive/` (per-era platform / upgrade-procedure / relnotes depth),
  `authentication.md`, `server-hardening.md`, `olap.md`, `domains-deep.md`,
  `server-administration.md`, `aws-telemetry-vpat.md`, the version-deltas
  section of `jrs-rest-api.md`, and the API-surface section of
  `visualize-embedding.md`.
- They were built from a full JRS PDF documentation corpus (9.0/10.0/10.1 sets
  plus archive-recovered 4.7→8.2 docs). The corpus itself is **not shipped**
  (large, gitignored under `docs/` when present locally); if a machine has it,
  its location and how to read/extend it are described in that machine's
  `LOCAL.md`. Page-number cites (`p.NN`) in the references refer to that corpus.

## Cross-platform (macOS/Linux)
The scripts run unchanged on Windows and under **PowerShell 7 (`pwsh`)** on
macOS/Linux. What makes them portable (and the conventions to keep):
- **Runtime:** `brew install powershell` (macOS) or the distro package (Linux) →
  invoke scripts as `pwsh scripts/<name>.ps1 …` (on Windows, `.\<name>.ps1` under
  either 5.1 or `pwsh`).
- **Tool names via helpers:** `_jrs_common.ps1` exposes `Test-JrsWindows`,
  `Get-JrsCurl` (`curl.exe`→`curl`), `Get-JrsPython` (`python`→`python3`), and
  `Get-JrsNull` (`NUL`→`/dev/null`). Scripts call these instead of hardcoding, so
  the right binary is chosen per OS. The Windows-PS-5.1 case is handled too
  (`$IsWindows` is `$null` there — the helpers test `-eq $false`).
- **Paths:** use `/` separators (valid on all three runtimes); avoid literal `\`.
- **Toolchain (macOS via Homebrew):** `brew install openjdk@11 postgresql@14
  curl python@3` and a JR7 lib dir; then set `jrLibDir` (and, if you check the
  bar-gradient customizer, `chartCustomizerJar`) in `jrs.config.json` to
  absolute macOS paths. Run `pwsh scripts/doctor.ps1` to confirm readiness.
- **Secrets:** `passwordCommand` in `jrs.config.json` runs under `pwsh`, so a
  macOS Keychain lookup works: `"passwordCommand": "security find-generic-password
  -s jrs -w"`.
- **Not ported:** nothing in the deploy pipeline is Windows-only. `make_docx.ps1`
  (a standalone HTML→DOCX utility) uses Word COM on Windows and falls back to
  LibreOffice (`soffice --convert-to`) or `pandoc` on macOS/Linux.
