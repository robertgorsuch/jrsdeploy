# JRS version matrix: 9.0.0 -> 10.0.0 -> 10.1.0

What changed between JasperReports Server versions, what each version runs on, and
what bites you when promoting or upgrading. Local STAGE is JRS 10.0.0 commercial;
PROD may differ. ASCII only. Terse on purpose.

ALL content here is [doc-only]: extracted from vendor PDFs in docs\, not exercised
against a live server. Verify against `GET /rest_v2/serverInfo` before relying on it.

This file is the DEEP 9.0 -> 10.1 delta. For the full 4.7 -> 10.1 span (upgrade
ladder from any version, platform cliffs, pain-point mitigations, pre-upgrade
checklist) see `upgrade-migration-playbook.md`; per-era source detail lives in
`version-archive/{platform-evolution,upgrade-procedures,relnotes-install-deltas}.md`.

Source abbreviations (all files in C:\Users\rgorsuch\tx-geocoder\docs\):
- 9.0 RN   = js-jrs_9.0.0_relnotes.pdf
- 10.1 RN  = js-jrs_10.1.0_relnotes.pdf
- 9.0 PS   = js-jrs_9.0.0_platform-support-commercial.pdf
- 10.1 PS  = js-jrs_10.1.0_platform-support-commercial.pdf
- 10.1 UG  = js-jrs_10.1.0_upgrade-guide.pdf
- 10.0 UG  = JasperReportsServerUpgradeGuidev10.0.0.pdf

No 10.0.0 relnotes or platform-support PDF is on hand; the 10.0.0 column below is
reconstructed from 10.1 UG "Changes in 10.0" (p.83-84) and 10.0 UG. Blank = not
stated in the available docs.

## 1. Feature / behavior delta

### New per version

| Area | 9.0.0 (Jan 2024) | 10.0.0 | 10.1.0 (Jul 2026) |
|---|---|---|---|
| Scheduling | Schedule status column on Schedules page (9.0 RN p.5) | - | Centralized Scheduler Dashboard: real-time job states, restart executions, full history (10.1 RN p.5) |
| Alerting | Alerting in Report Viewer for tables/crosstabs; email on threshold; managed on Schedules and Alerts page (9.0 RN p.4) | - | - |
| Ad hoc / viewer | Chart drill up/down; advanced DateTime calcs (YTD, PoP); default visualization type; Always-prompt input controls (9.0 RN p.5-6) | Redesigned Layout Band, adapts per visualization type (10.1 UG p.83) | Web Studio: drag-drop query building, composite elements, Advanced Query Designer, modernized repository UI (10.1 RN p.8-9) |
| Reports | Ad Hoc Component in JRXML reports (parent view edits auto-propagate); dashlet hyperlink type for Studio reports in dashboards (9.0 RN p.5-6) | Custom Input Controls: expressions to enable/disable, show/hide, retitle ICs (10.1 UG p.84) | - |
| Auth / security | OAuth with OpenID; JNDI Security (JNDI resources now mandatory, restricted access); roles that cannot be deleted (9.0 RN p.6-8) | csrfguard 4.3.0: per-page CSRF tokens forced on (10.1 UG p.84) | Password History Validation (last N); password storage moves to one-way PBKDF2/SCrypt/Argon2 (10.1 RN p.5-6; 10.1 UG p.81) |
| Ops / observability | Request-context logging (USER_ID, SESSION_ID, RESOURCE_URI, REQUEST_TYPE/STATUS, TIME_TAKEN); OpenTelemetry tracing; Office365 SMTP (9.0 RN p.7-8) | - | Enhanced logging stability; JDBC scalability improvements (10.1 RN p.9,12) |
| Internals | - | Jakarta EE 10 namespace (javax -> jakarta); Hibernate 6 (.hbm.xml -> JPA annotations); new in-house license validator + renamed license file (10.1 UG p.83) | Castor serializer replaced by Jackson; Apache Tiles retired; Spring 6.2.x / Spring Security 6.5.x (10.1 RN p.6,11-12) |

### Removed / deprecated per version

| Version | Removed or dropped |
|---|---|
| 9.0.0 | Progress JDBC drivers (all TI*.jar: cassandra, db2, hive, impala, mongodb, oracle, redshift, sforce, sparksql, sqlserver, googlebigquery, autorest) (9.0 RN p.13); WebSphere 8.5.5.x; Studio drops Xalan and outdated SQLite driver (9.0 RN p.19); WebLogic 12.2.1.4 and Tomcat 8.5.x demoted to Compatible (9.0 RN p.18) |
| 10.0.0 | javax.* app servers: Jakarta move requires Tomcat 10.1.x (10.1 UG p.83) |
| 10.1.0 | MySQL 8.0 as repo DB (8.4 only); Studio drops OLAP/Mondrian data adapters, TIBCO Maps plug-in, TIBCO DV driver, Jakarta SOAP API lib (10.1 RN p.14); accessibility features removed from Community Edition -> "TagPDF not supported" exception on first run with CE library 10.1.0 (10.1 RN p.7) |

### REST / API-visible changes

- 9.0.0: outputControlMapForContexts property hides stack traces in the
  /rest_v2/contexts flow (9.0 RN p.9). New import behavior props
  calenderTrigger.resetStartTimeOnImport and simpleTrigger.resetStartTimeOnImport
  (9.0 RN p.9). Fixes: REST param value case-sensitivity vs DB (JS-59656), reports
  service UTF-8 charset (JS-31684) (9.0 RN p.28-29).
- 10.0.0: csrfguard 4.3.0 issues a unique CSRF token per visited API URL; master
  token can mint page tokens (10.1 UG p.84). Affects browser/cookie sessions, not
  basic-auth rest_v2 calls.
- 10.1.0: fixed XSS via unsanitized `type` query param on rest_v2 endpoints
  (JS-76888, present in 9.0.0) (10.1 RN p.19). Castor-to-Jackson serialization is
  claimed transparent to clients (10.1 UG p.81).

### Bundled JasperReports Library

| Server | Library |
|---|---|
| 9.0.0 | JasperReports Library 6.21.0 (adds PDF/A-2/3 flavors, JRPptxExporter, WEBP) (9.0 RN p.10,18) |
| 10.x | Library renumbered to match server: JasperReports Library Pro 10.1.0 in 10.1 (10.1 RN p.14) |

## 2. Platform support matrix

| Item | 9.0.0 (9.0 PS) | 10.1.0 (10.1 PS) |
|---|---|---|
| Java (server) | 8 (min 1.8.0_163), 11; 17 runtime-only on Tomcat 9 (p.22) | 17, 21 only; Oracle JDK / Temurin / Red Hat OpenJDK certified, other OpenJDKs compatible (p.20) |
| Tomcat | 9.0.x certified, 8.5.x compatible; Tomcat 10+ / Jakarta explicitly NOT certified (p.5) | 10.1.24+ and 11.0.11+ certified (p.5) |
| Other app servers | WildFly 18/19, JBoss EAP 7.2, JWS 5.7.2, WebSphere 9.0.5.5, WebLogic 14.1.1.0 (p.5) | WildFly 36, JBoss EAP 8.0 only; WebSphere and WebLogic gone from the table (p.5) |
| PostgreSQL (repo + DS) | 12, 13, 14, 15 (p.10) | 14, 15, 16, 17 (p.9) |
| Other repo DBs | MySQL 5.7.28/8.0, Oracle 19c, DB2 11.5, SQL Server 2016/2017/2019 (p.9-10) | MySQL 8.4, Oracle 19c/23ai/26ai, DB2 11.5, SQL Server 2016-2022 (p.8-9) |
| Browsers | Firefox 119+, Edge 120+, Safari 17+, Chrome 120+ (p.7) | unchanged (p.6) |
| Headless (export) | Chromium 116+ (p.8) | unchanged (p.7) |
| Docker / K8s | tomcat:9.0.73-jdk11/17 images; K8s 1.25.x+ (p.20-21) | tomcat:10.1.55-jdk17/21 images; K8s 1.34+ (p.18-19) |

Changes to notice 9.0 -> 10.1: Java floor jumps 8 -> 17; Tomcat 9 -> 10.1/11
(Jakarta, happened at 10.0); PostgreSQL 12/13 dropped; MySQL 8.0 dropped;
WebSphere/WebLogic dropped; Sybase demoted Certified -> Compatible. Browsers and
headless Chromium requirements are identical across the range.

## 3. Upgrade paths and the js-upgrade flow

### Supported source versions

| Target | Direct from | Multi-hop |
|---|---|---|
| 9.0.0 | 8.0.x, 8.1.x, 8.2.x (9.0 RN p.20) | v7 -> 8.0.x first; v6 -> 7.1.x -> 8.0.x -> 9.0.0 (9.0 RN p.21) |
| 10.0.0 | 9.0, 8.0.x-8.2 (10.0 UG p.3, TOC chapters) | older via prior guides |
| 10.1.0 | 9.0.x and 10.0.x (10.1 RN p.16) | 8.x or older: use the older guides first (10.1 UG p.11) |

Compact/Split installs cannot cross during upgrade: 10.0 Compact -> 10.1 Compact
only; to end on Split, upgrade Compact->Compact then migrate Compact->Split
(10.1 UG p.82). Same rule at 9.0->10.0 (10.1 UG p.84).

### samedb vs newdb (buildomatic, run from <js-install-NEW>/buildomatic)

- samedb = in-place: `js-upgrade-samedb.bat|.sh` upgrades the war, migrates the
  existing jasperserver DB, adds new repo resources. Used for 10.0 -> 10.1
  (10.1 UG p.40,44).
- newdb = export/reimport: on the OLD server run
  `js-export.bat --everything --output-zip js-9.0-export.zip` (10.1 UG p.52), then
  on the new install `js-upgrade-newdb.bat <path>\js-9.0-export.zip` which drops
  and recreates the DB and imports the export. Used for 9.0 -> 10.1
  (10.1 UG p.53,57).
- Test mode: `js-upgrade-newdb.bat test <zip>` validates default_master.properties,
  app-server location, and DB connectivity without changing anything (10.1 UG p.45).
- Log: `<js-install>/buildomatic/logs/js-upgrade-<date>-<n>.log` (10.1 UG p.45).
- newdb does NOT import access/audit/monitoring events (since 7.9.0); reimport the
  same export zip via the UI Import page with those checkboxes ticked afterwards
  (10.1 UG p.80). On Split installs the import routes those events to the audit DB
  (10.1 UG p.57); after a Split samedb run `transfer-audit-data.bat|.sh`
  (10.1 UG p.44).
- Overlay upgrade zip (js-jrs_10.1.0_overlay.zip): commercial only, Tomcat only,
  10.0.0+ -> 10.1.0, supports rollback (10.1 UG p.9-10).

### Keystore (.jrsks) rules - the classic upgrade killer

- Before any upgrade, back up `$HOME/.jrsks` and `$HOME/.jrsksp` of the OS user who
  installed the server (10.1 UG p.28,39,51). Restore = copy back to $HOME; without
  them the login page errors out (10.1 UG p.33).
- Run all js-upgrade scripts as that same OS user (10.1 UG p.44).
- If the upgrade prompts "create a keystore": ABORT. It means the original keystore
  was not found; continuing corrupts the repository and locks out all users. Fix the
  keystore location (or point keystore.init.properties at it: WEB-INF/classes/,
  buildomatic/, buildomatic/conf_source/iePro/) and rerun (10.1 UG p.30,44,58).

### Other version-specific upgrade landmines

- License must be in place BEFORE running the upgrade; 10.x renames the license
  file (10.1 UG p.83 says jaspersoft.jrs.license; p.44 shows placing
  jasperserver.jrs.license in the user home - docs are inconsistent, check both).
- 10.0 Jakarta move: resources can stop working or change behavior purely from the
  Tomcat 10.1.x jump; custom code must move javax.* -> jakarta.* (10.1 UG p.83).
  Any custom jar in WEB-INF/lib (e.g. chart customizers) must be rebuilt/verified.
- 10.1 samedb + modern password strategy: existing user passwords need the password
  migration utility (10.1 UG p.81).
- Oracle 23ai+ repo: set new `dbVersion` property in default_master.properties so
  the right quartz DDL (quartz-23onwards.ddl) runs (10.1 UG p.82).
- UI customizations (JS/CSS) do not survive: upgrade first, then reapply on the
  new source packages and rebuild (10.1 UG p.80).
- Repo DB schema changes exist between every pair 9.0.0 / 10.0.0 / 10.1.0
  (10.1 RN p.17) - never point an old war at a new DB or vice versa.

## 4. What this means for this skill

- Cross-version promotion (promote.ps1 STAGE -> PROD) is only safe old -> new or
  same-version. Explicit doc statement: "Resources exported from version 10.1.0
  cannot be imported into older versions" (10.1 UG p.82). Assume the same for any
  newer-to-older direction (repo schema changes at every release, 10.1 RN p.17).
  Check `GET /rest_v2/serverInfo` on BOTH servers before promoting; refuse or warn
  when PROD < STAGE.
- Export/import across servers also has a key dimension: content encrypted with the
  STAGE keystore will not decrypt on PROD unless keys were exported/imported (same
  mechanism as the "export with a custom key, import the key first" recovery flow,
  10.1 UG p.44). Plain repo resources (jrxml, images, .jrtx) are unaffected.
- If PROD ever gets upgraded to 10.1: our bundled-Postgres repo must be >= 14, and
  basic-auth rest_v2 calls keep working, but any cookie/browser-session tooling
  must handle per-page CSRF tokens (10.0+ csrfguard 4.3.0).
- JRXML compatibility: a 9.0.x server runs JR Library 6.21.0; 10.x runs Library
  10.x. Reports exercising newer library features will not fill on an older PROD.
  The skill's JR7-style jrxml targets 10.x; treat any 9.0-or-older PROD as a
  compile-target downgrade and lint accordingly.
- Server upgrades of STAGE itself: back up .jrsks/.jrsksp before touching anything,
  use samedb within the 10.x line, and rerun the skill's connection tests plus a
  sample fill after (Jakarta/Tomcat jumps can silently alter resource behavior).
- `doctor.ps1` prints the serverInfo version for EVERY `environments` profile
  (STAGE and PROD side by side) and flags the chart-customizer jar as STALE when
  the server's WEB-INF/lib copy differs from the bundled one -- run it after any
  server upgrade before promoting: a 10.x jump (Jakarta) is exactly when a custom
  jar silently stops matching.
- Target-dialect SQL: `scaffold_jrxml.py --dialect x100` refuses ordered
  aggregates / ordered aggregate windows, correlated columns inside aggregates in
  subqueries and `;` inside comments before any compile, because those pass the
  JR compiler and the JRS validator and only die at fill time on an Actian
  Vector/Avalanche datasource. The default (`postgres`) is unchanged.
