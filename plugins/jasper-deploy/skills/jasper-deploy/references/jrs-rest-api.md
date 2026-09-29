# JasperReports Server 10.0.0 REST v2 — endpoint map (this install)

Distilled from the JRS 10.0.0 REST API Reference, scoped to the
report-design/deploy/run workflow this skill automates. Each entry is tagged:

- **[verified]** — exercised against this server (`localhost:8081/jasperserver-pro`,
  `superuser` with the password from `jrs.config.json`, HTTP Basic) and confirmed working.
- **[doc-only]** — present in the docs / WADL but not yet exercised here; the
  payload/flow below is from the reference, treat as a starting point.

**Source of truth for this exact install:** the live WADL —
`http://localhost:8081/jasperserver-pro/rest_v2/application.wadl?detail=true`
(it never version-drifts the way the external community docs do, and the docs
site 403s scripted fetches anyway).

**Authoritative offline docs (preferred over the community URL, which 403s
scripted fetches):** the full JRS 10.0.0 PDF set lives in `docs/` — machine-local
and **gitignored** (~62 MB, freely re-downloadable from Jaspersoft), like the
`jasperreports-lib` jars. `docs/` now also holds the complete **9.0.0** and
**10.1.0** PDF sets (same machine-local, gitignored arrangement);
`js-jrs_10.1.0_rest-api-reference.pdf` and `js-jrs_9.0.0_rest-api-reference.pdf`
are the sources for the "Version deltas" section at the end of this file.
The key one is
`docs/JasperReportsServerRESTAPIReferencev10.0.0.pdf` (344 pp) —
extract text with `pypdfium2` (`pdftoppm` isn't available, so the Read tool can't
rasterize it). Page map for the services below: resource descriptors p.44–63,
`resources` p.64, `permissions` p.99, `export` p.108 / `import` p.115,
`reports` p.131, `reportExecutions` p.137, `inputControls` p.161, `options`
p.188, `jobs` p.193, `alerts` p.235, `queryExecutor` p.294, `caches` p.298,
`organizations`/`users`/`roles` p.299–323, `attributes` p.325. Other relevant
guides in `docs/`: Visualize.js (embedding), Ultimate, User, Domains, Auth
Cookbook. Online mirror:
<https://community.jaspersoft.com/documentation/jasperreports-server/tibco-jasperreports-server-rest-api-reference/v1000/jasperreports-server-rest-api-reference-_-overview/>

All paths below are under `…/jasperserver-pro/rest_v2/`. Auth is HTTP Basic on
every call. On **Windows**, POST/PUT JSON bodies from a **file**
(`--data "@req.json"`) — an inline `-d '{...}'` gets its quotes stripped by the
PowerShell→curl boundary and the server answers `400 serialization.error`.

---

## resources — repository CRUD  **[verified]**
The backbone the skill scripts already use.
- `GET  /resources?folderUri=/reports/geocoder&recursive=true&type=reportUnit`
  — list. Use `type=jdbcDataSource` for datasources (the generic `type=dataSource`
  returns `204`/empty on this server).
- `PUT  /resources{uri}?createFolders=true` (`Content-Type:
  application/repository.reportUnit+json`) — create/replace. See `deploy_report.ps1`.
- `DELETE /resources{uri}` — `204` on success; recursive on a folder.
- `GET  /resources{uri}` — fetch a resource descriptor (e.g. to read a deployed
  report's `jrxmlFileReference`, then `GET` that file URI to recover the jrxml —
  this is how the `uspopulation_tibcomaps` sample was pulled back out).
- **Datasource descriptor types** (ref p.46–51) — `create_datasource.ps1` only
  emits `jdbcDataSource`, but the resources service also takes
  `jndiJdbcDataSource`, `awsDataSource`, `virtualDataSource` (Teiid join over
  several DSs), `beanDataSource`, and `customDataSource`, each with its own
  `application/repository.<type>+json` content type and fields. Use these for a
  non-PostgreSQL/JDBC backend; the JDBC path is the one verified here.

## reports — synchronous run  **[verified]**
- `GET /reports{uri}.{fmt}` — fill + export in one blocking call.
  Formats confirmed `200` here: **pdf, html, xlsx, csv, docx, pptx** (docs also
  list rtf, ods, odt, xml). Verify Office/OpenDocument output by `200` + size
  (magic is `PK`, not `%PDF-`).
- Pass report parameters / input-control values as query string:
  `…/PieChartReport.pdf?MaxOrderID=11077`.
- A `400` with an XML `errorDescriptor` body is a fill failure — read the
  `message`. Common causes here: a leading `WITH` CTE (server SQL validator —
  see SKILL.md gotchas), or an external resource the server can't reach (the
  TibcoMaps sample 400s on `maps.google.com`).

## reportExecutions — asynchronous run  **[verified]**
Proper path for large/slow fills that can time out on the synchronous endpoint.
1. `POST /reportExecutions` body `{"reportUnitUri":"…","outputFormat":"pdf",
   "interactive":false,"async":true}` → `{requestId, exports:[{id,status}]}`.
2. `GET /reportExecutions/{requestId}/status` → `{"value":"ready"}` when done
   (`queued`/`execution` while running).
3. `GET /reportExecutions/{requestId}/exports/{exportId}/outputResource` →
   the bytes. `exportId` is `exports[0].id` from step 1 (or re-`GET
   /reportExecutions/{requestId}`).
- Add more formats to one execution: `POST /reportExecutions/{requestId}/exports`.
- **More capabilities (doc-only, ref p.137–160):** export an already-run
  execution asynchronously, `POST /reportExecutions/{id}/parameters` to re-fill
  with changed input-control values, `…/{id}/exports/{exportId}/outputResource`
  + `…/attachments/…`, page status (`…/{id}/status?page=N`), bookmarks
  (`…/{id}/exports/{exportId}/bookmarks`), and raw parameter values.

## options — saved input-control value sets  **[verified]** (create→list→update→delete)
Report options are named sets of input-control values saved beside a report
(ref p.188); pair with the `inputControls` service. Verified on
`county_summary_param` (the `minEdges` control):
- `POST /reports{uri}/options?label=NAME` body `{"<controlId>":["<value>"], …}`
  (full literal URL — the inline `?label=` triggers the curl `000` quirk) →
  `200` `{uri,id,label}`; the option lands as a sibling resource
  (`/reports/geocoder/<NAME>`).
- `GET  /reports{uri}/options` → `{reportOptionsSummary:[{uri,id,label}]}`
  (`"No options found …"` when none).
- `PUT  /reports{uri}/options/{id}` body `{"<controlId>":[…]}` — update values.
- `DELETE /reports{uri}/options/{id}` — remove.
- **Run with the option applied — run the option's OWN sibling URI** as if it were
  a report: `GET /reports/<folder>/<optionId>.pdf`. **Verified:** running
  `…/reports/geocoder/MinEdges50k.pdf` produced the 17-county output (subtitle
  "…at least 50000 edges", 2.4 KB) vs. the 254-county default (13.8 KB). NOTE: a
  `?reportOptions=<id>` query param on the *report's* URL did **not** apply the
  saved values here (still got the default) — use the option resource URI.

## queryExecutor — run a Domain query for raw data  **[verified, Domain-only]**
Returns query results without building a report — **but the only resource it
supports is a Domain** (ref p.294), so it's outside this skill's JDBC-report
scope (Domains are web-UI/semantic-layer authored). Verified the service
executes and returns the documented shape: `POST /queryExecutor{domainUri}`
(`Content-Type: application/xml`) with a `<query><queryFields><queryField
id="JoinTree.table.col"/>…</queryFields><queryFilterString>…</queryFilterString></query>`
→ `200` `{"names":[…],"values":[[…],…]}` (rows as bare value arrays). Field ids
come from the Domain schema via the **metadata** service:
`GET /domains{domainUri}/metadata` → `rootLevel.items[].properties.resourceId`.
A populated result needs a Domain whose backing datasource is live — the audit
domains were empty here and the sample foodmart Domain `400`s ("Review the Domain
settings", its DB isn't connected on this box).

## contexts — live datasource connection test  **[verified]** (no resource created)
The gap-closer for "descriptor stored but will not connect" (G29): POST a
datasource descriptor to `/contexts` and the server OPENS the connection.
- `POST /contexts` with `Content-Type: application/repository.jdbcDataSource+json`
  (or `…jndiJdbcDataSource+json` / `…customDataSource+json` — the generic
  `application/connections.jdbc+json` guess **415s**, G52), body = the ordinary
  descriptor (label/driverClass/connectionUrl/username/password).
- `201` = connected (body echoes the descriptor, password stripped);
  `400 connection.failed` = real driver error in `parameters[]` + a
  `sql.exception` detail (verified: bad password → `FATAL: password
  authentication failed`, SQL state 28P01). Nothing is stored either way.
- Wrapped by `Invoke-JrsConnectionTest` (`_jrs_common.ps1`),
  `create_datasource.ps1 -Test`, and doctor's "JRS->DB connection" check.

## thumbnails — report preview images  **[verified]**
- `GET /thumbnails{reportUri}?defaultAllowed=true|false` → `200` + image bytes
  (**JPEG** on this install, not PNG) from the report's last **UI** execution;
  REST-only runs do not refresh it. `defaultAllowed=true` substitutes the
  generic placeholder; with `false` a never-UI-run report → `204`.
- Send **no `Accept: image/*` header** — an explicit image ask `406`s; the
  unadorned GET returns the bytes. Batch form: `POST /thumbnails` with
  form-encoded `uri=` params. Wrapped by `get_thumbnail.ps1`.

## settings — read-only server configuration  **[verified]**
- `GET /settings/{group}` → `200` JSON. Groups verified live: `request`,
  `dataSourcePatterns`, `userTimeZones`, `awsSettings`, `decimalFormatSymbols`,
  `dateTimeSettings`, `globalConfiguration`, `inputControls` (unknown group →
  `404`). `globalConfiguration` carries ~47 keys (maxFileSize, defaultRole,
  passwordMask, …). Anonymous-relevant groups need no auth in the UI path, but
  authenticated GET works for all.
- NOTE: the Visualize.js cross-origin gate is **not** here — `domainWhitelist`
  is a server ATTRIBUTE (`GET /attributes?name=domainWhitelist`; bean chain
  `JSCorsConfiguration` → `DomainWhitelistProviderImpl`). Doctor's
  "server settings (REST)" check reports both.

## diagnostic — log collectors (support bundles)  **[verified]** (start→stop→download→delete)
- `POST /diagnostic/collectors` `{"name":"x","verbosity":"LOW|MEDIUM|HIGH"}` →
  `200` `{id, status:RUNNING}`; optional `filterBy` `{userId, sessionId,
  resourceAndSnapshotFilter:{resourceUri}}`. Names must be unique (dup →
  `400` validateName, G53). **Use `LOW`: starting a `HIGH` collector breaks
  every type-filtered repository search (`ClassCastException`, healed only by
  a Tomcat restart) on JRS 10.0.0 — bisected live, G54.**
- `PUT /diagnostic/collectors/{id}` with `status:"STOPPED"` → `200`
  `SHUTTING_DOWN` (finishes async; wait a beat before download).
- `GET /diagnostic/collectors/{id}/content` (`Accept: application/zip`) → zip of
  `collectorSettings.xml` + `diagnostic.log.jsEncrypted` (encrypted with the
  server key — a support bundle, not casual reading).
- `GET /diagnostic/collectors` (list; `204` when none);
  `DELETE /diagnostic/collectors/{id}` — **a bare collection DELETE removes ALL
  collectors** (G53). Wrapped by `manage_diagnostic.ps1`.

## alerts — data-threshold notifications  **[verified]** (create→list→get→delete; ref p.235)
The data-driven sibling of `jobs`: fire when a watched report element's value
crosses a threshold. Verified full CRUD against `county_summary`:
- **`PUT /alerts` creates** (and `POST /alerts/{id}` *modifies* — the alerts
  service inverts the usual REST verbs, per the ref). Like jobs, **both
  `Content-Type` AND `Accept` = `application/alert+json`**. Returns `201` + the
  descriptor with a numeric `id`.
- `GET /alerts` lists; `GET /alerts/{id}` (Accept `application/alert+json`) reads
  one; `DELETE /alerts/{id}` → `200` echoing the id; then `GET` → `resource.not.found`.
  Batch ops: `?id=…&id=…`, `/alerts/pause|resume|restart`.
- **Required descriptor parts** (minimum that returned `201`): `label`,
  `trigger.simpleTrigger`, `source.reportUnitURI`, **`baseOutputFilename`**
  (omitting it `400`s `error.not.empty` on that field — even for an email-only
  alert), `outputFormats`, **`repositoryDestination`** (omitting it `400`s
  `error.report.alert.no.repository.output`), `mailNotification` with
  **`toAddresses` as a WRAPPER OBJECT `{"address":["a@b"]}`** — a bare array
  `400`s `serialization.error` deserializing `ClientAddressesListWrapper` (this
  differs from `jobs`, where recipients are a plain array), and `dataPointAlert`
  (`name`, `dataPoint.elementUUID`, `operator` =
  equals|notEqual|less|lessOrEqual|greater|greaterOrEqual, `thresholdValue`,
  `dataPointType:"NUMERIC"`, `resourceURI`).
- **Re-verified via `scripts/manage_alert.ps1`** (the wrapper that bakes in the
  two shape rules above): full create→list→get→delete round-trip. NOTE the
  **list** (collection) endpoint returns an `alertsummary` summary representation
  under `application/json` — requesting `application/alert+json` there `406`s
  (that media type is for the single-resource get only).
- **Firing — verified to the SMTP step.** A once-only immediate alert
  (`simpleTrigger.startType=1, occurrenceCount=1`) on a report with a numeric
  element fired on its Quartz trigger, ran the report, and drove the notification
  pipeline to the mail send — log: `ReportExecutionAlerting … executeAndSendReport
  → sendMailNotification`. The send then failed **only** because this server's
  configured SMTP host is the placeholder `mail.example.com:25`
  (`UnknownHostException`) — i.e., the evaluate→notify machinery works; only a
  reachable mailserver is missing. The once-only alert self-removes after firing
  (`GET /alerts/{id}` → `404`).
- **Actual email delivery — not captured here** (no admin in this context). The
  mail host is in `…/WEB-INF/js.quartz.properties`
  (`report.scheduler.mail.sender.host/.port/.username/.password/.from`); it's
  writable but **only reloads on a `jasperreportsTomcat` service restart**
  (needs elevation). To capture a delivered alert: point it at a local catcher
  (`localhost:25`), restart the service, fire the alert, observe the message.
- JR7-native `<element …>` accepts a `uuid="…"` attribute (compiles clean); the
  `dataPointAlert.dataPoint.elementUUID` is resolved against the JasperPrint at
  fire time. The alerts UI captures it by click; via REST, supply the element's
  design `uuid`.

## jobs — scheduling  **[verified]** (full create→list→get→delete round-trip)
Recurring / triggered / emailed report delivery. **Wrapped by
`scripts/schedule_job.ps1`** (create/list/get/delete; simpleTrigger now/at/
recurring, output formats, repo destination, optional mail).
- `PUT /jobs` — create. **Both `Content-Type` AND `Accept` must be
  `application/job+json`** — a plain `application/json` Accept gives `406 Not
  Acceptable`. Returns the created job with a numeric `id`. Minimal descriptor
  that worked here (saves a PDF to the repo, once, at a future date):
  ```json
  {"label":"…","source":{"reportUnitURI":"/reports/geocoder/county_summary","parameters":{}},
   "trigger":{"simpleTrigger":{"timezone":"America/Chicago","startType":2,
     "startDate":"2026-12-01 09:00:00","occurrenceCount":1}},
   "baseOutputFilename":"county_summary_verify","outputFormats":{"outputFormat":["PDF"]},
   "repositoryDestination":{"folderURI":"/reports/geocoder","saveToRepository":true,"overwriteFiles":true}}
  ```
  `simpleTrigger.startType`: 1 = now, 2 = at `startDate` (`yyyy-MM-dd HH:mm:ss`);
  `occurrenceCount` 1 = once, -1 = forever (with `recurrenceInterval` +
  `recurrenceIntervalUnit`). Add `mailNotification` for email delivery.
- `GET  /jobs?reportUnitURI=/reports/geocoder/county_summary` — list (`204` if none).
- `GET  /jobs/{id}` — full descriptor (`Accept: application/job+json`).
- `DELETE /jobs/{id}` — `200`, echoes the id; afterward `GET /jobs/{id}` →
  `resource.not.found`.

## permissions  **[verified]** (set → confirm → restore round-trip)
A resource with no explicit ACL returns `204` and inherits from its parent
(geocoder inherits from `/`). Entries are `{uri, recipient:"role:/ROLE_X", mask}`.
- `GET /permissions{uri}` — explicit perms only (`204` = none/inherited).
- `GET /permissions{uri}?effectivePermissions=true` — resolved/inherited ACLs.
- `PUT /permissions{uri}` — **replace all explicit perms** on the resource.
  **`Content-Type: application/collection+json`** (NOT `…collection.permission+json`,
  which `415`s; that wrong guess cost two tries — the WADL is authoritative).
  Body: `{"permission":[{"uri":"repo:/reports/geocoder","recipient":"role:/ROLE_USER","mask":1}]}`.
- **Remove explicit perms / restore inheritance:** `PUT {"permission":[]}` → back to `204`.
- A single-permission `PUT`/`POST` (per WADL) uses plain `application/json`.
- `mask` values seen live: 1 = administer, 2 = read+delete (docs also: 6
  read+write+delete, 18 read+write, 30 read-only, 32 execute-only, 0 none).

> **Windows/PowerShell gotcha (both services):** an inline `"$baseUrl?query=…"`
> passed to `curl.exe` yields exit-code `000` (request never sent). Assign the
> **full literal URL to a variable first**, then pass the variable. Same root
> cause as the JSON-body quoting issue — keep complex args out of the inline
> PowerShell→curl boundary.

## attributes  **[verified]** (server-level scoped + user-level single, both round-tripped)
Server/org/user key-value attributes — usable in datasource/report expressions
(`{attribute('name')}`), handy for not hard-coding DB creds per environment.
Holders: server `/attributes` · org `/organizations/{id}/attributes` · user
`/users/{u}/attributes`. Entry shape: `{name, value, secure, inherited, holder}`.

- **User / org single attribute** — there's a per-name sub-resource
  `/users/{u}/attributes/{attrName}` (and `/organizations/{id}/…`):
  `PUT` a single `{"name":…,"value":…}` (`application/json`) → `201`;
  `GET` → `200`; `DELETE` → then `GET` is `resource.not.found`. Isolated and safe.
- **Server level has NO `/attributes/{name}` sub-resource** — only the collection
  at `/attributes`. ⚠️ **A bare `PUT /attributes` REPLACES ALL attributes** (this
  server has ~134 system attributes — mondrian/adhoc/log4j/etc.; a full PUT would
  wipe them). **Always scope the partial update with `?name=`:**
  `PUT /attributes?name=foo` body `{"attribute":[{"name":"foo","value":"bar"}]}`
  → updates only `foo`. **Verified:** count went 134 → 135 (delta exactly 1),
  the other 134 untouched. Multiple: repeat `&name=…`.
- `GET /attributes?name=foo` reads one; `DELETE /attributes?name=foo` removes one
  (also scoped — verified count restored 135 → 134).
- `secure:true` write-masks the value in reads; `?_embedded=...` and `hal+json`
  representations are available per the WADL.

## inputControls — parameterized reports  **[verified]** (author → discover → run)
Verified by deploying a parameterized geocoder report (`county_summary_param`:
`HAVING count(*) >= $P{minEdges}`) with an embedded control, then filtering it
via REST — `?minEdges=50000` shrank the output from 254 to 17 counties.

**Read / run flow:**
- `GET /reports{uri}/inputControls` — control definitions. Each has an `id`,
  a string `type` (e.g. `singleValueNumber`, `singleSelect`), and `state.options`.
- `GET /reports{uri}/inputControls/{id}/values` — selectable values (cascading
  controls supported; `200` even for a free single-value control).
- Run with the chosen value(s) as query params on the run endpoints:
  `…/reports{uri}.pdf?{controlId}=50000` (confirmed to filter; output size
  tracks the row count). The same works on `reportExecutions` via `parameters`.

**Authoring an input control in the report-unit descriptor** (what
`deploy_report.ps1` does *not* yet do — build the descriptor by hand). Several
non-obvious shapes, each found by reading the `400` body:
- `inputControls` on the report unit is a **flat array** (the `{inputControl:[…]}`
  XML nesting is wrong in JSON → `ArrayList … from Object value`).
- Each element is a **polymorphic wrapper object**: `{"inputControl":{…}}` for an
  inline control or `{"inputControlReference":{"uri":…}}` for a shared one
  (`known type ids = [inputControl, inputControlReference]`).
- The embedded control uses **legacy numeric type codes**, NOT the string enums
  the read API returns (`Cannot deserialize value of type 'byte' from String
  "singleValue"`): control `type` `2` = single value; the nested
  `dataType.dataType.type` is **ordinal** `0`=text, `1`=number, `2`=date,
  `3`=dateTime, `4`=time (so `1` for a numeric control — `2` silently yields a
  *date* control).
- **Binding:** the control's repo id = its URI last segment, derived from its
  **`label`** (spaces→`_`, case kept). That id MUST equal the jrxml `$P{param}`
  name or the value never reaches the query. (Set `label:"minEdges"`, put prose
  in `description`.) JRS materializes the inline control + dataType into
  `…_files/` sub-resources.
- Re-deploying `409`s (optimistic lock) — DELETE the report unit first
  (cascades the `_files`), confirm `404`, then PUT.
Minimal inline control that worked:
```json
"inputControls":[{"inputControl":{
  "label":"minEdges","description":"Minimum TIGER edge count per county",
  "mandatory":false,"readOnly":false,"visible":true,"type":2,
  "dataType":{"dataType":{"label":"minEdges number","type":1}}}}]
```

## import / export — promotion & backup  **[verified]**
Already wrapped by `export_resource.ps1` / `import_resource.ps1` (the supported
path for dashboards, and for moving any folder between servers). Verified two
ways: a Supermart dashboard round-trip, and a **destructive** geocoder round-trip
— export `county_summary` → DELETE it (`resource.not.found`) → import the zip →
report restored (original label / dataSourceReference / jrxmlFileReference) and
runs to a byte-identical PDF.
- `POST /export {uris,parameters}` → `{id}`; poll `/export/{id}/state` until
  `phase=finished`; download `/export/{id}/exportFile` (the `/exportFile`
  suffix is required — a bare `GET /export/{id}` is `405`). The zip is a `PK`
  archive: `index.xml` + `resources/<repo-path>.xml` descriptors + `*.data`
  blobs (jrxml etc.) + `.folder.xml` metadata + referenced datasources.
- `POST /import?update=true` (multipart `-F file=@…;type=application/zip`); poll
  `/import/{id}/state`. `update=false` fails on an existing resource.

---

### Embedding — Visualize.js  **[verified]**  (`docs/JasperReportsServerVisualize.jsGuide…pdf`)
Not a REST flow but the natural "what next" for deployed reports/dashboards: a
JS API to embed them in a web app. **Verified end-to-end** — `county_summary`
rendered into a `<div>` on a page served from a *different* origin (`:8000`),
authenticated cross-origin, success callback fired (driven headless via
Playwright + the installed Chrome; screenshot confirmed the interactive table).
Working page (served from any plain web server, NOT the JRS webapp):
```html
<script src="http://localhost:8081/jasperserver-pro/client/visualize.js"></script>
<div id="container"></div>
<script>
visualize({ server:"http://localhost:8081/jasperserver-pro",
            auth:{ name:"superuser", password:"superuser" } }, function(v){
  v.report({ resource:"/reports/geocoder/county_summary", container:"#container",
             success:function(){/*…*/}, error:function(e){/*…*/} });
});
</script>
```
Also `v.dashboard(…)`, `v.inputControls(…)`, `v.resourcesSearch(…)`. JRS ≥7.9
auto-generates this embed code from the repository UI.
**Gotchas found while verifying:**
- **Serve the embed page from OUTSIDE the JRS webapp.** Everything under
  `…/jasperserver-pro/` is behind the auth filter, so a page dropped in the webapp
  just 302-redirects to the login screen before your JS runs. Serve it from a
  separate origin (a plain `python -m http.server`) and let the `auth` block log
  in cross-origin.
- **`/client/visualize.js` loads anonymously (`200`, ~126 KB)** — but sending it
  HTTP **Basic** creds makes the form-auth filter `302` it; just request it with
  no `Authorization` header.
- **Cross-origin needs CORS**, controlled by the server `domainWhitelist`
  attribute (it's `*` here → `Access-Control-Allow-Origin: <your origin>` comes
  back; tighten it for production).
- **Headless capture:** Chrome `--screenshot --virtual-time-budget` fires before
  the async fill finishes (you get visualize's own "Loading…"). Use Playwright
  (`channel="chrome"`, no chromium download) and `wait_for_function` on a
  success flag, then screenshot.
Out of scope for *authoring*, but the deployed artifacts are directly embeddable.

### Now in scope (scripted) — see SKILL.md
- **Domains / semantic layer** (`semanticLayerDataSource`): single-table Domains
  are scaffolded + created (`scaffold_domain_schema.py` + `create_domain.ps1`).
  The schema.xml must be **embedded inline** in the descriptor
  (`schema.schemaFile.content`), not a pre-uploaded `schemaFileReference` (which
  500s `resource.does.not.exist`). Multi-table = Designer + export/import.
- **Ad Hoc views** (`adhocDataView`): list / get-to-JSON / export / import
  (`manage_adhoc.ps1`). A raw JSON PUT is rejected `500 "bytes is null"` (carries
  a companion binary) — move them with the export/import envelope, like dashboards.
- **Themes**: deploy CSS + activate per organization (`deploy_theme.ps1`,
  `scaffold_theme.py`). Theme files are repository **file** resources under a
  `Themes` folder; activation is `PUT /rest_v2/organizations/{id}` `{"theme":…}`.
- **Style templates** (`.jrtx`): a repository file resource referenced by a
  report `<template>` expression (`scaffold_style_template.py` +
  `scaffold_jrxml.py --style-template`). Default-style attr is `default="true"`.
- **Non-JDBC datasources**: `jndiJdbcDataSource` / `beanDataSource` /
  `customDataSource` / `virtualDataSource` / `awsDataSource` via
  `create_datasource.ps1 -Type`. AWS `region` is the endpoint host
  (`us-east-1.amazonaws.com`), not the bare code.
- **Query-based + cascading input controls**: `deploy_report.ps1
  -QueryControl/-QueryMultiControl` builds a `query` resource + an inputControl
  (type 4 single / 7 multi, `valueColumn`+`visibleColumns`+`queryReference`);
  cascade via `$P{parent}` in the child query SQL.
- **OLAP / Mondrian**: `create_mondrian.ps1` uploads an `olapMondrianSchema`
  (standalone file resource) + creates a `secureMondrianConnection`
  (`dataSource.dataSourceReference` + `schema.schemaReference`); an `olapUnit`
  view is best-effort (creating it opens the connection + validates the MDX).
- **Permissions / attributes**: `manage_permissions.ps1`, `manage_attributes.ps1`
  (see the verified sections above).
- **Users / roles / organizations**: `manage_users.ps1`, `manage_roles.ps1`,
  `manage_organizations.ps1`. **[verified]** role + user create→get→delete on
  `organization_1`; org list/read. `PUT /rest_v2/users/{u}` and `/roles/{name}`
  create-or-update (idempotent); org-scope via `/organizations/{org}/users|roles`.
  **Org create is POST on the collection** (`/organizations?createDefaultUsers=true`,
  WADL id `putOrganization`) — NOT a `PUT {id}`; org `update` is a `PUT {id}`
  read-modify-write (the `{"theme":…}` path `deploy_theme.ps1 -Activate` uses).
  User descriptor: `{fullName,password,enabled,externallyDefined,roles:[{name}]}`.
- **Async run / options / caches**: `run_report_async.ps1` (reportExecutions
  submit→poll→download, **[verified]** 32 KB PDF), `manage_options.ps1` (saved
  input-control sets, **[verified]** create→list→run→delete — run the option's own
  sibling URI), `manage_cache.ps1` (`DELETE /rest_v2/caches/{id}`, DELETE-only —
  no list GET; **[verified]** `queryCache` → `204`).

### Deliberately out of scope
XML/A endpoint config, diagnostics, install/upgrade/security/telemetry — present
in the API and in the `docs/` PDFs, but outside this skill's remit. Discover them
via the WADL or the `docs/` guides if ever needed. (Users/roles/organizations
admin — previously out of scope — is now scripted; see above.)

---

## Version deltas: 9.0.0 and 10.1.0 (doc-only)

Diffed `docs/js-jrs_9.0.0_rest-api-reference.pdf` (336 pp) and
`docs/js-jrs_10.1.0_rest-api-reference.pdf` (347 pp) section-by-section against
each other and the 10.0.0 reference above (pypdf text extract + word-level
diff; branding/re-wrap churn filtered out). The three references share the same
service roster; the material deltas are few. Everything below is **[doc-only]**.

### New in 10.1.0 (absent from the 10.0.0 reference)
- **jobs historical data** - `GET /jobsAudit/jobsHistoricalData/{jobId}`
  (`?sortType=NONE|SORTBY_EXECUTION_TIME|SORTBY_START_TIME|SORTBY_END_TIME|
  SORTBY_STATUS|SORTBY_ERROR`) - per-run execution history for a scheduled job
  (10.1 REST ref p.232-234). Response:
  `{"historicalData":[{"executionTime":492,"status":"FAILED",
  "startTime":"...","endTime":"...","error":"..."}]}`. Gated: both auditing and
  the jobsHistoricalData property must be enabled or the call is `403` with
  errorCode `feature.disabled` ("Jobs Historical Data endpoint is blocked");
  missing/inactive job -> `404`. Not on this 10.0.0 install.
- **job success/failure counters** - the job descriptor and job search results
  gain `succeededJobsCount` / `failedJobsCount` (ignored on input)
  (10.1 p.196-197 and p.205).
- **inputControls `caseSensitive`** - query-based control `state` gains a
  `caseSensitive` boolean, governed by the server property
  `inputControl.handler.values.caseSensitive` in `WEB-INF/js.config.properties`
  (default true) (10.1 p.164-167). Absent from the 10.0.0 reference.

### Changed 10.0.0 -> 10.1.0
- **export state wording** - the 10.1 doc shows `/export/{id}/state` phases
  `finished` / `failed` where the 10.0 doc showed `ready` / `failure`
  (10.1 p.113 vs 10.0 p.113). The live 10.0.0 server already answers
  `phase=finished` (the verified export flow above polls exactly that), so this
  is doc alignment, not a server change - but promotion tooling talking to
  unknown versions should accept both spellings.
- Nothing else material: the remaining section diffs (jobs descriptor text,
  alerts, permissions, resources, import, admin services) are formatting and
  branding churn only.

### 9.0.0 targets - what promote.ps1 / export-import must NOT assume
STAGE here is 10.0.0; a PROD on 9.0.0 differs as follows (each verified absent
from the 9.0.0 PDF by full-text search, not just the ToC):
- **No `licenseFeatures` service.** 10.x adds `GET /licenseFeatures` ->
  `{"mt":true,"cl":true,...}` and `GET /licenseFeatures/{code}` (codes: mt, cl,
  al, ds, fusion, rb, aud, dv, vj, ana, wl, ahd, db); superuser/jasperadmin
  only, other users get `401` (10.0 ref p.20-22; 10.1 ref p.20-22; whole
  service absent from 9.0). Expect `404` on 9.0.0.
- **No `jobsAudit/jobsHistoricalData`** (10.1.0-only, above) - absent on both
  9.0.0 and 10.0.0 targets.
- **No input-control expressions** - the 10.x Input Control descriptor and
  structure document `readOnlyExpression` / `visibilityExpression` (10.0 ref
  p.53 and p.163-166); both absent from the 9.0.0 reference. Controls authored
  with these may not round-trip onto a 9.0.0 server.
- **No documented dashboard web-page `domainWhitelist` attribute flow** - the
  "Viewing Dashboard Web Page Domain Whitelist Attributes" GET is 10.x-only
  (10.0 ref p.332); do not assume it (or Visualize.js CORS behavior keyed to
  it) on 9.0.0.
- **File uploads** - 10.x adds the note that over HTTPS, `font`/`img` file
  uploads need an explicit MIME type (`font/ttf`, `image/png`) where HTTP
  accepted `font/*`, `image/*` (10.0 ref p.81-82); not in the 9.0.0 doc.
- Otherwise the 9.0.0 roster already covers everything the skill scripts use:
  resources, reports, reportExecutions, inputControls, options, jobs, alerts
  (+ both calendars services), permissions, export/import, keys, favorites,
  queryExecutor, caches, organizations/users/roles, attributes - same paths and
  shapes at the level this map documents (e.g. keys 9.0 p.125 = 10.0 p.128).
  A newer export catalog can still be refused by an older import for
  encryption-key or catalog-version reasons - an import-service runtime
  concern, not an endpoint difference.
- NOTE: the `contexts`, `thumbnails`, `settings`, and `diagnostic` services
  verified live above appear in NONE of the three REST reference PDFs (they are
  WADL-visible only) - their presence on a 9.0.0 target is unconfirmed; probe
  before relying on them in promotion tooling.

### Confirming any live target
Do not trust the PDFs for a given server: `GET rest_v2/serverInfo` and read the
`version` field ("9.0.0" / "10.0.0" / "10.1.0"), then fetch that server's own
WADL (`rest_v2/application.wadl?detail=true`) and grep it for the endpoint in
question (`jobsHistoricalData`, `licenseFeatures`, `contexts`, ...). The WADL
is generated from the running code, so it is ground truth for that exact
target; this section only predicts it. The serverInfo service itself is
identical across 9.0.0-10.1.0 (9.0 ref p.18; 10.1 ref p.18).

---

## Gotchas: REST / PowerShell 5.1 / curl / file upload

Moved here from `gotchas.md` (which keeps the symptom index). Entry ids (G33...)
are stable so the index links resolve. Each entry: Symptom / Cause / Fix /
Handled-by (the script or flag that already deals with it). ASCII only.

### G33
- Symptom: re-deploying an existing report fails `409 versions not match`.
- Cause: optimistic locking.
- Fix: `-Overwrite` (`?overwrite=true`). Observed 10.0.0: this RE-CREATES the unit (version 0, inputControls dropped unless the body carries them -- deploy_report carries them since 1.2.1) and still 403s under a dashboard lock (G21).
- Handled-by: `deploy_report.ps1 -Overwrite`.

### G34
- Symptom: an async report-execution POST fails `400 serialization.error`.
- Cause: on Windows an inline `-d '{...}'` gets its quotes mangled by PowerShell/curl.
- Fix: write the JSON to a file and pass `--data "@req.json"`.
- Handled-by: `run_report_async.ps1` / `schedule_job.ps1` / `manage_alert.ps1` all
  pass the body from a file.

### G35
- Symptom: an attribute call `405`s; the base URL is silently dropped.
- Cause: PowerShell 5.1 treats `?` as a variable-name char, so `"$base?name"`
  evaluates `$base?name` (undefined) and drops `$base`.
- Fix: build the path with braces: `"${base}?name=..."`.
- Handled-by: `manage_attributes.ps1`.

### G36
- Symptom: a server attribute write wipes all ~134 system attributes.
- Cause: a bare `PUT /attributes` REPLACES the whole set.
- Fix: always scope the server call with `?name=`.
- Handled-by: `manage_attributes.ps1` (always name-scoped at server scope).

### G37
- Symptom: PowerShell drops the database-name argument to `create_datasource.ps1`.
- Cause: `-Db` is a reserved alias of `-Debug`.
- Fix: use `-Database`.
- Handled-by: `create_datasource.ps1 -Database`.

### G38
- Symptom: PowerShell eats Maven/Java `-D...` args.
- Cause: PS parses `-D...` as its own switches.
- Fix: put them after the `--%` stop-parsing token.
- Handled-by: N/A (caller convention).

### G39
- Symptom: a wrapper script aborts on a clean (exit 0) compile/render.
- Cause: the SLF4J "No providers" line goes to stderr; under
  `$ErrorActionPreference="Stop"` that aborts the wrapper.
- Fix: invoke `java` directly, or check the `.jasper`/`.png` output rather than the
  pipeline error state.
- Handled-by: the shared `Invoke-JrCompile` helper absorbs SLF4J-on-stderr.

### G40
- Symptom: a large report times out on the synchronous `/reports/{uri}.{fmt}` endpoint.
- Cause: the sync endpoint blocks until the fill finishes.
- Fix: use the async `reportExecutions` service (submit -> poll `.../status` until
  `ready` -> download `.../outputResource`; `exportId` from
  `GET .../reportExecutions/{rid}` -> `exports[0].id`).
- Handled-by: `run_report_async.ps1`.

### G41
- Symptom: a `/Type /Page` grep reads 0 on a perfectly good PDF.
- Cause: the PDF page tree is usually compressed.
- Fix: verify by HTTP `200` + correct magic bytes (`%PDF-`, or `PK` for Office/OD
  zip formats) + a non-trivial byte size, not by counting page objects.
- Handled-by: `verify_report.ps1` / `build_dashlets.ps1` verify this way.

### G42
- Symptom: an uploaded image (logo) does not resolve via `repo:`.
- Cause: it was uploaded with Type `png`/`jpg` instead of `img`.
- Fix: upload images with `Type img`. The `-Type` set is
  `txt|csv|img|font|jrxml|prop|jar|xml|unspecified` (default `txt`); there is no
  `png`/`jpg` file type on the server side, `img` covers every raster format.
- Handled-by: `upload_file.ps1 -Type img` (see the param doc in `scripts/upload_file.ps1`).

### G56
- Symptom: a PUT of an inputControl (or any descriptor carrying a one-item list)
  is rejected with `ArrayList from String value` / a JSON-shape error, although
  the same PowerShell object works when the list has two or more items.
- Cause: PowerShell 5.1 `ConvertTo-Json` unwraps a single-element array to a
  scalar (`"visibleColumns":"col"` instead of `["col"]`), and the server
  deserializer wants an array.
- Fix: keep the array an array: wrap with `@(...)` at the call site, pass the
  object via `-InputObject`, or use the comma operator (`,$arr`) when piping.
  Where the shape matters (`visibleColumns`, list-of-values `items`), build the
  JSON string by hand and write it to a temp file for `Invoke-JrsPut -JsonFile`.
- Handled-by: `deploy_report.ps1` (query controls: hand-built `visibleColumns`
  JSON, see the comment near the `-QueryControl` loop) and the POS-suite control
  helpers (`New-LovControl` builds `items` by hand for the same reason).

### G57
- Symptom: an inline inputControl PUT fails `Cannot deserialize value of type
  'byte' from String "singleValue"` (or a control shows the wrong widget).
- Cause: the write API takes the LEGACY NUMERIC type codes, not the string enums
  the read API returns (`singleValue`, `singleSelect`, ...). The nested
  `dataType.dataType.type` is likewise ordinal (`0`=text, `1`=number, `2`=date,
  `3`=datetime).
- Fix: use the numeric `type` codes. The ones the scripts emit and have verified:

  | code | control | used by |
  | --- | --- | --- |
  | 1 | boolean (checkbox) | hand-authored only |
  | 2 | single value (typed; needs a `dataType`) | `deploy_report.ps1 -Control name=single[=text/number/date]` |
  | 3 | single-select, list of values | `deploy_report.ps1 -Control name=select`, `New-LovControl` |
  | 4 | single-select, query-backed | `deploy_report.ps1 -QueryControl`, `New-QueryControl` |
  | 6 | multi-select, list of values | `deploy_report.ps1 -Control name=multiselect` |
  | 7 | multi-select, query-backed | `deploy_report.ps1 -QueryMultiControl` |
  | 8 / 9 | multi-select checkbox (LOV / query) | hand-authored only |
  | 10 / 11 | single-select radio (LOV / query) | hand-authored only |

  Codes 1, 8-11 are the JRS legacy `InputControl` constants and are listed for
  completeness; only 2/3/4/6/7 are exercised by the scripts.
- Handled-by: `deploy_report.ps1` (`-Control`, `-QueryControl`,
  `-QueryMultiControl`); the inputControls section above documents the
  round-trip.

## Gotchas: export/import, permissions/admin, alerts/options/run, environment

Moved here from `gotchas.md`; ids are stable. These are behaviors of the
endpoints mapped above (`import / export`, `permissions`, `alerts`, `options`,
`contexts`, `diagnostic`) plus install-level facts about reaching the server.

### G25
- Symptom: 405 on `GET /rest_v2/export/{id}`.
- Cause: the export download endpoint is `/exportFile`, not the bare id.
- Fix: download from `/rest_v2/export/{id}/exportFile` (after polling
  `/rest_v2/export/{id}/state` to `phase=finished`).
- Handled-by: `export_resource.ps1`.

### G26
- Symptom: an ad hoc view JSON PUT fails `500 "bytes is null"`.
- Cause: an `adhocDataView` carries a large opaque `query.multiAxis`/`component`
  state plus a companion binary; a raw JSON PUT cannot reconstruct it (same
  don't-PUT lesson as dashboards).
- Fix: use the export/import envelope (carries the view plus its backing Topic/Domain).
- Handled-by: `manage_adhoc.ps1 -Action export|import` (wraps `export_resource.ps1`/`import_resource.ps1`).

### G43
- Symptom: setting permissions returns `415`.
- Cause: `Content-Type: application/collection.permission+json` is rejected.
- Fix: use `Content-Type: application/collection+json`. Masks: 1=administer,
  2=read+delete, 18=read+write, 30=read-only, 32=execute-only.
- Handled-by: `manage_permissions.ps1`.

### G44
- Symptom: `manage_users.ps1` auth fails (401) or sets the wrong password.
- Cause: `-Password` is the NEW user's initial password, not the JRS auth password.
- Fix: pass the JRS auth password as `-JrsPassword`.
- Handled-by: `manage_users.ps1`.

### G45
- Symptom: creating an organization with `PUT {id}` does not work as expected.
- Cause: org create is a POST on the collection
  (`/rest_v2/organizations?createDefaultUsers=true`, WADL id `putOrganization`).
- Fix: POST to create; `update` is a read-modify-write `PUT {id}` (so setting
  `-Theme` does not blank other fields).
- Handled-by: `manage_organizations.ps1`.

### G46
- Symptom: alert create fails `400`.
- Cause: two shape traps -- `mailNotification.toAddresses` must be a wrapper object
  `{address:[...]}` (NOT a bare array, unlike jobs); and `baseOutputFilename` is
  required even for an email-only alert.
- Fix: use the wrapper object and always set `baseOutputFilename`.
- Handled-by: `manage_alert.ps1`.

### G47
- Symptom: a saved report option's input-control values are not applied.
- Cause: a `?reportOptions=<id>` query on the report URL does NOT apply them.
- Fix: run the option's OWN sibling URI as a report:
  `GET /reports/<folder>/<id>.pdf`.
- Handled-by: `manage_options.ps1 -Action run`.

### G48
- Symptom: a JR Library sample deploys + runs (200 + valid PDF) but renders blank.
- Cause: many samples rely on parameters the Java harness supplies (e.g.
  `MaxOrderID`); with no default they fill empty. (A 200 + valid PDF only means it
  ran, not that it has content.)
- Fix: pass params at run time (`...PieChartReport.pdf?MaxOrderID=11077`) or bake in
  defaults.
- Handled-by: `report\inject_chart_defaults.py` injects `<defaultValueExpression>`.

### G50
- Symptom: every path `401`s.
- Cause: targeting port 8080, an unrelated Bearer-token-gated Java service.
- Fix: target `http://localhost:8081/jasperserver-pro` (REST v2, HTTP Basic,
  `superuser` with the password from `jrs.config.json` -- not the default).
- Handled-by: credential resolution defaults to 8081.

### G51
- Symptom: every call `401`s on the RIGHT server with the RIGHT password --
  even `GET /rest_v2/serverInfo` -- when the same credentials worked minutes
  earlier.
- Cause: JRS account lockout. 10 failed logins disable the account
  (`jiuser.enabled = false`); a client retrying with a STALE password (the
  classic culprit: a deployed jasper-wizard WAR whose `web.xml` still holds the
  old `jrsPass` after a password change, failing once per proxied request)
  burns through the 10 in seconds. The lockout does NOT auto-expire, and no
  org admin can re-enable the root `superuser` via REST.
- Fix: re-enable directly in the repo metadata DB (the bundled Postgres, on the
  port from `jrs.config.json` -- see G59): `UPDATE jiuser SET enabled=true,
  numberoffailedloginattempts=0 WHERE username='superuser';` -- then fix the
  stale-credential client.
- Handled-by: `webapp/jasper-wizard/build.ps1` patches the assembled
  `web.xml`'s JRS connection from the skill's gitignored `jrs.config.json` at
  build time, so a rebuilt wizard always matches the local server creds; the
  smoke test's `wizard-api` step catches the drift before it can lock the
  account.

### G52
- Symptom: `POST /rest_v2/contexts` (datasource connection test) fails `415
  Unsupported Media Type`.
- Cause: guessing a `application/connections.jdbc+json` content type. The
  contexts service wants the descriptor's OWN repository media type.
- Fix: `Content-Type: application/repository.jdbcDataSource+json` (or
  `...jndiJdbcDataSource+json` / `...customDataSource+json`). Then 201 = the
  server-side connection actually opened; 400 `connection.failed` carries the
  driver's real error.
- Handled-by: `Invoke-JrsConnectionTest` (`_jrs_common.ps1`) /
  `create_datasource.ps1 -Test` / doctor's "JRS->DB connection" check.

### G53
- Symptom: diagnostic collectors vanish after a "delete one" call; or the
  downloaded collector zip's log will not open; or creating a collector 400s
  with a `validateName` stack trace.
- Cause: three sharp edges of `/rest_v2/diagnostic/collectors`: (1) a DELETE on
  the bare collection (no id) deletes ALL collectors (same family as G36's
  PUT-/attributes wipe); (2) the zip's `diagnostic.log.jsEncrypted` is
  encrypted with the server key -- intended for Jaspersoft support, only
  `collectorSettings.xml` is plaintext; (3) collector names must be unique
  among live collectors.
- Fix: always delete by id (`-Id`); treat the zip as a support bundle; use a
  fresh name per run.
- Handled-by: `manage_diagnostic.ps1` (requires `-Id` unless `-All`; notes the
  encryption; documents the name rule).

### G54
- Symptom: every type-filtered repository search
  (`resources?type=jdbcDataSource`, `jndiJdbcDataSource`, ...) suddenly `500`s
  with `ClassCastException: Cannot cast RepoJdbcDataSource to
  RepoResourceItemBase` -- single GETs and `q=` text search still work, the
  wizard's datasource list breaks, and clearing caches via
  `DELETE /caches/{id}` does nothing.
- Cause: a diagnostic collector started at **verbosity HIGH** (JRS 10.0.0
  server bug). Bisected live: the search breaks the moment the HIGH collector
  STARTS and stays broken after stop/delete; a full LOW-verbosity lifecycle
  (start->stop->download->delete) is clean.
- Fix: restart Tomcat (only cure), and use `LOW` verbosity for collectors.
- Handled-by: `manage_diagnostic.ps1` defaults to `LOW` and warns on `HIGH`;
  the smoke's `diagnostic` step runs the LOW lifecycle.

### G59
- Symptom: `psql`, `report_usage.ps1` or `doctor.ps1` connect to a `jasperserver`
  database that is EMPTY or stale (no `jiauditevent` rows, old users), or the
  G51 lockout `UPDATE` "succeeds" but the account stays locked.
- Cause: the JRS-bundled PostgreSQL may listen on a NON-default port, and a
  separate, stale `jasperserver` database can exist on the default 5432 (a
  decoy left by an earlier install). Pointing at 5432 by habit reads the wrong
  instance.
- Fix: read the live port from the JRS `context.xml` (the repository JNDI
  datasource URL) or `jrs.config.json`'s `repoDb.port`, never assume 5432. Write
  it into `jrs.config.json` so every script resolves the same instance.
- Handled-by: `jrs.config.json` (`repoDb`, schema-documented in
  `jrs.config.schema.json`); `doctor.ps1` counts against that instance and,
  when `webappDir` is set, parses `<webapp>/META-INF/context.xml` (or
  `WEB-INF/js.jdbc.properties`) for the repository JDBC URL and cross-checks the
  REAL port against `repoDb`; `admin-and-scheduling.md` describes the
  usage-report queries against it.
