# jasper-deploy 1.3.0: safety model ported from jrsctl

Date: 2026-09-28. Scope: items 4, 5, 7 and 8 of the jrsctl comparison. Validated on
STAGE only; PROD is never contacted by this work.

## Goal

Make the 2026-08-28 incident class (a dry run that wrote to PROD) structurally
impossible in the plugin scripts, using the model jrsctl proved: plan by default,
a positive write gate, a write guard below the scripts, a run journal with
compensations, and a recorded-server test that proves the plan path issues no
writes.

## 1. Positive write gate (item 4)

`promote.ps1`, `compose_dashboard.ps1`, `teardown_dashboard.ps1` and
`deploy_report.ps1 -Overwrite` plan by default and write only with `-Apply`.
`-WhatIf` and `-DryRun` stay accepted (they mean "plan", the default) and
`-Apply` together with either of them is an error. A clobbered `-Apply` switch
defaults to `$false`, which is plan mode: the failure direction is now safe.

Callers that need writes pass `-Apply` through: `build_dashlets.ps1 -Compose`,
`reconcile.ps1 -Apply`, `smoke_test.ps1`, `scripts/pos_perf/restore_prod_pos.ps1
-Apply`, and the wizard servlet.

## 2. Write guard in the HTTP helpers (item 5)

`_jrs_common.ps1` gains `Assert-JrsWriteAllowed`, called by `Invoke-JrsPut`,
`Invoke-JrsDelete` and `Invoke-JrsRest` for every method other than GET, except
the read-like POST endpoints `/rest_v2/export`, `/rest_v2/reportExecutions`,
`/rest_v2/contexts` and `/rest_v2/reports/`. It refuses when:

1. plan mode is active (`$Global:JrsPlanMode -eq $true`): "PLAN MODE: refused
   PUT <url>; pass -Apply to write". Scripts enter plan mode through
   `Enter-JrsPlanMode -Apply:$Apply`, which never downgrades a plan-mode parent
   to apply, and restore the previous mode in `finally`.
2. the target is PROD and `$env:JRS_ALLOW_PROD_WRITE` is not `1`. A target is
   PROD when its profile name starts with `prod` or its URL equals the URL of a
   profile whose name starts with `prod` (so an explicit `-ToServerUrl` triple
   is covered). `Resolve-JrsConfig` computes this as `IsProd`.

Direct curl mutations move behind the helpers: the dashboard DELETE in
`compose_dashboard.ps1` and the import POST in `import_resource.ps1`
(`Invoke-JrsRest -FormFile`). Export POSTs stay direct: they create nothing.

## 3. Run journal and rollback (item 7)

`_jrs_run.ps1` (no param block; dot-sourced by `_jrs_common.ps1`) writes one
directory per run under `<skill>/out/runs/<runId>` (`$env:JRS_RUNS_DIR`
overrides): `run.json` (id, operation, target url and env, mode, status, plan,
started/ended) and `transitions.jsonl` (one line per step transition:
PLANNED, RUNNING, SUCCEEDED, FAILED, SKIPPED, COMPENSATED, COMPENSATE_FAILED,
plus the step's compensation record). Run ids are `r-yyyyMMdd-HHmmss-xxxx`.
A script that starts a run while `$Global:JrsCurrentRun` is set joins the
parent run instead of opening its own, so a promote's child scripts journal
into the promote's run.

Compensation records are data, replayed by `recover_run.ps1`:

- `reimport` `{ zip }`: re-import a backup archive with update=true (restores a
  deleted dashboard or an overwritten report unit and its controls).
- `delete` `{ uri }`: remove a resource the run created from nothing.

Backups are taken before every delete or overwrite in apply mode, by default
(`-NoBackup` skips and records the step as irreversible). This closes the gap
where promote's teardown deleted dashboards with no backup.

`promote.ps1 -Apply` compensates automatically when a step fails: the failing
step first, then every succeeded mutating step in reverse (`-NoRollback`
disables). Exit codes follow jrsctl: 0 ok, 2 precheck failed and nothing
mutated, 3 failed and rolled back, 4 rollback incomplete.

`recover_run.ps1 -List | -RunId <id|latest> [-Rollback] [-Apply]` shows a run,
prints the rollback plan, and with `-Rollback -Apply` replays the
compensations in reverse and records the outcome. It resolves the target from
the run record, so the PROD guard still applies.

## 4. Recorded-server harness (item 8)

`tests/mock_jrs.py` is a small HTTP server that replays a recording
(`tests/recordings/<version>-<edition>/mappings.json`, `recording.json` for
provenance) and appends every request as a JSON line to a log file. Unmatched
GETs answer a JRS-style 404. Writes are accepted (200 or 201, import and export
state machines answer `finished`) so apply-mode runs can be exercised too.

`scripts/record_server.ps1 -Manifest ... -Env stage -Out <dir>` records the
sanitised GET exchanges a promote plan needs (serverInfo, folders, dashboards,
tiles with `?expanded=true`, controls). Bodies are stored as returned; no
credentials appear in GET bodies and `creationDate`/`updateDate` are dropped.

`tests/harness.Tests.ps1` starts the mock, runs `promote.ps1 -Manifest` in a
separate PowerShell process against it (source and target are the same mock
under two host spellings) and asserts:

- plan mode: zero PUT, POST or DELETE in the request log, exit 0;
- apply mode: writes occur, the run journal exists, every mutating step has a
  compensation, exit 0;
- a `prod` target without `JRS_ALLOW_PROD_WRITE` is refused before any request.

## STAGE validation

1. Pester suite green, including the new harness tests.
2. A two-tile harness suite under `/reports/_smoke/harness` on STAGE: deploy,
   compose with `-Apply`, record it, tear it down with `-Apply` (backup taken),
   roll the run back with `recover_run.ps1`, verify with `verify_suite.ps1`.
3. `promote.ps1 -Manifest` from STAGE (as `127.0.0.1`) to STAGE (`localhost`)
   in plan mode and then apply mode, then a rollback of that run.
