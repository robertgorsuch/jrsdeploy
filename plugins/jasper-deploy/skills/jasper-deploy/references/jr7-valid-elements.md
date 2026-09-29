# JR7 valid elements / attributes (strict-Jackson reference)

Authoritative, source-cited list of the element/attribute names that JasperReports
7.0.6 actually accepts for the constructs that bite, to back a pre-deploy linter.

## Why this matters (strict-Jackson behavior)

JR7 parses jrxml / `.jrtx` / `.jrdax` with a STRICT Jackson XML deserializer
(`FAIL_ON_UNKNOWN_PROPERTIES` is on). An unknown element or attribute throws
`UnrecognizedPropertyException` at fill time, which JasperReports Server surfaces
as an opaque HTTP `400` (often with an XML `errorDescriptor` body), NOT a clean
compile error. There are NO XSDs in JR7 -- the valid names come entirely from
Jackson annotations on the model classes in the JasperReports 7.0.6 source tree
(download from the jasperreports GitHub releases; referred to below as `<jr-src>`).

How a name is derived (precedence):
- `@JacksonXmlProperty(localName = "...")` or `@JsonProperty("...")` -> that exact name.
- `@JacksonXmlProperty(isAttribute = true)` with NO localName -> Jackson bean naming
  from the getter (`getFooBar()` -> `fooBar`; a boolean `isDefault()` -> `default`).
- `@JacksonXmlElementWrapper(useWrapping = false)` -> the child element REPEATS with
  no wrapper element (e.g. multiple `<columnNames>`, multiple `<seriesColor>`).
- `@JsonIgnore` -> the name is NOT accepted/emitted (read path).

NOTE: many legacy `JRXmlConstants.ATTRIBUTE_*` / `ELEMENT_*` string constants still
exist in the source but feed the OLD SAX/Castor writer path, not the Jackson model.
Where the legacy constant name differs from the Jackson-derived name, the Jackson
name is the one that parses (the `isDefault` vs `default` trap below is exactly this).

---

## 1. CSV data adapter (`.jrdax`)

Root element `<csvDataAdapter>` (`@JsonRootName("csvDataAdapter")`).

Source files:
- `<jr-src>\ext\data-adapters\src\main\java\net\sf\jasperreports\data\csv\CsvDataAdapterImpl.java`
- `<jr-src>\ext\data-adapters\src\main\java\net\sf\jasperreports\data\csv\CsvDataAdapter.java`
- `<jr-src>\ext\data-adapters\src\main\java\net\sf\jasperreports\dataadapters\AbstractDataAdapter.java`
- `<jr-src>\ext\data-adapters\src\main\java\net\sf\jasperreports\dataadapters\DataAdapter.java`
- `<jr-src>\ext\data-adapters\src\main\java\net\sf\jasperreports\dataadapters\AbstractClasspathAwareDataAdapter.java`

`CsvDataAdapterImpl` carries no per-getter Jackson annotations, so property names
are Jackson bean names of its getters/setters. Valid child elements:

| Element | Type / default | Source |
| --- | --- | --- |
| `name` | String (from `AbstractDataAdapter.getName`) | AbstractDataAdapter.java |
| `dataFile` | DataFile (the JR7 replacement for `fileName`; holds the `repo:`/location) | CsvDataAdapterImpl.java `getDataFile()` |
| `fileName` | String, DEPRECATED -- setter is `@JsonProperty`, getter is `@JsonIgnore`. Still ACCEPTED on input (back-compat) and converted to a `StandardRepositoryDataLocation`, but prefer `dataFile`. | CsvDataAdapter.java / CsvDataAdapterImpl.java |
| `encoding` | String | CsvDataAdapterImpl.java |
| `recordDelimiter` | String (default `"\n"`) | CsvDataAdapterImpl.java |
| `fieldDelimiter` | String (default `","`) | CsvDataAdapterImpl.java |
| `useFirstRowAsHeader` | boolean (default `false`) | CsvDataAdapterImpl.java |
| `columnNames` | List<String> -- REPEATED `<columnNames>` (no wrapper), `@JacksonXmlElementWrapper(useWrapping=false)` on `getColumnNames()` | CsvDataAdapter.java |
| `queryExecuterMode` | boolean (default `false`) | CsvDataAdapterImpl.java |
| `datePattern` | String | CsvDataAdapterImpl.java |
| `numberPattern` | String | CsvDataAdapterImpl.java |
| `locale` | Locale | CsvDataAdapterImpl.java |
| `timeZone` | TimeZone | CsvDataAdapterImpl.java |
| `class` | XML ATTRIBUTE on the root -- `DataAdapter` is `@JsonTypeInfo(use=Id.CLASS, include=As.PROPERTY, property="class")`; the serialized class name carries the subtype. | DataAdapter.java |

Note: `classpath` (repeated, no wrapper) exists only on adapters that extend
`AbstractClasspathAwareDataAdapter` -- the CSV adapter extends `AbstractDataAdapter`
directly, so `classpath` is NOT valid on a `<csvDataAdapter>`.

REJECTED JR6-era names (throw `UnrecognizedPropertyException` -> 400):
- `useConnection` -- not in the JR7 model at all.
- any wrapper element such as `<columnNames>` wrapping repeated `<columnName>`
  children -- the JR7 form is repeated `<columnNames>` elements directly.

This reconciles with SKILL.md, which lists the valid set as: `name, fileName,
dataFile, fieldDelimiter, recordDelimiter, useFirstRowAsHeader, columnNames,
queryExecuterMode, datePattern, numberPattern, encoding, timeZone, locale` --
CONFIRMED against source, with the added nuance that `fileName` is deprecated
(use `dataFile`) and `class` is a root attribute.

---

## 2. Style template (`.jrtx`)

Root element `<jasperTemplate>` (`@JsonRootName("jasperTemplate")`).

Source files:
- `<jr-src>\core\src\main\java\net\sf\jasperreports\engine\JRTemplate.java`
- `<jr-src>\core\src\main\java\net\sf\jasperreports\engine\JRStyle.java`
- `<jr-src>\core\src\main\java\net\sf\jasperreports\engine\xml\JRXmlConstants.java`

`<jasperTemplate>` children (JRTemplate.java):
| Element | Notes | Source |
| --- | --- | --- |
| `template` | `getIncludedTemplates()` -> `JRTemplateReference[]`; `@JacksonXmlProperty(localName=ELEMENT_template)` + `@JacksonXmlElementWrapper(useWrapping=false)` -- REPEATED `<template>`, no wrapper | JRTemplate.java:144-146 |
| `style` | `getStyles()` -> `JRStyle[]`; `@JacksonXmlProperty(localName=ELEMENT_style)` + unwrapped -- REPEATED `<style>`, no wrapper | JRTemplate.java:153-155 |

Default-style attribute on `<style>` -- the trap:
- `JRStyle.isDefault()` is `@JacksonXmlProperty(isAttribute = true)` with NO
  `localName` (JRStyle.java:276-277). Jackson bean-names the boolean getter
  `isDefault` to the property `default`. So the correct attribute is
  **`default="true"`**.
- REJECTED: the JR6-era **`isDefault="true"`** throws
  `UnrecognizedPropertyException` -> 400. (The constant
  `JRXmlConstants.ATTRIBUTE_isDefault = "isDefault"` at JRXmlConstants.java:347
  still exists but feeds the legacy SAX writer, NOT the Jackson model -- do not be
  misled by it. Also the class javadoc at JRStyle.java:64/74 still SAYS
  `isDefault="true"`; the javadoc is stale relative to the Jackson annotation.)

This confirms SKILL.md's `.jrtx default="true"` (not `isDefault="true"`) note.
Other `<style>` attributes are bean/localName-named on `JRStyle` getters, e.g.
`name`, `mode`, `forecolor`, `backcolor`, `fill`, `hTextAlign`, `vTextAlign`,
`fontName`, `bold`, `italic`, `underline`, `fontSize`, `pdfFontName`, `pattern`,
`blankWhenNull` (JRStyle.java:269-559), plus child `<conditionalStyle>`.

---

## 3. Charts (plots)

Source files (all under
`<jr-src>\ext\charts\src\main\java\net\sf\jasperreports\charts\`):
- `JRChartPlot.java`, `base\JRBaseChartPlot.java` (series colors, common plot attrs)
- `JRPiePlot.java`
- `JRBarPlot.java`
- `JRCommonLinePlot.java`, `JRLinePlot.java`
- `JRAreaPlot.java`, `JRCategoryPlot.java`
- `JRMeterPlot.java`

### 3a. Series colors (all plots, via JRChartPlot)

- Element is the REPEATED `<seriesColor>` (`@JacksonXmlProperty(localName =
  ELEMENT_seriesColor)` + `@JacksonXmlElementWrapper(useWrapping=false)`),
  JRChartPlot.java:167-169. There is NO `<seriesColors>` wrapper element.
- Each `<seriesColor>` (`JRSeriesColor`, impl `JRBaseChartPlot.JRBaseSeriesColor`)
  has attributes:
  - **`order`** -- `@JacksonXmlProperty(localName = "order", isAttribute = true)`,
    JRChartPlot.java:202; the constructor param is `@JsonProperty("order")` at
    JRBaseChartPlot.java:292. The Java field is `seriesOrder` but the XML name is
    `order`.
  - `color` -- attribute, JRChartPlot.java:208 / JRBaseChartPlot.java:293.
- REJECTED: **`seriesOrder`** as the attribute name, and a `<seriesColors>`
  wrapper -- either throws `UnrecognizedPropertyException`. Confirms SKILL.md.

### 3b. Pie / pie3d plot (`<piePlot>`, JRPiePlot)

Attributes (all `@JacksonXmlProperty(isAttribute=true)`, JRPiePlot.java):
`circular`, `labelFormat`, `legendLabelFormat`, `showLabels`. Plus inherited
`<seriesColor>` (3a) and the `JRChartPlot` common attrs (`backcolor`, etc.).

### 3c. Bar / bar3d / stackedbar plot (`<barPlot>`, JRBarPlot)

JRBarPlot extends `JRCategoryPlot`. Bar-specific boolean attributes
(`@JacksonXmlProperty(isAttribute=true)`, bean-named, JRBarPlot.java:47-78):
- **`showTickMarks`** (`getShowTickMarks`)
- **`showTickLabels`** (`getShowTickLabels`)
- `showLabels` (`getShowLabels`)

### 3d. Line plot (`<linePlot>`, JRLinePlot)

JRLinePlot extends `JRCategoryPlot, JRCommonLinePlot`. The line flags come from
`JRCommonLinePlot` (`@JacksonXmlProperty(isAttribute=true)`,
JRCommonLinePlot.java:44-57):
- **`showLines`** (`getShowLines`)
- **`showShapes`** (`getShowShapes`)

IMPORTANT: a line plot does NOT extend the bar plot, so **`showTickMarks` /
`showTickLabels` are REJECTED on a `<linePlot>`** (throw
`UnrecognizedPropertyException`), and conversely `showLines`/`showShapes` are
REJECTED on a `<barPlot>`. Confirms SKILL.md's line-vs-bar distinction.

### 3e. Area / stackedArea plot (`<areaPlot>`, JRAreaPlot)

JRAreaPlot extends ONLY `JRCategoryPlot` (JRAreaPlot.java:40). It has NEITHER
`showTickMarks`/`showTickLabels` NOR `showLines`/`showShapes` -- grep confirms no
such property exists on `JRAreaPlot` or `JRBaseAreaPlot`. Its content is the
`JRCategoryPlot` axis-label expressions (`categoryAxisLabelExpression`,
`valueAxisLabelExpression`, domain/range min/max value expressions,
JRCategoryPlot.java:39-64) plus `JRChartPlot` common attrs and `<seriesColor>`.
`JRCategoryPlot` also carries **`valueAxisTickLabelMask`** (a decimal-format
mask string, e.g. `"$#,##0"`, applied to the value-axis tick labels) and
`categoryAxisTickLabelRotation` -- valid on any plot in the JRCategoryPlot
family (bar, line, area), same source class.

CORRECTION to SKILL.md: SKILL.md's scaffolder note groups "area" with bar as
using `showTickMarks/showTickLabels`. Per source, an `<areaPlot>` accepts NEITHER
tick attribute -- emitting them would 400. (Stackedbar, being a bar plot, does use
the tick attributes; area does not.) A linter should treat tick attributes as
valid ONLY on bar-family plots.

### 3f. Meter / dial plot (`<meterPlot>`, JRMeterPlot)

JRMeterPlot extends `JRChartPlot` (JRMeterPlot.java). Attributes
(`@JacksonXmlProperty(isAttribute=true)` unless noted):
- `shape` (`MeterShapeEnum`, e.g. `dial`/`chord`/`circle`/`pie`), JRMeterPlot.java:79-80
- `meterAngle` (Integer), :99-100
- `units` (String), :108-109
- `tickInterval` (Double), :118-119
- `tickCount` (Integer), :126-127
- **`meterColor`** -- `@JsonGetter("meterColor")` +
  `@JacksonXmlProperty(localName = "meterColor", isAttribute = true)` mapping the
  getter `getMeterBackgroundColor()`, :134-136. The XML name is `meterColor`
  (NOT `meterBackgroundColor`).
- `needleColor` (Color), :143-144
- `tickColor` (Color), :151-152

Meter child ELEMENTS: `dataRange` (`getDataRange`), `valueDisplay`
(`getValueDisplay`), and repeated `<interval>`
(`@JacksonXmlProperty(localName="interval")` + unwrapped), JRMeterPlot.java:58-90.

`fontSize` trap (per SKILL.md): `fontSize` is a FONT/STYLE attribute
(`JRStyle.ATTRIBUTE_fontSize = "fontSize"`, used on text elements / a
`valueDisplay`'s `<font>`), NOT a direct attribute of `<meterPlot>`. Put font
sizing on the nested font, not on the meter plot element.

---

## Linter quick-reject table (JR6 name -> JR7 name)

| Construct | REJECTED (JR6 / wrong) | VALID (JR7) | Source |
| --- | --- | --- | --- |
| CSV adapter | `useConnection` | (no equivalent) | CsvDataAdapterImpl.java |
| CSV adapter file | `<fileName>` (deprecated) | `<dataFile>` | CsvDataAdapter.java |
| .jrtx default style | `isDefault="true"` | `default="true"` | JRStyle.java:276-277 |
| series color index | `seriesOrder="N"` | `order="N"` | JRChartPlot.java:202 |
| series color wrapper | `<seriesColors>...` | repeated `<seriesColor>` | JRChartPlot.java:167-169 |
| line plot | `showTickMarks`/`showTickLabels` | `showLines`/`showShapes` | JRCommonLinePlot.java:44-57 |
| bar plot | `showLines`/`showShapes` | `showTickMarks`/`showTickLabels` | JRBarPlot.java:47-60 |
| area plot | `showTickMarks`/`showTickLabels`/`showLines`/`showShapes` | (none -- not supported) | JRAreaPlot.java:40 |
| meter color | `meterBackgroundColor` | `meterColor` | JRMeterPlot.java:134-136 |
