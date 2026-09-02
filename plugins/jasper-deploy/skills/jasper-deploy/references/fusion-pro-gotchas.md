# FusionMaps / FusionWidgets (Pro) gotchas — reverse-engineered

Pro fusion components (`xmlns:fm="http://jaspersoft.com/fusion"`) are parsed by a
strict Jackson deserializer and rendered server-side. They **cannot be compiled
locally** (the open-source lib lacks the classes), so a bad element surfaces only
as an opaque `400 "JRXML.content is invalid"` on deploy — with no hint which
element is wrong. The notes below are the ones that cost trial-and-error.

## Debugging strategy
- **Community charts/widgets** (JFreeChart pie/bar/line/area/meter/thermometer):
  compile LOCALLY first (`compile_jrxml.ps1`). Jackson throws a precise
  `UnrecognizedPropertyException` naming the bad field + the list of valid ones —
  far faster than server round-trips.
- **Pro components** (FusionMaps `fm:map`, FusionWidgets `fm:angularGauge`): can't
  compile locally → iterate by deploy + run-to-PDF + rasterize (pypdfium2). Bisect
  by removing suspect elements when you hit the opaque 400.

## FusionMaps (`fm:map`)
- **Valid `fm:entity` children only:** `idExpression`, `valueExpression`,
  `labelExpression`, `colorExpression`. **`displayValueExpression` is NOT valid**
  (it caused an opaque 400). To show a second measure, fold it into
  `labelExpression`.
- **Outer frame** = the *canvas* border, not the chart border. Kill it with
  `showCanvasBorder=0` + `canvasBorderThickness=0` (mapProperty). `showBorder=0`
  alone does nothing to that frame.
- **Legend position** supports only **BOTTOM or RIGHT** (the renderer is binary —
  no LEFT/TOP). For a left/custom legend: hide the built-in one (`showLegend=0`),
  shift the map right (component `x`), and draw your own swatches (`<rectangle>` +
  `<staticText>` per color band).
- **Label contrast:** `baseFontColor` sets the on-map data-label color (use white
  over dark fills); it ALSO whitens the legend, so set `legendItemFontColor` back
  to a dark color so the legend stays readable on the white page.
- **Entity ids** for the World / NorthAmerica maps are zero-padded country keys:
  USA=`023`, Mexico=`016`, Canada=`005` (the bundled World Map sample uses the
  2-digit `23`/`16`/`05` on `WorldwithCountries`). Map name in
  `mapNameExpression` matches the JS file's registered name (e.g. `"NorthAmerica"`,
  `"Texas"`, `"WorldwithCountries"`). Map JS lives in
  `…/jasperserver-pro/fusion/maps/fusioncharts.<map>.js`.
- A map/chart in a band that fills before row iteration (e.g. `title`) needs
  `evaluationTime="Report"` or it binds zero data.
- **Texas map keys are 3-digit FIPS strings.** `fusioncharts.texas.js` writes
  FIPS < 100 as quoted zero-padded keys (`"001"`) and >= 101 as bare ints (`113`).
  Bind `idExpression` to the raw `countyfp` (`'001'`), never `(countyfp::int)::text`
  (`'1'`): the cast leaves 50 counties unbound and they render in the default fill
  with no error. Diff keys vs data with
  `curl <server>/fusion/maps/fusioncharts.texas.js` + a regex on `"(\d+)":\{outlines`.

## KPI gauges — prefer the JFreeChart meter over the Pro angular gauge
- **FusionWidgets `fm:angularGauge`** is Pro-only and deploys with an opaque 400
  that's very hard to diagnose (no local compile, no bundled jrxml sample). Avoid
  it for a simple KPI dial.
- Use the **community JFreeChart meter** instead (`<element kind="chart"
  chartType="meter">`, `shape="dial"`). It compiles + renders locally. Scaffold it
  with **`scaffold_kpi_dial.py`** (bakes in the rules below).
- Meter specifics:
  - **SQUARE chart element → perfect-circle dial.** A non-square element renders
    an ellipse.
  - The meter's own **`<valueDisplay>` does not render reliably** — overlay a
    `textField` (evaluationTime="Report") centered in the circle for the value.
  - Plot is `<plot shape="dial" units="…" tickCount="…" meterAngle="180"
    needleColor= tickColor=>` with `<dataRange><lowExpression>/<highExpression>`,
    optional `valueDisplay`, and `<interval label= backgroundColor=>` color zones.
  - Element-name gotchas: the dial-face color is **`meterColor`** (not
    `meterBackgroundColor`); a `<font>`'s size attr is **`fontSize`** (not `size`).
