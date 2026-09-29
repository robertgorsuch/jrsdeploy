# Changelog — jasper-deploy plugin

## 1.3.0 (2026-09-28) -- safety model ported from jrsctl

Items 4, 5, 7 and 8 of the jrsctl comparison (spec
`specs/2026-09-28-jasper-deploy-safety-model-design.md`).
Validated on STAGE only: deploy -> compose -> teardown -> rollback -> verify_suite
PASS, and promote plan -> apply -> rollback -> verify_suite PASS, all on
`/reports/_smoke/harness`. PROD was not contacted.

### Positive write gate (plan by default)
- `promote.ps1`, `compose_dashboard.ps1`, `teardown_dashboard.ps1` and
  `deploy_report.ps1 -Overwrite` print their plan and write nothing unless
  `-Apply` is passed. `-WhatIf` / `-DryRun` stay accepted as names for the
  default; `-Apply` with either is an error. A clobbered switch now defaults to
  plan mode (the incident direction is closed).
- Callers that are the deploy command pass `-Apply` through: `build_dashlets.ps1`,
  `reconcile.ps1 -Apply`, `smoke_test.ps1`, `scripts/pos_perf/restore_prod_pos.ps1
  -Apply`, the wizard servlet.

### Write guard below the scripts (`_jrs_common.ps1`)
- `Enter-JrsPlanMode` / `Restore-JrsPlanMode` / `Test-JrsPlanMode`; a parent in
  plan mode is never downgraded by a child called with `-Apply`.
- `Assert-JrsWriteAllowed` runs inside `Invoke-JrsPut`, `Invoke-JrsDelete` and
  every non-GET `Invoke-JrsRest` (export / reportExecutions / contexts / reports
  are read-like): `PLAN MODE` while planning (G64), `PROD GUARD` for a `prod*`
  profile or its URL unless `$env:JRS_ALLOW_PROD_WRITE = '1'` (G65). Reads are
  never guarded. Each `-Apply` run also prechecks the target before any backup.
- `Resolve-JrsConfig` exposes `IsProd` (`Test-JrsProdTarget`).
- `Invoke-JrsRest -FormFile` (multipart); `import_resource.ps1` and the
  dashboard DELETE in `compose_dashboard.ps1` now go through the guarded helpers.

### Run journal and rollback (`_jrs_run.ps1`, `recover_run.ps1`)
- Every `-Apply` run writes `out/runs/<runId>/run.json` + `transitions.jsonl`
  (`r-yyyyMMdd-HHmmss-xxxx`; `$env:JRS_RUNS_DIR` overrides). Child scripts join
  the parent run. Passwords are never persisted.
- Backups are taken by default before every delete/overwrite (`-NoBackup` to
  skip, journaled as irreversible). This closes the teardown-without-backup gap.
- Compensations are data: `reimport {zip, uri}` (pre-delete then import, so a
  dashboard's companion files come back) and `delete {uri}`.
- `promote.ps1 -Apply` compensates automatically on failure, failing step first
  then succeeded steps newest-first (`-NoRollback` disables). Exit codes: 0, 2
  nothing mutated, 3 rolled back, 4 rollback incomplete.
- `recover_run.ps1 -List | -RunId <id|latest> [-Rollback [-Apply]]` replaces the
  POS-only restore script for the generic case; it resolves the run's own target
  so the PROD guard still applies.
- `Export-JrsBackup` shared helper; `New-JrsDeployResult` accepts `Status PLAN`.

### Recorded-server harness
- `tests/mock_jrs.py`: stateful replay of `tests/recordings/<ver>-<edition>/`
  with a JSON-lines request log; accepts writes, answers export/import state
  machines, learns imported URIs from the archive's index.xml.
- `scripts/record_server.ps1 -Manifest -Env stage`: read-only recorder
  (serverInfo, folders, dashboards, tiles incl. `?expanded=true`, controls);
  timestamps and credential-shaped keys stripped.
- `tests/recordings/10.0.0-PRO/`: recorded from STAGE 2026-09-28 for
  `tests/fixtures/harness/harness_dashboard.json` (+ `src/tile_a|b.jrxml`).
- `tests/harness.Tests.ps1` (9 tests): promote/teardown/compose in plan mode
  issue GETs only and exit 0; promote `-Apply` writes, journals >= 4
  compensations, exits 0; `recover_run -Rollback` plans without writing and
  `-Apply` replays and exits 3; `deploy_report -Overwrite` without `-Apply` never
  PUTs. Skips cleanly when python or the recording is missing.
- Unit tests: `tests/write_guard.Tests.ps1` (16), `tests/run_journal.Tests.ps1`
  (9). Suite: 142 passed.
- `smoke_test.ps1` precheck now names the failing Pester tests; the test files that
  expect a child's stderr pin `$ErrorActionPreference = 'Continue'` so the suite is
  green under the smoke test's `Stop` as well. Smoke on STAGE 2026-09-28: 25/25.

## 1.2.1 (2026-08-28) -- incident fixes

A `promote.ps1 -Manifest ... -WhatIf` run against PROD was NOT read-only and
tore the pos_perf suite down (10 dashboards deleted, 22 tiles re-created
without their input controls). Root causes and fixes:

- `promote.ps1` dot-sourced `ensure_controls.ps1` to borrow functions; that
  script's `param([switch]$WhatIf, ...)` re-bound `$WhatIf` to `$false` in the
  caller. Shared functions moved to `_controls_common.ps1` (no param block);
  new `tests/dotsource.Tests.ps1` fails any dot-source of a script that
  declares parameters. (G60)
- `deploy_report.ps1 -Overwrite`: `?overwrite=true` re-creates the unit and
  drops `inputControls`; the live list is now carried into the PUT body unless
  `-Control*` supplies new ones. Docs corrected: the overwrite is not in-place
  and does not bypass a dashboard lock. (G21, G61)
- `promote.ps1` attach phase decides from LIVE target state after the tile
  step instead of the plan-time snapshot. (G63)
- `import_resource.ps1` prints the import state's `warnings[]` /
  `errorDescriptor` (a "finished" import can still have skipped resources).
- `Get-ReportControlUris` / restore helper: `return ,@()` so empty lists do
  not reach callers as `$null`; `ensure_controls.ps1` no longer assigns its
  parsed spec into its own `[string]$Spec` parameter. (G62)
- Repo: `scripts/pos_perf/restore_prod_pos.ps1` (plan by default, `-Apply`
  writes) re-attaches controls from STAGE and recomposes the 10 dashboards.

## 1.2.0 (2026-08-28)

Driven by the POS suite build/promotion sessions (Aug 20-27): every manual loop
that recurred in RUNBOOK.md is now a script, and the helper traps that caused
silent misreads are fixed.

### New scripts
- `verify_suite.ps1`: one read-only script for the "verify the build on STAGE
  without a browser" loop (report units exist / render code+bytes+pages /
  server-vs-git jrxml byte-diff / dashboard exists + input-control count vs
  manifest `filters`); `-Env` profiles, csv/json output, `-Offline` preflight,
  non-zero exit on any FAIL. Replaces five hand-written RUNBOOK recipes.
- `ensure_controls.ps1`: declarative, idempotent input-control creation from a
  JSON spec or a manifest `controls` key (types 1-7, LOV/query/dataType
  sub-resources, `-Update`, `-WhatIf`, `-Env`); generalises the four ad hoc
  `scripts/pos_perf/*_controls.ps1` scripts. Example: `fixtures/controls.example.json`.

### Promotion and recompose
- `promote.ps1`: manifest mode (`-Manifest <file|dir|glob> -FromEnv/-ToEnv
  [-WhatIf] [-EnsureControls] [-Backup]`) replays the PROD promotion in
  dependency-safe order: teardown -> folders -> controls -> distinct tiles
  (deploy_report -Overwrite, or export+import) -> re-attach controls ->
  compose -Replace. `-WhatIf` prints the full plan with target state and a
  byte-level jrxml comparison and issues GETs only. `-Uri` mode unchanged.
- `compose_dashboard.ps1`: explicit `-Replace` (idempotent delete+import
  transaction logged as [1/3] backup -> [2/3] delete -> [3/3] import), `-Env`,
  `-EnsureControls`; surfaces the fix on 403 `resource.in.use` /
  `import.decode.failed`; returns `{Uri, Code, Replaced, BackupPath, ...}`.
- `sync_manifest_from_dashboard.ps1` / `sync_manifest.py`: round-trip the
  designer presentation keys and the filter group (docked/floating, strip
  height); `-Manifest`/`--merge` update a manifest in place preserving key
  order; `-WhatIf`/`--dry-run` print a diff. gen -> sync -> gen is a fixed point.
- `gen_dashboard.py` honours `filterStripHeight`.
- `manifest.schema.json`: `controls` key, filter-group keys, per-dashlet
  `showTitleBar`/`resource`/`jrxml`/`controls`; `dataSourceUri` no longer required.

### Helper ergonomics
- `_jrs_common.ps1`: `Test-JrsResource` ([bool], HTTP 200 only) and
  `Assert-JrsResource` so existence checks no longer silently pass on
  `Invoke-JrsGet`'s non-throwing 404; `Get-JrsDashboardsReferencing`,
  `New-JrsDeployResult`; `Invoke-JrsDownload -TimeoutSec`.
- `deploy_report.ps1`: emits a `{Uri, Code, Status, ControlsAttached, Message}`
  result object on the pipeline (Write-Host is not captured by `2>&1` under
  PS 5.1); explains `resource.in.use` with the referencing dashboard(s) and
  the two fixes; accepts `-Env`.

### Preflight, lint, scaffold, CI guards
- `doctor.ps1`: SHA-256-compares the server's chart-customizer jar with the
  bundled one (WARN STALE + copy/restart steps); reads the real repository-DB
  port from `META-INF/context.xml` / `js.jdbc.properties` and cross-checks
  `repoDb` (bundled Postgres is often on 5433; never assume 5432); probes every
  `environments` profile and prints its version; new `jrsWebappDir` config key
  and `-ConfigPath`.
- `scaffold_jrxml.py --dialect x100`: static pre-compile check refuses ordered
  aggregates / ordered aggregate windows, correlated columns inside aggregates
  in subqueries, and `;` inside SQL comments (exit 3, nothing written);
  `--allow-dialect-warnings`, `--check-only`, `check_dialect_sql()` exported.
  Missing psql now exits 2 cleanly. Default postgres behaviour unchanged.
- `lint_jrxml.ps1 -Manifest`: manifest lint (missing `filterFloating` with
  `filters` -- the STAGE/PROD divergence after a8503f2 -- dashlets outside
  `folder`, duplicate dashlet names, invalid JSON / missing keys).
- `check_docs.ps1` check 5: junction guard -- fails if anything under
  `.claude/skills/jasper-deploy` is tracked in git (cf. f2184cf) or a real
  directory copy diverges from the plugin skill.

### References
- `gotchas.md` restructured into a symptom -> fix index (tables per area,
  stable G-ids, Where links); 582 -> 235 lines. Detail moved to its owner:
  G1-G14 -> `jr7-schema.md`; G25-G26, G33-G48, G50-G54 -> `jrs-rest-api.md`;
  G27-G32b -> `data-and-semantic-layer.md`.
- New gotchas G55-G59: area plot takes neither tick nor showLines/showShapes;
  PS 5.1 ConvertTo-Json single-element unwrap; inputControl type-code table;
  same-named metric differs across period windows (31.6 vs 33.7 gross margin);
  bundled metadata Postgres on a non-default port. G5: customizer jar must stay
  in WEB-INF/lib.
- New `x100-sql.md` (X100 engine restrictions + sql.ps1 splitter/export traps);
  `server-administration.md` "Preflight: doctor.ps1"; `ci-smoke.md`
  verify_suite; `dashboards.md` / `dashboard-model.md` replace transaction,
  ensure_controls, promote manifest mode, in-place sync, `controls` key.

### Tests
- New: `deploy_report`, `verify_suite`, `promote`, `sync_manifest`,
  `check_docs`, `doctor` Pester suites; `test_scaffold_jrxml.py` (18 cases,
  wired into CI on both OS legs); `_jrs_common` and `lint_jrxml` suites extended.

## 1.1.0 (2026-08-07)

### Packaging
- The plugin now ships only its own payload. Previously `source: "./"` cloned
  the entire working repository (~266 files) into every install — demo report
  suites, census loader scripts, a 239 KB sample SQL dump, workspace docs, a
  runtime lock file, and a repo-root `.claude/settings.json` that enabled
  unrelated plugins on installers' machines. The plugin source is now
  `plugins/jasper-deploy/` (skill + commands + manifests only).
- Skill moved from `.claude/skills/jasper-deploy/` to
  `plugins/jasper-deploy/skills/jasper-deploy/`.

### New: slash commands
- `/jasper-deploy:doctor` — preflight the toolchain and server connectivity
- `/jasper-deploy:smoke` — run the full 24-step smoke test
- `/jasper-deploy:deploy` — scaffold/compile/deploy a report and verify it
- `/jasper-deploy:promote` — promote a resource between environments

### SKILL.md
- Frontmatter description cut from ~2.4 KB to ~0.6 KB (it is injected into
  every session's skill list; the capability detail lives in the body).
- Machine-specific facts (server ports, install paths, local PDF doc corpus)
  moved out of SKILL.md into an optional, gitignored `LOCAL.md` overlay that
  the skill reads when present. SKILL.md is now environment-neutral; new
  environments start with `jrs.config.example.json` + `doctor.ps1`.
- Happy-path example now derives server URL and credentials from
  `jrs.config.json` instead of a hardcoded localhost URL.

### CI
- Re-enabled the offline skill checks (doc/link consistency + Pester unit
  tests) on pull requests, now on a windows-latest + ubuntu-latest matrix —
  the ubuntu/pwsh leg backs the cross-platform claim in SKILL.md.
- Added a plugin-manifest sanity step (marketplace source path + payload).

## 1.0.0 (2026-08-05)

- Initial release: jasper-deploy skill (49 scripts, 29 reference files,
  lint gate, smoke test, Pester tests) packaged as an installable Claude Code
  plugin with the jaspersoft-tools marketplace.
