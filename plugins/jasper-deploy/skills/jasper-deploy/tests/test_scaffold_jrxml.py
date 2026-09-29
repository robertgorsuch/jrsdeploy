#!/usr/bin/env python3
"""Unit tests for scripts/scaffold_jrxml.py --dialect checks (plain unittest;
also discoverable by pytest). Offline: no psql, no server.

Run:  python -m unittest tests/test_scaffold_jrxml.py -v      (from the skill root)
      python -m pytest tests/test_scaffold_jrxml.py            (if pytest is installed)
"""
import io
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "scripts")
sys.path.insert(0, SCRIPTS)

import scaffold_jrxml as sj  # noqa: E402

SCRIPT = os.path.join(SCRIPTS, "scaffold_jrxml.py")


def rules(findings):
    return sorted({r for _lv, r, _m in findings})


class DialectCheckerTests(unittest.TestCase):

    def test_postgres_is_a_no_op(self):
        q = "SELECT string_agg(x, ',' ORDER BY x) FROM t -- a; b"
        self.assertEqual(sj.check_dialect_sql(q, "postgres"), [])
        self.assertEqual(sj.check_dialect_sql(q), [])

    def test_unknown_dialect_raises(self):
        with self.assertRaises(ValueError):
            sj.check_dialect_sql("SELECT 1", "oracle")

    def test_clean_x100_query_passes(self):
        q = ("SELECT s.store_id, SUM(s.net_sales) AS sales,\n"
             "       ROW_NUMBER() OVER (ORDER BY SUM(s.net_sales) DESC) AS rk\n"
             "FROM sales s JOIN stores st ON st.id = s.store_id\n"
             "WHERE s.sale_date >= DATE '2026-01-01'\n"
             "GROUP BY s.store_id")
        self.assertEqual(sj.check_dialect_sql(q, "x100"), [])

    def test_string_agg_order_by_refused(self):
        q = "SELECT STRING_AGG(name, ', ' ORDER BY name) FROM products"
        self.assertEqual(rules(sj.check_dialect_sql(q, "x100")), ["x100-ordered-aggregate"])

    def test_array_agg_listagg_within_group(self):
        for q in ("SELECT ARRAY_AGG(x ORDER BY y) FROM t",
                  "SELECT LISTAGG(x, ',') WITHIN GROUP (ORDER BY x) FROM t",
                  "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) FROM t"):
            self.assertIn("x100-ordered-aggregate", rules(sj.check_dialect_sql(q, "x100")), q)

    def test_running_total_window_refused(self):
        q = "SELECT d, SUM(amt) OVER (PARTITION BY store ORDER BY d) FROM t"
        self.assertEqual(rules(sj.check_dialect_sql(q, "x100")), ["x100-ordered-aggregate"])

    def test_unordered_window_and_ranking_allowed(self):
        q = ("SELECT d, SUM(amt) OVER (PARTITION BY store) AS tot,\n"
             "       RANK() OVER (PARTITION BY store ORDER BY amt DESC) AS rk,\n"
             "       LAG(amt) OVER (ORDER BY d) AS prev FROM t")
        self.assertEqual(sj.check_dialect_sql(q, "x100"), [])

    def test_semicolon_in_line_and_block_comment(self):
        q = "SELECT 1 -- note; careful\nFROM t /* also; here */"
        f = sj.check_dialect_sql(q, "x100")
        self.assertEqual([r for _l, r, _m in f], ["x100-semicolon-in-comment"] * 2)
        self.assertIn("line 1", f[0][2])
        self.assertIn("line 2", f[1][2])

    def test_semicolon_in_string_literal_is_fine(self):
        q = "SELECT 'a; b' AS s, '--; not a comment' FROM t"
        self.assertEqual(sj.check_dialect_sql(q, "x100"), [])

    def test_correlated_aggregate_refused(self):
        q = ("SELECT o.id, o.total\n"
             "FROM orders o\n"
             "WHERE o.total > (SELECT AVG(l.qty * o.unit_price) FROM lines l)")
        f = sj.check_dialect_sql(q, "x100")
        self.assertEqual(rules(f), ["x100-correlated-aggregate"])
        self.assertIn("o.unit_price", f[0][2])

    def test_uncorrelated_subquery_aggregate_allowed(self):
        q = ("SELECT o.id FROM orders o\n"
             "WHERE o.total > (SELECT AVG(l.qty) FROM lines l WHERE l.order_id = o.id)")
        # o.id is referenced in the WHERE, not inside the aggregate -> allowed
        self.assertEqual(sj.check_dialect_sql(q, "x100"), [])

    def test_report_downgrade_with_allow(self):
        f = sj.check_dialect_sql("SELECT STRING_AGG(x ORDER BY x) FROM t", "x100")
        buf = io.StringIO()
        self.assertTrue(sj.report_dialect_findings(f, allow_warnings=False, stream=buf))
        self.assertIn("SQL ERROR [x100-ordered-aggregate]", buf.getvalue())
        buf = io.StringIO()
        self.assertFalse(sj.report_dialect_findings(f, allow_warnings=True, stream=buf))
        self.assertIn("SQL WARN [x100-ordered-aggregate]", buf.getvalue())


class CliTests(unittest.TestCase):
    """Argument parsing / --check-only through the real CLI (no psql needed)."""

    def run_cli(self, *args, env=None):
        e = dict(os.environ)
        e.pop("PGPASSWORD", None)
        if env:
            e.update(env)
        return subprocess.run([sys.executable, SCRIPT, *args],
                              capture_output=True, text=True, env=e)

    def test_help_lists_dialect_flags(self):
        r = self.run_cli("--help")
        self.assertEqual(r.returncode, 0, r.stderr)
        for flag in ("--dialect", "--allow-dialect-warnings", "--check-only"):
            self.assertIn(flag, r.stdout)

    def test_check_only_clean_postgres(self):
        r = self.run_cli("--name", "t", "--query", "SELECT 1 AS one", "--check-only")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("check-only (postgres): 0 finding(s), 0 error(s)", r.stdout)

    def test_check_only_x100_refuses_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "x.jrxml")
            r = self.run_cli("--name", "t", "--dialect", "x100", "--out", out,
                             "--query", "SELECT STRING_AGG(a, ',' ORDER BY a) FROM t")
            self.assertEqual(r.returncode, 3)
            self.assertIn("x100-ordered-aggregate", r.stderr)
            self.assertIn("nothing written", r.stderr)
            self.assertFalse(os.path.exists(out))

    def test_check_only_x100_exit_1(self):
        r = self.run_cli("--name", "t", "--dialect", "x100", "--check-only",
                         "--query", "SELECT 1 -- x; y")
        self.assertEqual(r.returncode, 1)
        self.assertIn("1 error(s)", r.stdout)

    def test_allow_dialect_warnings_downgrades(self):
        r = self.run_cli("--name", "t", "--dialect", "x100", "--check-only",
                         "--allow-dialect-warnings", "--query", "SELECT 1 -- x; y")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("SQL WARN [x100-semicolon-in-comment]", r.stderr)

    def test_default_path_still_needs_psql(self):
        # Without --check-only the postgres default path reaches introspection;
        # with psql absent from PATH it must fail there (exit 2), proving the
        # argument parsing before it is unchanged.
        with tempfile.TemporaryDirectory() as d:
            r = self.run_cli("--name", "t", "--query", "SELECT 1 AS one",
                             "--out", os.path.join(d, "t.jrxml"), env={"PATH": d})
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn("psql", r.stderr)
            self.assertFalse(os.path.exists(os.path.join(d, "t.jrxml")))


if __name__ == "__main__":
    unittest.main()
