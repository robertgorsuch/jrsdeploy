# JRS 10 dashboard model (reverse-engineered)

A JasperReports Server dashboard (`resourceType=dashboard`) is a small,
deterministic model: a descriptor `.xml` plus three companion files in its
`_files` folder. `gen_dashboard.py` synthesizes all four from a manifest;
`compose_dashboard.ps1` wraps them in an importable archive. This file documents
the shapes so the generator isn't the only source of truth.

## Why import, not PUT
PUTting a hand-built model to `/rest_v2/resources` stores it (201) but the JRS 10
client renders it **blank** — the designer/import broker does extra work on save
that a raw PUT skips. The **import** service reproduces that work, so a
synthesized archive that matches a designer export renders correctly. Always go
through `compose_dashboard.ps1` (export real dashlets → inject → import), never a
direct PUT. Re-zip with **forward-slash** entries — the Java importer silently
ignores back-slash paths.

## Descriptor (`<name>.xml`)
`<dashboardModelResource>` with `<folder>`, `<name>`, `<label>`, a `<foundation>`
naming the three companion resources (`layout`/`wiring`/`components`), a
`<resourceDescriptor type="reportUnit">` + `<resource><uri>` per **report** tile
(text/image tiles are NOT listed), and three `<localResource>` blocks for the
companion files (`wiring.data` json, `layout` html, `components.data`
dashboardComponent).

## components.data (JSON array)
Element 0 is the `dashboardProperties` singleton (canvas color, margins, refresh,
title bar). Then one object per dashlet. The **component id** = `re.sub(r'[^0-9A-Za-z]','_', label)` (must be unique); `layout` and `wiring` reference it.

- **report tile** — `{"type":"reportUnit","id","name","label","resource":"<uri>","dataSourceUri":"<uri>","scaleToFit":"width","showTitleBar":true, ...}`
- **text tile** — `{"type":"text","id","name","label":"Text","text","alignment","bold","italic","underline","font","size","color":"rgba(..)","backgroundColor","verticalAlignment","scaleToFit":"height","showDashletBorders","parameters":[],"toolbar":null}`
- **image tile** — `{"type":"image","id","name","label":"Image","url":"repo:/path or http://..","scaleToFit":"container","showTitleBar":false,"showDashletBorders","dashletHyperlinkTarget","parameters":[],"outputParameters":[]}`

## layout (HTML)
One `<div>` per component on a **40-wide** grid:
`<div data-componentId='ID' data-x='..' data-y='..' data-width='..' data-height='..'></div>`.

## wiring.data (JSON array)
Two base events broadcast from the properties singleton to every tile:
`@init`→each `ID:@refresh`, and `@applyParams`→each `ID:@applyParams`. Extra
producer→consumer events (cross-dashlet filtering) can be appended — the manifest
`"wiring":[{"producer":"A:out","consumers":["B:param"]}]` passes them through.

## Recompose ALWAYS deletes the dashboard first
`compose_dashboard.ps1` imports with `update=true`, which **does NOT overwrite an
existing dashboard's companion files** (`layout`/`components`/`wiring`). So a
recompose over an existing dashboard silently keeps the OLD layout. The script now
**deletes the dashboard before importing by default** (pass `-KeepExisting` to
skip). Deleting it also releases the `resource.in.use` locks on the dashlet
reports. If you ever import by hand, DELETE the dashboard first.

## Designer hand-edits vs the manifest — keep them in sync
Rearranging a dashboard in the JRS designer changes the live `layout` and
`components` (positions, sizes, scale-to-fit, title bars, toolbar buttons,
filter-strip docking), but the compose **manifest** is unaware -- a later
recompose would revert the hand edits. After any designer edit, sync the
manifest from the live dashboard:
```powershell
& scripts\sync_manifest_from_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Env stage -WhatIf  # diff only
& scripts\sync_manifest_from_dashboard.ps1 -Manifest report\pos_perf\trs_dashboard.json -Env stage          # update in place
& scripts\sync_manifest_from_dashboard.ps1 -Uri /reports/<folder>/<name> -Out report\<new>.json              # fresh manifest
```
`-Manifest` updates the file **in place**: every other key (queries, `outDir`,
`controls`, per-tile build settings) and the key order survive, tiles are
matched by `resource` (or kind+name), and a unified diff is printed. Synced
keys, mirroring exactly what `gen_dashboard.py` writes:
- dashboard: `autoRefresh`, `showExportButton`, `showPrintButton`, `canvasColor`,
  `dashletFilterShowPopup`, `filters[]`, `filterControlFolder`, `filterOwner`,
  `filterButtonsPosition`, `filterFloating` (docked = `false`), `filterStripHeight`
- report tile: `x/y/width/height`, `scaleToFit`, `showTitleBar` (tile `y` is
  stored WITHOUT the filter-strip offset that the generator adds back)
- text tile: `text`, `size`, `align`, `bold`, `italic`, `color`, `background`, `valign`
- image tile: `url`, `scaleToFit`

The round trip is a fixed point: `gen -> export -> sync -> gen` reproduces the
same `layout` / `components.data` / `wiring.data` (`tests\sync_manifest.Tests.ps1`).
Then a `compose_dashboard.ps1 -Replace` is safe.

## Manifest `controls` key and promotion
A manifest may declare the input controls its tiles/filter strip need
(`"controls": {folder, dataSourceUri, controls:[{name,label,type|kind,values|
query+valueColumn,dataType}]}` or a bare array); `ensure_controls.ps1`,
`compose_dashboard.ps1 -EnsureControls` and `promote.ps1 -Manifest
-EnsureControls` create them idempotently (GET first). A per-dashlet
`"controls": [...]` names what to re-attach to that report unit after a
redeploy. Full field list: `references/manifest.schema.json`; workflow:
`references/dashboards.md`.

## Tile sizing rule (avoid scrollbars / whitespace)
Tiles render the report scaled **to the tile width** (`scaleToFit:width`), so the
report's page aspect drives the fit:
- A tile scrolls when the report is **taller** than the tile: ensure
  `tile_height/tile_width  ≥  page_height/page_width`.
- Dashlet **padding** (~5px each side) shrinks the usable tile, so a tile sized to
  the EXACT page aspect still scrolls a little — make the **report page ~5–10%
  shorter** than the exact match (this is why the timestamp tile is 600×72, not 96).
- Trim the report page to its content so the tile shows no empty band. Wide-short
  reports (tables, bar/line, KPI strips) suit short bands; near-square (dials) or
  portrait (maps) need taller tiles.
- Every tile: `showTitleBar:false` (now honored per-dashlet by `gen_dashboard.py`).

## Ready-made tile recipes
- **Live "last refreshed" timestamp** — a tiny report (not a text tile, which is
  static): `SELECT now()::timestamp AS refreshed`, one `textField`
  (`evaluationTime="Report"`) formatting it + a version string. Re-runs each load →
  dynamic. Page ~600×72 for a `~12×2` tile.
- **KPI number strip (N-up)** — one report, query returns one row of N aggregates;
  N cells each = a label `staticText` + a big `textField` (pattern `$#,##0` /
  `#,##0`, `evaluationTime="Report"`), with thin `<line>` dividers. Page very
  wide-short (e.g. 1600×130 for a full-width `40×4`–`40×7` row).
- **KPI dial** — `scaffold_kpi_dial.py` (JFreeChart meter; see
  `references/fusion-pro-gotchas.md`).
- **Top-N table tile** — scaffold a table, add a `#` rank column via
  `$V{REPORT_COUNT}`, currency pattern on money cols, drop the page footer, and
  trim to a wide-short page (e.g. 800×214).

## What is NOT synthesizable (designer-only)
- **Ad hoc/OLAP-backed filter groups** -- the manifest `filters` key synthesizes
  a docked filterGroup + one inputControl component per control for REPORT
  tiles (`ownerResourceId` = the owning report); filter UIs over ad hoc views
  still depend on designer-generated temp resources (`tmpAdv_*_files`).
- **Ad hoc views** (`adhocDataView`) — a large opaque `<unifiedState>` (chart
  state, filters, columns) on top of a **Domain** semantic layer (`schema.xml`)
  and an auto-generated topic jrxml. Author in the Ad Hoc Designer; promote with
  `export_resource.ps1` / `import_resource.ps1` / `promote.ps1`.
