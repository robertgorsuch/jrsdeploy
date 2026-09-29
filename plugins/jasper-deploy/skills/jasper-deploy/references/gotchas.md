# jasper-deploy gotchas (by symptom)

Entry point for "I saw X, what now". One table per area: Symptom | Cause | Fix |
Where. The Where column links to the reference that owns the area and carries
the full entry (Symptom / Cause / Fix / Handled-by). Entry ids (G1...) are
stable across files, so `G12` means the same thing everywhere.

Areas whose detail lives in another reference:
- JR7 jrxml, charts, `.jrdax`, `.jrtx` -> `jr7-schema.md` (element truth in
  `jr7-valid-elements.md`)
- REST, PowerShell 5.1, curl, file upload -> `jrs-rest-api.md`
- Datasources, Domains, OLAP, warehouse SQL -> `data-and-semantic-layer.md`,
  `x100-sql.md`
- Export/import, permissions/admin, alerts/options/run, environment (401s,
  lockout, contexts, diagnostic collectors, metadata DB port) -> `jrs-rest-api.md`

Areas whose detail is still in this file (see "Details" below): SQL security
validator, Pro charts, dashboards, collateral docs (Word COM), and the
customizer-jar note.

ASCII only. Terse on purpose.

## JR7 jrxml + community charts

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G1 | 400 UnrecognizedPropertyException at fill on a `line` chart | line plot takes `showLines`/`showShapes`, not the bar tick props | emit the plot per chart type | [jr7-schema.md#g1](jr7-schema.md#g1) |
| G2 | pie/pie3d 400 UnrecognizedPropertyException with gradient slices | it is repeated `<seriesColor order=...>`, no `<seriesColors>` wrapper, no `seriesOrder` | `<seriesColor order="N" color="#hex"/>` under `<plot>` | [jr7-schema.md#g2](jr7-schema.md#g2) |
| G3 | KPI gauge deploys, opaque 400 at run | Pro FusionWidgets gauge does not fill here | JFreeChart meter `shape="dial"` | [jr7-schema.md#g3](jr7-schema.md#g3) |
| G4 | dial value missing; dial is an oval | `<valueDisplay>` unreliable; non-square element | square element + overlay textField | [jr7-schema.md#g4](jr7-schema.md#g4) |
| G5 | `bar` report fails to fill | gradient customizer class not on the JRS classpath | copy `actian-chart-customizers.jar` to `WEB-INF/lib` + restart, or `--no-gradient` | [jr7-schema.md#g5](jr7-schema.md#g5) |
| G6 | fill fails after a SQL hand-edit | `<field class>` no longer matches the column type | resync the class | [jr7-schema.md#g6](jr7-schema.md#g6) |
| G7 | gradient/trend not applied on bar3D, stackedbar, multi-series | gradient is scoped to `bar` and `pie` only | expected; use a supported type | [jr7-schema.md#g7](jr7-schema.md#g7) |
| G8 | no-query report yields 0 pages | no detail rows, nothing emitted | `whenNoDataType="AllSectionsNoDetail"` | [jr7-schema.md#g8](jr7-schema.md#g8) |
| G9 | `repo:` logo absent in local RenderPng | `repo:` resolves server-side only | deploy + run-to-PDF to check | [jr7-schema.md#g9](jr7-schema.md#g9) |
| G10 | subreport invalid resource | URI points at a reportUnit, not a jrxml file | pass a jrxml FILE URI | [jr7-schema.md#g10](jr7-schema.md#g10) |
| G55 | area/stackedArea chart 400 UnrecognizedPropertyException | `JRAreaPlot` takes NEITHER tick props NOR showLines/showShapes | bare `<plot/>` | [jr7-schema.md#g55](jr7-schema.md#g55) |

## Data adapters (.jrdax) and style templates (.jrtx)

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G11 | CSV-backed report 400 UnrecognizedPropertyException at fill | strict Jackson rejects JR6 fields like `<useConnection>` | only the 13 valid `CsvDataAdapterImpl` elements | [jr7-schema.md#g11](jr7-schema.md#g11) |
| G12 | default style ignored / generic 400 | `.jrtx` uses `isDefault="true"` (6.x) | `default="true"` | [jr7-schema.md#g12](jr7-schema.md#g12) |
| G13 | CSV report 0 rows or "Misplaced quote" | UTF-8 BOM; `recordDelimiter` vs real line endings | strip BOM; `&#10;` or `&#13;&#10;` | [jr7-schema.md#g13](jr7-schema.md#g13) |
| G14 | `resourceBundle` report fails despite `whenResourceMissingType="Key"` | attribute covers keys, not a missing bundle | `-ResourceFiles "X.properties=path"` | [jr7-schema.md#g14](jr7-schema.md#g14) |

## SQL security validator, Pro charts / maps

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G15 | leading-`WITH` (CTE) query 400 / error UID at fill, compiles clean locally | JRS validator requires the query to start with `SELECT` | push CTEs into nested `FROM` subqueries | [#g15](#g15) |
| G16 | Pro chart/map blank or uniform, no error | bound to main dataset in a band that fills before rows | `evaluationTime="Report"` or `summary` band | [#g16](#g16) |
| G17 | Pro component will not compile locally | Pro components are 6.x jrxml; no mixing with JR7 | skip local compile; deploy + run-to-PDF | [#g17](#g17) |

## Dashboards

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G18 | PUT dashboard stores 201 but never renders | raw PUT skips the designer/import broker work | never PUT; compose + import | [#g18](#g18) |
| G19 | `ExtractToDirectory: the given path's format is not supported` | absolute `-WorkDir` joined to CWD | pass an absolute `-WorkDir` (fixed) | [#g19](#g19) |
| G20 | recompose silently keeps the OLD layout | import will not overwrite companion files | delete the dashboard first (default) | [#g20](#g20) |
| G21 | 403 `resource.in.use` re-deploying a dashlet report | dashlet locked by its dashboard; `?overwrite=true` is blocked too | recompose the dashboard with `-Replace` (teardown -> tile -> compose); `promote.ps1 -Manifest` orders it | [#g21](#g21) |
| G61 | redeployed tile lost its input controls; dashboard import then "finishes" but creates nothing | `PUT ?overwrite=true` RE-CREATES the unit (version 0) and drops `inputControls`; the dashboard's filter wiring then has a broken dependency and the importer skips it silently | `deploy_report.ps1 -Overwrite` now carries the live list over; promote attach phase decides from LIVE state; `import_resource.ps1` prints import warnings | [#g61](#g61) |
| G63 | promotion said "keep (N attached)" but the target ends with 0 controls | plan computed before the tile step re-created the unit (stale plan-time state) | attach phase re-reads the target after the tile step (1.2.1) | [#g63](#g63) |
| G22 | imported dashboard is a silent no-op | back-slash zip entries | forward-slash entries + `index.xml` | [#g22](#g22) |
| G23 | designer edits reverted on recompose | stale manifest | `sync_manifest_from_dashboard.ps1` first | [#g23](#g23) |
| G24 | dashboard URL "No flow definition found" | no `dashboardRuntimeFlow` | `dashboard/viewer.html#%2F...` | [#g24](#g24) |

## Export / import

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G25 | 405 on `GET /rest_v2/export/{id}` | download is `/exportFile` | poll `/state`, then `/exportFile` | [jrs-rest-api.md#g25](jrs-rest-api.md#g25) |
| G26 | ad hoc view PUT 500 "bytes is null" | opaque state + companion binary | export/import envelope | [jrs-rest-api.md#g26](jrs-rest-api.md#g26) |

## Datasources, Domains / OLAP, warehouse SQL

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G27 | datasource list empty / 204 | `type=dataSource` returns nothing | `type=jdbcDataSource` | [data-and-semantic-layer.md#g27](data-and-semantic-layer.md#g27) |
| G28 | AWS datasource 400 "invalid Region" | `-Region` is the endpoint host | `us-east-1.amazonaws.com` | [data-and-semantic-layer.md#g28](data-and-semantic-layer.md#g28) |
| G29 | non-JDBC datasource 201 but will not connect | create validates shape only | provision the server-side prerequisite | [data-and-semantic-layer.md#g29](data-and-semantic-layer.md#g29) |
| G30 | Domain create 500 `resource.does.not.exist` | pre-uploaded `schemaFileReference` | inline `schema.schemaFile.content` | [data-and-semantic-layer.md#g30](data-and-semantic-layer.md#g30) |
| G31 | Domain metadata wrong | `datasourceId` != datasource leaf | `--datasource-id <leaf>` | [data-and-semantic-layer.md#g31](data-and-semantic-layer.md#g31) |
| G32 | `olapUnit` 500 on create | view creation validates MDX live | best-effort; fix schema to match DB | [data-and-semantic-layer.md#g32](data-and-semantic-layer.md#g32) |
| G32b | multi-table Domain 400 `element.name.not.unique` | `<item id>` must be globally unique | suffix `_1`, `_2` designer-style | [data-and-semantic-layer.md#g32b](data-and-semantic-layer.md#g32b) |
| G58 | same-named metric differs across boards (31.6 vs 33.7 gross margin) | different period windows, same basis | state the window in the label; reconcile on one window | [data-and-semantic-layer.md#g58](data-and-semantic-layer.md#g58) |
| X1 | X100 rejects an ordered window / running total | no ordered aggregate windows | self-join or pandas | [x100-sql.md](x100-sql.md) |
| X2 | X100 rejects an aggregate over a scalar subquery | no correlated vars inside aggregates | materialise a one-row table | [x100-sql.md](x100-sql.md) |
| X3 | `INTERVAL()` fails on an X100 table | unsupported | Julian-day arithmetic; `DATE + n` works | [x100-sql.md](x100-sql.md) |
| T1 | `sql.ps1 run-file` runs a truncated or merged statement | `;` or an unbalanced `'` inside a SQL comment | keep both out of comments | [x100-sql.md](x100-sql.md) |
| T2 | `sql.ps1 export-csv` output unusable for a big result | not a bulk path | read over `pyodbc` | [x100-sql.md](x100-sql.md) |

## REST / PowerShell 5.1 / curl / file upload

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G33 | 409 versions not match on re-deploy | optimistic locking | `-Overwrite` (`?overwrite=true`) | [jrs-rest-api.md#g33](jrs-rest-api.md#g33) |
| G34 | async POST 400 serialization.error | inline `-d '{...}'` quotes mangled | body from a file `--data "@req.json"` | [jrs-rest-api.md#g34](jrs-rest-api.md#g34) |
| G35 | attribute call 405, base URL dropped | `"$base?name"` reads `$base?name` in PS 5.1 | `"${base}?name=..."` | [jrs-rest-api.md#g35](jrs-rest-api.md#g35) |
| G36 | all ~134 system attributes wiped | bare `PUT /attributes` replaces the set | always `?name=` scoped | [jrs-rest-api.md#g36](jrs-rest-api.md#g36) |
| G37 | database name dropped | `-Db` is an alias of `-Debug` | `-Database` | [jrs-rest-api.md#g37](jrs-rest-api.md#g37) |
| G38 | Maven/Java `-D` args eaten | PS parses them as switches | after `--%` | [jrs-rest-api.md#g38](jrs-rest-api.md#g38) |
| G39 | wrapper aborts on a clean compile | SLF4J on stderr under `Stop` | check the output file, not the pipeline | [jrs-rest-api.md#g39](jrs-rest-api.md#g39) |
| G40 | sync `/reports/{uri}.{fmt}` times out | blocking fill | async `reportExecutions` | [jrs-rest-api.md#g40](jrs-rest-api.md#g40) |
| G41 | `/Type /Page` grep reads 0 on a good PDF | compressed page tree | 200 + magic bytes + size | [jrs-rest-api.md#g41](jrs-rest-api.md#g41) |
| G42 | uploaded image will not resolve via `repo:` | uploaded as `png`/`jpg` | `upload_file.ps1 -Type img` | [jrs-rest-api.md#g42](jrs-rest-api.md#g42) |
| G56 | one-item list rejected (`ArrayList from String value`) | PS 5.1 `ConvertTo-Json` unwraps single-element arrays | `@()` / `-InputObject` / `,$arr`, or hand-built JSON | [jrs-rest-api.md#g56](jrs-rest-api.md#g56) |
| G57 | inputControl PUT `Cannot deserialize ... from String "singleValue"` | write API wants numeric type codes | 2 single, 3 LOV, 4 query, 6 multi LOV, 7 multi query | [jrs-rest-api.md#g57](jrs-rest-api.md#g57) |
| G60 | a `-WhatIf` / `-DryRun` script WROTE to the server | it dot-sourced a helper script that has its own `param()` block; dot-sourcing re-runs that block and re-binds `$WhatIf`, `$Env`, ... to defaults in the caller's scope | dot-source only param-less files (`_jrs_common.ps1`, `_controls_common.ps1`); `tests/dotsource.Tests.ps1` enforces it | [#g60](#g60) |
| G62 | a function's empty result makes `@(...)`.Count 1, or `$x.Controls` is null after `$x = Read-...` | `return @()` emits nothing (caller gets `$null`; `@($null)` has Count 1); `$spec` and `[string]$Spec` are the SAME variable, so the object is coerced to a string | `return ,@()`; never reuse a parameter name (any case) for a local | [#g62](#g62) |

## Permissions / attributes / admin, reports, collateral

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G43 | 415 setting permissions | `collection.permission+json` rejected | `application/collection+json` | [jrs-rest-api.md#g43](jrs-rest-api.md#g43) |
| G44 | `manage_users.ps1` 401 | `-Password` is the NEW user's password | `-JrsPassword` for auth | [jrs-rest-api.md#g44](jrs-rest-api.md#g44) |
| G45 | org create `PUT {id}` wrong | create is POST on the collection | POST; update is read-modify-write PUT | [jrs-rest-api.md#g45](jrs-rest-api.md#g45) |
| G46 | alert create 400 | `toAddresses` wrapper; `baseOutputFilename` required | `{address:[...]}` + filename | [jrs-rest-api.md#g46](jrs-rest-api.md#g46) |
| G47 | saved option values not applied | `?reportOptions=` does nothing | run the option's own URI | [jrs-rest-api.md#g47](jrs-rest-api.md#g47) |
| G48 | JR Library sample renders blank | harness params missing | pass params or bake defaults | [jrs-rest-api.md#g48](jrs-rest-api.md#g48) |
| G49 | `make_docx.ps1` path / format / inline-if failure | Word COM wants absolute paths; 16/17 codes; PS 5.1 parse | resolve paths, use codes, variable first | [#g49](#g49) |

## Environment

| Id | Symptom | Cause | Fix | Where |
| --- | --- | --- | --- | --- |
| G50 | everything 401s | wrong port (an unrelated service) | target the JRS port from `jrs.config.json` | [jrs-rest-api.md#g50](jrs-rest-api.md#g50) |
| G51 | 401 with the RIGHT password, even `serverInfo` | account lockout from a stale-credential client | re-enable in the metadata DB; fix the client | [jrs-rest-api.md#g51](jrs-rest-api.md#g51) |
| G52 | `POST /contexts` 415 | guessed media type | descriptor's own `repository.<type>+json` | [jrs-rest-api.md#g52](jrs-rest-api.md#g52) |
| G53 | collectors vanish / encrypted log / dup name | bare DELETE; server-key encryption; unique names | delete by id; support bundle; fresh name | [jrs-rest-api.md#g53](jrs-rest-api.md#g53) |
| G54 | type-filtered searches 500 after a collector | HIGH-verbosity collector bug | restart Tomcat; use LOW | [jrs-rest-api.md#g54](jrs-rest-api.md#g54) |
| G59 | psql / `report_usage.ps1` reach an EMPTY or stale metadata DB | bundled Postgres on a non-default port; a decoy on 5432 | read the port from `context.xml`, never assume 5432 | [jrs-rest-api.md#g59](jrs-rest-api.md#g59) |
| G5 | customizer-styled reports fail on a fresh target | jar not in that server's `WEB-INF/lib` | copy the jar there (survives restart, not reinstall) | [jr7-schema.md#g5](jr7-schema.md#g5) |

---

## Details (areas without a dedicated reference)

### G15
- Symptom: a report whose query starts with `WITH` (CTE) fails at fill time --
  `JSSecurityException` (`Validator.validateSQL`) surfaced as a generic 400 / error
  UID. A clean local `compile_jrxml.ps1` does NOT catch it (the CTE is valid JR/SQL).
  A 400 with an XML `errorDescriptor` body (magic `<?xml`) is the tell.
- Cause: the JRS SQL security validator requires queries to begin with `SELECT`.
  Window functions (`... over ()`) are fine; only a leading `WITH`/non-SELECT is rejected.
- Fix: push each CTE down into a nested subquery in `FROM` so the statement starts
  with `SELECT`: `WITH a AS (...), b AS (... FROM a) SELECT ... FROM b` becomes
  `SELECT ... FROM (... FROM (...) a) b`. Verify identical output in psql first.
- Handled-by: `deploy_report.ps1` lints + blocks before deploy (`-SkipSqlLint` overrides);
  `scaffold_jrxml.py` warns.

### G16
- Symptom: a Pro chart/map renders blank or uniform (no error).
- Cause: a component bound to the main dataset, placed in a band that fills BEFORE
  row iteration (e.g. `title`), binds zero data.
- Fix: set `evaluationTime="Report"`, or place the component in `summary`.
- Handled-by: author per the Pro recipe.

### G17
- Symptom: a Pro component (HTML5 HighCharts, FusionMaps) will not compile with the
  local JR7 jars.
- Cause: Pro components are authored in legacy 6.x jrxml; the open-source lib cannot
  compile them, and you cannot mix JR7-native with 6.x in one file.
- Fix: skip local compile -- deploy then run-to-PDF to validate (200 + non-trivial
  PDF; `.html` export contains the component markup).
- Handled-by: the whole file must be 6.x; JRS `legacy-jrxml-*` modules convert at fill.

### G18
- Symptom: a hand-built dashboard PUT to `/rest_v2/resources` stores `201` but never
  renders (frames spin forever; designer shows it empty) -- even when the model is
  byte-equivalent to a working one.
- Cause: the JRS 10 client needs extra broker work the designer/import does on save;
  a raw PUT skips it.
- Fix: do NOT PUT. Use the import path: synthesize companion files, inject into a real
  designer-shaped export envelope, re-zip, and import.
- Handled-by: `compose_dashboard.ps1` / `build_dashlets.ps1 -Compose`.

### G19
- Symptom: `ExtractToDirectory: the given path's format is not supported`.
- Cause: an absolute `-WorkDir` was joined with `Get-Location` unconditionally,
  producing an invalid `C:\cwd\C:\abs` path.
- Fix: pass an absolute `-WorkDir` (now honored); needed when CWD is not writable
  (e.g. the web wizard runs from the Tomcat temp dir).
- Handled-by: `compose_dashboard.ps1 -WorkDir <abs>` (fixed).

### G20
- Symptom: recompose over an existing dashboard silently keeps the OLD layout.
- Cause: JRS import will not overwrite an existing dashboard's companion files
  (`layout`/`components`/`wiring`).
- Fix: delete the target dashboard before importing (also frees dashlet
  `resource.in.use` locks).
- Handled-by: `compose_dashboard.ps1` deletes first by default (`-KeepExisting` to skip);
  `build_dashlets.ps1 -Compose` inherits it.

### G21
- Symptom: 403 `resource.in.use` (naming the owning dashboard) when re-deploying a
  report that is already a dashlet -- with OR without `-Overwrite`.
- Cause: a dashlet report is modification-locked by its owning dashboard. On 10.0.0
  `PUT ?overwrite=true` is a delete+re-create (the unit comes back at version 0),
  so the lock blocks it exactly like a DELETE. (Earlier text here claimed the
  overwrite "dodges" the lock; the 2026-08-28 PROD run and a STAGE retest disproved it.)
- Fix: recompose the owning dashboard: `compose_dashboard.ps1 -Manifest ... -Replace
  -Backup` (export, delete, redeploy tiles, import), or `promote.ps1 -Manifest`,
  which orders teardown -> folders -> controls -> tiles -> attach -> compose.
- Handled-by: `deploy_report.ps1` names the owning dashboard(s) and the recompose
  command; `build_dashlets.ps1` treats 403 as "in-use (kept)"; `teardown_dashboard.ps1`.

### G22
- Symptom: imported dashboard archive is a silent no-op.
- Cause: the Java importer ignores back-slash zip entry paths.
- Fix: re-zip with forward-slash entries and point `index.xml`'s
  `repositoryResources` at the dashboard.
- Handled-by: `compose_dashboard.ps1`.

### G23
- Symptom: a recompose reverts hand-edits made in the JRS designer.
- Cause: the compose manifest is stale relative to the live (rearranged) dashboard.
- Fix: re-derive the manifest from the live dashboard before recomposing.
- Handled-by: `sync_manifest_from_dashboard.ps1 -Uri <dash> -Out <manifest.json>`.

### G24
- Symptom: opening a dashboard URL errors "No flow definition found".
- Cause: there is no `dashboardRuntimeFlow`; a dashboard is not a `flow.html` flow.
- Fix: use the HTML5 viewer with the URI in the URL-encoded hash fragment:
  `.../dashboard/viewer.html#%2Freports%2F...`.
- Handled-by: N/A (use the right URL).

### G49
- Symptom: `make_docx.ps1` fails on a relative path, saves the wrong format, or
  PowerShell will not parse an inline conditional as a method arg.
- Cause: Word COM requires absolute paths; the SaveAs format codes are 16=`.docx`,
  17=`.pdf`; PowerShell 5.1 will not parse an inline `(if ... {} else {})` as a
  method argument.
- Fix: resolve paths to absolute; use codes 16/17; assign a conditional to a variable
  first. The script also releases the COM object in a `finally` block so a failed run
  leaves no orphaned `WINWORD.EXE`.
- Handled-by: `make_docx.ps1`.

### G60
- Symptom: `promote.ps1 -Manifest ... -WhatIf` tore down every PROD dashboard
  (2026-08-28). The script's own `if ($WhatIf) { return }` was correct.
- Cause: `. (Join-Path $PSScriptRoot "ensure_controls.ps1")` to borrow two functions.
  Dot-sourcing executes the target's `param([switch]$WhatIf, [string]$Env, ...)`
  in the CALLER's scope with no arguments, so `$WhatIf` became `$false`.
- Fix: shared functions live in files with no `param()` block
  (`_controls_common.ps1`); scripts never dot-source each other.
  `tests/dotsource.Tests.ps1` parses every script and fails on a dot-source of a
  file that declares parameters.
- Rule for any dry-run flag: prove it against STAGE with the write helpers stubbed
  to throw before pointing it at PROD.

### G61
- Symptom: after a tile redeploy the report unit has `version 0`, a new
  creationDate and NO `inputControls`; the next dashboard import returns
  `phase=finished` but the dashboard does not exist.
- Cause: `PUT rest_v2/resources/<uri>?overwrite=true` re-creates the unit from
  the body; a body without `inputControls` clears the attachments. The dashboard
  archive's filter wiring then references controls the tiles no longer carry and
  the importer skips the dashboard (its warnings were not printed before 1.2.1).
- Fix: `deploy_report.ps1 -Overwrite` GETs the live unit first and carries its
  `inputControls` into the PUT body (literal JSON, see G56) unless `-Control*`
  supplies new ones. `import_resource.ps1` prints `warnings[]` / `errorDescriptor`.
  To repair: re-PUT each unit with the reference server's list, then recompose
  (`scripts/pos_perf/restore_prod_pos.ps1` in the repo is the worked example).

### G62
- Symptom: `Get-Controls` "returned" an empty list but the caller saw `$null`
  and reported every tile as MISSING; `ensure_controls.ps1 -Spec` said
  "ensure 0 input control(s) under" although the file had 7.
- Cause: (a) `return @()` writes nothing to the pipeline, so the caller receives
  `$null`, and `@($null).Count` is 1. (b) `$spec = Read-ControlSpecFile -Path $Spec`
  assigns into the `[string]$Spec` parameter (names are case-insensitive) and the
  object is coerced to `"@{Folder=...}"`.
- Fix: `return ,@()` / `return ,@($list)`; use a distinct local name (`$specObj`).

### G63
- Symptom: promotion plan printed `keep (4 attached)` for a tile, execution
  redeployed the tile, and the target ended with 0 controls.
- Cause: the plan was annotated from target state BEFORE execution; the tile step
  re-created the unit (G61) and the attach step trusted the stale "keep".
- Fix: the attach phase re-reads the live unit after the tile step and attaches
  whenever live != wanted (`promote.ps1` 1.2.1). Plan lines now say
  "re-verified live after the tile step".

### G64
- Symptom: a script throws `PLAN MODE: refused PUT/DELETE/POST <url> -- this run is
  planning only (nothing is written); pass -Apply to write`.
- Cause: `promote.ps1`, `compose_dashboard.ps1`, `teardown_dashboard.ps1` and
  `deploy_report.ps1 -Overwrite` plan by default (1.3.0). Plan mode is a process-wide
  state set by `Enter-JrsPlanMode` and enforced inside `Invoke-JrsPut` /
  `Invoke-JrsDelete` / non-GET `Invoke-JrsRest`, so a child script or a clobbered
  switch (G60) cannot turn a plan into writes. A parent in plan mode is never
  downgraded by a child called with `-Apply`.
- Fix: re-run with `-Apply` (after reading the plan). If you see it from a script
  that has no `-Apply`, the caller is planning: pass `-Apply` at the top.

### G65
- Symptom: `PROD GUARD: refused <method> <url> on <server> [env prod]. Writes to a
  prod profile need $env:JRS_ALLOW_PROD_WRITE = '1' ...`, exit 2, nothing written.
- Cause: the target profile name starts with `prod`, or its URL equals such a
  profile's URL (an explicit `-ToServerUrl` triple is caught too). Reads are never
  guarded; `POST /rest_v2/export` counts as a read. The check also runs as a
  precheck at the start of every `-Apply` run, before any backup export.
- Fix: a human sets `$env:JRS_ALLOW_PROD_WRITE = '1'` in the shell for that one
  run, after the same `-Apply` run succeeded on STAGE (RUNBOOK policy, incident
  2026-08-28). Agents never set it.
