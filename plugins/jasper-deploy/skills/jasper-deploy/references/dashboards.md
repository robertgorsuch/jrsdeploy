# Dashboards — compose, author, promote, teardown

Deep reference for JRS dashboards. The dashboard *model shapes* (descriptor +
companion files) are in `references/dashboard-model.md`; this file is the
*workflow*. `$skill` = the skill's `scripts/` dir.

## Fully scripted: compose a dashboard of report dashlets — `build_dashlets.ps1`
Drives the **entire** dashboard pipeline from one JSON manifest — no designer
needed for a dashboard whose tiles are deployed reports (each a tabular report
with a chart in its summary band):
```powershell
$env:PGPASSWORD = "postgres"
& $skill\build_dashlets.ps1 -Manifest report\foodmart\dashboard.json -Compose
```
For each `dashlets[]` entry it **scaffolds → compiles → deploys → verifies** (runs
to PDF, asserts `200` + `%PDF-` + non-trivial size), prints a results table, then
with **`-Compose`** assembles them into the dashboard. **Verified end-to-end**
building the 7-tile `foodmart_kpi_dashboard_auto`. The unified manifest carries
both the build spec and the grid layout:
```jsonc
{ "db":"foodmart", "dataSourceUri":"/public/Samples/Data_Sources/FoodmartDataSource",
  "folder":"/reports/foodmart", "name":"foodmart_kpi_dashboard_auto",
  "label":"...", "outDir":"report\\foodmart",
  "dashlets":[ {
    "name":"foodmart_yoy_sales", "title":"Year-over-Year Sales", "chart":"bar",
    "chartCategory":"month","chartValue":"sales","chartSeries":"year",
    "chartHeight":380, "landscape":true, "queryFile":"report\\foodmart\\yoy_sales.sql",
    "x":0,"y":0,"width":40,"height":10 }, ... ] }
```
`x/y/width/height` place each tile on a 40-wide grid (omit them all and pass
`-AutoGrid`; manifest `"cols"` sets the column count, default 2). Use
`-SkipVerify` to skip the run-to-PDF check.

**Mixed tiles.** A dashlet's `"kind"` is `report` (default), `text`, or `image`:
- `text` — `{"kind":"text","name":"Hdr","text":"…","size":18,"bold":true,
  "align":"center","color":"rgba(..)","background":"rgb(..)"}`
- `image` — `{"kind":"image","name":"Logo","url":"repo:/path or http://…"}`

Only report tiles are exported/referenced; text/image carry no repository
resource. A manifest-level `"wiring":[{"producer":"A:out","consumers":["B:param"]}]`
appends cross-dashlet (filter) wiring. **Verified:** a text+report+report+image
dashboard composes, imports, and re-exports intact. The full model schema is in
`references/dashboard-model.md`. (Interactive **filterGroup + inputControl** tiles
and **ad hoc views** stay designer-authored — see below.)

## How the compose step works (and why it renders, unlike a raw PUT)
A JRS dashboard is a descriptor + three companion files (`components` = the
dashlet frames + a `DashboardProperties` singleton, `layout` = the `<div
data-componentId data-x data-y data-width data-height>` grid, `wiring` =
`@init`→`@refresh` / `@applyParams` events). `gen_dashboard.py` synthesizes all
four from the manifest (the model shape is reverse-engineered from a real
designer export; `id` = `re.sub('[^0-9A-Za-z]','_', label)`).
`compose_dashboard.ps1` then: exports the already-deployed dashlet reports (→ a
real, importable envelope: reportUnit descriptors + jrxml, datasource, folder
chain, valid `index.xml`), **injects** the synthesized dashboard into it, points
`index.xml`'s `repositoryResources` at the dashboard, re-zips with
**forward-slash** entries (the Java importer ignores back-slash paths — a silent
no-op), and **imports** it. Because the archive is structurally identical to a
designer export, the imported dashboard **renders** — verified by a clean
re-export round-trip (a broken import cannot be re-exported) and the HTML5 viewer.

> **Why import, not PUT?** You *can* PUT a hand-built dashboard model straight to
> `/rest_v2/resources` and the server stores it (201) — but the JRS 10 client
> **silently won't render it** (frames spin forever; the designer shows it empty),
> even when the stored model is byte-for-byte equivalent to a working one. The
> designer/import broker does extra work on save that a raw PUT skips. The
> **import** path reproduces that work, so it renders. Don't PUT.

`compose_dashboard.ps1 -WorkDir` accepts an **absolute** path (defaults to the
relative `out\dash_build`). Earlier it joined the work dir with `Get-Location`
unconditionally, so an absolute `-WorkDir` produced an invalid `C:\cwd\C:\abs`
path and `ExtractToDirectory` threw "the given path's format is not supported";
that's fixed — pass an absolute `-WorkDir` when the caller's CWD isn't writable
(e.g. the web wizard runs it from the Tomcat temp dir).

## Gotcha — `resource.in.use` (403)
A report that is already a dashlet of an **existing** dashboard is
modification-locked by JRS: re-deploying it (delete or `?overwrite=true` PUT
alike) returns `403 resource.in.use` naming the owning dashboard.
`build_dashlets.ps1` treats this as **"in-use (kept)"** — not a failure — leaves
the deployed version in place, still verifies it renders, and continues to
compose. To actually push report changes, delete/recreate the owning dashboard
(or compose under a new name) first. `deploy_report.ps1 -Overwrite` updates **in
place** via `?overwrite=true` (no delete), which also dodges the delete-protection
on referenced resources.

## Author in the designer; promote via export/import
For dashboards with non-report tiles (ad hoc views, filter groups, text/input
controls) authoring is still a manual designer step:
1. Author once in the **designer**, dragging in already-deployed reports / ad hoc
   views, then Save:
   `http://localhost:8081/jasperserver-pro/dashboard/designer.html`
   (open an existing one at `dashboard/designer.html#<url-encoded uri>`).
2. **Version-control / back up / promote** it with the REST v2 export+import
   service (the archive is the designer's own output, so it re-imports and renders
   identically — ideal for dev→prod promotion across servers):
```powershell
& $skill\export_resource.ps1 -Uri /reports/geocoder/sales_dashboard -Out backups\sales_dashboard.zip
& $skill\import_resource.ps1 -Zip backups\sales_dashboard.zip      # -Update:$false to fail on existing
```
`export_resource.ps1`: POST `/rest_v2/export` `{uris,parameters}` → `{id}`, polls
`/rest_v2/export/{id}/state` until `phase=finished`, downloads
`/rest_v2/export/{id}/exportFile` (the download is **`/exportFile`** — a bare
`GET /rest_v2/export/{id}` returns `405`). `import_resource.ps1`: POSTs the zip
multipart to `/rest_v2/import?update=true`, polls `/rest_v2/import/{id}/state`.
Both export folders recursively (export a folder URI to grab a whole app).
**Verified:** round-trip export+import of the `1._Supermart_Dashboard` sample, and
a **destructive** round-trip of `5._Top_Performers` — export → DELETE the
dashboard (`resource.not.found`) → import → the full component model is restored
intact (all frames: charts, text dashlet, filter group, input control; plus the
embedded ad hoc views, `layout` and `wiring`). The export archive holds the
dashboard `.xml` descriptor + `_files/{components.data,layout,wiring.data}` + each
embedded ad hoc view.

## Recompose = replace -- `compose_dashboard.ps1 -Replace`
A recompose over an existing dashboard is ONE logged transaction:
`[backup] -> DELETE dashboard -> import fresh archive -> verify`. That is the
default; `-Replace` names it explicitly (idempotent: same manifest in, same
dashboard out, any number of times) and `-KeepExisting` skips the delete
(rarely wanted -- the import then cannot change the live layout). **Since 1.3.0
the script plans by default**: without `-Apply` it prints the COMPOSE PLAN (GETs
only) and returns `Code = PLAN`. With `-Apply` the old dashboard is exported to
`-BackupDir` first by default (`-NoBackup` skips; the archive path comes back as
`BackupPath`) and the delete + import steps are journaled under `out/runs/<runId>`
with a `reimport` (or `delete`, for a new dashboard) compensation, so
`recover_run.ps1 -RunId <id> -Rollback -Apply` undoes the recompose. `-Env <profile>`
targets a named environment (a `prod*` profile additionally needs
`$env:JRS_ALLOW_PROD_WRITE = '1'`, G65); `-EnsureControls` creates the manifest's
`controls` first (see below). The script returns a result object on the pipeline:
```powershell
& $skill\compose_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Replace -Env stage          # plan only
$r = & $skill\compose_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Replace -Apply -Env stage
$r   # Uri, Code, Replaced, BackupPath, Dashlets, ModelResources, ViewUrl, RunId
```
If the import is blocked by `403 resource.in.use` (a tile still owned by a live
dashboard, e.g. after `-KeepExisting`) or by `import.decode.failed` (an archive
exported by a different server), the error names the fix.

## Declarative input controls -- `ensure_controls.ps1` and the manifest `controls` key
The per-suite control scripts (`New-FinanceControls`, `New-ChurnControls`, ...)
are generalised into one JSON-driven, idempotent script:
```powershell
& $skill\ensure_controls.ps1 -Spec fixtures\controls.example.json -Env prod -WhatIf   # plan only
& $skill\ensure_controls.ps1 -Spec report\pos_perf\trs_dashboard.json -Env prod        # manifest "controls" key
```
It GETs each `<folder>/<name>` first and creates only what is absent (the
`_lov` / `_query` / `_dt` sub-resource, then the `inputControl`). `-Update`
PUTs existing controls in place; a `403 resource.in.use` (the control is
attached to a report unit) is a warning that names the fix, never a silent
no-op. Spec shape (standalone file, or the `controls` key of a manifest):
```jsonc
{ "folder": "/reports/x/controls", "dataSourceUri": "/datasources/x",
  "controls": [
    { "name": "p_yyyymm", "label": "Month", "type": 3, "values": ["202401=202401", "..."] },
    { "name": "p_store",  "label": "Store", "kind": "query",
      "query": "SELECT DISTINCT storenumber FROM stores ORDER BY 1", "valueColumn": "storenumber" },
    { "name": "p_franchisee", "kind": "multiquery", "query": "SELECT id AS fv, name AS fl FROM f",
      "valueColumn": "fv", "labelColumn": "fl" },
    { "name": "p_asof", "type": 2, "dataType": "date" } ] }
```
Type codes: 1 bool, 2 single value, 3 single-select LOV, 4 single-select
query, 5 multi value, 6 multi-select LOV, 7 multi-select query. In a manifest
the folder defaults to `filterControlFolder` / `<folder>/controls` and the
datasource to the manifest `dataSourceUri`; a manifest whose `filters` strip
names controls should declare them here so a promotion can create them. A
per-dashlet `"controls": ["p_asof", "/full/uri"]` lists what to re-attach to
that report unit after a redeploy (`deploy_report.ps1 -Overwrite` drops
attachments); omit it and `promote.ps1` copies the source server's list.

## Promote dev→prod — `promote.ps1`
`promote.ps1 -Uri <uri> -ToServerUrl … -ToUser … -ToPassword …` exports from the
source (this skill's config by default, or `-From*`) and imports into the target
server in one step (a folder URI promotes a whole app). Named profiles:
`-FromEnv stage -ToEnv prod`.

**Manifest mode** replays the whole hand-run suite promotion (RUNBOOK "PROD
promotion" recipes: controls, teardown, 28 deploys, attach, recompose) from the
compose manifests, in dependency-safe order across every manifest given:
```powershell
& $skill\promote.ps1 -Manifest report\pos_perf\*_dashboard.json -FromEnv stage -ToEnv prod -EnsureControls          # plan (default; -WhatIf is the same)
& $skill\promote.ps1 -Manifest report\pos_perf\*_dashboard.json -FromEnv stage -ToEnv prod -EnsureControls -Apply   # human-run; needs JRS_ALLOW_PROD_WRITE=1
```
Phases: (1) tear down every target dashboard (`teardown_dashboard.ps1`; frees
the `resource.in.use` locks) -> (2) ensure folders -> (3) ensure input
controls (manifest `controls` spec, else copy the source's definition of each
`filters` control) -> (4) deploy each DISTINCT tile once: a local jrxml
(dashlet `jrxml`, manifest `outDir`, or beside the manifest) goes through
`deploy_report.ps1 -Overwrite`; otherwise export+import from the source (which
can fail with `import.decode.failed` across servers -- keep the jrxml local)
-> (5) re-attach each tile's controls -> (6) `compose_dashboard.ps1 -Replace`
per dashboard on the target. **Plan by default (1.3.0):** without `-Apply` the
script prints the full plan -- what exists on the target, the action per step,
and a byte comparison of each local jrxml against the target's (`identical`
tiles are skipped and only re-attached) -- and issues GETs only; plan mode is
enforced by the write guard in `_jrs_common.ps1` for every child script (G64).
`-Apply` runs the plan under a journaled run (`out/runs/<runId>`): every delete
and overwrite is backed up first (`-NoBackup` to skip), each mutating step
carries a `reimport`/`delete` compensation, and a failed step triggers an
automatic rollback (the failing step first, then every succeeded step newest
first; `-NoRollback` leaves it to `recover_run.ps1`). Exit codes follow jrsctl:
0 ok, 2 nothing mutated, 3 failed and rolled back, 4 rollback incomplete. A
succeeded run can still be undone later: `recover_run.ps1 -RunId <id> -Rollback
-Apply`. `-Manifest` accepts a file, a directory (every `*.json` with `dashlets`),
or a glob. Validated on STAGE 2026-09-28 (plan -> apply -> rollback -> verify_suite
PASS) and offline by `tests/harness.Tests.ps1` against the STAGE recording.

## Teardown — `teardown_dashboard.ps1`
`teardown_dashboard.ps1 -Uri <dash> [-IncludeReports] [-Apply] [-NoBackup]` deletes
the dashboard first (releasing the `resource.in.use` locks), then its report tiles +
`<report>_controls` folders; a report still used by another dashboard is skipped,
not half-deleted. **Plans by default** (`-DryRun` is the same); `-Apply` exports
every resource to `out/backups` before deleting it and journals the run, so
`recover_run.ps1 -RunId <id> -Rollback -Apply` re-imports them (proven on STAGE
2026-09-28: dashboard + 2 tiles deleted, 3/3 compensated, verify_suite PASS).

## View a dashboard
Use the HTML5 viewer (NOT a `flow.html` flow — there is no `dashboardRuntimeFlow`;
that errors "No flow definition found"). The resource URI goes in the
**URL-encoded hash fragment**:
`http://localhost:8081/jasperserver-pro/dashboard/viewer.html#%2Freports%2Fgeocoder%2Fsales_dashboard`

## Scope summary
A dashboard of **report dashlets** is fully scripted (`build_dashlets.ps1
-Compose`). Export/import additionally promotes/versions *any* dashboard across
servers. **Ad hoc views** and **Domains** have their own scripted lifecycle (see
data-and-semantic-layer.md): single-table Domains are scaffolded + created
outright, and ad hoc views are listed/inspected/exported/imported. The remaining
manual step is authoring dashboards whose tiles are **filter groups / input
controls** drawn in the designer. Everything else — reports, their embedded
charts, report-tile dashboards, style templates, datasources, domains, and
themes — is scripted.
