# Server administration (ops/config layer)

[doc-only] Everything in this file is distilled from the vendor PDFs in docs/
(primarily js-jrs_10.1.0_administrator-guide.pdf; page cites are that guide's
printed pages unless marked otherwise). Nothing here is live-verified on this
install; for the verified REST-level admin surface (users/roles/orgs,
permissions, attributes, jobs, alerts, caches DELETE, diagnostics) see
admin-and-scheduling.md - this file covers the ops/config layer underneath it.

## Import/export - command-line js-import / js-export

Catalogs: the unit of import/export is a "catalog" - a zip (or folder tree) of
XML files + private-format data files describing repo resources, orgs, users,
roles, jobs (10.1 admin guide p245). The catalog XML syntax is NOT public; for
programmatic access use REST v2 instead (p246). Passwords are encrypted inside
catalogs, but catalogs still leak usernames, DB URLs, and report output - treat
them as sensitive (p246).

Tools live in `<js-install>/buildomatic/`: `js-import.bat|.sh`,
`js-export.bat|.sh` (p264). Rules:
- STOP the server before running (caches/config/security corruption otherwise)
  - most important for import (p265).
- All options start with `--`. URIs are repo paths from root and MUST include
  `/organizations/<org>` in commercial editions unless you pass
  `--organization` (then URIs are org-relative) (p265).
- `Temp` folders (root and per-org) are never exported (p270).
- WAR-file installs must first configure the utilities: copy
  `buildomatic/sample_conf/<db>_master.properties` ->
  `buildomatic/default_master.properties`, edit DB values, then
  `js-ant clean-config gen-config` (generates
  `build_conf/default/js.jdbc.properties` and `js.quartz.properties`); JDBC
  driver goes in `buildomatic/conf_source/iePro/lib` (p274). Binary-installer
  installs are pre-configured.

### js-export options (p266-269)
- `--everything` = all resources + permissions + jobs + calendars + users +
  roles (equivalent to `--uris --repository-permissions --report-jobs
  --calendars --users --roles`); audit/monitoring data NOT included unless
  flagged. Combine with `--organization` for one org.
- `--uris a,b` folders/resources (recursive); `--resource-types` filter
  (adhocDataView, dashboard, reportUnit, jdbcDataSource, inputControl,
  mondrianConnection, olapUnit, file, folder, ...).
- `--repository-permissions` (only with `--uris`);
  `--skip-dependent-resources` exports without datasource/controls/images.
- `--report-jobs uris` and `--report-alerts uris` (folder URI = all reports
  under it); `--calendars` all scheduler calendars.
- `--users u1,"u2|org_1"` / `--roles` / `--role-users` / `--users-roles`;
  `--include-attributes` (+ `--skip-attribute-values` for names only).
- `--include-access-events` (last-modified metadata),
  `--include-audit-events`, `--include-monitoring-events`,
  `--include-server-settings` (persistent UI settings: Log/Ad Hoc/Ad Hoc
  Cache/OLAP Settings).
- Output: `--output-zip file.zip` or `--output-dir dir`.

### js-import options (p270-273)
- `--input-zip` / `--input-dir`.
- Default collision behavior: existing resource is LEFT UNCHANGED. `--update`
  replaces when URI+type match; a type mismatch errors and skips (p273).
- `--skip-user-update` (with `--update`): don't touch existing users.
- `--organization <id>` targets an org; `--merge-organization` when catalog
  org id differs (import contents win on name collisions; merged org takes the
  imported org's id).
- `--broken-dependencies skip|include|cancel`.
- `--include-server-settings`: only works if the source settings were modified
  via the UI AND the catalog was an "everything" export; takes effect on
  restart (p272).
- `--skip-themes`: required for catalogs with themes from some Release-5-era
  servers; incompatible old themes can break the whole UI (p264).
- `--include-alerts`, `--include-access-events`, audit/monitoring flags mirror
  export.

### Buildomatic equivalents (p275-276)
`js-ant export -DexportFile=f.zip -DexportArgs="--everything"` and
`js-ant import -DimportFile=f.zip -DimportArgs="--update"` - same options,
no configuration needed regardless of install method. `.zip` suffix on the
file name selects zip output automatically.

### Encryption keys on export/import (p247-249)
Since 7.5 keys are automatic: same-server round trips just work (UI: pick
"Server key"; CLI: auto-detected). Cross-server promotion (e.g. STAGE->PROD)
needs a shared key: generate a key during export on server A, import that key
into server B's keystore via the CLI, then specify it when importing the
catalog. Pre-7.5 catalogs: use the "Legacy key" (UI) / deprecated
ImportExportEncSecret (CLI). Key create/import/export procedures live in the
Security Guide, not the admin guide.

### UI import/export (p249+)
Repository right-click export (system + org admins; per-folder/resource,
optional "Include dependencies" - unchecking it creates broken dependencies)
vs Settings > Export ("everything", system admin only). Settings > Import is
the UI twin of js-import. The skill's export_resource.ps1 uses the REST
export service instead (see export-import.md/gotchas G25).

## Repository internals

- Every resource/folder has an ID (unique within its folder only), a display
  name, and optional description; the repo path is the chain of parent-folder
  IDs + resource ID, e.g. /reports/samples/Freight (p79). Repo search matches
  IDs, names, AND descriptions (p24).
- References from a JasperReport: local resource (embedded in the report unit,
  invisible elsewhere), external reference (repo resource shared by many
  reports), or absolute path in the JRXML. For ABSOLUTE references the server
  does NOT maintain the dependency: no warning on upload if missing, and it
  will happily let you delete the referenced resource - the report then fails
  at run time (p76-77). External references are dependency-managed.
- Special folders: `Themes` at root and in every org (special activate/upload/
  download menus); `Temp` (excluded from export); `Organizations` holds tenant
  subtrees, and its `Folder Template` contents are copied into every new org
  (p89). Put cross-org shared resources in Public with visibility-restricting
  permissions to avoid cross-org export dependencies (p247).
- Edit-in-place rules per type (Ad Hoc view Open+overwrite, dashboard Open in
  Designer, Domain Edit, JasperReport Edit for datasource/controls) - p85-86.

## Logging (log4j2)

- Default log: `WEB-INF/logs/jasperserver.log`; config:
  `WEB-INF/log4j2.properties` (Log4j2 + SLF4J) (p396).
- Effective level precedence (low->high): root level in log4j2.properties
  (default ERROR) -> per-logger level in the file -> per-logger level set in
  the Log Settings UI (p397-398). File edits need a restart; UI changes are
  immediate, persist in the REPOSITORY, override the files, and are never
  written back to them (p398, 400).
- UI: Manage > Server Settings > Log Settings; change listed loggers via
  dropdowns, or add any unlisted logger class at the bottom (p402). Common
  loggers ship commented-out in log4j2.properties - uncomment to enable
  (p400).
- Log line context supports USER_ID, SESSION_ID, REQUEST_TYPE/STATUS,
  TIME_TAKEN via pattern `%X{USER_ID}` etc. in the appender layout (p400-401).
- DEBUG on several loggers can cripple performance; don't leave it on (p397).

### Audit vs access vs monitoring events
Three distinct subsystems - don't conflate:
- Access events: lightweight last-modified/"who ran what" records
  (jiaccessevent in the metadata DB; report_usage.ps1 reads it - see
  admin-and-scheduling.md). Exported with `--include-access-events`.
- Audit: detailed per-event records (login/logout, report run incl. SQL and
  params, resource CRUD...); event list defined in
  `...\WEB-INF\applicationContext-audit.xml` (p414).
- Monitoring: built ON audit events, feeds a multi-dimensional Domain for
  Ad Hoc analysis of report performance (p412-413).

Enabling (all in `WEB-INF/js.config.properties`, default subsystem OFF,
p416-417): `feature.audit_monitoring.enabled=true` master switch, then
`audit.records.enabled=true` and/or `monitoring.records.enabled=true`.
(This install: both ON - see memory/jrs-repo-db-port-5433.) CLOB fields must
be enabled before audit Domains work (p416). Archiving: daily job moves audit
rows older than `maxAuditEventAgeToArchive` (default 30 days) to archive
tables, and deletes anything older than `maxAuditEventAge`; schedules are
Quartz cron expressions on the auditService bean (p417-418). Disable
individual events/properties in the `enabledEventsMapping` map of
applicationContext-audit.xml - disabling an event removes it from BOTH audit
and monitoring (p418). Reporting: Audit Domain + Audit Archive Domain and
prebuilt admin-only reports (p420-423); scheduled-job monitoring Ad Hoc
views/Domains under /Public/CompletedSchedules (p439-445).

### Log collectors
UI (Manage > Server Settings > Log Collectors) and REST lifecycle are covered
in admin-and-scheduling.md + gotchas G53/G54. Config knobs:
`applicationContext-diagnosticCollectors-pro.xml` - `appenderMaxFileSize`
(default 50MB/file), `logFilePattern` with `.gz` for compressed bundles
(p412-413). Bundle contents are encrypted with the server key (p411).

## Caches (Ehcache) - Ad Hoc vs OLAP

- Ad Hoc cache: Ehcache-based dataset cache for Ad Hoc views on Topics/Domains
  and reports generated from them. Config `...\WEB-INF\adhoc-ehcache.xml`:
  `maxBytesLocalHeap` default 400M (recommend ~half of JVM -Xmx),
  `timeToIdleSeconds` default 1800, `timeToLiveSeconds` default 5400
  (p301-302). Default cache key is per-user (duplicate datasets across users);
  granularity is configurable (p301). Data staging shares the same heap
  budget (p313).
- OLAP cache: Ad Hoc views on OLAP connections use the Mondrian cache instead
  (p300). Flush: Manage > Server Settings > OLAP Settings > Flush OLAP Cache
  (p306). Disable: `mondrian.rolap.star.disable-caching` on the same page.
- Disabling the Ad Hoc cache = set maxBytesLocalHeap to 1 byte (every query
  goes to the datasource); also re-false any of the three cache props if
  changed in applicationContext-adhoc.xml (p306-307).
- REST-side invalidation (`DELETE /rest_v2/caches/queryCache`) is scripted in
  manage_cache.ps1 - see admin-and-scheduling.md.

## Multi-tenancy: orgs, themes, attribute precedence

- Org tree under the root; Manage > Organizations shows the hierarchy;
  admins can export/import entire orgs from that page (duplicate an org,
  change hierarchy, backups) (p37).
- Theme inheritance: each Themes folder (root + per org) holds a
  server-controlled `default` theme plus custom theme folders. Active theme at
  root = system theme for everyone unless an org activates its own; an org's
  inherited theme is the combination of parent themes, and org themes can
  override individual files while inheriting the rest (p214-217). Cheapest
  customization: put override rules in `overrides_custom.css` - it is always
  the LAST CSS loaded, so its rules win (p220). Theme activation via REST is
  deploy_theme.ps1 -Activate (themes.md).
- Attributes: two lookup styles (p58-59). Categorical = exact level (user OR
  org OR server; no value if absent there). Hierarchical = search user ->
  user's org -> parent orgs -> server, first hit wins. Editing an inherited
  attribute at a lower level silently creates a local override that then takes
  precedence (p67); attribute-level permissions exist precisely to stop lower
  orgs redefining/reading a higher-level name (p61). Server-level values are
  global to all users but differ per server - the standard trick for
  test-vs-prod datasource attributes (p58).

## Session, heartbeat, license, misc config

- Settings UI map (Manage > Server Settings): Log Settings, Log Collectors,
  Ad Hoc Settings, Ad Hoc Cache, OLAP Settings, Cloud Settings, Server
  Attributes, Restore Defaults, Import, Export (p280). UI-changed settings
  persist in the repo and take precedence over config files after restart;
  each setting is independent, so displayed values can be a mix of file and
  repo sources (p281-282).
- Session persistence (p284-286): if the app server persists sessions across
  webapp restarts, repo browsing and REST session IDs survive; interactive
  editors (Ad Hoc, dashboard, Domain designer) do NOT - user is redirected
  with unsaved work lost. Redeploys never preserve sessions.
- Heartbeat (p365-366): install-time prompt; reports OS/JVM/app server/DB
  types+versions and server edition to Jaspersoft. Controlled in
  `WEB-INF/js.config.properties`: `heartbeat.enabled`,
  `heartbeat.askForPermission.enabled`, `heartbeat.permissionGranted.enabled`
  (all feed heartbeatBean in applicationContext-heartbeat.xml). Distinct from
  the 9.0+ telemetry program - see aws-telemetry-vpat.md.
- License: feature set is license-gated (p17); the About JasperReports Server
  footer link shows version/build/license details (p32); set real email on
  superuser/jasperadmin - license issues may be notified by mail (p31).
- Report thumbnails: OFF by default; `WEB-INF/js.spring.properties`
  `property.reportThumbnailServiceEnabled=true` (needs restart) before the
  thumbnails REST used by manage_thumbnails works server-side (p363-364).
- 404 body is configurable to a generic message to avoid leaking resource
  existence (p364).

## Scheduler config (js.quartz.properties)

- Misfire policies per job kind: `report.quartz.misfirepolicy.singlesimplejob`
  / `.repeatingsimplejob` (SMART_POLICY, MISFIRE_INSTRUCTION_FIRE_NOW,
  ..._IGNORE_MISFIRE_POLICY, reschedule variants) (p348-350).
- `calenderTrigger.resetStartTimeOnImport` (sic - vendor typo) and
  `simpleTrigger.resetStartTimeOnImport` (default false): set true to stop
  imported jobs firing immediately after a catalog import; execution
  recalculates to the next trigger time (p351).
- Notification mail bodies are templated via
  `mail.service.body.scheduler.notification.template` and friends (p359-360).
  The SMTP host/sender itself is generated into js.quartz.properties by
  buildomatic from default_master.properties (`js-ant gen-config`, p274) -
  needed before job email delivery or alert mail works (cross-ref
  admin-and-scheduling.md alerts).

## 9.0.0 -> 10.1.0 admin-guide deltas (material only)

Same chapter structure; 10.1 adds (9.0 admin guide lacks): the OpenTelemetry
chapter (Jaeger-based tracing of report execution/scheduling spans, 10.1
p376-393); Configuring JasperReports Web Studio Access (p367); password
storage strategy + password history config (p374); a Downloading and
Installing JDBC Drivers section; the 404-message setting; Disabling the
Alerts. If a customer is on 9.0.x, don't cite those features.

## Preflight: doctor.ps1 (what each check proves, and what it cannot)

`scripts/doctor.ps1` is the canonical first step on a fresh clone. It never
aborts on a failing item; every line is PASS / WARN / FAIL and only FAIL sets
a non-zero exit. Optional inputs come from `jrs.config.json`
(`references/jrs.config.schema.json`): `jrsWebappDir`, `chartCustomizerJar`,
`repoDb`, `environments`. `-ConfigPath` points it at another config file
(used by `tests/doctor.Tests.ps1`, which runs fully offline).

| Check line | Source of truth | Meaning of WARN |
|---|---|---|
| `jrs.config.json` | the config file + schema `required` list | n/a (missing/invalid is FAIL) |
| `JRS server reachable` | GET `rest_v2/serverInfo` on the resolved server | n/a (FAIL) |
| `PostgreSQL reachable` / `repo metadata DB` | psql `select 1` / `count(*) from jiaccessevent` on `repoDb` | psql absent, DB unreachable, or 0 access events (you are on the stale :5432 decoy, not the live bundled instance) |
| `JRS->DB connection (contexts)` | POST `/rest_v2/contexts` - the JRS JVM opens the connection | the server, not this shell, cannot reach the DB (driver, host, credentials) |
| `server settings (REST)` | `/rest_v2/settings/globalConfiguration` + `domainWhitelist` attribute | REST settings unreadable; unset whitelist means Visualize.js cross-origin embeds 403 |
| `JR runtime jars` | `jrLibDir` contents | n/a (FAIL) |
| `chart-customizer jar` | `<jrsWebappDir>/WEB-INF/lib/actian-chart-customizers.jar` vs the bundled `chart_customizers/` jar, SHA-256 | absent (only bar-gradient reports need it) or STALE - copy the bundled jar over it and restart Tomcat |
| `repo DB port (webapp config)` | the jdbc URL in `<jrsWebappDir>/META-INF/context.xml` (fallback `WEB-INF/js.jdbc.properties`) | webapp dir unknown, or `repoDb` in jrs.config.json disagrees with what the server actually uses. The bundled PostgreSQL often listens on a NON-default port such as 5433; never assume 5432 - `report_usage.ps1` and check 3b read `repoDb` |
| `env profile '<name>'` | GET `rest_v2/serverInfo` per `environments` entry (profile keys shadow top-level ones, `passwordCommand` honoured) | that profile is unreachable - `promote.ps1 -ToEnv <name>` will fail. The version printed per profile is what `version-matrix.md` section 4 wants compared before a promotion (never promote newer -> older) |
| `Python (sqlglot, pypdfium2)` | `python -c "import ..."` | lineage / visual baselines unavailable |
| `key scripts present` | `scripts/` | n/a (FAIL) |

Limits: the webapp checks only see a LOCAL exploded war (set `jrsWebappDir`;
leave it unset on a laptop that only talks to a remote server and accept the
WARN). The chart-customizer comparison is a byte hash - a rebuilt-but-identical
jar passes, a functionally identical jar built on another machine does not.
The env-profile probe uses HTTP Basic only; SSO-fronted servers report a
non-200 and need a manual check.
