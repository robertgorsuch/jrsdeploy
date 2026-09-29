# JasperReports 7 jrxml cheat-sheet (JR7-native, NOT 6.x)

JR 7.0.6 introduced a new Jackson-based jrxml schema that is **not backward
compatible** with 6.x. A 6.x jrxml will fail the JR7 loader. There is no
standalone CLI converter — to migrate a 6.x file, open it in Jaspersoft Studio
(it auto-upgrades on save). The scaffolder in this skill emits JR7-native XML
directly.

## What changed from 6.x
- **No XML namespace / DOCTYPE.** Root element is `<jasperReport name="..">`.
- `<queryString>` → `<query language="SQL">`.
- `<reportElement>` is **gone**. `x`, `y`, `width`, `height` are flattened
  directly onto the element.
- Generic element tag is `<element kind="...">` instead of `<textField>`,
  `<staticText>`, etc. being top-level tags.
- Style attributes (`fontSize`, `bold`, `forecolor`, `hTextAlign`, …) live as
  attributes on `<element>`.

## Root
```xml
<jasperReport name="my_report" language="java"
    pageWidth="595" pageHeight="842" columnWidth="555"
    leftMargin="20" rightMargin="20" topMargin="20" bottomMargin="20">
```
A4 portrait = 595×842, columnWidth = pageWidth − left − right. Letter = 612×792.

## Query + fields
```xml
<query language="SQL"><![CDATA[ SELECT ... ]]></query>
<field name="county" class="java.lang.String"/>
<field name="population" class="java.lang.Long"/>
```

## Bands
- **Single-instance bands** put `height` on the section tag itself:
  `<title height="44"> … </title>`, `<columnHeader height="18"> … </columnHeader>`,
  `<pageFooter height="16"> … </pageFooter>`, `<summary height="46"> … </summary>`.
- **Repeating / multi-band sections** wrap a `<band>`:
  `<detail><band height="13"> … </band></detail>`, and group headers/footers
  `<groupHeader><band height="24"> … </band></groupHeader>`.

## Elements
```xml
<!-- static label -->
<element kind="staticText" x="6" y="0" width="194" height="18"
    fontSize="9.0" bold="true" forecolor="#FFFFFF" vTextAlign="Middle">
  <text><![CDATA[County]]></text>
</element>

<!-- data-bound field -->
<element kind="textField" x="300" y="0" width="80" height="13"
    fontSize="8.0" hTextAlign="Right" vTextAlign="Middle" pattern="#,##0">
  <expression><![CDATA[$F{population}]]></expression>
</element>

<!-- shapes -->
<element kind="rectangle" x="0" y="0" width="555" height="18"
    mode="Opaque" backcolor="#34495E" forecolor="#34495E"/>
<element kind="line" x="0" y="12" width="555" height="1" forecolor="#EEEEEE"/>
```
- `kind` ∈ `textField | staticText | line | rectangle | image | …`
- `textField` uses `<expression>`; `staticText` uses `<text>`.
- Alignment: `hTextAlign="Left|Center|Right"`, `vTextAlign="Top|Middle|Bottom"`.
- `pattern` is a `java.text`/`DecimalFormat` pattern (`#,##0`, `#,##0.00`,
  `yyyy-MM-dd`).

## Variables and groups
```xml
<variable name="totPop" class="java.lang.Long" calculation="Sum">
  <expression><![CDATA[$F{population}]]></expression>
</variable>

<group name="DensityClass">
  <expression><![CDATA[$F{density_class}]]></expression>
  <groupHeader><band height="24"> … </band></groupHeader>
  <groupFooter><band height="6"> … </band></groupFooter>
</group>
```

## Built-ins
- `$V{PAGE_NUMBER}` — page counter. For "Page X of Y", the total-pages field
  needs `evaluationTime="Report"`.
- `$F{name}` fields, `$P{name}` parameters, `$V{name}` variables.

## Gotchas
- PDF export lives in the `jasperreports-pdf` (OpenPDF) module, **not** core.
- Field `class` must match the JDBC type (see PG→Java map in scaffold_jrxml.py):
  int4→Integer, int8→Long, numeric→BigDecimal, float8→Double, bool→Boolean,
  date→java.sql.Date, timestamp(tz)→java.sql.Timestamp, else String.
- Ground-truth reference file:
  `../../../report/tx_density_blockgroup_report_jr7.jrxml`.

### JR7 jrxml + community charts (moved from gotchas.md)
Entry ids (G1...) are stable; `gotchas.md` keeps the symptom index and links
here. Each entry: Symptom / Cause / Fix / Handled-by. Element-level truth for
every plot lives in `jr7-valid-elements.md`.

#### G1
- Symptom: 400 UnrecognizedPropertyException at fill time on a `line` chart.
- Cause: a line plot does NOT accept `showTickMarks` / `showTickLabels` (those are
  bar/stackedbar plot props). A line plot uses `showLines` / `showShapes`.
- Fix: emit the correct plot per chart type (line -> showLines/showShapes;
  bar/stackedbar -> showTickMarks/showTickLabels; area -> neither, see G55).
- Handled-by: `scaffold_jrxml.py --chart line` emits the right plot;
  `lint_jrxml.ps1` rejects tick props on a line plot.

#### G2
- Symptom: 400 UnrecognizedPropertyException at fill time on a `pie`/`pie3d` chart
  with branded gradient slices.
- Cause: two name traps. The element is repeated `<seriesColor>` (there is NO
  `<seriesColors>` wrapper), and the index attribute is `order`, NOT `seriesOrder`.
  Either wrong name throws.
- Fix: repeated `<seriesColor order="N" color="#hex"/>` under `<plot>`. Pure jrxml,
  no customizer/jar/restart. `ORDER BY <value> DESC` so the largest slice is deepest.
- Handled-by: `scaffold_jrxml.py --chart pie` (default gradient; `--no-gradient` opts out).

#### G3
- Symptom: a single-value KPI gauge deploys but returns opaque `400`s at run.
- Cause: the Pro FusionWidgets angular gauge does not fill cleanly here.
- Fix: use a JFreeChart **meter** (`shape="dial"`) instead -- a community chart that
  compiles + renders locally.
- Handled-by: `scaffold_kpi_dial.py`.

#### G4
- Symptom: dial value not displayed; the dial renders as an oval, not a circle.
- Cause: the meter's `<valueDisplay>` is unreliable; a non-SQUARE element makes the
  meter an ellipse; `meterColor`/`fontSize` are element-name traps.
- Fix: SQUARE element -> perfect circle; overlay a `textField` for the value instead
  of `<valueDisplay>`.
- Handled-by: `scaffold_kpi_dial.py` bakes all three in.

#### G5
- Symptom: a `bar` report fails to fill (no gradient styling).
- Cause: `--chart bar` is styled by `com.actian.jasper.GradientTrendCustomizer` by
  default; that is a Java class whose jar must be on the JRS classpath. Missing jar
  -> fill failure.
- Fix: build + copy `actian-chart-customizers.jar` (shipped with the skill as
  `chart_customizers/actian-chart-customizers.jar`, source under
  `chart_customizers/com/`) into `...\jasperserver-pro\WEB-INF\lib\` and restart
  Tomcat (see SKILL.md one-time block). The jar must REMAIN in `WEB-INF/lib`:
  it survives restarts but NOT a JRS reinstall/upgrade, and a target server that
  never received it (a fresh PROD, for instance) fails every customizer-styled
  report until it is copied there or the reports are re-scaffolded
  `--no-gradient`. Or opt out per-report.
- Handled-by: `scaffold_jrxml.py --no-gradient` (plain flat bars, no jar needed);
  `upgrade-migration-playbook.md` lists the jar among the things to re-verify
  after any hop.

#### G6
- Symptom: report fails to fill after a hand-edit to the SQL.
- Cause: a `<field class=...>` no longer matches the JDBC column type.
- Fix: keep `<field class>` in sync with the column type.
- Handled-by: `scaffold_jrxml.py` sets it from introspection; only an issue on manual edits.

#### G7
- Symptom: branded blue gradient / trend line not applied.
- Cause: the gradient customizer + pie seriesColor gradient apply only to `bar`
  (customizer) and `pie`/`pie3d` (seriesColor). Not bar3D / stackedbar /
  `--chart-series` multi-series.
- Fix: expected; use a supported chart type if you need the gradient.
- Handled-by: scaffolder scopes it automatically.

#### G8
- Symptom: a no-query report (e.g. static barcodes) produces 0 pages.
- Cause: with no detail rows JR emits nothing.
- Fix: set `whenNoDataType="AllSectionsNoDetail"` on the root.
- Handled-by: author per the community-component recipe. (QR also needs `zxing-core`
  on the classpath.)

#### G9
- Symptom: the Actian logo / a `repo:` image is missing in a local `RenderPng` preview.
- Cause: `repo:` refs resolve server-side at fill time, not in a local render.
- Fix: deploy + run-to-PDF to verify the image. The logo must exist once in the repo
  (`upload_file.ps1 ... -Type img`, see `jrs-rest-api.md` G42).
- Handled-by: branding is on by default in `scaffold_jrxml.py` (`--no-logo` / `--logo-uri`).

#### G10
- Symptom: subreport fails to resolve / invalid resource.
- Cause: `--subreport` URI pointed at a reportUnit instead of a jrxml file resource.
- Fix: point it at a jrxml FILE resource (e.g. `/reports/x/rpt_files/Label_main_jrxml`
  or one uploaded with `upload_file.ps1`).
- Handled-by: caller must pass a file URI.

#### G55
- Symptom: 400 UnrecognizedPropertyException at fill time on an `area` /
  `stackedArea` chart, with a plot that compiles cleanly for a bar or line chart.
- Cause: `JRAreaPlot` extends ONLY `JRCategoryPlot`; it has NEITHER
  `showTickMarks`/`showTickLabels` (bar family) NOR `showLines`/`showShapes`
  (line). Any of the four throws.
- Fix: emit a bare `<plot/>` for area charts (only the `JRCategoryPlot` extras such
  as `categoryAxisTickLabelRotation` / `valueAxisTickLabelMask` and
  `<seriesColor>` are valid). Verified: a bare `<plot/>` compiles and fills.
- Handled-by: `scaffold_jrxml.py --chart area` emits a bare plot;
  `lint_jrxml.ps1` rejects any of the four attributes on an area plot (both the
  JR7 `<plot>` inside an area chart and a legacy `<areaPlot>`). Detail:
  `jr7-valid-elements.md` section 3e.

### Data adapters (.jrdax) and style templates (.jrtx) - strict Jackson (moved from gotchas.md)

#### G11
- Symptom: 400 UnrecognizedPropertyException at fill time for a CSV-backed report
  (NOT a clean compile error).
- Cause: JR7 parses the `.jrdax` with a strict Jackson deserializer; any unknown
  element throws. JR6-era fields like `<useConnection>` are rejected.
- Fix: only these `CsvDataAdapterImpl` elements are valid: `name, fileName, dataFile,
  fieldDelimiter, recordDelimiter, useFirstRowAsHeader, columnNames, queryExecuterMode,
  datePattern, numberPattern, encoding, timeZone, locale`.
- Handled-by: author the `.jrdax` from the verified template.

#### G12
- Symptom: the style template's default style is ignored, or a generic 400 at fill.
- Cause: JR7 parses the `.jrtx` with the same strict Jackson deserializer; the
  default-style attribute is `default="true"`, NOT the 6.x `isDefault="true"`. Wrong
  name throws UnrecognizedPropertyException (surfaced as a generic 400, not a compile
  error). Source proof: `JRStyle.isDefault()` is a Jackson attribute with no
  `localName`, so the bean name is `default`; the `ATTRIBUTE_isDefault` constant and
  the class javadoc still say `isDefault` but feed only the legacy SAX writer
  (`jr7-valid-elements.md` section 2).
- Fix: use `default="true"`.
- Handled-by: `scaffold_style_template.py`.

#### G13
- Symptom: CSV report yields 0 rows, or fill error "Misplaced quote".
- Cause: (a) a UTF-8 BOM at the start of the CSV trips the parser; (b) `recordDelimiter`
  does not match the CSV's real line endings.
- Fix: strip the UTF-8 BOM; set `recordDelimiter` to `&#10;` for LF or `&#13;&#10;`
  for CRLF (JRS preserves it).
- Handled-by: prep the CSV before `upload_file.ps1`.

#### G14
- Symptom: a report with `resourceBundle="X"` fails even though `whenResourceMissingType="Key"`.
- Cause: that attribute only covers missing keys, not a missing bundle file.
- Fix: embed the `.properties` bundle in the report unit.
- Handled-by: `deploy_report.ps1 -ResourceFiles "X.properties=path"`.
