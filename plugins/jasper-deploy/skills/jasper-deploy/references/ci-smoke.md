# Running smoke_test.ps1 as recurring regression CI

`scripts/smoke_test.ps1` is the skill's end-to-end regression test. Run it after
editing ANY script (it exercises the whole pipeline against the live
JasperReports Server and PostgreSQL on this machine). This note covers running it
on a schedule so regressions surface without a human remembering to run it.

## What it covers (19 asserted steps)
Per `SKILL.md`, the test scaffolds -> **lints** (`lint_jrxml.ps1`) -> compiles -> deploys (+ an input control) ->
verifies content -> runs to PDF -> schedules a job (CRUD) -> sets an alert (CRUD)
-> composes a dashboard (report + text tile) -> deploys a **style template** and
runs a report that references it -> creates a single-table **Domain** -> creates
a multi-table **Domain with a join** -> creates a non-JDBC (**jndi**) datasource
-> deploys a UI **theme** -> creates an **AWS** datasource -> deploys a report
with **cascading query input controls** (asserts the child option count changes
per parent) -> sets + clears **permissions** -> server **attribute** CRUD ->
creates a **Mondrian** schema + connection -> scaffolds a **Visualize.js embed**
page (offline content check) -> creates a datasource with **`-Test`** (the
`/contexts` service opens the live connection first) -> fetches a report
**thumbnail** -> runs a **diagnostic collector** lifecycle (start/stop/download
zip/delete) -> tears down. It asserts each of the **24 steps** under a throwaway
`/reports/_smoke` folder (the theme lives under `/themes`), and cleans
everything up at the end. When the **jasper-wizard** WAR is deployed
next to JRS an extra `wizard-api` step also runs (GET `/jasper-wizard/api/health`,
`/api/summary`, `/api/datasources` must all return 200); on machines without the
wizard it is skipped, not failed.

## Prerequisites for a fresh clone
Before the test can pass on a freshly cloned machine, two things must already be
set up (the test does not create them):
1. `jrs.config.json` in the skill root -- copy `jrs.config.example.json` to
   `jrs.config.json` and fill in the password (`superuser`) and `jrLibDir`. It is
   gitignored. See `SKILL.md` (Credentials).
2. The two sample databases AND their JRS datasource bindings -- `foodmart`
   (`/public/Samples/Data_Sources/FoodmartDataSource`) and `postgis_34_sample`
   (`/datasources/postgis_34_sample`). See **`references/seed-data.md`** for load
   and verification steps.

The test also needs `$env:PGPASSWORD` set (the DB password, `postgres`) in the
environment it runs under, because the scaffolders shell out to `psql`.

## Manual run
```powershell
$env:PGPASSWORD = "postgres"
& .\plugins\jasper-deploy\skills\jasper-deploy\scripts\smoke_test.ps1
```

## Windows Task Scheduler (recurring local CI)
Register a daily task that sets `PGPASSWORD`, runs the smoke test, and writes a
**timestamped log artifact** so you can see when a regression first appeared. The
inner command sets the env var, cd's to the repo, and tees output to a per-run
log; the task's own exit code is the test's pass/fail.

```powershell
# set to your checkout location
$repo = "C:\path\to\your\checkout"
$logDir = "$repo\out\smoke-logs"
New-Item -ItemType Directory -Force $logDir | Out-Null

# the command Task Scheduler will run (PowerShell -Command); %DATE/TIME via PS at run time
$inner = '$ts = Get-Date -Format yyyyMMdd_HHmmss; ' +
         '$env:PGPASSWORD = "postgres"; ' +
         "Set-Location '$repo'; " +
         "& '$repo\plugins\jasper-deploy\skills\jasper-deploy\scripts\smoke_test.ps1' " +
         "*>&1 | Tee-Object -FilePath '$logDir\smoke_'+\$ts+'.log'; " +
         'exit $LASTEXITCODE'

schtasks /Create /TN "jasper-deploy smoke" /SC DAILY /ST 06:30 /RL HIGHEST /F `
  /TR ("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"" + $inner + "\"")

# run it once on demand / inspect / remove:
schtasks /Run    /TN "jasper-deploy smoke"
schtasks /Query  /TN "jasper-deploy smoke" /V /FO LIST
schtasks /Delete /TN "jasper-deploy smoke" /F
```
Notes:
- `*>&1` redirects all PowerShell streams (incl. the harmless SLF4J-on-stderr)
  into the log so a non-zero stream does not abort under a strict caller.
- Each run writes `out\smoke-logs\smoke_<timestamp>.log`; keep or prune those as
  your artifact history.
- `/RL HIGHEST` is needed because parts of the pipeline (and any chart-customizer
  jar reinstall) may require elevation; the JRS service must be running.
- Store the DB password in the task command (above) or, more safely, as a
  machine env var the task inherits, rather than committing it.

## macOS / Linux (recurring local CI via cron)
On macOS/Linux run the same smoke test under `pwsh` from `cron` (or a `launchd`
agent). Add a crontab line (`crontab -e`) that sets the DB password, cd's to the
repo, and tees a timestamped log:
```sh
30 6 * * *  PGPASSWORD=postgres /usr/local/bin/pwsh -NoProfile \
  -File "$HOME/tx-geocoder/plugins/jasper-deploy/skills/jasper-deploy/scripts/smoke_test.ps1" \
  > "$HOME/tx-geocoder/out/smoke-logs/smoke_$(date +\%Y\%m\%d_\%H\%M\%S).log" 2>&1
```
(`brew install powershell` provides `pwsh`; use `which pwsh` for its path. The JRS
server and PostgreSQL must be running on this host.)

## Claude Code drivers (cloud + interval)
The same test can be driven by Claude Code's scheduling primitives instead of (or
in addition to) Task Scheduler:
- **`/schedule`** -- a cloud cron "routine" that runs on a schedule. Useful for a
  managed, off-machine cadence; the routine's prompt would set `$env:PGPASSWORD`
  and invoke `scripts/smoke_test.ps1`, then report pass/fail. (Cloud agents do not
  have this machine's localhost JRS/PostgreSQL, so use `/schedule` to remind/kick
  a run on this host, with the actual execution happening here.)
- **`/loop`** -- run the test (or a slash command wrapping it) on a recurring
  local interval during a session, e.g. poll after each change.

## verify_suite.ps1 -- read-only suite verification (STAGE / PROD, no browser)

`scripts/verify_suite.ps1` is the second CI-style check, complementary to the
smoke test: the smoke test proves the SKILL still works (it creates and tears
down its own throwaway resources), `verify_suite.ps1` proves a DEPLOYED SUITE
still matches its manifests. It never writes to the server (every call is a
GET), so it is safe to point at PROD and safe to run on a schedule.

It replaces the hand-written "verify the build on STAGE without a browser"
loops that RUNBOOK.md carried per phase. For every dashboard manifest
(`references/manifest.schema.json`; `report/pos_perf/*_dashboard.json` are the
real ones) it checks:

| check                | what it asserts                                                                 | flag        |
|----------------------|---------------------------------------------------------------------------------|-------------|
| `report_exists`      | every report dashlet's report unit answers HTTP 200 (`Test-JrsResource`)         | always      |
| `render`             | run each unit with default params to pdf/html; records HTTP code, bytes, pages   | `-Render`   |
| `jrxml_bytediff`     | deployed main jrxml == local git jrxml, byte for byte (SHA-256)                  | `-ByteDiff` |
| `dashboard_exists`   | the composed dashboard answers HTTP 200                                          | always      |
| `dashboard_controls` | `resources[].type == inputControl` count == manifest `filters` count (0 if none) | always      |
| `control_exists`     | each manifest filter exists under `filterControlFolder` (default `<folder>/controls`) | always |
| `local_jrxml`        | (`-Offline` only) the git jrxml for each dashlet can be found                    | `-Offline`  |

Each check is one object on the pipeline (`Manifest, Dashboard, Check, Target,
Status, Code, Bytes, Pages, Detail, LocalFile`), followed by a host summary
line; the exit code is 1 when anything FAILed. `-FailFast` stops at the first
FAIL, `-Out results.csv|json` also writes the table. Rendered files and server
jrxml copies land under `<skill>/out/verify/<env>/`.

The jrxml file resource is named after the unit's LABEL (`<uri>_files/<label>_main_jrxml`),
so the byte-diff reads its real URI from the report unit descriptor
(`jrxml.jrxmlFileReference.uri`) rather than guessing. A byte mismatch is a
FAIL even when the detail says "line endings / BOM only": the RUNBOOK
promotion precondition is exact bytes. A server copy that carries `uuid`
attributes is a JRS re-serialization -- redeploy from git.

```powershell
$jd = ".\plugins\jasper-deploy\skills\jasper-deploy\scripts"
# pre-flight, no server: manifests parse and every dashlet's git jrxml is found
& "$jd\verify_suite.ps1" -Manifest report\pos_perf -Offline
# STAGE: existence + controls + render + byte-diff, table to csv, exit 1 on any FAIL
& "$jd\verify_suite.ps1" -Manifest report\pos_perf -Env stage -Render -ByteDiff -Out out\verify_stage.csv
# PROD, one board, read-only
& "$jd\verify_suite.ps1" -Manifest report\pos_perf\trs_dashboard.json -Env prod
# work with the objects
$rows = & "$jd\verify_suite.ps1" -Manifest report\pos_perf -Env stage -ByteDiff
$rows | Where-Object Status -eq FAIL | Format-Table Dashboard, Check, Target, Detail
```
`-Env` uses the `environments` profiles in `jrs.config.json` exactly as
`promote.ps1 -FromEnv/-ToEnv` does; `-ServerUrl/-User/-Password` override it.
Local jrxml lookup order per dashlet: dashlet `jrxml` (relative to the
manifest), manifest `outDir/<leaf>.jrxml`, `<manifest dir>/<leaf>.jrxml`,
`report/<manifest name>/<leaf>.jrxml`.

To schedule it, reuse the Task Scheduler / cron recipes above with
`verify_suite.ps1 -Manifest report\pos_perf -Env stage -Render -ByteDiff`
in place of `smoke_test.ps1`; no `PGPASSWORD` is needed.

## Cross-references
- `references/seed-data.md` -- the sample DBs + bindings the test assumes.
- `SKILL.md` (Notes / gotchas -> "Smoke test") -- the authoritative step list.

## Run journal, rollback and the recorded-server harness (1.3.0)

Every `-Apply` run of `promote.ps1`, `compose_dashboard.ps1`,
`teardown_dashboard.ps1` or `deploy_report.ps1 -Overwrite` is journaled under
`out/runs/<runId>/` (`run.json` + `transitions.jsonl`; `$env:JRS_RUNS_DIR`
overrides). Each mutating step carries a compensation (`reimport {zip, uri}` or
`delete {uri}`); backups are taken by default before every delete/overwrite.

```powershell
& $skill\recover_run.ps1 -List                              # newest first: id, operation, status, target, exit
& $skill\recover_run.ps1 -RunId latest                      # plan, transitions, what can be rolled back
& $skill\recover_run.ps1 -RunId r-20260929-0010 -Rollback   # rollback plan only (GETs; nothing written)
& $skill\recover_run.ps1 -RunId r-20260929-0010 -Rollback -Apply   # replay newest-first; exit 3 = ROLLED_BACK, 4 = incomplete
```

The harness proves, offline, what the 2026-08-28 incident lacked: that a
plan-mode run issues no PUT/POST/DELETE.

```powershell
& $skill\record_server.ps1 -Manifest tests\fixtures\harness\harness_dashboard.json -Env stage   # read-only; -> tests/recordings/10.0.0-PRO
Invoke-Pester -Path tests\harness.Tests.ps1     # starts tests/mock_jrs.py on a free port, runs the real scripts in a child PowerShell
```

`tests/mock_jrs.py --port N --recording <dir> --log <file>` replays the
recording, logs every request as a JSON line, accepts writes (stateful: a
DELETE makes the next GET 404, an imported archive's `index.xml` URIs appear)
and answers the export/import state machines, so apply-mode runs and rollbacks
can be exercised end to end without a server. Re-record when a suite changes.
Unmatched GETs answer a JRS-style `resource.not.found`.
