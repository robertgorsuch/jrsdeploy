package com.jasperwizard;

import jakarta.servlet.ServletConfig;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Dispatcher servlet for the Jaspersoft Artifact Wizard.
 *
 * Design split:
 *   - Reads / preview / run  -> proxied to JasperReports Server via {@link JrsClient}
 *     (auth added server-side: no browser creds, no CORS).
 *   - Create / deploy        -> shelled out to the verified jasper-deploy scripts
 *     via {@link ScriptRunner} (scripts are bundled in WEB-INF/scripts so the
 *     LocalService Tomcat account can run them without touching the user profile).
 *
 * Routes are grouped by feature below; each handler is a small private method.
 */
public class WizardServlet extends HttpServlet {

    private String jrsUrl, jrsUser, jrsPass, repoRoot, pgPassword, pgHost, pgPort, pgUser, pythonExe, scriptsDir;
    private int timeoutSec;
    private File workDir;
    private JrsClient jrs;

    @Override
    public void init(ServletConfig cfg) throws ServletException {
        super.init(cfg);
        jrsUrl     = ctx("jrsUrl", "http://localhost:8081/jasperserver-pro");
        jrsUser    = ctx("jrsUser", "superuser");
        jrsPass    = ctx("jrsPass", "superuser");
        // repoRoot is only a fallback when the WAR-bundled WEB-INF/scripts is absent:
        // web.xml context-param -> JASPER_WIZARD_REPO_ROOT env var -> working dir
        String repoEnv = System.getenv("JASPER_WIZARD_REPO_ROOT");
        repoRoot   = ctx("repoRoot", (repoEnv != null && !repoEnv.isEmpty()) ? repoEnv : System.getProperty("user.dir"));
        pgPassword = ctx("pgPassword", "postgres");
        pgHost     = ctx("pgHost", "localhost");
        pgPort     = ctx("pgPort", "5432");
        pgUser     = ctx("pgUser", "postgres");
        pythonExe  = ctx("pythonExe", "python");
        timeoutSec = Integer.parseInt(ctx("scriptTimeoutSec", "180"));

        String bundled = getServletContext().getRealPath("/WEB-INF/scripts");
        scriptsDir = (bundled != null && new File(bundled).isDirectory())
                ? bundled
                : repoRoot + File.separator + ".claude" + File.separator + "skills"
                  + File.separator + "jasper-deploy" + File.separator + "scripts";

        File ctxTmp = (File) getServletContext().getAttribute("jakarta.servlet.context.tempdir");
        workDir = (ctxTmp != null) ? new File(ctxTmp, "work") : new File(System.getProperty("java.io.tmpdir"), "jasper-wizard");
        workDir.mkdirs();

        jrs = new JrsClient(jrsUrl, jrsUser, jrsPass, timeoutSec);
    }

    private String ctx(String name, String dflt) {
        String v = getServletContext().getInitParameter(name);
        return (v == null || v.isEmpty()) ? dflt : v;
    }

    // =========================================================== routing ====

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String p = path(req);
        try {
            switch (p) {
                case "/health":           health(resp); return;
                case "/summary":          summary(resp); return;
                case "/datasources":      proxy("/rest_v2/resources?type=jdbcDataSource&recursive=true", resp); return;
                case "/reports":          proxy("/rest_v2/resources?folderUri=" + JrsClient.enc(param(req,"folder","/reports")) + "&type=reportUnit&recursive=true", resp); return;
                case "/resources":        listResources(req, resp); return;
                case "/run":              runReport(req, resp); return;
                case "/controls":         proxy("/rest_v2/reports" + req.getParameter("uri") + "/inputControls", resp); return;
                case "/controls/values":  controlValues(req, resp); return;
                case "/export":           exportResource(req, resp); return;
                case "/permissions":      proxy("/rest_v2/permissions" + req.getParameter("uri") + "?effectivePermissions=true", resp); return;
                case "/jobs":             proxy("/rest_v2/jobs?reportUnitURI=" + JrsClient.enc(param(req,"reportUri","")), resp); return;
                case "/domains":          proxy("/rest_v2/resources?type=semanticLayerDataSource&recursive=true", resp); return;
                case "/adhoc":            proxy("/rest_v2/resources?folderUri=" + JrsClient.enc(param(req,"folder","/public")) + "&type=adhocDataView&recursive=true", resp); return;
                case "/adhoc/export":     adhocExport(req, resp); return;
                default:                  json(resp, 404, err("unknown GET " + p));
            }
        } catch (Exception e) { json(resp, 500, err(e.getMessage())); }
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String p = path(req);
        try {
            switch (p) {
                case "/datasources":   createDatasource(req, resp); return;
                case "/query/preview": previewQuery(req, resp); return;
                case "/reports":       deployReport(req, resp); return;
                case "/dashboards":    composeDashboard(req, resp); return;
                case "/permissions":   setPermissions(req, resp); return;
                case "/jobs":          createJob(req, resp); return;
                case "/domains":       createDomain(req, resp); return;
                case "/themes":        deployTheme(req, resp); return;
                default:               json(resp, 404, err("unknown POST " + p));
            }
        } catch (Exception e) { json(resp, 500, err(e.getMessage())); }
    }

    @Override
    protected void doDelete(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String p = path(req);
        try {
            switch (p) {
                case "/resources":   { JrsClient.Resp r = jrs.delete("/rest_v2/resources" + req.getParameter("uri")); json(resp, r.ok()?200:r.code, "{\"ok\":"+r.ok()+"}"); return; }
                case "/jobs":        { JrsClient.Resp r = jrs.delete("/rest_v2/jobs/" + req.getParameter("id"));      json(resp, r.ok()?200:r.code, "{\"ok\":"+r.ok()+"}"); return; }
                case "/permissions": clearPermissions(req, resp); return;
                default:             json(resp, 404, err("unknown DELETE " + p));
            }
        } catch (Exception e) { json(resp, 500, err(e.getMessage())); }
    }

    // ============================================================ reports ====

    /** Run psql to preview a query's columns + a few rows before deploying. */
    private void previewQuery(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String db = param(req, "db", "postgis_34_sample");
        String query = req.getParameter("query");
        if (empty(query)) { json(resp, 400, err("query is required")); return; }
        String q = query.trim();
        while (q.endsWith(";")) q = q.substring(0, q.length() - 1).trim();
        // wrap so any user ORDER BY/LIMIT is preserved and we still cap the rows
        String copy = "COPY (SELECT * FROM (" + q + ") _q LIMIT 25) TO STDOUT WITH CSV HEADER";
        List<String> cmd = new ArrayList<>(List.of(
                "psql", "-h", pgHost, "-p", pgPort, "-U", pgUser, "-d", db,
                "-w", "-v", "ON_ERROR_STOP=1", "-c", copy));
        Map<String, String> env = new HashMap<>();
        env.put("PGPASSWORD", pgPassword);
        ScriptRunner.Result r = new ScriptRunner(workDir, timeoutSec, env).exec(cmd);
        if (!r.ok()) { json(resp, 200, "{\"ok\":false,\"error\":" + Json.str(r.output) + "}"); return; }
        json(resp, 200, "{\"ok\":true,\"csv\":" + Json.str(r.output) + "}");
    }

    private void deployReport(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String name = req.getParameter("name"), query = req.getParameter("query"), ds = req.getParameter("dataSourceUri");
        if (empty(name) || empty(query) || empty(ds)) { json(resp, 400, err("name, query and dataSourceUri are required")); return; }
        String folder = param(req, "folder", "/reports/wizard"), label = param(req, "label", name);
        String db = param(req, "db", "postgis_34_sample");
        String safe = name.replaceAll("[^A-Za-z0-9_]", "_");
        File jrxml = new File(workDir, safe + "_" + System.currentTimeMillis() + ".jrxml");

        List<String> sa = new ArrayList<>();
        addArg(sa, "--name", safe);
        addArg(sa, "--title", param(req, "title", name));
        addArg(sa, "--subtitle", param(req, "subtitle", ""));
        addArg(sa, "--db", db);
        addArg(sa, "--query", query);
        addArg(sa, "--template", param(req, "template", "slate"));
        addArg(sa, "--out", jrxml.getAbsolutePath());
        String chart = param(req, "chart", "");
        if (!empty(chart) && !chart.equalsIgnoreCase("none")) {
            addArg(sa, "--chart", chart);
            addArg(sa, "--chart-category", param(req, "chartCategory", ""));
            addArg(sa, "--chart-value", param(req, "chartValue", ""));
        }
        addArg(sa, "--group-by", param(req, "groupBy", ""));
        addArg(sa, "--page-size", param(req, "pageSize", "letter"));
        if ("true".equalsIgnoreCase(req.getParameter("landscape"))) sa.add("--landscape");
        // optional report parameter: NAME:TYPE:DEFAULT used as $P{NAME} in the query
        String paramSpec = param(req, "paramSpec", "");
        if (!empty(paramSpec)) addArg(sa, "--param", paramSpec);

        Map<String, String> sEnv = new HashMap<>(); sEnv.put("PGPASSWORD", pgPassword);
        ScriptRunner.Result scaffold = run(sEnv).python(pythonExe, script("scaffold_jrxml.py"), sa);
        if (!scaffold.ok()) { json(resp, 500, stepFail("scaffold", scaffold)); return; }

        String target = (folder + "/" + safe).replaceAll("//+", "/");
        List<String> da = new ArrayList<>();
        addArg(da, "-Jrxml", jrxml.getAbsolutePath());
        addArg(da, "-TargetUri", target);
        addArg(da, "-Label", label);
        addArg(da, "-DataSourceUri", ds);
        da.add("-Overwrite");
        da.add("-Apply");   // deploy_report -Overwrite plans by default (jasper-deploy 1.3.0)
        // optional interactive input control: param:kind[:label[:extra]]
        String control = param(req, "control", "");
        if (!empty(control)) { da.add("-Control"); da.add(control); }
        // optional query-backed control: param|valueCol|visibleCols|SQL
        String queryControl = param(req, "queryControl", "");
        if (!empty(queryControl)) { da.add("-QueryControl"); da.add(queryControl); }

        ScriptRunner.Result deploy = run(jrsEnv()).powershell(script("deploy_report.ps1"), da);
        if (!deploy.ok()) { json(resp, 500, stepFail("deploy", deploy)); return; }

        String preview = req.getContextPath() + "/api/run?uri=" + JrsClient.enc(target) + "&format=pdf";
        json(resp, 200, "{\"ok\":true,\"reportUri\":" + Json.str(target)
                + ",\"previewUrl\":" + Json.str(preview)
                + ",\"output\":" + Json.str("[scaffold]\n" + scaffold.output + "\n[deploy]\n" + deploy.output) + "}");
    }

    /** Run a report and stream it. Forwards extra params as input-control values;
     *  async=true routes large fills through run_report_async.ps1. */
    private void runReport(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri");
        String fmt = param(req, "format", "pdf");
        if (empty(uri)) { json(resp, 400, err("uri is required")); return; }

        if ("true".equalsIgnoreCase(req.getParameter("async"))) {
            File out = new File(workDir, "async_" + System.currentTimeMillis() + "." + fmt);
            List<String> a = new ArrayList<>();
            addArg(a, "-ReportUri", uri); addArg(a, "-Format", fmt); addArg(a, "-OutFile", out.getAbsolutePath());
            ScriptRunner.Result r = run(jrsEnv()).powershell(script("run_report_async.ps1"), a);
            if (!r.ok() || !out.exists()) { json(resp, 500, stepFail("async-run", r)); return; }
            resp.setContentType(contentType(fmt));
            try (OutputStream os = resp.getOutputStream()) { Files.copy(out.toPath(), os); }
            return;
        }

        StringBuilder rest = new StringBuilder("/rest_v2/reports" + uri + "." + fmt);
        char sep = '?';
        Enumeration<String> names = req.getParameterNames();
        while (names.hasMoreElements()) {
            String n = names.nextElement();
            if (n.equals("uri") || n.equals("format") || n.equals("async")) continue;
            rest.append(sep).append(JrsClient.enc(n)).append('=').append(JrsClient.enc(req.getParameter(n)));
            sep = '&';
        }
        jrs.stream(rest.toString(), resp);
    }

    private void controlValues(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri"), id = req.getParameter("id");
        StringBuilder rest = new StringBuilder("/rest_v2/reports" + uri + "/inputControls/" + id + "/values");
        char sep = '?';
        Enumeration<String> names = req.getParameterNames();
        while (names.hasMoreElements()) {
            String n = names.nextElement();
            if (n.equals("uri") || n.equals("id")) continue;
            rest.append(sep).append(JrsClient.enc(n)).append('=').append(JrsClient.enc(req.getParameter(n)));
            sep = '&';
        }
        proxy(rest.toString(), resp);
    }

    // ======================================================== datasources ====

    private void createDatasource(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri"), database = req.getParameter("database");
        if (empty(uri) || empty(database)) { json(resp, 400, err("uri and database are required")); return; }
        List<String> a = new ArrayList<>();
        addArg(a, "-Uri", uri);
        addArg(a, "-Label", param(req, "label", uri));
        addArg(a, "-Database", database);
        addArg(a, "-DbHost", param(req, "host", "localhost"));
        addArg(a, "-DbPort", param(req, "port", "5432"));
        addArg(a, "-DbUser", param(req, "dbUser", "postgres"));
        addArg(a, "-DbPassword", param(req, "dbPassword", "postgres"));
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("create_datasource.ps1"), a);
        json(resp, r.ok()?200:500, "{\"ok\":" + r.ok() + ",\"uri\":" + Json.str(uri) + ",\"output\":" + Json.str(r.output) + "}");
    }

    // ========================================================== dashboards ===

    private void composeDashboard(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String name = req.getParameter("name"), reports = req.getParameter("reports");
        if (empty(name) || empty(reports)) { json(resp, 400, err("name and reports are required")); return; }
        String folder = param(req, "folder", "/reports/wizard"), label = param(req, "label", name);
        int cols = Integer.parseInt(param(req, "cols", "2"));
        String safe = name.replaceAll("[^A-Za-z0-9_]", "_");

        String[] uris = reports.split(",");
        int gridW = 40, tileW = Math.max(1, gridW / cols), tileH = 10;
        StringBuilder dl = new StringBuilder();
        for (int i = 0; i < uris.length; i++) {
            String uri = uris[i].trim();
            if (uri.isEmpty()) continue;
            String leaf = uri.substring(uri.lastIndexOf('/') + 1);
            int col = i % cols, row = i / cols;
            if (dl.length() > 0) dl.append(",");
            dl.append("{\"kind\":\"report\",\"name\":").append(Json.str(leaf))
              .append(",\"title\":").append(Json.str(leaf))
              .append(",\"reportUri\":").append(Json.str(uri))
              .append(",\"x\":").append(col * tileW).append(",\"y\":").append(row * tileH)
              .append(",\"width\":").append(tileW).append(",\"height\":").append(tileH).append("}");
        }
        String manifest = "{\"folder\":" + Json.str(folder) + ",\"name\":" + Json.str(safe)
                + ",\"label\":" + Json.str(label) + ",\"cols\":" + cols + ",\"dashlets\":[" + dl + "]}";
        File mf = new File(workDir, safe + "_dash_" + System.currentTimeMillis() + ".json");
        Files.write(mf.toPath(), manifest.getBytes(StandardCharsets.UTF_8));

        List<String> a = new ArrayList<>();
        addArg(a, "-Manifest", mf.getAbsolutePath());
        addArg(a, "-WorkDir", new File(workDir, "dash_build_" + System.currentTimeMillis()).getAbsolutePath());
        a.add("-Apply");   // compose_dashboard plans by default (jasper-deploy 1.3.0)
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("compose_dashboard.ps1"), a);
        String dashUri = (folder + "/" + safe).replaceAll("//+", "/");
        String viewer = jrsUrl + "/dashboard/viewer.html#" + JrsClient.enc(dashUri);
        json(resp, r.ok()?200:500, "{\"ok\":" + r.ok() + ",\"dashboardUri\":" + Json.str(dashUri)
                + ",\"viewerUrl\":" + Json.str(viewer) + ",\"output\":" + Json.str(r.output) + "}");
    }

    // ============================================================= domains ===

    private void createDomain(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String name = req.getParameter("name"), table = req.getParameter("table"), ds = req.getParameter("dataSourceUri");
        if (empty(name) || empty(table) || empty(ds)) { json(resp, 400, err("name, table and dataSourceUri are required")); return; }
        String db = param(req, "db", "foodmart");
        String safe = name.replaceAll("[^A-Za-z0-9_]", "_");
        String dsLeaf = ds.substring(ds.lastIndexOf('/') + 1);
        File schema = new File(workDir, safe + "_schema_" + System.currentTimeMillis() + ".xml");

        List<String> pa = new ArrayList<>();
        addArg(pa, "--name", safe); addArg(pa, "--table", table); addArg(pa, "--db", db);
        addArg(pa, "--datasource-id", dsLeaf); addArg(pa, "--out", schema.getAbsolutePath());
        Map<String, String> env = new HashMap<>(); env.put("PGPASSWORD", pgPassword);
        ScriptRunner.Result sch = run(env).python(pythonExe, script("scaffold_domain_schema.py"), pa);
        if (!sch.ok()) { json(resp, 500, stepFail("schema", sch)); return; }

        List<String> da = new ArrayList<>();
        addArg(da, "-Uri", "/domains/" + safe);
        addArg(da, "-SchemaFile", schema.getAbsolutePath());
        addArg(da, "-DataSourceUri", ds);
        addArg(da, "-Label", param(req, "label", name));
        da.add("-Overwrite");
        ScriptRunner.Result cd = run(jrsEnv()).powershell(script("create_domain.ps1"), da);
        if (!cd.ok()) { json(resp, 500, stepFail("create-domain", cd)); return; }
        json(resp, 200, "{\"ok\":true,\"domainUri\":" + Json.str("/domains/" + safe)
                + ",\"output\":" + Json.str("[schema]\n" + sch.output + "\n[domain]\n" + cd.output) + "}");
    }

    // ============================================================== adhoc ====

    private void adhocExport(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri");
        if (empty(uri)) { json(resp, 400, err("uri is required")); return; }
        File zip = new File(workDir, "adhoc_" + System.currentTimeMillis() + ".zip");
        List<String> a = new ArrayList<>();
        addArg(a, "-Action", "export"); addArg(a, "-Uri", uri); addArg(a, "-OutFile", zip.getAbsolutePath());
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("manage_adhoc.ps1"), a);
        if (!r.ok() || !zip.exists()) { json(resp, 500, stepFail("adhoc-export", r)); return; }
        streamFile(zip, "application/zip", uri.substring(uri.lastIndexOf('/') + 1) + ".zip", resp);
    }

    // ========================================================= scheduling ====

    private void createJob(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String reportUri = req.getParameter("reportUri");
        if (empty(reportUri)) { json(resp, 400, err("reportUri is required")); return; }
        List<String> a = new ArrayList<>();
        addArg(a, "-ReportUri", reportUri);
        addArg(a, "-Label", param(req, "label", ""));
        String startType = param(req, "startType", "now");
        addArg(a, "-StartType", startType);
        if (startType.equals("at")) addArg(a, "-StartDate", param(req, "startDate", ""));
        String recurUnit = param(req, "recurrenceIntervalUnit", "");
        if (!empty(recurUnit)) {
            addArg(a, "-OccurrenceCount", "-1");
            addArg(a, "-RecurrenceInterval", param(req, "recurrenceInterval", "1"));
            addArg(a, "-RecurrenceIntervalUnit", recurUnit);
        }
        // -OutputFormats is a string[] -> pass comma-joined (PowerShell binds it)
        String formats = param(req, "formats", "PDF");
        a.add("-OutputFormats"); a.add(formats);
        String mailTo = param(req, "mailTo", "");
        if (!empty(mailTo)) { a.add("-MailTo"); a.add(mailTo); }
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("schedule_job.ps1"), a);
        json(resp, r.ok()?200:500, "{\"ok\":" + r.ok() + ",\"output\":" + Json.str(r.output) + "}");
    }

    // ======================================================== permissions ====

    private void setPermissions(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri"), recipient = req.getParameter("recipient"), mask = req.getParameter("mask");
        if (empty(uri) || empty(recipient) || empty(mask)) { json(resp, 400, err("uri, recipient and mask are required")); return; }
        List<String> a = new ArrayList<>();
        addArg(a, "-Action", "set"); addArg(a, "-Uri", uri);
        a.add("-Recipient"); a.add(recipient); a.add("-Mask"); a.add(mask);
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("manage_permissions.ps1"), a);
        json(resp, r.ok()?200:500, "{\"ok\":" + r.ok() + ",\"output\":" + Json.str(r.output) + "}");
    }

    private void clearPermissions(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri");
        if (empty(uri)) { json(resp, 400, err("uri is required")); return; }
        List<String> a = new ArrayList<>();
        addArg(a, "-Action", "clear"); addArg(a, "-Uri", uri);
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("manage_permissions.ps1"), a);
        json(resp, r.ok()?200:500, "{\"ok\":" + r.ok() + ",\"output\":" + Json.str(r.output) + "}");
    }

    // ============================================================== themes ===

    private void deployTheme(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String name = req.getParameter("name");
        if (empty(name)) { json(resp, 400, err("name is required")); return; }
        String safe = name.replaceAll("[^A-Za-z0-9_]", "_");
        String palette = param(req, "palette", "corporate");
        File cssDir = new File(workDir, "theme_" + safe + "_" + System.currentTimeMillis());
        cssDir.mkdirs();
        File css = new File(cssDir, "overrides_custom.css");
        List<String> pa = new ArrayList<>();
        addArg(pa, "--name", safe); addArg(pa, "--palette", palette); addArg(pa, "--out", css.getAbsolutePath());
        ScriptRunner.Result scaffold = run(null).python(pythonExe, script("scaffold_theme.py"), pa);
        if (!scaffold.ok()) { json(resp, 500, stepFail("scaffold-theme", scaffold)); return; }
        List<String> da = new ArrayList<>();
        addArg(da, "-CssFile", css.getAbsolutePath()); addArg(da, "-Name", safe); da.add("-Overwrite");
        ScriptRunner.Result deploy = run(jrsEnv()).powershell(script("deploy_theme.ps1"), da);
        json(resp, deploy.ok()?200:500, "{\"ok\":" + deploy.ok() + ",\"theme\":" + Json.str(safe)
                + ",\"output\":" + Json.str("[scaffold]\n" + scaffold.output + "\n[deploy]\n" + deploy.output) + "}");
    }

    // ========================================================= repository ====

    private void listResources(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String folder = param(req, "folder", "/");
        String type = param(req, "type", "");
        String rest = "/rest_v2/resources?folderUri=" + JrsClient.enc(folder) + "&recursive=true"
                + (empty(type) ? "" : "&type=" + JrsClient.enc(type));
        proxy(rest, resp);
    }

    private void exportResource(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String uri = req.getParameter("uri");
        if (empty(uri)) { json(resp, 400, err("uri is required")); return; }
        File zip = new File(workDir, "export_" + System.currentTimeMillis() + ".zip");
        List<String> a = new ArrayList<>();
        addArg(a, "-Uri", uri); addArg(a, "-Out", zip.getAbsolutePath());
        ScriptRunner.Result r = run(jrsEnv()).powershell(script("export_resource.ps1"), a);
        if (!r.ok() || !zip.exists()) { json(resp, 500, stepFail("export", r)); return; }
        streamFile(zip, "application/zip", uri.substring(uri.lastIndexOf('/') + 1) + ".zip", resp);
    }

    // ============================================================== shared ===

    /**
     * Aggregate the server's metadata + runtime characteristics and the repository
     * inventory into one JSON document (one round-trip for the UI):
     *  - server:      raw serverInfo (version, edition, license, build, formats, features)
     *  - repository:  count of resources per type
     *  - identity:    organizations / users / roles counts
     *  - scheduling:  total scheduled jobs
     *  - datasources: the JDBC datasource list (raw)
     */
    private void summary(HttpServletResponse resp) throws IOException {
        String server = okBody(jrs.get("/rest_v2/serverInfo"));
        String[] types = {"reportUnit", "dashboard", "adhocDataView", "semanticLayerDataSource",
                          "jdbcDataSource", "olapUnit", "inputControl", "query", "file", "folder"};
        StringBuilder repo = new StringBuilder("{");
        for (int i = 0; i < types.length; i++) {
            int c = countJsonArray(okBody(jrs.get("/rest_v2/resources?type=" + types[i] + "&recursive=true")), "resourceLookup");
            if (i > 0) repo.append(",");
            repo.append(Json.str(types[i])).append(":").append(c);
        }
        repo.append("}");
        int users = countJsonArray(okBody(jrs.get("/rest_v2/users")), "user");
        int roles = countJsonArray(okBody(jrs.get("/rest_v2/roles")), "role");
        int orgs  = countJsonArray(okBody(jrs.get("/rest_v2/organizations")), "organization");
        int jobs  = countJsonArray(okBody(jrs.get("/rest_v2/jobs")), "jobsummary");
        String ds = okBody(jrs.get("/rest_v2/resources?type=jdbcDataSource&recursive=true"));
        if (ds.isEmpty()) ds = "{}";
        if (server.isEmpty()) server = "{}";

        String out = "{\"ok\":true"
                + ",\"server\":" + server
                + ",\"repository\":" + repo
                + ",\"identity\":{\"organizations\":" + orgs + ",\"users\":" + users + ",\"roles\":" + roles + "}"
                + ",\"scheduling\":{\"jobs\":" + jobs + "}"
                + ",\"datasources\":" + ds + "}";
        json(resp, 200, out);
    }

    private static String okBody(JrsClient.Resp r) {
        return (r != null && r.body != null && !r.body.isEmpty() && r.code < 400) ? r.body : "";
    }

    /** Count the elements of a named JSON array without a full parser: walk the
     *  array body tracking string/escape state and brace/bracket depth, counting
     *  top-level commas. Robust for arrays of objects or scalars; 0 if empty/absent. */
    static int countJsonArray(String json, String key) {
        if (json == null) return 0;
        int k = json.indexOf("\"" + key + "\"");
        if (k < 0) return 0;
        int open = json.indexOf('[', k);
        if (open < 0) return 0;
        int depth = 0, commas = 0;
        boolean inStr = false, esc = false, any = false;
        for (int i = open + 1; i < json.length(); i++) {
            char c = json.charAt(i);
            if (inStr) {
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
                continue;
            }
            if (c == '"') { inStr = true; any = true; }
            else if (c == '[' || c == '{') { depth++; any = true; }
            else if (c == ']') { if (depth == 0) break; depth--; }
            else if (c == '}') { depth--; }
            else if (c == ',') { if (depth == 0) commas++; }
            else if (!Character.isWhitespace(c)) any = true;
        }
        return any ? commas + 1 : 0;
    }

    private void health(HttpServletResponse resp) throws IOException {
        boolean up = false;
        try { up = jrs.get("/rest_v2/serverInfo").ok(); } catch (Exception ignore) {}
        json(resp, 200, "{\"ok\":true,\"server\":" + Json.str(jrsUrl) + ",\"jrsUp\":" + up + "}");
    }

    /** GET a JRS path and forward the JSON body verbatim (204/empty -> {}). */
    private void proxy(String restPath, HttpServletResponse resp) throws IOException {
        JrsClient.Resp r = jrs.get(restPath);
        String body = (r.code == 204 || r.body.isEmpty()) ? "{}" : r.body;
        json(resp, r.code == 204 ? 200 : r.code, body);
    }

    private ScriptRunner run(Map<String, String> extraEnv) { return new ScriptRunner(workDir, timeoutSec, extraEnv); }

    private Map<String, String> jrsEnv() {
        Map<String, String> e = new HashMap<>();
        e.put("JRS_URL", jrsUrl); e.put("JRS_USER", jrsUser); e.put("JRS_PASS", jrsPass); e.put("PGPASSWORD", pgPassword);
        return e;
    }

    private String script(String file) { return scriptsDir + File.separator + file; }

    private static void addArg(List<String> a, String flag, String value) {
        if (value != null && !value.isEmpty()) { a.add(flag); a.add(value); }
    }
    private static String path(HttpServletRequest req) { return req.getPathInfo() == null ? "/" : req.getPathInfo(); }
    private static String param(HttpServletRequest req, String name, String dflt) {
        String v = req.getParameter(name); return (v == null || v.isEmpty()) ? dflt : v;
    }
    private static boolean empty(String s) { return s == null || s.trim().isEmpty(); }

    private static String contentType(String fmt) {
        switch (fmt.toLowerCase()) {
            case "pdf":  return "application/pdf";
            case "html": return "text/html";
            case "csv":  return "text/csv";
            case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
            case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
            default:      return "application/octet-stream";
        }
    }
    private void streamFile(File f, String ct, String filename, HttpServletResponse resp) throws IOException {
        resp.setContentType(ct);
        resp.setHeader("Content-Disposition", "attachment; filename=\"" + filename + "\"");
        try (OutputStream os = resp.getOutputStream()) { Files.copy(f.toPath(), os); }
    }
    private static String err(String m) { return "{\"ok\":false,\"error\":" + Json.str(m) + "}"; }
    private static String stepFail(String step, ScriptRunner.Result r) {
        return "{\"ok\":false,\"failedStep\":" + Json.str(step) + ",\"output\":" + Json.str(r.output) + "}";
    }
    private static void json(HttpServletResponse resp, int status, String body) throws IOException {
        resp.setStatus(status);
        resp.setContentType("application/json;charset=UTF-8");
        try (PrintWriter w = resp.getWriter()) { w.write(body); }
    }
}
