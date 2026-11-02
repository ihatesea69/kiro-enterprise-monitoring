"""Tests for patch P6 (kiro-enterprise-monitoring): projection range of the report tables.

Upstream projected export_date over 2020-01-01,NOW+1YEARS. Athena lists one S3
prefix per projected day on every unfiltered query, so each SPICE refresh paid
~2,860 LIST per table read, growing by 365 a year. P6 makes the range a
parameter, and deploy.sh REQUIRES a start date: no silent wide range.

Offline: no AWS, no network.
"""
from __future__ import annotations

import os
import re
import subprocess
import shutil
import unittest

from _helpers import SCRIPTS, load

DEPLOY = (SCRIPTS / "deploy.sh").read_text()


def _ranges(ddl: list[str]) -> list[str]:
    return re.findall(r"'projection\.export_date\.range' = '([^']*)'", "\n".join(ddl))


class TestP6BuildViews(unittest.TestCase):
    def setUp(self):
        self.bv = load("build_views")

    def test_range_is_taken_from_arguments(self):
        ddl = self.bv.report_tables_ddl("db", "bucket", "normalized", "2026-11-01", "NOW")
        self.assertEqual(_ranges(ddl), ["2026-11-01,NOW", "2026-11-01,NOW"])

    def test_rolling_window_accepted(self):
        ddl = self.bv.report_tables_ddl("db", "bucket", "normalized", "NOW-13MONTHS", "NOW")
        self.assertEqual(_ranges(ddl), ["NOW-13MONTHS,NOW"] * 2)

    def test_function_default_is_upstream(self):
        ddl = self.bv.report_tables_ddl("db", "bucket", "normalized")
        self.assertEqual(_ranges(ddl), ["2020-01-01,NOW+1YEARS"] * 2)

    def test_location_template_still_formatted(self):
        ddl = "\n".join(self.bv.report_tables_ddl("db", "bucket", "normalized", "2026-11-01", "NOW"))
        self.assertIn("'storage.location.template' = 's3://bucket/normalized/facts/export_date=${export_date}/'", ddl)
        self.assertNotIn("{loc}", ddl)

    def test_bad_bounds_rejected(self):
        for start, end in (("2026/11/01", "NOW"), ("2026-11-01'; DROP", "NOW"), ("2026-11-01", "TOMORROW")):
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                self.bv.report_tables_ddl("db", "bucket", "normalized", start, end)


class TestP6Deploy(unittest.TestCase):
    def test_both_build_views_calls_pass_the_range(self):
        self.assertEqual(DEPLOY.count('--projection-start "${PROJECTION_START}"'), 2)
        self.assertEqual(DEPLOY.count('--projection-end "${PROJECTION_END}"'), 2)
        self.assertEqual(DEPLOY.count('scripts/build_views.py"'), 2)

    def test_end_defaults_to_now(self):
        self.assertIn('PROJECTION_END="${PROJECTION_END:-NOW}"', DEPLOY)

    def test_start_has_no_default(self):
        self.assertIn('PROJECTION_START="${PROJECTION_START:-}"', DEPLOY)
        self.assertNotRegex(DEPLOY, r"PROJECTION_START:-[^}]")
        self.assertNotRegex(DEPLOY, r"--projection-start\s+[\"']?2020")


@unittest.skipUnless(shutil.which("bash") and "System32" not in (shutil.which("bash") or ""),
                     "needs a real bash (not the WSL launcher)")
class TestP6DeployGuardRuns(unittest.TestCase):
    """Run only the P6 guard block, cut out of deploy.sh, under bash."""

    def _guard(self) -> str:
        start = DEPLOY.index('PROJECTION_START="${PROJECTION_START:-}"')
        end = DEPLOY.index("fi\n", start) + 3
        return DEPLOY[start:end] + 'echo "OK ${PROJECTION_START},${PROJECTION_END}"\n'

    def _run(self, env_start: str | None) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k not in ("PROJECTION_START", "PROJECTION_END")}
        if env_start is not None:
            env["PROJECTION_START"] = env_start
        # Full path: on Windows CreateProcess searches System32 (the WSL
        # launcher) before PATH, so a bare "bash" can miss the bash which() found.
        return subprocess.run([shutil.which("bash"), "-c", self._guard()], capture_output=True, text=True, env=env)

    def test_unset_stops(self):
        r = self._run(None)
        self.assertEqual(r.returncode, 1)
        self.assertIn("set PROJECTION_START", r.stderr)

    def test_date_passes(self):
        r = self._run("2026-11-01")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "OK 2026-11-01,NOW"))

    def test_rolling_passes_and_garbage_stops(self):
        self.assertEqual(self._run("NOW-13MONTHS").returncode, 0)
        self.assertEqual(self._run("2020").returncode, 1)


if __name__ == "__main__":
    unittest.main()
