# Deploy options, input controls, scheduling, admin

Deep reference for `deploy_report.ps1` options, input controls, jobs/alerts, and
the admin services (permissions, attributes, users/roles/orgs, async run, options,
cache). `$skill` = the skill's `scripts/` dir; credentials resolve as in SKILL.md.

## Deploy — `deploy_report.ps1` (full options)
Wraps the jrxml in a reportUnit descriptor (jrxml inlined as base64) and PUTs it
to `/rest_v2/resources`, creating intermediate folders. JRS compiles the jrxml
server-side on first run.
```powershell
& $skill\deploy_report.ps1 `
    -Jrxml report\county_summary.jrxml `
    -TargetUri /reports/geocoder/county_summary `
    -Label "County Edge Summary" `
    -DataSourceUri /datasources/postgis_34_sample
```
Verified working: a live deploy returns `201 Created` and the report unit is
retrievable at its URI. The `-DataSourceUri` must already exist (see
data-and-semantic-layer.md). Re-deploying an existing report without `-Overwrite`
fails `409 versions not match` (optimistic locking).

Also:
- **`-Overwrite`** passes `?overwrite=true`. Observed on 10.0.0 this is NOT an
  in-place update: the unit is re-created (version 0, new creationDate) and its
  `inputControls` are dropped unless the body carries them (`deploy_report.ps1`
  now carries the live list over). It is still refused with `403 resource.in.use`
  while a dashboard references the report -- recompose with `-Replace` first
  (G21, G61).
- **SQL lint** (on by default): blocks a query that begins with `WITH`/non-`SELECT`
  before deploying (the JRS security validator rejects it at fill time anyway).
  `-SkipSqlLint` overrides.
- **`-ResourceFiles "name=path"`** — embed companion resources (resource bundles,
  images) in the report unit.

### Static input controls — `-Control "param:kind[:label[:extra]]"` (repeatable)
Attaches a JRS input control to the matching `$P{param}`, so the report prompts.
`kind` = `select`/`multiselect` (extra = `Food;Drink;…`, or `Label=value;…`) or
`single` (extra = `text|number|date|datetime`). Controls are created as standalone
repository resources under `<report>_controls/` and referenced (the verified
pattern — embedding controls in the report unit is rejected). Verify with
`GET /rest_v2/reports/{uri}/inputControls`.

### Query-backed controls — `-QueryControl` / `-QueryMultiControl` (`string[]`)
Controls whose option list comes from SQL. Format `"param|valueCol|visibleCols|SQL"`
(`|`-delimited; SQL is last so it may contain `|`; `visibleCols` comma-separated,
defaults to `valueCol`). Each gets a companion `query` resource on the report's
datasource (so `-DataSourceUri` is required). **Cascading:** reference a parent
control as `$P{parent}` in a child's SQL and pass the parent earlier in the array
— the child's options then filter by the parent's selection. (single = inputControl
type 4, multi = type 7.) **Verified end-to-end:** a Product_Family →
Product_Department cascade returns 16 / 4 / 6 departments for Food / Drink /
Non-Consumable via
`GET /rest_v2/reports/{uri}/inputControls/{child}/values?{parent}=…`. PowerShell
arrays take comma-separated values (`-QueryControl $a,$b`), not a repeated flag.

## Browse / delete deployed resources
```powershell
# list a folder's contents (drop &type= to see all resource kinds)
curl.exe -s -u "${user}:${pass}" "http://localhost:8081/jasperserver-pro/rest_v2/resources?folderUri=/reports/geocoder&recursive=true&type=reportUnit"
# delete one resource (204 No Content on success); the repo URI is appended after /rest_v2/resources
curl.exe -s -u "${user}:${pass}" -X DELETE "http://localhost:8081/jasperserver-pro/rest_v2/resources/reports/geocoder/county_summary"
```
Deleting a folder is recursive (removes the report units inside it). To redeploy
in bulk, loop `deploy_report.ps1 -Overwrite` over the `report\*.jrxml` files.

## Schedule a job — `schedule_job.ps1`
Recurring / triggered / one-off report delivery to the repository and/or by email
(thin wrapper over the `jobs` REST service; resolves creds like `deploy_report.ps1`
and passes its JSON body from a file). **Verified end-to-end** (create→list→get→
delete round-trips, wired into `smoke_test.ps1`).
```powershell
# one-off PDF saved to the repo at a future date
& $skill\schedule_job.ps1 -ReportUri /reports/geocoder/county_summary `
    -Label "County summary" -StartDate "2026-12-01 09:00:00"
# every day forever, two formats, emailed
& $skill\schedule_job.ps1 -ReportUri /reports/geocoder/county_summary `
    -StartType now -OccurrenceCount -1 -RecurrenceInterval 1 -RecurrenceIntervalUnit DAY `
    -OutputFormats PDF,XLSX -MailTo ops@example.com
& $skill\schedule_job.ps1 -Action list -ReportUri /reports/geocoder/county_summary  # list/get/delete (-Id N)
```
`-StartType` `now|at` (default `at` if `-StartDate` given). For a recurring job set
`-OccurrenceCount -1` plus `-RecurrenceInterval`/`-RecurrenceIntervalUnit`
(`MINUTE|HOUR|DAY|WEEK`). `-Parameters @{p="v"}` bakes in report params.

## Data alert — `manage_alert.ps1`
Fire a notification when a watched numeric report element crosses a threshold:
```powershell
& $skill\manage_alert.ps1 -ReportUri /reports/geocoder/county_summary `
    -Label "Edge count high" -ElementUuid <element-uuid> -Operator ">" `
    -Threshold 500000 -MailTo ops@example.com
& $skill\manage_alert.ps1 -Action list -ReportUri /reports/geocoder/county_summary  # list/get/delete (-Id N)
```
`-ElementUuid` is the design `uuid` of the JR7 `<element>` to watch (the alerts UI
captures it by click; via REST you supply it — creation only validates the
descriptor shape, not element existence, so it's resolved at fire time).
`-Operator` accepts the JRS enums (`equals|notEqual|less|lessOrEqual|greater|
greaterOrEqual`) or the symbols `== != < <= > >=`. Firing drives the
evaluate→notify pipeline to the SMTP send; actual delivery needs a reachable mail
host configured server-side (see the alerts section of `references/jrs-rest-api.md`).
**Two shape gotchas the script handles** (both surfaced as `400` otherwise): the
alert's `mailNotification.toAddresses` is a wrapper object `{address:[…]}`, **not**
a bare array (unlike jobs); and `baseOutputFilename` is required even for an
email-only alert.

## Async report run — `run_report_async.ps1`
Run a report through the `reportExecutions` service (submit → poll `…/status` until
`ready` → download `…/outputResource`). The proper path for large/slow fills that
time out on the synchronous `/reports/{uri}.{fmt}` endpoint. The final download
uses a direct `curl -o` so binary output is byte-intact. **Verified** (32 KB PDF
round-trip). (Raw curl recipe is in reports.md.)
```powershell
& $skill\run_report_async.ps1 -ReportUri /reports/foodmart/top_5_customers_revenue -OutFile out\rpt.pdf
& $skill\run_report_async.ps1 -ReportUri /reports/geocoder/county_summary_param `
    -Format xlsx -Parameters @{ minEdges = 50000 } -OutFile out\county.xlsx
```

## Saved report options — `manage_options.ps1`
Named saved sets of input-control values stored beside a report
(`/rest_v2/reports{uri}/options`). **Verified** create→list→run→delete on
`county_summary_param`/`minEdges` (the 50k option ran to the 17-county filtered
PDF). **Gotcha:** to *run* with the saved values, run the option's OWN sibling URI
as a report (`GET /reports/<folder>/<id>.pdf`) — a `?reportOptions=<id>` query on
the report URL does **not** apply them.
```powershell
$rpt = "/reports/foodmart/sample_report"
& $skill\manage_options.ps1 -Action create -ReportUri $rpt -Label Food_Snacks -Values @{ category="Food"; department=@("Snacks","Dairy") }
& $skill\manage_options.ps1 -Action list   -ReportUri $rpt
& $skill\manage_options.ps1 -Action run    -ReportUri $rpt -Id Food_Snacks -OutFile out\opt.pdf
& $skill\manage_options.ps1 -Action delete -ReportUri $rpt -Id Food_Snacks
```

## Clear a server cache — `manage_cache.ps1`
`DELETE /rest_v2/caches/{id}` (invalidate the Ad Hoc / query result cache after the
data changes). The service is DELETE-only — there is no list-all GET. **Verified:**
`queryCache` → `204`.
```powershell
& $skill\manage_cache.ps1 -CacheId queryCache
```

## Permissions — `manage_permissions.ps1`
Get/set/clear repository ACLs via the `permissions` service:
```powershell
& $skill\manage_permissions.ps1 -Action get   -Uri /reports/geocoder -Effective
& $skill\manage_permissions.ps1 -Action set   -Uri /reports/geocoder -Recipient role:/ROLE_USER -Mask 30
& $skill\manage_permissions.ps1 -Action clear -Uri /reports/geocoder      # back to inherited (204)
```
`-Recipient`/`-Mask` are parallel arrays (one mask per recipient); `set` uses
`Content-Type: application/collection+json` (NOT `…collection.permission+json`,
which `415`s). Masks: 1=administer, 2=read+delete, 18=read+write, 30=read-only,
32=execute-only. **Verified:** set → confirm → clear round-trip.

## Attributes — `manage_attributes.ps1`
Get/set/delete a key-value attribute at server / org / user scope (usable in
datasource/report expressions as `{attribute('name')}`):
```powershell
& $skill\manage_attributes.ps1 -Scope server -Action set -Name dbHost -Value db.prod.internal
& $skill\manage_attributes.ps1 -Scope user   -UserName jdoe -Action set -Name region -Value west
& $skill\manage_attributes.ps1 -Scope server -Action delete -Name dbHost
```
**Verified:** server-scope set → get → delete round-trip. **Two gotchas the script
handles:** (1) a bare `PUT /attributes` REPLACES ALL ~134 system attributes, so the
server scope is **always `?name=`-scoped**; (2) PowerShell 5.1 treats `?` as a
variable-name char, so the path is built with `${base}` braces (else `"$base?name"`
silently drops the base and `405`s).

## Usage / access events — `report_usage.ps1`
Read-only "who ran what" reporting straight from the repository *metadata*
PostgreSQL (table `jiaccessevent`; access-event auditing is ON on this install).
No REST surface exists for these events, so the script queries via `psql`.
Connection resolves: params → `repoDb` in `jrs.config.json` → defaults
`localhost:5433/jasperserver/postgres`; password from `$env:PGPASSWORD`/.pgpass.
```powershell
$env:PGPASSWORD = "postgres"
& $skill\report_usage.ps1                                    # top resources, 30 days
& $skill\report_usage.ps1 -Action users -Days 7              # per-user activity
& $skill\report_usage.ps1 -Action top -Type ReportUnit -Days 0 -Limit 10
& $skill\report_usage.ps1 -Action recent -Limit 25           # latest raw events
& $skill\report_usage.ps1 -Action resource -Uri /reports/geocoder/county_summary
& $skill\report_usage.ps1 -Csv > usage.csv                   # machine-readable
```
Reads-only by default (`updating = false`); add `-IncludeUpdates` to count
writes/deploys too. `-Type` matches the stored Java class's simple name
(`ReportUnit`, `DashboardModelResource`, `AdhocDataView`, ...). **Verified:**
`top`/`users`/CSV against the live :5433 metadata DB.
**Gotcha (this install):** the live metadata DB is the JRS-**bundled** PostgreSQL
on **:5433**; a stale decoy `jasperserver` DB on :5432 has an EMPTY
`jiaccessevent`. 0-row results trigger a warning pointing at `repoDb`;
`doctor.ps1` checks the same thing.

## Diagnostic log collectors — `manage_diagnostic.ps1`
The supported way to capture server-side logs around a failing report without
trawling catalina.out: start a collector, reproduce, stop, download the bundle.
Full lifecycle **verified** (`/rest_v2/diagnostic/collectors`):
```powershell
$c = & $skill\manage_diagnostic.ps1 -Action start -Name repro_bug | ConvertFrom-Json
# ... reproduce the failure (optionally scope with -UserId / -ResourceUri) ...
& $skill\manage_diagnostic.ps1 -Action stop -Id $c.id          # -> SHUTTING_DOWN (async)
& $skill\manage_diagnostic.ps1 -Action download -Id $c.id -Out bug.zip
& $skill\manage_diagnostic.ps1 -Action delete -Id $c.id
```
**Sharp edges the script guards (gotchas.md G53/G54):** a bare collection
DELETE wipes ALL collectors (delete requires `-Id` unless `-All`); the zip's
`diagnostic.log.jsEncrypted` is encrypted with the server key (a support
bundle — only `collectorSettings.xml` is plaintext); collector names must be
unique among live collectors (duplicate → `400` validateName); and **verbosity
stays at the `LOW` default** — starting a `HIGH` collector breaks every
type-filtered repository search on JRS 10.0.0 until Tomcat restarts (G54; the
script warns if you insist on `-Verbosity HIGH`).

## Users, roles & organizations (admin)
Tenant/identity administration over the REST v2 `users`, `roles`, and
`organizations` services. All resolve credentials the same way as the other scripts
and pass JSON bodies from a file. **Verified end-to-end** (create→get→delete
round-trips for roles and users; org list + read).

**`manage_users.ps1`** — user CRUD + role assignment. `create`/`delete`/`get` hit
`/rest_v2/users/{username}` (or `/rest_v2/organizations/{org}/users/{username}` when
`-Organization` is given); `PUT` both creates and updates (idempotent on username).
**Gotcha:** the JRS auth password is `-JrsPassword` here, because `-Password` is the
*new user's* initial password.
```powershell
& $skill\manage_users.ps1 -Action list   -Organization organization_1
& $skill\manage_users.ps1 -Action create -UserName jdoe -FullName "Jane Doe" `
    -Password "Secret123!" -Roles ROLE_USER,ROLE_ADMINISTRATOR -Organization organization_1
& $skill\manage_users.ps1 -Action delete -UserName jdoe -Organization organization_1
```

**`manage_roles.ps1`** — role CRUD (`/rest_v2/roles/{name}`, `PUT` create/update).
Pass `-Organization` for a tenant-scoped role.
```powershell
& $skill\manage_roles.ps1 -Action list
& $skill\manage_roles.ps1 -Action create -Name ROLE_ANALYST -Organization organization_1
& $skill\manage_roles.ps1 -Action delete -Name ROLE_ANALYST -Organization organization_1
```

**`manage_organizations.ps1`** — organization (tenant) CRUD. **Gotcha:** create is
**POST on the collection** (`/rest_v2/organizations?createDefaultUsers=true`, WADL
id `putOrganization`), not a `PUT {id}`; `update` is a read-modify-write `PUT {id}`
(so e.g. setting `-Theme` doesn't blank other fields) — the same `{"theme":…}`
activation `deploy_theme.ps1 -Activate` performs.
```powershell
& $skill\manage_organizations.ps1 -Action list
& $skill\manage_organizations.ps1 -Action create -Id acme -TenantName "ACME Inc"
& $skill\manage_organizations.ps1 -Action update -Id organization_1 -Theme corporate
& $skill\manage_organizations.ps1 -Action delete -Id acme
```

## Web wizard (self-service UI over these scripts)
`webapp/jasper-wizard/` (in the repo, **not** under this skill dir) is a Jakarta
servlet WAR giving business users a browser UI for the whole lifecycle — reports
(SQL→chart/table with live query preview + interactive input controls), dashboards,
data sources, domains, themes, run & export (multi-format + async), scheduling,
repository browse, ad hoc view list/export, permissions, and a Server Summary
overview. Runs inside the JRS Tomcat at `http://localhost:8081/jasper-wizard/`.

**It consumes these scripts** — so if you change a script's parameters or stdout
shape, the wizard's matching handler may need updating. The split:
- **reads / preview / run** are proxied straight to JRS REST by `JrsClient`
  (auth added server-side: no browser creds, no CORS);
- **create / deploy** shell out to the verified scripts via `ScriptRunner`
  (`scaffold_jrxml.py`, `deploy_report.ps1`, `create_datasource.ps1`,
  `compose_dashboard.ps1`, `scaffold_domain_schema.py`+`create_domain.ps1`,
  `scaffold_theme.py`+`deploy_theme.ps1`, `schedule_job.ps1`,
  `manage_permissions.ps1`, `manage_adhoc.ps1`, `export_resource.ps1`,
  `run_report_async.ps1`).

**Build & deploy:** `cd webapp\jasper-wizard; .\build.ps1` (no Maven — compiles
against Tomcat 10.1's bundled Jakarta `servlet-api.jar` with JDK 11, bundles the
scripts into the WAR, hot-deploys to Tomcat). Key environment realities the build
already accounts for (see `webapp/jasper-wizard/README.md`):
- **Tomcat 10.1 = Jakarta Servlet** (`jakarta.servlet.*`, not `javax.*`).
- **Tomcat runs as `NT AUTHORITY\LocalService`**, which can't read the user
  profile/repo — so the scripts are **bundled inside the WAR** (`WEB-INF/scripts`)
  and the child processes run from the **container temp dir** (writable). This is
  why the wizard passes an absolute `-WorkDir` to `compose_dashboard.ps1`.
- **No local compile** of jrxml (drops the `jasperreports-lib` dependency); JRS
  compiles server-side on deploy and `deploy_report.ps1` lints the SQL first.
