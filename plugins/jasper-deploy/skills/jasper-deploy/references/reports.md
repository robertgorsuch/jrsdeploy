# Reports — scaffold, style, compile, run, visualize

Deep reference for producing a single JasperReports report. SKILL.md has the
lean happy-path; this file holds every flag, the verified gotchas, and the
visualization-component syntax. `$skill` = the skill's `scripts/` dir (see
SKILL.md "Conventions").

## Scaffold a JR7 jrxml from SQL — `scaffold_jrxml.py`
Introspects a query's result columns (via a psql TEMP VIEW over
`information_schema`), maps PostgreSQL types to Java field classes, and emits a
tabular JR7 report (title, column header, detail band, page footer "Page X of Y").

```powershell
$env:PGPASSWORD = "postgres"
python $skill\scaffold_jrxml.py `
    --name county_summary `
    --title "Texas County Edge Summary" `
    --subtitle "From the TIGER geocoder load" `
    --query "SELECT c.name AS county, count(*)::int AS edge_count FROM tiger_data.tx_edges l JOIN tiger.county c ON c.statefp='48' AND c.countyfp=l.countyfp GROUP BY 1 ORDER BY 2 DESC" `
    --out report\county_summary.jrxml
```
Use `--query-file q.sql` for long queries. Options: `--db --host --port --user`
(defaults: postgis_34_sample / localhost / 5432 / postgres), `--page-size
a4|letter`, `--landscape`. The scaffold is a starting point — refine layout by
hand using `references/jr7-schema.md`, or open it in Jaspersoft Studio.

Field `class` must match the JDBC column type or fill fails — the scaffolder
handles this; if you hand-edit the SQL, keep `<field class>` in sync.

### Visual template — `--template`
`slate|corporate|forest|minimal|dark` (default `slate`, the original look). The
theme sets the column-header band, title/subtitle, group band, row-rule and
footer colors; `minimal` paints no header fill (dark header text + an underline
rule) for a clean look. **Verified:** all themes compile JR7-clean and render
(corporate = filled deep-blue header + blue title; minimal = underline style),
data identical across themes. To add a palette, extend the `THEMES` dict in
`scaffold_jrxml.py`.

### JFreeChart chart in the summary band — `--chart`
```powershell
python $skill\scaffold_jrxml.py --name metro_pop --chart bar `
    --query "SELECT metro, sum(pop)::bigint AS population FROM ... GROUP BY metro" `
    --out report\metro_pop.jrxml
```
`--chart` = `pie|pie3d|bar|bar3d|line|area|stackedbar`. The category column
defaults to the first text column and the value to the first numeric column;
override with `--chart-category`, `--chart-value`, `--chart-series` (multi-series
category charts), `--chart-height`. Best with a small number of categories.
`--chart-label-rotation -45` rotates category-axis tick labels so long bar/line
labels don't truncate. (The scaffolder emits the correct JR7 plot per chart type;
plot props are per-class and the strict Jackson loader rejects any the class does
not declare: `line` uses `showLines/showShapes`; `bar`/`bar3d`/`stackedbar` use
`showTickMarks/showTickLabels`; **`area` (`JRDesignAreaPlot`) accepts NEITHER pair**
— it gets a bare `<plot/>` (only `categoryAxisTickLabelRotation` is valid). The
wrong pair throws `UnrecognizedPropertyException` at compile/fill. `lint_jrxml.ps1`
catches it; per-class valid lists are in `references/jr7-valid-elements.md`.)

### Advanced report features (all on `scaffold_jrxml.py`, all verified)
- `--param NAME:TYPE[:DEFAULT]` — a report parameter used as `$P{NAME}` in the
  query (TYPE = string|integer|long|decimal|double|boolean|date|timestamp).
  Introspection substitutes the default literal for `$P{..}` so psql can run the
  query; the jrxml keeps `$P{..}`. Pair with `deploy_report.ps1 -Control` for an
  interactive prompt (see admin-and-scheduling.md). Run-time override:
  `…/rpt.pdf?NAME=value`.
- `--group-by COLUMN` — group header + a subtotal footer summing every numeric
  column (the query should `ORDER BY COLUMN`).
- `--highlight "COL:OP:VALUE:#COLOR"` — a `<conditionalStyle>` shading the cell
  when the condition holds (numeric `> >= < <= == !=`; strings `== / !=`).
- `--drill "COL:TARGET_URI[:p=COL2;..]"` — COL becomes a ReportExecution
  hyperlink running TARGET_URI with row values as params.
- `--crosstab ROW:COL:MEASURE` — a JR7-native pivot (rows × columns, Sum of
  MEASURE) with row/column totals + grand total, instead of the flat table.
- `--subreport JRXML_FILE_URI[:p=COL;..]` — embed a child report in the summary
  band on the parent connection. The URI must point to a jrxml **file** resource
  (e.g. `/reports/x/rpt_files/Label_main_jrxml`, or one uploaded with
  `upload_file.ps1`) — not a reportUnit.

## Shared style templates (.jrtx) — `scaffold_style_template.py`
Instead of repeating inline colors/fonts in every report, factor styling into a
**shared style template** (`.jrtx`) deployed once and referenced by many reports
— change the `.jrtx`, redeploy it, and every consuming report restyles.

`scaffold_style_template.py` emits a JR7 `.jrtx` (root `<jasperTemplate>` with
named `<style>`s) from the same palettes as `--template`:
```powershell
python $skill\scaffold_style_template.py --name jd_corporate --palette corporate `
    --out report\jd_corporate.jrtx      # palette in slate|corporate|forest|minimal|dark; --font, --base-size
```
Styles emitted: `jdBase` (the **default** style — sets fontName/base color for
every text element), plus `jdTitle/jdSubtitle/jdColumnHeader/jdDetail/
jdGroupHeader/jdGroupFooter/jdPageFooter` for hand-referencing via `style="…"`.
Deploy the `.jrtx` as a repository **file** resource, then reference it from a
scaffold with `--style-template`:
```powershell
& $skill\upload_file.ps1 -File report\jd_corporate.jrtx -Uri /styles/jd_corporate -Type xml -Overwrite
python $skill\scaffold_jrxml.py --name styled_rpt --style-template /styles/jd_corporate `
    --query "SELECT …" --out report\styled_rpt.jrxml   # emits <template><![CDATA["repo:/styles/jd_corporate"]]></template>
```
`--style-template` wraps a leading-`/` value as `repo:URI`; JRS resolves it at
fill time and applies the template's default style. **Verified end-to-end**
(deploy + run-to-PDF, `200` + `%PDF-`). **Gotcha:** JR7 parses the `.jrtx` with
the same strict Jackson deserializer as a `.jrdax` — the default-style attribute
is **`default="true"`**, NOT the 6.x `isDefault="true"` (a wrong name throws
`UnrecognizedPropertyException` at fill time as a generic `400`, not a clean
compile error).

## Compile — `compile_jrxml.ps1`
Compiles against the JR7 runtime. A clean compile is the fastest check that the
jrxml is JR7-valid before deploying.
```powershell
& $skill\compile_jrxml.ps1 -Jrxml report\county_summary.jrxml
```
(The SLF4J "No providers" lines are harmless.) To preview a PDF locally, fill
the `.jasper` against the DB with the existing `report\FillReport.java` helper.

**JR runtime lib dir** resolves via `-LibDir` → `$env:JR_LIB_DIR` →
`jrs.config.json` `jrLibDir` → the machine default; set `jrLibDir` on a fresh
clone. The shared `Invoke-JrCompile` helper also absorbs the harmless
SLF4J-on-stderr that would otherwise abort a `$ErrorActionPreference=Stop` caller.

A clean local compile does NOT catch the leading-`WITH` CTE security-validator
rejection (the CTE is valid JR/SQL) — see the SQL gotcha in SKILL.md.

## Run / export / verify a deployed report
Synchronous run to PDF:
```powershell
curl.exe -s -u "${user}:${pass}" -o out.pdf `
    "http://localhost:8081/jasperserver-pro/rest_v2/reports/reports/geocoder/county_summary.pdf"
```
A `200` and a `%PDF-` file confirm JRS compiled the jrxml, connected through the
datasource, filled, and exported.

**Other export formats** — same synchronous endpoint, different extension.
**Verified on this server** (all `200` with real content): `.xlsx`, `.csv`,
`.docx`, `.pptx` (also `.rtf`, `.ods`, `.odt`, `.xml`). The magic bytes differ
per format (`PK` for the Office/OpenDocument zip formats), so verify by HTTP
`200` + a non-trivial byte size rather than `%PDF-`.

**Verify content + visuals (not just HTTP 200)** — `verify_report.ps1` asserts
more than a `%PDF-`: the format returns `200` + right magic + non-trivial size;
the CSV export has `>= -MinRows` data rows and contains every `-Contains` string;
and page 1 rasterized matches a committed `-Baseline` PNG within `-MaxPixelDiff`
(mean abs pixel diff; `-UpdateBaseline` / a missing baseline saves it). `-Params
@{name="val"}` sets run params. Throws on any failed assertion.
```powershell
& $skill\verify_report.ps1 -Uri /reports/foodmart/foodmart_top_categories `
    -MinRows 10 -Contains "Vegetables","Snack Foods" -Baseline baselines\top_categories.png
```

**Thumbnail — the cheapest visual check** — `get_thumbnail.ps1` fetches the
server's stored preview image (**JPEG** on this install) of a report's last
**UI** execution via `GET /rest_v2/thumbnails{uri}`; REST-only runs do not
refresh it. By default the generic placeholder is returned for a never-UI-run
report; `-NoDefault` instead exits 2 on the 204 so you can tell them apart.
Send no `Accept: image/*` header (it `406`s — the script handles this).
```powershell
& $skill\get_thumbnail.ps1 -Uri /reports/foodmart/foodmart_sales_by_region
& $skill\get_thumbnail.ps1 -Uri /reports/geocoder/county_summary -Out county.jpg -NoDefault
```

**Verify a whole folder** — run each to PDF and check HTTP code + `%PDF-` magic +
non-trivial byte size. (Do NOT count `/Type /Page` objects — the page tree is
usually compressed, so the grep reads 0 on a perfectly good PDF.) A `400` with an
XML `errorDescriptor` body (magic `<?xml`) is a fill failure — read it; a
leading-`WITH` CTE in the query is a common cause.
```bash
base="http://localhost:8081/jasperserver-pro/rest_v2/reports/reports/geocoder"
for r in county_summary metro_population_piechart tx_addr_zip_summary; do
  curl.exe -s -u "$user:$pass" -o "out/$r.pdf" -w "%{http_code}" "$base/$r.pdf"
  echo "  $r  $(head -c5 out/$r.pdf)  $(stat -c%s out/$r.pdf)b"
done
```
**Open a deployed folder in the JRS web UI:**
`http://localhost:8081/jasperserver-pro/flow.html?_flowId=searchFlow&folderUri=/reports/geocoder`

**Preview locally as an image** (handy for charts) — fill + render a page to PNG:
```powershell
$env:PGPASSWORD = "postgres"
java --class-path "$env:JR_LIB_DIR\*" `
    report\RenderPng.java report\my_report.jasper out.png   # optional 3rd arg = page index
```

### deploy_report.ps1 result object and existence checks

`deploy_report.ps1` writes ONE object to the pipeline when it succeeds
(`New-JrsDeployResult` in `_jrs_common.ps1`): `Uri`, `Code` (HTTP), `Status`
(`OK`), `ControlsAttached` (int), `Message`. The progress lines still go to
the host stream, which a `2>&1` redirect does NOT capture under Windows
PowerShell 5.1 -- test the object, not the text:
```powershell
$r = & .\deploy_report.ps1 -Jrxml report\x.jrxml -TargetUri /reports/x -Overwrite -Env stage
if ($r.Status -ne "OK") { throw $r.Message }
$r.ControlsAttached      # 0 unless -Control/-QueryControl were given
```
Failures throw (exit code 1 under `powershell -File`). A 403/400
`resource.in.use` -- the report is a dashlet of a live dashboard; the lock
blocks `?overwrite=true` as well -- is explained with the dashboard(s) that
reference it (`Get-JrsDashboardsReferencing`) and the way out:
`compose_dashboard.ps1 -Manifest ... -Replace -Backup` to export,
drop and recompose the owning dashboard.

Existence checks: `Invoke-JrsGet` returns `{ Code = "404" }` instead of
throwing, so `if (Invoke-JrsGet ...)` is always true. Use the helpers:
```powershell
. .\scripts\_jrs_common.ps1
$jrs = Resolve-JrsConfig -Env stage
Test-JrsResource   -Jrs $jrs -Uri /reports/x                    # [bool], $true only on HTTP 200
Assert-JrsResource -Jrs $jrs -Uri /reports/x -What "report unit" # throws "report unit not found on <server> [env stage]: /reports/x (HTTP 404)"
Test-JrsResource -Uri /reports/x -Env prod                       # resolves the server itself when -Jrs is omitted
```
For a whole dashboard suite (exists + render + byte-diff against git +
controls) use `verify_suite.ps1` -- see `references/ci-smoke.md`.

### Big reports — async execution (`reportExecutions`)
The synchronous `/reports/{uri}.{fmt}` endpoint blocks until the fill finishes
and can time out on large reports (the `tx_density_blockgroup_report*` reports
are ~1 MB / tens of thousands of rows). The async service queues the fill and
lets you poll. **Verified round-trip on this server.** The
`run_report_async.ps1` wrapper (see admin-and-scheduling.md) does submit → poll →
download; the raw recipe (NOTE: pass the JSON body from a **file** — an inline
`-d '{...}'` gets its quotes mangled and the server 400s `serialization.error`):
```powershell
'{"reportUnitUri":"/reports/geocoder/county_summary","outputFormat":"pdf","interactive":false,"async":true}' |
    Set-Content out\req.json -Encoding utf8
$rid = (curl.exe -s -u "${user}:${pass}" -H "Content-Type: application/json" -H "Accept: application/json" `
    --data "@out\req.json" "http://localhost:8081/jasperserver-pro/rest_v2/reportExecutions" | ConvertFrom-Json).requestId
# poll until ready -> {"value":"ready"}
curl.exe -s -u "${user}:${pass}" -H "Accept: application/json" ".../rest_v2/reportExecutions/$rid/status"
# download (exportId from GET .../reportExecutions/$rid -> exports[0].id)
curl.exe -s -o out.pdf -u "${user}:${pass}" ".../rest_v2/reportExecutions/$rid/exports/$exportId/outputResource"
```

## Bulk deploy (e.g. the JR Library demo samples) — `deploy_jr_samples.ps1`
Walks a folder of `.jrxml`, deploys each under `-TargetRoot`, and runs it to PDF
to verify (writes a results CSV). A report with no `<query>` is "standalone"
(deploys + runs on an empty data source); reports WITH a query are skipped unless
you pass `-DataSourceUri`.
```powershell
& $skill\deploy_jr_samples.ps1 -SamplesDir <jr-src>\demo\samples
& $skill\deploy_jr_samples.ps1 -SamplesDir ...\demo\samples\charts -DataSourceUri /datasources/postgis_34_sample
```
The JR Library `charts` samples query an HSQLDB demo DB (`SELECT * FROM Orders`).
`report\translate_hsqldb_demo.py` translates `demo/hsqldb/test.script` →
PostgreSQL (handles `CREATE MEMORY TABLE` and `\uXXXX` escapes) so the tables
load into `postgis_34_sample` and the samples run against the existing data
source. Caveat: many library samples rely on parameters the Java harness supplies
(e.g. `MaxOrderID`) — without a default they render blank; pass them at run time
(`...PieChartReport.pdf?MaxOrderID=11077`) or bake in defaults.
`report\inject_chart_defaults.py` does the latter for the charts samples (injects
`<defaultValueExpression>` into self-closing `<parameter>` tags) so they render
with content from the JRS UI with no input. A `200`+valid-PDF only means it ran,
not that it has content — spot-check pages.

## File resources & CSV data adapters — `upload_file.ps1`
Uploads any local file to JRS as a repository file resource (REST v2) —
CSV/image/font/properties referenced by reports:
```powershell
& $skill\upload_file.ps1 -File data\foo.csv -Uri /reports/jr_samples/data/foo -Type csv
```
Verified: the file uploads and is retrievable at its repo URI, byte-intact.

**CSV-backed reports** reference a CSV via a `.jrdax` data adapter (a
`<csvDataAdapter>` with `fileName`=`repo:/path`, `useFirstRowAsHeader` or explicit
`columnNames`, `recordDelimiter` (CRLF=`&#13;&#10;`, preserved by JRS),
`fieldDelimiter`, `datePattern`, `queryExecuterMode`). Set the adapter on the
relevant `<dataset>`/subDataset with a `net.sf.jasperreports.data.adapter`
property (= the adapter's `repo:` URI) and remove any `dataSourceExpression`.
Upload the CSV and the `.jrdax` with `upload_file.ps1`; deploy companion
resources (resource bundles, images) embedded in the report unit with
`deploy_report.ps1 -ResourceFiles "name=path"`.

**Verified (subdataset adapters):** the `chartthemes` AllChartsReport (5 CSVs via
subdataset adapters) renders all chart themes this way.
**Verified (single-CSV main report, end-to-end):** `csv_metro_pop.jrxml` reads a
7-row CSV as its **main** dataset — no JDBC datasource, no `<query>` — via a
report-level `net.sf.jasperreports.data.adapter` property pointing at
`metro_pop_adapter.jrdax`; fields map to columns by header
(`useFirstRowAsHeader`), and a numeric column declared `class="java.lang.Integer"`
is summed in a variable (the adapter does the String→Integer conversion). Flow:
upload the CSV + `.jrdax` (`upload_file.ps1`), deploy the report **with no
datasource** (the "won't run until a datasource is attached" warning is expected
and wrong for adapter-backed reports), run to PDF → all rows render.

Gotchas that cause a silent 0-row or a fill error:
1. **Strip the UTF-8 BOM** from the CSV — it trips the parser with "Misplaced
   quote"; match `recordDelimiter` to the CSV's real line endings (`&#10;` for LF,
   `&#13;&#10;` for CRLF).
2. A report with `resourceBundle="X"` needs the `.properties` bundle embedded
   (`-ResourceFiles "X.properties=..."`) even with `whenResourceMissingType="Key"`
   (that only covers missing keys, not a missing bundle).
3. **JR7 parses the `.jrdax` with strict Jackson** — an unknown element throws
   `UnrecognizedPropertyException` at fill time (`400`), NOT a clean compile error.
   JR6-era fields like `<useConnection>` are rejected; the only valid
   `CsvDataAdapterImpl` elements are: `name, fileName, dataFile, fieldDelimiter,
   recordDelimiter, useFirstRowAsHeader, columnNames, queryExecuterMode,
   datePattern, numberPattern, encoding, timeZone, locale`.

The single-CSV *query-executer* report (`csvdatasource`, empty
`<query language="csv">`) is still a harder case — build that one in Jaspersoft
Studio — but the property-on-main-dataset form above needs no Studio.

## Visualization components
Two tiers. **Community** components compile + preview locally (RenderPng) *and*
deploy. **Pro** components are authored in the legacy 6.x jrxml format and only
render server-side on JRS Pro — the open-source lib can't compile them, so
validate them by **deploy → run-to-PDF** (a `200` + a non-trivial PDF, and the
`.html` export containing the component markup, confirm a render).

**Verified (both tiers, end-to-end):** Community — `compile_jrxml.ps1` → `.jasper`
then `RenderPng` → PNG for JFreeChart pie/bar (`metro_population_piechart`,
`metro_population_bar`), spider/radar (`metro_population_spider`), and barcode4j
QR/DataMatrix/Code128 (`barcode_demo`) — all render offline from the local jars,
content matching the data. Pro — deploy → run-to-PDF → rasterize for HTML5
HighCharts (`metro_population_html5`) and FusionMaps choropleth
(`tx_county_density_map`, `tx_county_population_map`) — both render server-side
with correct data. (RenderPng note: the SLF4J "no providers" line goes to stderr;
under PowerShell `$ErrorActionPreference="Stop"` that can abort a wrapper script
even on a clean exit 0 — invoke the `java` compiler/renderer directly, or check
the `.jasper`/`.png` output rather than trusting the pipeline's error state.)

### Community (local + deploy)
Extra jars in the `JR_LIB_DIR` jar directory (outside this repo — rebuild
on a fresh clone, see below): `jasperreports-charts-7.0.6.jar`,
`jfreechart-1.5.6.jar`, `jasperreports-barcode4j-7.0.6.jar`, `barcode4j-2.1.jar`,
`zxing-core-3.4.0.jar`.

| Component | JR7 jrxml | Example |
|---|---|---|
| JFreeChart (pie/bar/line/area/…) | `<element kind="chart" chartType="…">` + `<dataset kind="pie\|category">` + `<plot>` | `metro_population_piechart.jrxml`, `metro_population_bar.jrxml` |
| Spider / radar | `<element kind="component"><component kind="spiderChart">` (chartSettings/dataset series-category-value/plot) | `metro_population_spider.jrxml` |
| Barcodes / QR | `<element kind="component"><component kind="barcode4j:QRCode\|DataMatrix\|Code128\|…">` + `<codeExpression>` | `barcode_demo.jrxml` |

Pie label tokens: `{0}`=key, `{1}`=value, `{2}`=percentage. A no-query report
(e.g. static barcodes) needs `whenNoDataType="AllSectionsNoDetail"` on the root
or it produces 0 pages. QR specifically needs `zxing-core` on the classpath.

**Rebuild the community jars** from the JR7 source (machine-local, not in repo):
```powershell
# Windows: $env:JAVA_HOME = "C:\path\to\jdk-11"
# macOS:   $env:JAVA_HOME = "/opt/homebrew/opt/openjdk@11"  (or $(/usr/libexec/java_home -v 11))
$env:JAVA_HOME = "C:\path\to\jdk-11"
mvn -f "<jr-src>/pom.xml" `
    -pl ext/charts,ext/barcode4j -am --% -Dmaven.test.skip=true package
```
Copy the built `ext\charts\target\jasperreports-charts-7.0.6.jar` and
`ext\barcode4j\target\jasperreports-barcode4j-7.0.6.jar`, plus from `~\.m2`:
`org\jfree\jfreechart\1.5.6\jfreechart-1.5.6.jar`,
`net\sf\barcode4j\barcode4j\2.1\barcode4j-2.1.jar`,
`com\google\zxing\core\3.4.0\core-3.4.0.jar` (→ `zxing-core-3.4.0.jar`), into
your `JR_LIB_DIR` jar directory. (JFreeChart 1.5.x bundles jcommon.)

### Pro (server-rendered only; deploy → run to validate)
Authored in legacy 6.x jrxml
(`xmlns="http://jasperreports.sourceforge.net/jasperreports"`,
`<componentElement>`, `<queryString>`, `<reportElement>`). The whole file must be
6.x — you can't mix JR7-native with these. JRS's `legacy-jrxml-*` modules convert
at fill time; **skip local compile**, deploy and run.

| Component | jrxml | Example |
|---|---|---|
| HTML5 charts (HighCharts) | `<hc:chart xmlns:hc="http://jaspersoft.com/highcharts" type="Column\|StackedBar\|…">` with `<hc:chartSetting>` + `<multiAxisData>` (`dataAxis` row buckets + `multiAxisMeasure`) | `metro_population_html5.jrxml` |
| FusionMaps choropleth | `<fm:map xmlns:fm="http://jaspersoft.com/fusion">` with `<fm:mapNameExpression>`, `<fm:colorRange>`s, `<fm:mapDataset><fm:entity>` (idExpression + valueExpression) | `tx_county_density_map.jrxml` |

**Gotcha:** a chart/map component bound to the main dataset and placed in a band
that fills *before* row iteration (e.g. `title`) must set
**`evaluationTime="Report"`**, or it binds zero data and renders blank/uniform
(no error). Put it in `summary`, or keep it in `title` with that attribute.

**Preview a Pro report as an image** (no local renderer for Pro components — use
the server's PDF and rasterize it): run to PDF, then
```bash
python -m pip install pypdfium2 Pillow   # one-time
python -c "import pypdfium2 as p; p.PdfDocument(r'out.pdf')[0].render(scale=3).to_pil().save(r'out.png')"
```

FusionMaps geometry lives in `…\jasperserver-pro\fusion\maps\fusioncharts.*.js`.
The installed **`Texas`** map (`fusioncharts.texas.js`) is keyed by **3-digit county
FIPS**: FIPS < 100 are quoted, zero-padded keys (`"001"`, `"029"`), FIPS >= 101 are
bare integers (`113`, `201`). Bind `idExpression` to the raw `countyfp` string — NOT
`(countyfp::int)::text`, which silently unbinds the 50 sub-100 counties (they fall to
the map's default fill; `tx_county_density_heatmap.jrxml` is the corrected form). Other Pro options present on this server: Fusion charts/gauges/widgets
(`jasperreports-fusion`), HighCharts heatmap/treemap/solid-gauge, and Ad Hoc
views/dashboards (web-UI, not jrxml). Get jrxml syntax from the bundled samples,
e.g. fetch `/public/Samples/Reports/ProfitDetailReport` (HTML5) or
`/public/Samples/Reports/14._World_Map` (FusionMaps) jrxml via REST.

## Reference reports known to compile and render
- `..\..\report\tx_density_blockgroup_report_jr7.jrxml` (tabular + groups)
- `..\..\report\metro_population_piechart.jrxml` (pie chart)

## Style templates / charts: gotchas
The failure modes for `.jrtx` style templates and JFreeChart plots live with the
element reference, not here:
- `jr7-schema.md` G12: the default-style attribute is `default="true"`, never the
  6.x `isDefault="true"` (strict Jackson throws a generic 400 at fill).
- `jr7-schema.md` G1 / G55: line plots take `showLines`/`showShapes`; bar and
  stackedbar take `showTickMarks`/`showTickLabels`; an area plot takes NEITHER,
  so `--chart area` emits a bare `<plot/>`. `lint_jrxml.ps1` enforces all three.
- `jr7-schema.md` G2: pie gradients are repeated `<seriesColor order=...>`.
- `jr7-schema.md` G5: `--chart bar` gradients need
  `chart_customizers/actian-chart-customizers.jar` in the server's `WEB-INF/lib`
  (survives restarts, not a reinstall); `--no-gradient` needs no jar.
- Symptom lookup for all of the above: `gotchas.md`.
