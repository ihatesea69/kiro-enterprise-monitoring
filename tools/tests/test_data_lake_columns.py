"""The Glue tables of infra/customer/data-lake must match build_views.report_tables_ddl().

The dashboard account builds its views on the raw tables created by build_views.py.
A customer-account table that drifts (a column added, moved or renamed) would read
shifted columns without any error, so this pins the two definitions to each other.
"""
from __future__ import annotations

import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "vendor" / "sample-kiro-user-analytics-quicksight-dashboard" / "scripts"
TF = (ROOT / "infra" / "customer" / "data-lake" / "main.tf").read_text(encoding="utf-8")

sys.path.insert(0, str(SCRIPTS))
import build_views as bv  # noqa: E402
import normalize_report_lambda as nz  # noqa: E402


def tf_list(name: str) -> list[str]:
    m = re.search(rf"{name}\s*=\s*\[(.*?)\]", TF, flags=re.S)
    assert m, f"{name} not found in main.tf"
    return re.findall(r'"([^"]+)"', m.group(1))


def ddl_columns(table: str) -> list[str]:
    stmts = bv.report_tables_ddl("db", "bucket", "normalized", "NOW-3MONTHS", "NOW")
    s = next(x for x in stmts if x.startswith(f"CREATE EXTERNAL TABLE db.{table} "))
    body = s.split("(", 1)[1].split(")\nPARTITIONED BY", 1)[0]
    cols = []
    for line in body.splitlines():
        parts = line.split()
        if len(parts) == 2:
            assert parts[1].rstrip(",") == "string"
            cols.append(parts[0])
    return cols


def ddl_props(table: str) -> dict[str, str]:
    stmts = bv.report_tables_ddl("db", "bucket", "normalized", "NOW-3MONTHS", "NOW")
    s = next(x for x in stmts if x.startswith(f"CREATE EXTERNAL TABLE db.{table} "))
    return dict(re.findall(r"'([^']+)'\s*=\s*'([^']*)'", s.split("TBLPROPERTIES", 1)[1]))


class DataLakeColumns(unittest.TestCase):
    def test_facts_columns_equal_ddl(self):
        self.assertEqual(tf_list("facts_columns"), ddl_columns("report_facts_raw"))

    def test_models_columns_equal_ddl(self):
        self.assertEqual(tf_list("models_columns"), ddl_columns("report_models_raw"))

    def test_facts_columns_equal_what_the_normalizer_writes(self):
        self.assertEqual(tf_list("facts_columns"), list(nz._FACT_OUT_HEADER))

    def test_models_columns_equal_what_the_normalizer_writes(self):
        self.assertEqual(tf_list("models_columns"), list(nz._MODEL_OUT_HEADER))

    def test_projection_properties_match(self):
        want = ddl_props("report_facts_raw")
        for key in ("projection.enabled", "projection.export_date.type", "projection.export_date.format",
                    "projection.export_date.range", "projection.export_date.interval",
                    "projection.export_date.interval.unit", "skip.header.line.count"):
            self.assertIn(f'"{key}"', TF, key)
            self.assertIn(key, want)
        self.assertEqual(want["projection.export_date.range"], "NOW-3MONTHS,NOW")
        self.assertIn('default     = "NOW-3MONTHS,NOW"', TF)

    def test_lambda_environment_names_are_the_ones_the_handler_reads(self):
        src = (SCRIPTS / "normalize_report_lambda.py").read_text(encoding="utf-8")
        for var in ("RAW_BUCKET", "RAW_PREFIX", "OUT_BUCKET", "OUT_PREFIX"):
            self.assertIn(f'os.environ["{var}"]', src)
            self.assertIn(f"{var} =", TF)
        self.assertIn("normalize_report_lambda.handler", TF)

    def test_raw_prefix_is_the_one_kiro_writes(self):
        self.assertIn('"${var.report_prefix}AWSLogs/${local.account_id}/KiroLogs/user_report/"', TF)


if __name__ == "__main__":
    unittest.main()
