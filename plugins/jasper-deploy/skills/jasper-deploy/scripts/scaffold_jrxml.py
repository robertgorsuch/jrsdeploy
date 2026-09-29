#!/usr/bin/env python3
"""Scaffold a JasperReports 7 (JR7-native) .jrxml from a SQL query.

Introspects the query's result columns by creating a TEMP VIEW over it and
reading information_schema.columns (via psql), maps PostgreSQL types to Java
field classes, and emits a tabular JR7 report: title, columnHeader, detail
band, and pageFooter. The output mirrors the idioms in the known-good
tx_density_blockgroup_report_jr7.jrxml so it compiles with JasperReports 7.0.6.

JR7 is NOT 6.x-compatible: no XML namespace, root is <jasperReport name=..>,
<query> (not <queryString>), and elements use <element kind=".." x= y= ..>
with x/y/width/height flattened on (no <reportElement>).

psql must be on PATH; the DB password is read from the PGPASSWORD env var.
"""
import argparse
import csv
import io
import os
import subprocess
import sys
from xml.sax.saxutils import escape

# --- PostgreSQL (udt_name) -> Java field class -------------------------------
UDT_TO_JAVA = {
    "int2": "java.lang.Integer",
    "int4": "java.lang.Integer",
    "int8": "java.lang.Long",
    "numeric": "java.math.BigDecimal",
    "float4": "java.lang.Double",
    "float8": "java.lang.Double",
    "bool": "java.lang.Boolean",
    "date": "java.sql.Date",
    "timestamp": "java.sql.Timestamp",
    "timestamptz": "java.sql.Timestamp",
    "time": "java.sql.Time",
    "timetz": "java.sql.Time",
}

NUMERIC_JAVA = {"java.lang.Integer", "java.lang.Long"}
DECIMAL_JAVA = {"java.math.BigDecimal", "java.lang.Double"}


def java_class(udt_name: str) -> str:
    return UDT_TO_JAVA.get(udt_name.lower(), "java.lang.String")


def display_pattern(jclass: str):
    if jclass in NUMERIC_JAVA:
        return "#,##0"
    if jclass in DECIMAL_JAVA:
        return "#,##0.00"
    if jclass == "java.sql.Date":
        return "yyyy-MM-dd"
    if jclass == "java.sql.Timestamp":
        return "yyyy-MM-dd HH:mm"
    return None


def is_right_aligned(jclass: str) -> bool:
    return jclass in NUMERIC_JAVA or jclass in DECIMAL_JAVA


def label_for(col: str) -> str:
    """county_pop -> 'County Pop'."""
    return " ".join(w.capitalize() for w in col.replace("_", " ").split())


# --- visual templates (color/style palettes) --------------------------------
# Keys threaded through build_jrxml so the scaffold isn't one hardcoded look:
#   header_bg  : column-header band fill (None = no fill -> dark text + rule)
#   header_fg  : column-header text color
#   title_fg   : title text color           subtitle_fg : subtitle text color
#   group_bg   : --group-by header band fill group_fg    : group header text
#   rule       : detail/row separator line color
#   footer_fg  : page-footer text color      title_size  : title font size (pt)
THEMES = {
    # the original look (unchanged default), so existing output is byte-stable
    "slate": {
        "header_bg": "#34495E", "header_fg": "#FFFFFF",
        "title_fg": "#000000", "subtitle_fg": "#666666",
        "group_bg": "#EAF2F8", "group_fg": "#000000",
        "rule": "#EEEEEE", "footer_fg": "#666666", "title_size": 16.0,
    },
    "corporate": {
        "header_bg": "#1F4E79", "header_fg": "#FFFFFF",
        "title_fg": "#1F4E79", "subtitle_fg": "#5B7DA6",
        "group_bg": "#DCE6F1", "group_fg": "#1F4E79",
        "rule": "#D6E0EF", "footer_fg": "#5B7DA6", "title_size": 17.0,
    },
    "forest": {
        "header_bg": "#2E5E3A", "header_fg": "#FFFFFF",
        "title_fg": "#1E3D26", "subtitle_fg": "#6B8E73",
        "group_bg": "#E3EFE5", "group_fg": "#1E3D26",
        "rule": "#D5E5D8", "footer_fg": "#6B8E73", "title_size": 16.0,
    },
    "minimal": {
        "header_bg": None, "header_fg": "#222222",
        "title_fg": "#111111", "subtitle_fg": "#888888",
        "group_bg": "#F2F2F2", "group_fg": "#333333",
        "rule": "#DDDDDD", "footer_fg": "#999999", "title_size": 15.0,
    },
    "dark": {
        "header_bg": "#222B36", "header_fg": "#E8EDF2",
        "title_fg": "#222B36", "subtitle_fg": "#7A8696",
        "group_bg": "#E4E8ED", "group_fg": "#222B36",
        "rule": "#CFD6DE", "footer_fg": "#7A8696", "title_size": 16.0,
    },
}
DEFAULT_THEME = "slate"


# --- report parameters -------------------------------------------------------
PARAM_TYPES = {
    "string": "java.lang.String", "integer": "java.lang.Integer",
    "long": "java.lang.Long", "decimal": "java.math.BigDecimal",
    "double": "java.lang.Double", "boolean": "java.lang.Boolean",
    "date": "java.sql.Date", "timestamp": "java.sql.Timestamp",
}


def parse_param(spec: str) -> dict:
    """'name:type[:default]' -> {name,type,jclass,default}. default may hold
    colons (e.g. a timestamp), so split at most twice."""
    parts = spec.split(":", 2)
    if len(parts) < 2 or parts[1].lower() not in PARAM_TYPES:
        sys.stderr.write(f"ERROR: bad --param '{spec}' (use name:type[:default], "
                         f"type in {sorted(PARAM_TYPES)})\n")
        sys.exit(2)
    name, ptype = parts[0], parts[1].lower()
    default = parts[2] if len(parts) == 3 else None
    return {"name": name, "type": ptype, "jclass": PARAM_TYPES[ptype], "default": default}


def param_default_expr(p: dict):
    """Java expression for a <defaultValueExpression>, or None."""
    v = p["default"]
    if v is None:
        return None
    t = p["type"]
    if t == "string":    return '"' + v.replace('"', '\\"') + '"'
    if t == "integer":   return f"Integer.valueOf({int(v)})"
    if t == "long":      return f"Long.valueOf({int(v)}L)"
    if t == "decimal":   return f'new java.math.BigDecimal("{v}")'
    if t == "double":    return f"Double.valueOf({float(v)})"
    if t == "boolean":   return "Boolean.TRUE" if v.lower() in ("1", "true", "yes") else "Boolean.FALSE"
    if t == "date":      return f'java.sql.Date.valueOf("{v}")'
    if t == "timestamp": return f'java.sql.Timestamp.valueOf("{v}")'
    return None


def param_sql_literal(p: dict) -> str:
    """A PostgreSQL literal to substitute for $P{name} during introspection so
    psql can execute the query (the emitted jrxml keeps $P{name} for JR)."""
    t, v = p["type"], p["default"]
    if v is None:                       # no default: a harmless typed placeholder
        return {"string": "''", "integer": "0", "long": "0", "decimal": "0",
                "double": "0", "boolean": "FALSE", "date": "CURRENT_DATE",
                "timestamp": "CURRENT_TIMESTAMP"}[t]
    if t in ("integer", "long", "decimal", "double"):
        return str(v)
    if t == "boolean":
        return "TRUE" if v.lower() in ("1", "true", "yes") else "FALSE"
    if t == "date":      return f"DATE '{v}'"
    if t == "timestamp": return f"TIMESTAMP '{v}'"
    return "'" + v.replace("'", "''") + "'"          # string


def substitute_params(query: str, params: list) -> str:
    """Replace $P{name} / $P!{name} with each param's SQL literal (for psql
    introspection only)."""
    import re
    out = query
    for p in params:
        out = re.sub(r"\$P!?\{" + re.escape(p["name"]) + r"\}",
                     param_sql_literal(p), out)
    return out


# --- SQL lint ----------------------------------------------------------------
def lint_sql(query: str):
    """Warnings for a JRS report query. The JRS SQL security validator requires
    statements to begin with SELECT; a leading WITH (CTE) compiles locally but
    is rejected at fill time (JSSecurityException). Returns [(level, msg), ...]."""
    import re
    s = query.strip()
    while True:                                   # strip leading SQL comments
        if s.startswith("--"):
            nl = s.find("\n"); s = s[nl + 1:].lstrip() if nl >= 0 else ""
        elif s.startswith("/*"):
            end = s.find("*/"); s = s[end + 2:].lstrip() if end >= 0 else ""
        else:
            break
    m = re.match(r"(?i)([a-z]+)", s)
    kw = m.group(1).lower() if m else ""
    if kw == "with":
        return [("ERROR", "query begins with WITH (CTE): JRS rejects this at fill "
                 "time even though it compiles locally. Push each CTE into a FROM "
                 "subquery so the statement starts with SELECT.")]
    if kw and kw != "select":
        return [("WARN", f"query begins with '{kw}', not SELECT; JRS requires "
                 "report queries to start with SELECT.")]
    return []


# --- SQL dialect pre-compile check (--dialect) ------------------------------
DIALECTS = ("postgres", "x100")

# Aggregates whose OVER(... ORDER BY ...) / inner ORDER BY forms X100 rejects.
_AGG_FUNCS = ("sum", "avg", "count", "min", "max", "string_agg", "array_agg",
              "listagg", "json_agg", "jsonb_agg", "group_concat", "stddev",
              "stddev_pop", "stddev_samp", "variance", "var_pop", "var_samp",
              "bool_and", "bool_or", "every")
_AGG_RE = "|".join(_AGG_FUNCS)


def _strip_strings(sql: str) -> str:
    """Blank out single-quoted string literals (keeping length/newlines) so a
    quote-bound ';' or '--' cannot masquerade as SQL syntax."""
    import re
    return re.sub(r"'(?:[^']|'')*'",
                  lambda m: "'" + " " * (len(m.group(0)) - 2) + "'", sql)


def _comments(sql: str):
    """Yield (start, end, text) of every SQL comment, string-literal aware."""
    s = _strip_strings(sql)
    i, n = 0, len(s)
    while i < n:
        if s.startswith("--", i):
            j = s.find("\n", i)
            j = n if j < 0 else j
            yield i, j, sql[i:j]
            i = j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
            yield i, j, sql[i:j]
            i = j
        else:
            i += 1


def _strip_comments(sql: str) -> str:
    out, last = [], 0
    for a, b, _t in _comments(sql):
        out.append(sql[last:a]); out.append(" " * (b - a)); last = b
    out.append(sql[last:])
    return "".join(out)


def _line_of(sql: str, pos: int) -> int:
    return sql.count("\n", 0, pos) + 1


def _balanced_span(s: str, open_idx: int):
    """Index just past the ')' matching the '(' at open_idx, or len(s)."""
    depth = 0
    for k in range(open_idx, len(s)):
        c = s[k]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return k + 1
    return len(s)


def _from_aliases(body: str) -> set:
    """Best-effort: table names + aliases introduced by FROM/JOIN clauses of
    ONE select body (nested parens are skipped so subqueries do not leak)."""
    import re
    # remove nested parenthesised parts so only this level's FROM is scanned
    flat, depth, buf = [], 0, []
    for c in body:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            continue
        if depth == 0:
            flat.append(c)
    flat = "".join(flat)
    names = set()
    for m in re.finditer(r"(?is)\b(?:from|join)\s+([\w.\"]+)(?:\s+(?:as\s+)?(?!on\b|where\b|join\b|inner\b|left\b|right\b|full\b|cross\b|group\b|order\b|limit\b|having\b|union\b)(\w+))?", flat):
        names.add(m.group(1).split(".")[-1].strip('"').lower())
        if m.group(2):
            names.add(m.group(2).lower())
        # comma-separated FROM lists: "from a x, b y"
    for m in re.finditer(r"(?is)\bfrom\s+([^;]*?)(?:\bwhere\b|\bgroup\b|\border\b|\bhaving\b|\blimit\b|$)", flat):
        for part in m.group(1).split(","):
            toks = part.strip().split()
            if not toks or toks[0].lower() in ("select",):
                continue
            names.add(toks[0].split(".")[-1].strip('"').lower())
            if len(toks) >= 2 and toks[-1].lower() not in ("on", "using"):
                names.add(toks[-1].strip('"').lower())
    return names


def check_dialect_sql(query: str, dialect: str = "postgres"):
    """Static pre-compile checks for a report query against a target SQL dialect.

    Returns [(level, rule, message), ...]; level is "ERROR" or "WARN". The
    postgres dialect performs no checks (unchanged legacy behaviour). The x100
    (Actian Vector / Avalanche) dialect refuses constructs the X100 engine
    rejects at run time -- which JR compiles happily and JRS surfaces only as a
    fill-time HTTP 400:

      x100-ordered-aggregate   : STRING_AGG/ARRAY_AGG/LISTAGG(... ORDER BY ...),
                                 WITHIN GROUP (ORDER BY ...), and any aggregate
                                 with OVER (... ORDER BY ...) -- X100 has no
                                 ordered aggregate windows.
      x100-correlated-aggregate: a column of an OUTER alias referenced inside an
                                 aggregate call in a subquery -- X100 does not
                                 allow correlated variables in aggregates.
      x100-semicolon-in-comment: ';' inside a -- or /* */ comment -- the
                                 admiral sql.ps1 run-file splitter has no comment
                                 awareness and would cut the statement there.

    Limits (regex heuristics, no full parser): the correlated-aggregate rule
    only sees qualified references (alias.col) whose alias is introduced by an
    enclosing FROM/JOIN and NOT by the subquery's own FROM/JOIN; unqualified
    outer columns, CTE-scoped names and lateral joins are not detected, and a
    subquery alias that shadows an outer alias is treated as local (no
    finding). The ordered-aggregate rule matches call text, so an ORDER BY
    in a nested subquery passed to an aggregate can produce a false positive
    -- use --allow-dialect-warnings to downgrade a known-good query.
    """
    import re
    findings = []
    if dialect not in DIALECTS:
        raise ValueError(f"unknown dialect '{dialect}' (choose from {', '.join(DIALECTS)})")
    if dialect != "x100":
        return findings

    # 1. ';' inside comments
    for a, _b, text in _comments(query):
        if ";" in text:
            findings.append(("ERROR", "x100-semicolon-in-comment",
                             f"line {_line_of(query, a)}: ';' inside a SQL comment; the "
                             "admiral sql.ps1 run-file splitter is not comment-aware and "
                             "splits the statement there. Remove the ';' from the comment."))

    code = _strip_comments(_strip_strings(query))

    # 2. ordered aggregates / ordered aggregate windows
    for m in re.finditer(r"(?is)\b(" + _AGG_RE + r")\s*\(", code):
        end = _balanced_span(code, m.end() - 1)
        args = code[m.end():end - 1]
        if re.search(r"(?is)\border\s+by\b", args):
            findings.append(("ERROR", "x100-ordered-aggregate",
                             f"line {_line_of(code, m.start())}: {m.group(1).upper()}(... ORDER BY ...) -- "
                             "X100 has no ordered aggregates; drop the ORDER BY or "
                             "pre-sort in a subquery."))
        tail = code[end:]
        om = re.match(r"(?is)\s*(?:filter\s*\([^)]*\)\s*)?over\s*\(", tail)
        if om:
            oend = _balanced_span(tail, om.end() - 1)
            if re.search(r"(?is)\border\s+by\b", tail[om.end():oend - 1]):
                findings.append(("ERROR", "x100-ordered-aggregate",
                                 f"line {_line_of(code, m.start())}: {m.group(1).upper()}(...) OVER (... ORDER BY ...) -- "
                                 "X100 does not support ordered aggregate windows (running "
                                 "totals); use a self-join or a ranking function instead."))
    for m in re.finditer(r"(?is)\bwithin\s+group\s*\(", code):
        findings.append(("ERROR", "x100-ordered-aggregate",
                         f"line {_line_of(code, m.start())}: WITHIN GROUP (ORDER BY ...) -- "
                         "X100 has no ordered-set aggregates."))

    # 3. correlated column references inside aggregates in subqueries
    outer_aliases = _from_aliases(code)
    for m in re.finditer(r"(?is)\(\s*select\b", code):
        end = _balanced_span(code, m.start())
        body = code[m.start() + 1:end - 1]
        local = _from_aliases(body)
        # aliases visible from enclosing scopes = everything outside this body
        enclosing = _from_aliases(code[:m.start()] + " " + code[end:]) | outer_aliases
        for am in re.finditer(r"(?is)\b(" + _AGG_RE + r")\s*\(", body):
            aend = _balanced_span(body, am.end() - 1)
            args = body[am.end():aend - 1]
            for ref in re.finditer(r"\b(\w+)\.(\w+)\b", args):
                alias = ref.group(1).lower()
                if alias in enclosing and alias not in local:
                    findings.append(("ERROR", "x100-correlated-aggregate",
                                     f"line {_line_of(code, m.start() + am.start())}: "
                                     f"{am.group(1).upper()}(...) references outer alias "
                                     f"'{ref.group(1)}.{ref.group(2)}' inside a subquery -- X100 "
                                     "does not allow correlated variables in aggregates; join "
                                     "the outer table into the subquery or aggregate first."))
                    break
    return findings


def report_dialect_findings(findings, allow_warnings=False, stream=None) -> bool:
    """Print findings; return True when the caller must refuse (an ERROR that
    was not downgraded by allow_warnings)."""
    stream = stream or sys.stderr
    refuse = False
    for level, rule, msg in findings:
        shown = "WARN" if (allow_warnings and level == "ERROR") else level
        stream.write(f"SQL {shown} [{rule}]: {msg}\n")
        if level == "ERROR" and not allow_warnings:
            refuse = True
    return refuse


# --- column introspection via psql -------------------------------------------
def introspect(query: str, host, port, user, db) -> list:
    """Return [(column_name, udt_name), ...] for the query's result set."""
    sql = query.strip().rstrip(";")
    script = (
        "CREATE TEMP VIEW _jr_scaffold AS\n"
        f"{sql}\n;\n"
        # scope to the temp schema so a same-named relation elsewhere can't
        # inject duplicate columns into the field list
        r"\copy (SELECT column_name, udt_name FROM information_schema.columns "
        "WHERE table_name = '_jr_scaffold' AND table_schema LIKE 'pg_temp%' "
        "ORDER BY ordinal_position) TO STDOUT WITH (FORMAT csv)\n"
    )
    cmd = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", db,
           "-v", "ON_ERROR_STOP=1", "-q", "-X", "-f", "-"]
    try:
        proc = subprocess.run(cmd, input=script, capture_output=True, text=True)
    except FileNotFoundError:
        sys.stderr.write("psql not found on PATH; column introspection needs the "
                         "PostgreSQL client (use --check-only for SQL checks alone).\n")
        sys.exit(2)
    if proc.returncode != 0:
        sys.stderr.write("psql introspection failed:\n" + proc.stderr + "\n")
        sys.exit(2)
    cols = []
    for row in csv.reader(io.StringIO(proc.stdout)):
        if len(row) >= 2:
            cols.append((row[0], row[1]))
    if not cols:
        sys.stderr.write("No columns detected for the query.\n")
        sys.exit(2)
    return cols


def row_count(query, host, port, user, db):
    """Result-row count for `query` (used to size a pie color gradient).
    Returns None if it can't be determined (gradient falls back to a fixed size)."""
    sql = query.strip().rstrip(";")
    # plain SQL over stdin (NOT \copy, which must be single-line) so a multi-line
    # subquery works; -t -A => the bare count on stdout.
    script = f"SELECT count(*) FROM ({sql}) _jr_cnt;\n"
    cmd = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", db,
           "-v", "ON_ERROR_STOP=1", "-q", "-X", "-t", "-A", "-f", "-"]
    proc = subprocess.run(cmd, input=script, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        return int(proc.stdout.strip())
    except ValueError:
        return None


# Actian-blue pie-slice gradient endpoints (match the bar customizer): deepest
# navy = largest slice, palest = smallest. Used as declarative <seriesColor>s so
# no chart customizer / server restart is needed for pies.
PIE_BLUE_DEEP = (0x0A, 0x2A, 0x4A)
PIE_BLUE_LIGHT = (0xB8, 0xD4, 0xEC)


def blue_gradient(n):
    """n Actian-blue hex colors from deep (slice 0 / largest) to light."""
    n = max(1, n)
    out = []
    for i in range(n):
        t = i / (n - 1) if n > 1 else 0.0
        r = round(PIE_BLUE_DEEP[0] + (PIE_BLUE_LIGHT[0] - PIE_BLUE_DEEP[0]) * t)
        g = round(PIE_BLUE_DEEP[1] + (PIE_BLUE_LIGHT[1] - PIE_BLUE_DEEP[1]) * t)
        b = round(PIE_BLUE_DEEP[2] + (PIE_BLUE_LIGHT[2] - PIE_BLUE_DEEP[2]) * t)
        out.append(f"#{r:02X}{g:02X}{b:02X}")
    return out


# --- width layout ------------------------------------------------------------
def layout_widths(cols, total):
    """Weighted column widths that are all positive and sum to exactly `total`.

    A fixed 40px minimum would overflow `total` once there are more than
    total/40 columns, pushing the rounding remainder negative; instead the
    minimum is capped to what actually fits, and the rounding remainder is
    spread across columns (never dumped onto one), so no width goes <= 0.
    """
    n = len(cols)
    weights = [1.0 if is_right_aligned(java_class(udt)) else 1.6 for _name, udt in cols]
    s = sum(weights)
    min_w = max(1, min(40, total // n))            # a floor that always fits
    raw = [max(min_w, int(total * w / s)) for w in weights]

    # nudge one px at a time (up or down) until the widths sum to exactly
    # `total`, never letting any column drop below min_w
    diff = total - sum(raw)
    step = 1 if diff > 0 else -1
    i = 0
    while diff != 0:
        idx = i % n
        if not (step < 0 and raw[idx] <= min_w):
            raw[idx] += step
            diff -= step
        i += 1
    return raw


# --- XML emission ------------------------------------------------------------
def el_static(x, y, w, h, text, *, fontsize=9.0, bold=False, forecolor=None,
              halign=None, valign="Middle"):
    attrs = [f'kind="staticText"', f'x="{x}"', f'y="{y}"',
             f'width="{w}"', f'height="{h}"', f'fontSize="{fontsize}"']
    if bold:
        attrs.append('bold="true"')
    if forecolor:
        attrs.append(f'forecolor="{forecolor}"')
    if halign:
        attrs.append(f'hTextAlign="{halign}"')
    if valign:
        attrs.append(f'vTextAlign="{valign}"')
    return (f'\t\t<element {" ".join(attrs)}>'
            f'<text><![CDATA[{text}]]></text></element>')


def el_textfield(x, y, w, h, expr, *, fontsize=8.0, halign=None,
                 valign="Middle", pattern=None):
    attrs = [f'kind="textField"', f'x="{x}"', f'y="{y}"',
             f'width="{w}"', f'height="{h}"', f'fontSize="{fontsize}"']
    if halign:
        attrs.append(f'hTextAlign="{halign}"')
    if valign:
        attrs.append(f'vTextAlign="{valign}"')
    if pattern:
        attrs.append(f'pattern="{pattern}"')
    return (f'\t\t<element {" ".join(attrs)}>'
            f'<expression><![CDATA[{expr}]]></expression></element>')


# --- chart support (JFreeChart, community) -----------------------------------
# maps --chart value -> (jrxml chartType attribute, dataset kind)
CHART_TYPES = {
    "pie": ("pie", "pie"),
    "pie3d": ("pie3D", "pie"),
    "bar": ("bar", "category"),
    "bar3d": ("bar3D", "category"),
    "line": ("line", "category"),
    "area": ("area", "category"),
    "stackedbar": ("stackedBar", "category"),
}

# Default JFreeChart customizer applied to `bar` charts: Actian-blue gradient bars
# (color encodes the measure) + an optional trend line (second series) on a
# secondary axis. Its jar (chart_customizers/actian-chart-customizers.jar) must be
# on the JasperReports Server classpath (WEB-INF/lib). Disable with --no-gradient.
CHART_CUSTOMIZER = "com.actian.jasper.GradientTrendCustomizer"


def first_text_col(cols):
    for name, udt in cols:
        if java_class(udt) == "java.lang.String":
            return name
    return cols[0][0]


def first_numeric_col(cols):
    for name, udt in cols:
        jc = java_class(udt)
        if jc in NUMERIC_JAVA or jc in DECIMAL_JAVA:
            return name
    return None


def second_numeric_col(cols, exclude):
    """First numeric column that isn't `exclude` (the trend-line measure)."""
    for name, udt in cols:
        if name == exclude:
            continue
        jc = java_class(udt)
        if jc in NUMERIC_JAVA or jc in DECIMAL_JAVA:
            return name
    return None


def build_chart(chart, cat, val, series, *, width, y, height, label_rotation=0,
                trend=None, customizer=None, slice_colors=None):
    """Return jrxml lines for a JFreeChart <element kind="chart">."""
    chart_type, ds_kind = CHART_TYPES[chart]
    head = (f'\t\t<element kind="chart" chartType="{chart_type}" x="0" y="{y}" '
            f'width="{width}" height="{height}" evaluationTime="Report"')
    if customizer:
        head += f' customizerClass="{customizer}"'
    o = [head + '>']
    if ds_kind == "pie":
        o.append('\t\t\t<dataset kind="pie">')
        o.append('\t\t\t\t<series>')
        o.append(f'\t\t\t\t\t<keyExpression><![CDATA[$F{{{cat}}}]]></keyExpression>')
        o.append(f'\t\t\t\t\t<valueExpression><![CDATA[$F{{{val}}}]]></valueExpression>')
        o.append('\t\t\t\t</series>')
        o.append('\t\t\t</dataset>')
        # Actian-blue slice gradient (deep -> light) via declarative <seriesColor>;
        # the query should ORDER BY value DESC so the largest slice is deepest.
        if slice_colors:
            o.append('\t\t\t<plot labelFormat="{0}: {2}" legendLabelFormat="{0} ({2})">')
            for i, c in enumerate(slice_colors):
                o.append(f'\t\t\t\t<seriesColor order="{i}" color="{c}"/>')
            o.append('\t\t\t</plot>')
        else:
            o.append('\t\t\t<plot labelFormat="{0}: {2}" legendLabelFormat="{0} ({2})"/>')
    else:
        o.append('\t\t\t<dataset kind="category">')
        o.append('\t\t\t\t<series>')
        if series:
            o.append(f'\t\t\t\t\t<seriesExpression><![CDATA[$F{{{series}}}]]></seriesExpression>')
        else:
            o.append(f'\t\t\t\t\t<seriesExpression><![CDATA["{escape(label_for(val))}"]]></seriesExpression>')
        o.append(f'\t\t\t\t\t<categoryExpression><![CDATA[$F{{{cat}}}]]></categoryExpression>')
        o.append(f'\t\t\t\t\t<valueExpression><![CDATA[$F{{{val}}}]]></valueExpression>')
        o.append('\t\t\t\t</series>')
        # second measure -> the customizer renders it as a trend line on a 2nd axis
        if trend:
            o.append('\t\t\t\t<series>')
            o.append(f'\t\t\t\t\t<seriesExpression><![CDATA["{escape(label_for(trend))}"]]></seriesExpression>')
            o.append(f'\t\t\t\t\t<categoryExpression><![CDATA[$F{{{cat}}}]]></categoryExpression>')
            o.append(f'\t\t\t\t\t<valueExpression><![CDATA[$F{{{trend}}}]]></valueExpression>')
            o.append('\t\t\t\t</series>')
        o.append('\t\t\t</dataset>')
        # JR7 plot classes differ by chart type, and the strict Jackson loader
        # rejects any property the target plot class does not declare:
        #   line      -> JRDesignLinePlot: showLines/showShapes ONLY
        #               (showTickMarks/showTickLabels throw UnrecognizedPropertyException)
        #   area      -> JRDesignAreaPlot: supports NEITHER the tick props NOR
        #               showLines/showShapes (verified: a bare <plot/> compiles;
        #               showTickMarks 400s). Only categoryAxisTickLabelRotation is valid.
        #   bar/bar3d/stackedbar -> JRDesignBarPlot: showTickMarks/showTickLabels.
        # categoryAxisTickLabelRotation (degrees, e.g. -45) is valid on every
        # category plot and keeps long category labels from being truncated.
        rot = (f' categoryAxisTickLabelRotation="{label_rotation}"'
               if label_rotation else '')
        if chart == "line":
            o.append(f'\t\t\t<plot showLines="true" showShapes="true"{rot}/>')
        elif chart == "area":
            o.append(f'\t\t\t<plot{rot}/>')
        else:
            o.append(f'\t\t\t<plot showTickMarks="true" showTickLabels="true"{rot}/>')
    o.append('\t\t</element>')
    return o


def safe_name(col: str) -> str:
    import re
    return re.sub(r"[^0-9A-Za-z_]", "_", col)


def highlight_condition(col: str, jclass: str, op: str, value: str) -> str:
    """A Java boolean expression for a <conditionalStyle>."""
    if jclass in NUMERIC_JAVA or jclass in DECIMAL_JAVA:
        return f"$F{{{col}}} != null && $F{{{col}}}.doubleValue() {op} {float(value)}"
    eq = f'$F{{{col}}} != null && $F{{{col}}}.equals("{value}")'
    return ("!(" + eq + ")") if op in ("!=", "<>") else eq


def build_crosstab(row_col, col_col, meas_col, jclass, *, width, y=10):
    """JR7-native <crosstab>: rows=row_col, columns=col_col, Sum(meas_col),
    with row/column totals and a grand total. Returns (lines, height)."""
    rg, cg, mn = "row_" + safe_name(row_col), "col_" + safe_name(col_col), "m_" + safe_name(meas_col)
    mcls = jclass.get(meas_col, "java.math.BigDecimal")
    mpat = display_pattern(mcls) or "#,##0"
    rowHW, cellW, ch, chh = 130, 90, 18, 20
    height = chh + ch * 2 + 4

    def cell(extra, bg):
        bgattr = f' mode="Opaque" backcolor="{bg}"' if bg else ' mode="Transparent"'
        return (f'\t\t\t<cell width="{cellW}" height="{ch}"{extra}><contents{bgattr}>'
                f'<element kind="textField" x="0" y="0" width="{cellW}" height="{ch}" fontSize="8.0" '
                f'hTextAlign="Right" vTextAlign="Middle" pattern="{mpat}">'
                f'<expression><![CDATA[$V{{{mn}}}]]></expression></element>'
                f'<box><pen lineWidth="0.5" lineColor="#CCCCCC"/></box></contents></cell>')

    o = [f'\t\t<element kind="crosstab" x="0" y="{y}" width="{width}" height="{height}">',
         '\t\t\t<dataset/>',
         f'\t\t\t<rowGroup name="{rg}" totalPosition="End" width="{rowHW}">',
         f'\t\t\t\t<bucket class="{jclass.get(row_col, "java.lang.String")}"><expression><![CDATA[$F{{{row_col}}}]]></expression></bucket>',
         f'\t\t\t\t<header><element kind="textField" x="2" y="0" width="{rowHW - 4}" height="{ch}" fontSize="8.0" bold="true" vTextAlign="Middle"><expression><![CDATA[$V{{{rg}}}]]></expression></element></header>',
         f'\t\t\t\t<totalHeader><element kind="staticText" x="2" y="0" width="{rowHW - 4}" height="{ch}" fontSize="8.0" bold="true" vTextAlign="Middle"><text><![CDATA[Total]]></text></element></totalHeader>',
         '\t\t\t</rowGroup>',
         f'\t\t\t<columnGroup name="{cg}" totalPosition="End" height="{chh}">',
         f'\t\t\t\t<bucket class="{jclass.get(col_col, "java.lang.String")}"><expression><![CDATA[$F{{{col_col}}}]]></expression></bucket>',
         f'\t\t\t\t<header><element kind="textField" x="0" y="0" width="{cellW}" height="{chh}" fontSize="8.0" bold="true" hTextAlign="Center" vTextAlign="Middle"><expression><![CDATA[$V{{{cg}}}]]></expression></element></header>',
         f'\t\t\t\t<totalHeader><element kind="staticText" x="0" y="0" width="{cellW}" height="{chh}" fontSize="8.0" bold="true" hTextAlign="Center" vTextAlign="Middle"><text><![CDATA[Total]]></text></element></totalHeader>',
         '\t\t\t</columnGroup>',
         f'\t\t\t<measure name="{mn}" calculation="Sum" class="{mcls}"><expression><![CDATA[$F{{{meas_col}}}]]></expression></measure>',
         cell('', None),
         cell(f' rowTotalGroup="{rg}"', "#EAF2F8"),
         cell(f' columnTotalGroup="{cg}"', "#EAF2F8"),
         cell(f' rowTotalGroup="{rg}" columnTotalGroup="{cg}"', "#D4E6F1"),
         '\t\t</element>']
    return o, height


# Default repository URI for the Actian logo placed top-left of every report's
# title band. Upload the image once with:
#   upload_file.ps1 -File "<...>\Actian-Logo-RGB_Vertical-Blue.jpg" -Uri /images/actian_logo -Type img -Overwrite
# Override with --logo-uri, or suppress with --no-logo.
DEFAULT_LOGO_URI = "repo:/images/actian_logo"


def el_image(x, y, w, h, expr, *, scale="RetainShape", halign="Left", valign="Middle"):
    return (f'\t\t<element kind="image" x="{x}" y="{y}" width="{w}" height="{h}" '
            f'scaleImage="{scale}" hImageAlign="{halign}" vImageAlign="{valign}">'
            f'<expression><![CDATA[{expr}]]></expression></element>')


def build_jrxml(name, title, subtitle, query, cols, *, page_w, page_h,
                margin=20, chart=None, chart_cat=None, chart_val=None,
                chart_series=None, chart_height=300, chart_label_rotation=0,
                chart_trend=None, chart_gradient=True, chart_slice_colors=None,
                params=None, group_by=None, drills=None, highlights=None,
                crosstab=None, subreport=None, theme=None, style_template=None,
                logo=DEFAULT_LOGO_URI):
    t = THEMES.get(theme or DEFAULT_THEME, THEMES[DEFAULT_THEME])
    col_w = page_w - 2 * margin
    widths = layout_widths(cols, col_w)
    xs = []
    acc = 0
    for w in widths:
        xs.append(acc)
        acc += w
    col_jclass = {c: java_class(u) for c, u in cols}
    numeric_cols = [c for c, u in cols if java_class(u) in NUMERIC_JAVA | DECIMAL_JAVA]
    drills = drills or {}
    # map column -> conditional style name (first highlight that names it wins)
    hl_style = {}
    hl_defs = []
    for i, h in enumerate(highlights or []):
        if h["col"] in col_jclass and h["col"] not in hl_style:
            sname = f"hl_{safe_name(h['col'])}_{i}"
            hl_style[h["col"]] = sname
            cond = highlight_condition(h["col"], col_jclass[h["col"]], h["op"], h["value"])
            hl_defs.append((sname, cond, h["color"]))

    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<!-- Generated by jasper-deploy scaffold_jrxml.py. JR7-native (JasperReports 7.0.6). -->',
           f'<jasperReport name="{escape(name)}" language="java" '
           f'pageWidth="{page_w}" pageHeight="{page_h}" columnWidth="{col_w}" '
           f'leftMargin="{margin}" rightMargin="{margin}" '
           f'topMargin="{margin}" bottomMargin="{margin}">']

    # external style template (shared .jrtx). Must precede <style>/<parameter>.
    # JRS resolves a "repo:/path" expression against the repository at fill time;
    # the template's isDefault style sets fontName/base color for all text.
    if style_template:
        expr = ('"repo:' + style_template + '"') if style_template.startswith("/") else f'"{style_template}"'
        out.append(f'\t<template><![CDATA[{expr}]]></template>')
        out.append('')

    # conditional-format styles (referenced by detail cells via style="..")
    for sname, cond, color in hl_defs:
        out.append(f'\t<style name="{sname}">')
        out.append(f'\t\t<conditionalStyle mode="Opaque" backcolor="{color}">')
        out.append(f'\t\t\t<conditionExpression><![CDATA[{cond}]]></conditionExpression>')
        out.append('\t\t</conditionalStyle>')
        out.append('\t</style>')
    if hl_defs:
        out.append('')

    # parameters (declared before the query so $P{..} resolves)
    for p in (params or []):
        dexpr = param_default_expr(p)
        if dexpr:
            out.append(f'\t<parameter name="{escape(p["name"])}" class="{p["jclass"]}">')
            out.append(f'\t\t<defaultValueExpression><![CDATA[{dexpr}]]></defaultValueExpression>')
            out.append('\t</parameter>')
        else:
            out.append(f'\t<parameter name="{escape(p["name"])}" class="{p["jclass"]}"/>')
    if params:
        out.append('')

    # query
    out.append('\t<query language="SQL"><![CDATA[')
    out.append(query.strip().rstrip(";"))
    out.append('\t]]></query>')
    out.append('')

    # fields
    for cname, udt in cols:
        out.append(f'\t<field name="{escape(cname)}" class="{java_class(udt)}"/>')
    out.append('')

    # group subtotal variables + group element (--group-by)
    gname = None
    if group_by and group_by in col_jclass:
        gname = "grp_" + safe_name(group_by)
        for nc in numeric_cols:
            out.append(f'\t<variable name="{safe_name(nc)}_grp" class="{col_jclass[nc]}" '
                       f'resetType="Group" resetGroup="{gname}" calculation="Sum">')
            out.append(f'\t\t<expression><![CDATA[$F{{{nc}}}]]></expression>')
            out.append('\t</variable>')
        out.append(f'\t<group name="{gname}">')
        out.append(f'\t\t<expression><![CDATA[$F{{{group_by}}}]]></expression>')
        # header: the group key in bold on a light band
        out.append('\t\t<groupHeader><band height="18">')
        out.append(f'\t\t\t<element kind="rectangle" x="0" y="0" width="{col_w}" height="18" '
                   f'mode="Opaque" backcolor="{t["group_bg"]}" forecolor="{t["group_bg"]}"/>')
        out.append(f'\t\t\t<element kind="textField" x="4" y="0" width="{col_w - 8}" height="18" '
                   f'fontSize="9.0" bold="true" forecolor="{t["group_fg"]}" vTextAlign="Middle">'
                   f'<expression><![CDATA['
                   f'"{escape(label_for(group_by))}: " + $F{{{group_by}}}]]></expression></element>')
        out.append('\t\t</band></groupHeader>')
        # footer: subtotals under each numeric column
        out.append('\t\t<groupFooter><band height="15">')
        out.append(f'\t\t\t<element kind="line" x="0" y="0" width="{col_w}" height="1" forecolor="#BBBBBB"/>')
        first_x = xs[0]
        out.append(f'\t\t\t<element kind="staticText" x="{first_x + 4}" y="1" width="120" height="13" '
                   'fontSize="8.0" bold="true" vTextAlign="Middle"><text><![CDATA[Subtotal]]></text></element>')
        for (cname, udt), x, w in zip(cols, xs, widths):
            if cname in numeric_cols:
                out.append(f'\t\t\t<element kind="textField" x="{x}" y="1" width="{w - 6}" height="13" '
                           f'fontSize="8.0" bold="true" hTextAlign="Right" vTextAlign="Middle" '
                           f'pattern="{display_pattern(col_jclass[cname])}"><expression><![CDATA['
                           f'$V{{{safe_name(cname)}_grp}}]]></expression></element>')
        out.append('\t\t</band></groupFooter>')
        out.append('\t</group>')
        out.append('')

    # title band -- Actian logo top-left, title/subtitle centered across full width
    title_h = 44 if subtitle else 28
    logo_sz = 44
    logo_gap = 8  # whitespace below the title band so the logo clears the column header
    if logo:
        title_h = max(title_h, logo_sz) + logo_gap
    out.append(f'\t<title height="{title_h}">')
    if logo:
        out.append(el_image(0, 0, logo_sz, logo_sz, f'"{logo}"', halign="Left", valign="Top"))
    out.append(el_static(0, 0, col_w, 24, escape(title), fontsize=t["title_size"],
                         bold=True, forecolor=t["title_fg"], halign="Center", valign=None))
    if subtitle:
        out.append(el_static(0, 26, col_w, 14, escape(subtitle), fontsize=9.0,
                             forecolor=t["subtitle_fg"], halign="Center", valign=None))
    out.append('\t</title>')
    out.append('')

    # crosstab mode: emit the crosstab in the summary band and skip the tabular
    # columnHeader/detail and any chart.
    if crosstab:
        ct_lines, ct_h = build_crosstab(crosstab[0], crosstab[1], crosstab[2],
                                        col_jclass, width=col_w, y=10)
        out.append(f'\t<summary height="{ct_h + 20}">')
        out.extend(ct_lines)
        out.append('\t</summary>')
        out.append('')
        out.append('</jasperReport>')
        return "\n".join(out) + "\n"

    # column header. A filled theme paints a band rectangle; a header_bg=None
    # theme (e.g. minimal) instead underlines the row with a rule and uses dark
    # header text.
    out.append('\t<columnHeader height="18">')
    if t["header_bg"]:
        out.append(f'\t\t<element kind="rectangle" x="0" y="0" width="{col_w}" '
                   f'height="18" mode="Opaque" backcolor="{t["header_bg"]}" forecolor="{t["header_bg"]}"/>')
    else:
        out.append(f'\t\t<element kind="line" x="0" y="17" width="{col_w}" '
                   f'height="1" forecolor="{t["rule"]}"/>')
    for (cname, udt), x, w in zip(cols, xs, widths):
        jc = java_class(udt)
        halign = "Right" if is_right_aligned(jc) else None
        pad = 6 if halign is None else 0
        out.append(el_static(x + pad, 0, w - pad - (6 if halign else 0), 18,
                             escape(label_for(cname)), fontsize=9.0, bold=True,
                             forecolor=t["header_fg"], halign=halign))
    out.append('\t</columnHeader>')
    out.append('')

    # detail
    out.append('\t<detail>')
    out.append('\t\t<band height="13">')
    for (cname, udt), x, w in zip(cols, xs, widths):
        jc = java_class(udt)
        halign = "Right" if is_right_aligned(jc) else None
        pad = 6 if halign is None else 0
        cx, cw = x + pad, w - pad - (6 if halign else 0)
        style = hl_style.get(cname)
        drill = drills.get(cname)
        if not style and not drill:
            out.append(el_textfield(cx, 0, cw, 13, f'$F{{{cname}}}', fontsize=8.0,
                                    halign=halign, pattern=display_pattern(jc)))
            continue
        # cell needs a style attr and/or a nested <hyperlink> -> emit longhand
        attrs = [f'kind="textField"', f'x="{cx}"', 'y="0"', f'width="{cw}"',
                 'height="13"', 'fontSize="8.0"', 'vTextAlign="Middle"']
        if halign: attrs.append(f'hTextAlign="{halign}"')
        if display_pattern(jc): attrs.append(f'pattern="{display_pattern(jc)}"')
        if style: attrs.append(f'style="{style}"')
        if drill:
            # JR7 flattens the hyperlink onto the textField: linkType/linkTarget
            # are attributes and <hyperlinkParameter> children sit directly on the
            # element (there is no <hyperlink> wrapper element).
            attrs.append('forecolor="#1A5276"')
            attrs.append('linkType="ReportExecution"')
            attrs.append('linkTarget="Blank"')
        out.append(f'\t\t\t<element {" ".join(attrs)}>')
        out.append(f'\t\t\t\t<expression><![CDATA[$F{{{cname}}}]]></expression>')
        if drill:
            out.append(f'\t\t\t\t<hyperlinkParameter name="_report"><expression><![CDATA["{drill["target"]}"]]></expression></hyperlinkParameter>')
            for pname, srccol in drill["params"]:
                out.append(f'\t\t\t\t<hyperlinkParameter name="{pname}"><expression><![CDATA[$F{{{srccol}}}]]></expression></hyperlinkParameter>')
        out.append('\t\t\t</element>')
    out.append(f'\t\t\t<element kind="line" x="0" y="12" width="{col_w}" '
               f'height="1" forecolor="{t["rule"]}"/>')
    out.append('\t\t</band>')
    out.append('\t</detail>')
    out.append('')

    # page footer
    ffg = t["footer_fg"]
    out.append('\t<pageFooter height="16">')
    out.append(el_static(0, 2, col_w // 2, 12, escape(title), fontsize=8.0,
                         forecolor=ffg, valign=None))
    out.append(f'\t\t<element kind="textField" x="{col_w - 155}" y="2" '
               f'width="120" height="12" forecolor="{ffg}" fontSize="8.0" '
               'hTextAlign="Right"><expression><![CDATA["Page " + $V{PAGE_NUMBER} + " of"]]>'
               '</expression></element>')
    out.append(f'\t\t<element kind="textField" x="{col_w - 33}" y="2" '
               f'width="33" height="12" forecolor="{ffg}" fontSize="8.0" '
               'evaluationTime="Report"><expression><![CDATA[" " + $V{PAGE_NUMBER}]]>'
               '</expression></element>')
    out.append('\t</pageFooter>')
    out.append('')

    # summary band: optional chart and/or subreport
    summary = []
    sy = 10
    if chart:
        # gradient-bar + trend-line customizer is the default for plain `bar`
        # charts (not multi-series, not disabled). trend = optional 2nd measure.
        use_cust = chart == "bar" and chart_gradient and not chart_series
        summary.extend(build_chart(chart, chart_cat, chart_val, chart_series,
                                   width=col_w, y=sy, height=chart_height,
                                   label_rotation=chart_label_rotation,
                                   trend=(chart_trend if use_cust else None),
                                   customizer=(CHART_CUSTOMIZER if use_cust else None),
                                   slice_colors=chart_slice_colors))
        sy += chart_height + 12
    if subreport:
        sub_uri, sub_params = subreport
        expr = ('"repo:' + sub_uri + '"') if sub_uri.startswith("/") else f'"{sub_uri}"'
        summary.append(f'\t\t<element kind="subreport" x="0" y="{sy}" width="{col_w}" '
                       'height="20" removeLineWhenBlank="true">')
        summary.append('\t\t\t<connectionExpression><![CDATA[$P{REPORT_CONNECTION}]]></connectionExpression>')
        summary.append(f'\t\t\t<expression><![CDATA[{expr}]]></expression>')
        for pn, sc in sub_params:
            summary.append(f'\t\t\t<parameter name="{pn}"><expression><![CDATA[$F{{{sc}}}]]></expression></parameter>')
        summary.append('\t\t</element>')
        sy += 320
    if summary:
        out.append(f'\t<summary height="{sy}">')
        out.extend(summary)
        out.append('\t</summary>')
        out.append('')

    out.append('</jasperReport>')
    return "\n".join(out) + "\n"


PAGE_SIZES = {"a4": (595, 842), "letter": (612, 792)}


def main():
    ap = argparse.ArgumentParser(description="Scaffold a JR7 jrxml from SQL.")
    ap.add_argument("--name", required=True, help="report name (no spaces)")
    ap.add_argument("--title", help="title band text (default: derived from --name)")
    ap.add_argument("--subtitle", help="optional subtitle line")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--query", help="SQL query text")
    src.add_argument("--query-file", help="path to a .sql file")
    ap.add_argument("--out", help="output .jrxml path (default: <name>.jrxml)")
    ap.add_argument("--db", default="postgis_34_sample")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", default="5432")
    ap.add_argument("--user", default="postgres")
    ap.add_argument("--page-size", default="a4", choices=list(PAGE_SIZES))
    ap.add_argument("--landscape", action="store_true")
    ap.add_argument("--template", default=DEFAULT_THEME, choices=list(THEMES),
                    help=f"visual template / color palette (default: {DEFAULT_THEME}). "
                         "Sets the column-header band, title/subtitle, group band, "
                         "row rule and footer colors. 'minimal' uses no header fill.")
    ap.add_argument("--style-template", metavar="JRTX_URI",
                    help="reference a shared .jrtx style template (see "
                         "scaffold_style_template.py). A leading-'/' value is wrapped "
                         "as repo:URI; the template's isDefault style sets the report "
                         "font/base color centrally. Deploy the .jrtx with upload_file.ps1.")
    ap.add_argument("--logo-uri", default=DEFAULT_LOGO_URI, metavar="URI",
                    help=f"image URI for the logo placed top-left of the title band "
                         f"(default: {DEFAULT_LOGO_URI}). Usually a repo:/... resource; "
                         "upload it once with upload_file.ps1 -Type img.")
    ap.add_argument("--no-logo", action="store_true",
                    help="suppress the top-left logo in the title band")
    ap.add_argument("--chart", choices=list(CHART_TYPES),
                    help="also add a JFreeChart in the summary band "
                         "(pie|pie3d|bar|bar3d|line|area|stackedbar)")
    ap.add_argument("--chart-category", help="key/category column (default: first text column)")
    ap.add_argument("--chart-value", help="numeric value column (default: first numeric column)")
    ap.add_argument("--chart-series", help="series column for multi-series category charts")
    ap.add_argument("--chart-height", type=int, default=300)
    ap.add_argument("--chart-label-rotation", type=int, default=0,
                    help="rotate category-axis tick labels by N degrees (e.g. -45) "
                         "to keep long bar/line labels from truncating")
    ap.add_argument("--chart-trend", metavar="COLUMN",
                    help="numeric column drawn as a trend line on a secondary axis "
                         "over a `bar` chart (default: the first numeric column other "
                         "than the bar value). Needs the chart customizer (on by default).")
    ap.add_argument("--no-gradient", action="store_true",
                    help="disable the default Actian gradient-bar + trend-line "
                         "customizer on `bar` charts (plain flat bars instead)")
    ap.add_argument("--param", action="append", default=[], metavar="NAME:TYPE[:DEFAULT]",
                    help="declare a report parameter referenced as $P{NAME} in the "
                         "query; TYPE in string|integer|long|decimal|double|boolean|"
                         "date|timestamp. Repeatable.")
    ap.add_argument("--group-by", metavar="COLUMN",
                    help="group rows by COLUMN with a group header + subtotal footer "
                         "(sums every numeric column). The query should ORDER BY COLUMN.")
    ap.add_argument("--drill", action="append", default=[], metavar="COL:TARGET_URI[:p=COL2;..]",
                    help="make COL a drill-down link that runs report TARGET_URI, "
                         "passing params p=COL2 (value from each row). Repeatable.")
    ap.add_argument("--highlight", action="append", default=[], metavar="COL:OP:VALUE:#COLOR",
                    help="conditionally shade a cell when COL OP VALUE holds; OP in "
                         "> >= < <= == != (string columns: == / !=). Repeatable.")
    ap.add_argument("--crosstab", metavar="ROW:COL:MEASURE",
                    help="render a pivot crosstab (rows=ROW, columns=COL, Sum of "
                         "MEASURE) with row/column totals instead of the flat table.")
    ap.add_argument("--subreport", metavar="JRXML_FILE_URI[:p=COL;..]",
                    help="embed a child report as a subreport in the summary band. "
                         "JRXML_FILE_URI must point to a jrxml FILE resource (not a "
                         "reportUnit) -- e.g. a report unit's main jrxml at "
                         "/reports/x/rpt_files/Label_main_jrxml, or a jrxml uploaded "
                         "with upload_file.ps1. Runs on the parent connection; "
                         "p=COL passes a field value as parameter p.")
    ap.add_argument("--dialect", default="postgres", choices=list(DIALECTS),
                    help="target SQL dialect of the datasource (default: postgres, "
                         "no extra checks). x100 (Actian Vector/Avalanche) runs a "
                         "static pre-compile check and REFUSES the scaffold on "
                         "ordered aggregates / ordered aggregate windows, correlated "
                         "columns inside aggregates in subqueries, and ';' inside "
                         "SQL comments. Heuristic; see check_dialect_sql.")
    ap.add_argument("--allow-dialect-warnings", action="store_true",
                    help="downgrade --dialect ERRORs to warnings and scaffold anyway")
    ap.add_argument("--check-only", action="store_true",
                    help="run the SQL lint + --dialect check on the query and exit "
                         "(0 clean, 1 findings); no psql, no file written")
    args = ap.parse_args()

    subreport = None
    if args.subreport:
        sp = args.subreport.split(":", 1)
        sub_uri = sp[0]
        sub_params = []
        if len(sp) == 2 and sp[1]:
            for pair in sp[1].split(";"):
                if "=" in pair:
                    pn, sc = pair.split("=", 1); sub_params.append((pn, sc))
        subreport = (sub_uri, sub_params)

    crosstab = None
    if args.crosstab:
        ct = args.crosstab.split(":")
        if len(ct) != 3:
            sys.stderr.write(f"ERROR: --crosstab needs ROW:COL:MEASURE, got '{args.crosstab}'\n"); sys.exit(2)
        crosstab = (ct[0], ct[1], ct[2])

    params = [parse_param(s) for s in args.param]

    drills = {}
    for d in args.drill:
        parts = d.split(":", 2)
        if len(parts) < 2:
            sys.stderr.write(f"ERROR: bad --drill '{d}' (COL:TARGET_URI[:p=COL2;..])\n"); sys.exit(2)
        col, target = parts[0], parts[1]
        pmap = []
        if len(parts) == 3 and parts[2]:
            for pair in parts[2].split(";"):
                if "=" in pair:
                    pn, sc = pair.split("=", 1); pmap.append((pn, sc))
        drills[col] = {"target": target, "params": pmap}

    highlights = []
    for h in args.highlight:
        parts = h.split(":", 3)
        if len(parts) != 4:
            sys.stderr.write(f"ERROR: bad --highlight '{h}' (COL:OP:VALUE:#COLOR)\n"); sys.exit(2)
        highlights.append({"col": parts[0], "op": parts[1], "value": parts[2], "color": parts[3]})

    if args.query_file:
        with open(args.query_file, encoding="utf-8") as f:
            query = f.read()
    else:
        query = args.query

    generic = lint_sql(query)
    for level, msg in generic:
        sys.stderr.write(f"SQL {level}: {msg}\n")
    dialect_findings = check_dialect_sql(query, args.dialect)
    refuse = report_dialect_findings(dialect_findings, args.allow_dialect_warnings)

    if args.check_only:
        n_err = sum(1 for lv, _m in generic if lv == "ERROR") + \
            (sum(1 for lv, _r, _m in dialect_findings if lv == "ERROR") if not args.allow_dialect_warnings else 0)
        n_all = len(generic) + len(dialect_findings)
        print(f"check-only ({args.dialect}): {n_all} finding(s), {n_err} error(s)")
        sys.exit(1 if n_err else 0)

    if refuse:
        sys.stderr.write(f"ERROR: query fails the {args.dialect} dialect check; "
                         "nothing written. Fix the SQL or pass --allow-dialect-warnings.\n")
        sys.exit(3)

    if "PGPASSWORD" not in os.environ:
        sys.stderr.write("WARNING: PGPASSWORD not set; psql may prompt or fail.\n")

    # introspect against a copy with $P{..} replaced by literals so psql can run it
    introspect_q = substitute_params(query, params) if params else query
    cols = introspect(introspect_q, args.host, args.port, args.user, args.db)

    w, h = PAGE_SIZES[args.page_size]
    if args.landscape:
        w, h = h, w

    chart_cat = chart_val = chart_trend = chart_slice_colors = None
    if args.chart:
        chart_cat = args.chart_category or first_text_col(cols)
        chart_val = args.chart_value or first_numeric_col(cols)
        if not chart_val:
            sys.stderr.write("ERROR: --chart needs a numeric column; none found "
                             "(use --chart-value).\n")
            sys.exit(2)
        # default trend column for the gradient-bar customizer: first other numeric
        if args.chart == "bar" and not args.no_gradient and not args.chart_series:
            chart_trend = args.chart_trend or second_numeric_col(cols, chart_val)
        # default Actian-blue slice gradient for pie charts (sized to the row count,
        # capped; the query should ORDER BY value DESC for largest=deepest)
        if args.chart in ("pie", "pie3d") and not args.no_gradient:
            n = row_count(introspect_q, args.host, args.port, args.user, args.db)
            chart_slice_colors = blue_gradient(min(n or 8, 24))

    title = args.title or label_for(args.name)
    xml = build_jrxml(args.name, title, args.subtitle, query, cols,
                      page_w=w, page_h=h, chart=args.chart, chart_cat=chart_cat,
                      chart_val=chart_val, chart_series=args.chart_series,
                      chart_height=args.chart_height,
                      chart_label_rotation=args.chart_label_rotation,
                      chart_trend=chart_trend, chart_gradient=(not args.no_gradient),
                      chart_slice_colors=chart_slice_colors,
                      params=params, group_by=args.group_by, drills=drills,
                      highlights=highlights, crosstab=crosstab, subreport=subreport,
                      theme=args.template, style_template=args.style_template,
                      logo=(None if args.no_logo else args.logo_uri))

    out_path = args.out or f"{args.name}.jrxml"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(xml)

    print(f"OK: scaffolded {out_path} ({len(cols)} fields)")
    for cname, udt in cols:
        print(f"    {cname:<24} {udt:<14} -> {java_class(udt)}")


if __name__ == "__main__":
    main()
