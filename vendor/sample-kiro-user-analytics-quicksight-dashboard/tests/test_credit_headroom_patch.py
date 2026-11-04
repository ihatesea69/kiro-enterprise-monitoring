"""Tests for patch P8 (kiro-enterprise-monitoring): per-user remaining monthly credits.

P8  scripts/normalize_report_lambda.py: the raw Usage_Limit column is carried
    as a NEW LAST field of every facts part, after the bookkeeping columns.
    scripts/build_views.py: report_facts_raw gains the same trailing column;
    report_facts / report_models are left byte-identical.
    athena/0b_credit_headroom.sql: one row per user per calendar month with
    the limit, credits month-to-date, remaining credits, a linear month-end
    projection and a status bucket.
    cfn/02-quicksight.yaml, scripts/create_dashboard.py, scripts/deploy.sh:
    SPICE dataset, 04:55 UTC refresh, Economics KPI + table, inventories.

P8 must be strictly additive, so several tests pin the PRE-P8 output (sha256
computed from origin/main 31f115f) after removing exactly what P8 adds.

Offline: no AWS, no network. Two things are modelled rather than executed:
the positional read of a part follows Hive's OpenCSVSerde (fields bind by
position; a missing trailing field is NULL), and only the view's scoring
layers (params, scored, rated) are executed, in sqlite3, which runs that SQL
unchanged. The Trino-only layers above them are checked structurally.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import sqlite3
import string
import types
import unittest
from unittest import mock

from botocore.exceptions import ClientError

from _helpers import ATHENA, CFN, SCRIPTS, load, view_substitutions
from test_crossaccount_patches import _Tag, _cfn_load, yaml

n = load("normalize_report_lambda")
bv = load("build_views")
cd = load("create_dashboard")

VIEW_FILE = ATHENA / "0b_credit_headroom.sql"
VIEW_SQL = VIEW_FILE.read_text()
TEMPLATE_TEXT = (CFN / "02-quicksight.yaml").read_text()
DEPLOY_BYTES = (SCRIPTS / "deploy.sh").read_bytes()
DEPLOY = DEPLOY_BYTES.decode("utf-8")
TEARDOWN = (SCRIPTS / "teardown.sh").read_text()

KEY = "user_report/us-east-1/2026/11/03/02/KIRO_IDE_1_user_report_202611030200.csv"
MARKER = "PATCH P8 (kiro-enterprise-monitoring)"

# Pre-P8 headers (origin/main 31f115f), pinned literally: P8 may only APPEND.
PRE_P8_FACT_HEADER = [
    "date", "userid", "client_type", "chat_conversations", "credits_used",
    "overage_cap", "overage_credits_used", "overage_enabled", "profileid",
    "subscription_tier", "total_messages", "new_user", "email",
    "src_path", "export_ts", "part_id", "processed_ts",
]
PRE_P8_MODEL_HEADER = [
    "date", "userid", "client_type", "subscription_tier", "model_name", "messages",
    "src_path", "export_ts", "part_id", "processed_ts",
]
PRE_P8_BOOKKEEPING = ["src_path", "export_ts", "part_id", "processed_ts"]

# sha256 of pre-P8 output, computed from origin/main 31f115f with the same
# arguments and canonical JSON (_sha) used below.
PRE_P8_DDL_EXCEPT_FACTS_RAW = "f1ec4fab6ab6296616ff5466a35a9e7ad9b84e379ca55bffbb80b43e7ad9f66c"
PRE_P8_FACTS_RAW_CREATE = "2d2d485f4d89d1f01756342a0d72b5b68d7c8db5073d9a19311d875f307992e4"
PRE_P8_DEFINITION = {
    False: "c2dec26663772a47b1c98582693497e683a50750d27f04ba236584733918b285",
    True: "fc032b7db40d12e4484bb5d6e67f948bba83ba09f62191f080b5892f39946740",
}
PRE_P8_QS_TEMPLATE = "3342d2a715b02ad6a2fd1a63afe7390a0da607b4e74a1996ee9b6628f5861fba"
PRE_P8_DEPLOY_SH = "4360db9659cc2038fc27fe3ba6b7b61e1d1ead72c5b373e5ddab8852b2e9e596"
PRE_P8_SCHEDULES = {
    "base-user-activity": "04:00", "daily-trends": "04:05", "user-totals": "04:10",
    "tier-breakdown": "04:15", "model-usage": "04:25", "user-daily-dense": "04:30",
    "activity-heatmap": "04:35", "wow-movers": "04:50",
}

# What P8 adds, by identifier. Removing exactly these must give back pre-P8.
P8_VISUALS = {"e-headroom-at-risk", "e-headroom-users"}
P8_FILTER_GROUPS = {"fg-latest-month-headroom", "fg-tier-headroom"}
P8_CALC_FIELDS = {"headroom_at_risk_user"}
P8_RESOURCES = {"CreditHeadroomDataSet", "CreditHeadroomRefreshSchedule"}
P8_DEPLOY_LINES = {
    b"# PATCH P8 (kiro-enterprise-monitoring): credit-headroom added to both lists;\n",
    b"# its view selects user_label.\n",
    b"    credit-headroom\n",
}
# P12 replaced these 3 original lines of deploy.sh (see test_grep_pipefail_patch.py).
P12_START = b"# PATCH P12 (kiro-enterprise-monitoring)"
P12_END = b"        | tr '\\t' '\\n')\"; then\n"
P12_ORIGINAL = (
    b'if aws iam list-attached-role-policies --role-name "${QS_IAM_ROLE_NAME}" \\\n'
    b"        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null \\\n"
    b"        | tr '\\t' '\\n' | grep -Fixq \"${ATHENA_POLICY_ARN}\"; then\n"
)


def _sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _canon(node):
    """CFN YAML (with _Tag intrinsics) -> plain JSON-able structure."""
    if isinstance(node, _Tag):
        return {"!" + node.tag: _canon(node.value)}
    if isinstance(node, dict):
        return {k: _canon(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_canon(v) for v in node]
    return node


def parse(body: str, key: str = KEY):
    return n._parse_file(body, key, "part-abc", "20261103031500")


def fact(row) -> dict:
    return dict(zip(n._FACT_OUT_HEADER, row))


def ddl_columns(table: str) -> list[str]:
    """Column names of a raw table, in DDL order (same parse as test_normalizer)."""
    ddl = "\n".join(bv.report_tables_ddl("db", "bucket", "normalized"))
    block = ddl[ddl.index(f"{table} ("):]
    block = block[:block.index("PARTITIONED BY")]
    cols = [ln.strip().split()[0] for ln in block.splitlines()
            if ln.strip() and not ln.strip().startswith(("(", ")"))]
    return [c for c in cols if c not in (table, "CREATE")]


def serde_read(part_text: str, columns: list[str]) -> list[dict]:
    """Model of Hive OpenCSVSerde with skip.header.line.count=1: a field binds
    to the column at the same POSITION, a missing trailing field is NULL (None),
    an extra field is dropped. Athena documents no header binding for CSV."""
    rows = list(csv.reader(io.StringIO(part_text)))[1:]
    return [{c: (r[i] if i < len(r) else None) for i, c in enumerate(columns)} for r in rows]


def rendered_view(identity_mapping: bool = False) -> str:
    subs = view_substitutions(bv, identity_mapping=identity_mapping)
    return string.Template(VIEW_SQL).substitute(**subs)


def cte_body(sql: str, name: str) -> str:
    """Body of the CTE `name`. Relies on this file's layout: the header
    `name AS (` ends a line and the closing `)` / `),` is alone at column 0."""
    m = re.search(rf"^(?:WITH )?{name} AS \(\n(.*?)^\),?$", sql, re.M | re.S)
    if not m:
        raise AssertionError(f"CTE {name} not found in {VIEW_FILE.name}")
    return m.group(1)


def select_aliases(select_body: str) -> list[str]:
    """Output names of a one-expression-per-line SELECT list (as written in
    the view): the AS alias, else the bare column after the table alias."""
    out = []
    for line in select_body.splitlines():
        code = line.split("--", 1)[0].strip().rstrip(",")
        if not code or code == "SELECT":
            continue
        m = re.search(r"\bAS\s+(\w+)$", code)
        if m:
            out.append(m.group(1))
        elif re.fullmatch(r"\w+\.\w+", code):
            out.append(code.split(".")[1])
    return out


def view_output_columns() -> list[str]:
    final = VIEW_SQL[VIEW_SQL.rindex("\nSELECT\n"):VIEW_SQL.rindex("\nFROM rated r")]
    return select_aliases(final)


def code_only(sql: str) -> str:
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


class FakeS3:
    """Just enough of the S3 client for handler(): list, head, get, put."""

    def __init__(self, objects: dict):
        self.objects = dict(objects)  # (bucket, key) -> bytes
        self.exceptions = types.SimpleNamespace(ClientError=ClientError)

    def etag(self, bucket: str, key: str) -> str:
        return hashlib.sha256(self.objects[(bucket, key)]).hexdigest()[:32]

    def get_paginator(self, name):
        assert name == "list_objects_v2", name
        s3 = self

        class _Pages:
            def paginate(self, Bucket, Prefix):  # noqa: N803 - boto3 names
                yield {"Contents": [{"Key": k, "ETag": f'"{s3.etag(b, k)}"'}
                                    for (b, k) in sorted(s3.objects)
                                    if b == Bucket and k.startswith(Prefix)]}
        return _Pages()

    def head_object(self, Bucket, Key):  # noqa: N803
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject")
        return {}

    def get_object(self, Bucket, Key):  # noqa: N803
        return {"Body": io.BytesIO(self.objects[(Bucket, Key)])}

    def put_object(self, Bucket, Key, Body, ContentType):  # noqa: N803
        self.objects[(Bucket, Key)] = Body


RAW = ("Date,UserId,Client_Type,Credits_Used,Subscription_Tier,Usage_Limit,auto_messages\n"
       "2026-11-02,u1,KIRO_IDE,4700.5,POWER,10000,12\n")


class TestP8Normalizer(unittest.TestCase):

    def test_usage_limit_binds_by_header_whatever_the_column_layout(self):
        """Same data in three header layouts: Usage_Limit moved, re-cased,
        padded, a model column added, New_User present in one only."""
        layouts = [
            RAW,
            ("auto_messages, USAGE_LIMIT ,Subscription_Tier,Credits_Used,Client_Type,UserId,Date,New_User\n"
             "12,10000,POWER,4700.5,KIRO_IDE,u1,2026-11-02,true\n"),
            ("Usage_Limit,Date,UserId,claude_opus_9.9_messages,Client_Type,Credits_Used,Subscription_Tier,auto_messages\n"
             "10000,2026-11-02,u1,3,KIRO_IDE,4700.5,POWER,12\n"),
        ]
        facts = [fact(parse(body)[0][0]) for body in layouts]
        for i, f in enumerate(facts):
            with self.subTest(layout=i):
                self.assertEqual(f["usage_limit"], "10000")
                self.assertEqual(f["credits_used"], "4700.5")
                self.assertEqual(len(f), len(n._FACT_OUT_HEADER))
        same = [{k: v for k, v in f.items() if k != "new_user"} for f in facts]
        self.assertEqual(same[0], same[1])
        self.assertEqual(same[0], same[2])

    def test_missing_usage_limit_is_empty_not_a_neighbouring_value(self):
        f = fact(parse("Date,UserId,Credits_Used,auto_messages\n2026-11-02,u1,5,7\n")[0][0])
        self.assertEqual(f["usage_limit"], "")
        short = parse("Date,UserId,Usage_Limit\n2026-11-02,u1\n")[0][0]
        self.assertEqual(fact(short)["usage_limit"], "")  # truncated row: restval None -> ""

    def test_header_only_appends_after_the_bookkeeping_columns(self):
        self.assertEqual(n._FACT_OUT_HEADER, PRE_P8_FACT_HEADER + ["usage_limit"])
        self.assertEqual(n._FACT_TRAILING_COLUMNS, ["usage_limit"])

    def test_bookkeeping_and_models_parts_are_unchanged(self):
        self.assertEqual(n._BOOKKEEPING, PRE_P8_BOOKKEEPING)
        self.assertEqual(n._MODEL_OUT_HEADER, PRE_P8_MODEL_HEADER)
        facts, models = parse(RAW)
        self.assertEqual([len(r) for r in models], [len(PRE_P8_MODEL_HEADER)])
        f = fact(facts[0])
        self.assertEqual([f[c] for c in PRE_P8_BOOKKEEPING],
                         [KEY, "202611030200", "part-abc", "20261103031500"])

    def test_part_written_before_p8_reads_usage_limit_as_null(self):
        """A pre-P8 part has 17 fields. Read against the P8 table, every old
        column keeps its value and usage_limit is NULL - nothing shifts."""
        values = ["2026-11-02", "u1", "KIRO_IDE", "3", "4700.5", "0", "0", "false", "p1",
                  "POWER", "12", "", "", KEY, "202611030200", "part-old", "20261103031500"]
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(PRE_P8_FACT_HEADER)
        w.writerow(values)
        row = serde_read(buf.getvalue(), ddl_columns("report_facts_raw"))[0]
        self.assertIsNone(row["usage_limit"])
        self.assertEqual([row[c] for c in PRE_P8_FACT_HEADER], values)

    def test_part_written_by_p8_reads_usage_limit_last(self):
        s3 = FakeS3({})
        facts, _ = parse(RAW)
        n._write_csv(s3, "out", "facts/part.csv", n._FACT_OUT_HEADER, facts)
        text = s3.objects[("out", "facts/part.csv")].decode("utf-8")
        row = serde_read(text, ddl_columns("report_facts_raw"))[0]
        self.assertEqual(row["usage_limit"], "10000")
        self.assertEqual((row["userid"], row["credits_used"], row["processed_ts"]),
                         ("u1", "4700.5", "20261103031500"))


class TestP8NormalizerBackfill(unittest.TestCase):
    """The ETag skip means already-normalized files keep their pre-P8 part until
    REPROCESS_ALL re-parses them. That is the backfill path for an existing
    deployment, so pin both halves of it."""

    ENV = {"RAW_BUCKET": "raw", "RAW_PREFIX": "user_report/", "OUT_BUCKET": "out",
           "OUT_PREFIX": "normalized"}

    def _setup(self):
        s3 = FakeS3({("raw", KEY): RAW.encode("utf-8")})
        part = n._part_name(KEY, s3.etag("raw", KEY))
        facts_key = f"normalized/facts/export_date=2026-11-03/{part}"
        models_key = f"normalized/models/export_date=2026-11-03/{part}"
        old = io.StringIO()
        csv.writer(old).writerows([PRE_P8_FACT_HEADER, ["2026-11-02", "u1"] + [""] * 15])
        s3.objects[("out", facts_key)] = old.getvalue().encode("utf-8")
        s3.objects[("out", models_key)] = b"old-models"
        return s3, facts_key, models_key

    def _run(self, s3, reprocess: str | None):
        env = dict(self.ENV)
        if reprocess is not None:
            env["REPROCESS_ALL"] = reprocess
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(n, "_s3", return_value=s3):
            if reprocess is None:
                os.environ.pop("REPROCESS_ALL", None)
            return n.handler({}, None)

    def test_without_reprocess_the_pre_p8_part_is_skipped(self):
        s3, facts_key, _ = self._setup()
        before = dict(s3.objects)
        result = self._run(s3, None)
        self.assertEqual((result["files_processed"], result["files_skipped"]), (0, 1))
        self.assertEqual(s3.objects, before)

    def test_reprocess_all_rewrites_the_same_part_with_usage_limit(self):
        s3, facts_key, models_key = self._setup()
        keys_before = set(s3.objects)
        result = self._run(s3, "true")
        self.assertEqual((result["files_processed"], result["files_failed"]), (1, 0))
        self.assertEqual(set(s3.objects), keys_before, "a new part was written instead of the same one")
        text = s3.objects[("out", facts_key)].decode("utf-8")
        self.assertEqual(next(csv.reader(io.StringIO(text))), n._FACT_OUT_HEADER)
        self.assertEqual(serde_read(text, ddl_columns("report_facts_raw"))[0]["usage_limit"], "10000")
        self.assertNotEqual(s3.objects[("out", models_key)], b"old-models")


class TestP8Ddl(unittest.TestCase):

    def test_report_facts_raw_ends_with_usage_limit(self):
        cols = ddl_columns("report_facts_raw")
        self.assertEqual(cols, n._FACT_OUT_HEADER)
        self.assertEqual(cols[-1], "usage_limit")
        self.assertIn("usage_limit          string\n)", "\n".join(bv.report_tables_ddl("db", "bucket", "normalized")))

    def test_report_models_raw_is_unchanged(self):
        self.assertEqual(ddl_columns("report_models_raw"), PRE_P8_MODEL_HEADER)

    def test_every_other_statement_is_byte_identical_to_pre_p8(self):
        """report_facts and report_models (the dedup views every SPICE dataset
        reads through), report_models_raw and the DROPs: unchanged bytes."""
        ddl = bv.report_tables_ddl("db", "bucket", "normalized")
        others = [s for s in ddl if "report_facts_raw (" not in s]
        self.assertEqual(len(others), 9)
        self.assertEqual(_sha(others), PRE_P8_DDL_EXCEPT_FACTS_RAW)

    def test_the_raw_table_change_is_only_the_trailing_column(self):
        stmt = next(s for s in bv.report_tables_ddl("db", "bucket", "normalized")
                    if "report_facts_raw (" in s)
        pre = stmt.replace("    processed_ts         string,\n    usage_limit          string\n",
                           "    processed_ts         string\n")
        self.assertNotEqual(pre, stmt)
        self.assertEqual(hashlib.sha256(pre.encode()).hexdigest(), PRE_P8_FACTS_RAW_CREATE)


class TestP8View(unittest.TestCase):

    def test_renders_as_one_statement_in_both_identity_modes(self):
        for mapping in (False, True):
            with self.subTest(identity_mapping=mapping):
                sql = rendered_view(mapping)
                self.assertEqual(len(bv.split_statements(sql)), 1)
                self.assertIn("CREATE OR REPLACE VIEW test_db.credit_headroom AS", sql)

    def test_sorts_after_the_views_it_reads(self):
        names = [p.name for p in sorted(ATHENA.glob("*.sql"))]
        pos = names.index(VIEW_FILE.name)
        self.assertLess(names.index("00_base_user_activity.sql"), pos)
        self.assertLess(names.index("00b_user_dim.sql"), pos)

    def test_requested_columns_are_all_present(self):
        cols = view_output_columns()
        for c in ("month", "user_id", "user_label", "idc_username", "idc_email", "user_tier",
                  "usage_limit", "credits_used_mtd", "remaining_credits", "pct_used",
                  "overage_enabled", "overage_cap", "overage_credits_used", "days_elapsed",
                  "projected_month_end_credits", "status", "is_latest_month"):
            with self.subTest(column=c):
                self.assertIn(c, cols)
        self.assertEqual(len(cols), len(set(cols)))

    def test_thresholds_are_two_constants_in_one_place(self):
        code = code_only(VIEW_SQL)
        self.assertRegex(code, r"SELECT 0\.75 AS watch_pct, 0\.90 AS at_risk_pct")
        self.assertEqual(code.count("0.75"), 1)
        self.assertEqual(code.count("0.90"), 1)
        rated = cte_body(code, "rated")
        self.assertIn("p.at_risk_pct", rated)
        self.assertIn("p.watch_pct", rated)

    def test_credits_are_summed_over_every_client_row_of_the_month(self):
        """base_user_activity is one row per (user, day, client); the month
        total must SUM all of them, so client_type is not a grouping key."""
        body = cte_body(rendered_view(), "usage_mtd")
        self.assertIn("FROM test_db.base_user_activity b", body)
        self.assertIn("SUM(b.credits_used)", body)
        self.assertIn("SUM(b.overage_credits_used)", body)
        self.assertRegex(body, r"GROUP BY b\.user_id, date_trunc\('month', b\.activity_date\)\s*$")
        self.assertNotIn("client_type", body)

    def test_usage_limit_follows_the_report_facts_dedup_order(self):
        body = cte_body(rendered_view(), "limits")
        key = re.search(r"max_by\(usage_limit,\s*\(([^)]*)\)\)", body)
        self.assertIsNotNone(key, "limits must take max_by over a row key")
        key_cols = [c.strip() for c in key.group(1).split(",")]
        self.assertEqual(key_cols[0], "activity_date")
        rf = next(s for s in bv.report_tables_ddl("db", "bucket", "normalized")
                  if "VIEW db.report_facts AS" in s)
        order = re.search(r"ORDER BY (.*?)\n\s*\) AS rn", rf, re.S).group(1)
        dedup = re.findall(r"(?:COALESCE\()?(\w+)(?:, '?'?\))? DESC", order)
        self.assertEqual(key_cols[1:], dedup)
        self.assertIn("usage_limit IS NOT NULL", body)
        rows = cte_body(rendered_view(), "limit_rows")
        self.assertIn("FROM test_db.report_facts_raw", rows)
        self.assertIn("TRY(CAST(NULLIF(trim(usage_limit), '') AS double))", rows)

    def test_days_come_from_the_data_not_the_wall_clock(self):
        code = code_only(VIEW_SQL).lower()
        for clock in ("current_date", "now()", "current_timestamp", "localtimestamp"):
            with self.subTest(clock=clock):
                self.assertNotIn(clock, code)
        self.assertIn("max(activity_date) as max_date", code)
        m = cte_body(code_only(VIEW_SQL), "m")
        self.assertIn("LEAST(w.max_date, s.month_end)", m)
        self.assertIn("date_diff('day', s.month, LEAST(w.max_date, s.month_end)) + 1 AS days_elapsed", m)
        self.assertIn("day_of_month(s.month_end)", m)
        self.assertIn("date_add('day', -1, date_add('month', 1, u.month))", cte_body(VIEW_SQL, "spans"))
        self.assertIn("s.month = date_trunc('month', w.max_date)", m)


class TestP8ScoringMath(unittest.TestCase):
    """Executes the view's own params / scored / rated SQL in sqlite3 over a
    fixture `m` (the CTE that feeds them)."""

    M_COLUMNS = ["month", "user_id", "user_tier", "usage_limit", "credits_used_mtd",
                 "overage_enabled", "overage_cap", "overage_credits_used", "as_of_date",
                 "days_elapsed", "days_in_month", "is_latest_month"]

    # user_id: (usage_limit, credits_used_mtd, days_elapsed, days_in_month) ->
    #          (status, pct_used, remaining_credits, projected)
    CASES = {
        # First customer, day 2 of November: about 4,700 of 10,000 in one day.
        "a_day2":       ((10000.0, 4700.0, 2, 30), ("AT_RISK", 0.47, 5300.0, 70500.0)),
        "b_ok":         ((10000.0, 3000.0, 15, 30), ("OK", 0.30, 7000.0, 6000.0)),
        "c_watch":      ((10000.0, 7600.0, 25, 30), ("WATCH", 0.76, 2400.0, 9120.0)),
        "d_watch_edge": ((10000.0, 7500.0, 30, 30), ("WATCH", 0.75, 2500.0, 7500.0)),
        "e_risk_pct":   ((10000.0, 9100.0, 29, 30), ("AT_RISK", 0.91, 900.0, 9100.0 * 30 / 29)),
        "f_risk_edge":  ((10000.0, 9000.0, 30, 30), ("AT_RISK", 0.90, 1000.0, 9000.0)),
        "g_proj_edge":  ((10000.0, 5000.0, 15, 30), ("AT_RISK", 0.50, 5000.0, 10000.0)),
        "h_exhausted":  ((10000.0, 10000.0, 20, 30), ("EXHAUSTED", 1.0, 0.0, 15000.0)),
        "i_overage":    ((10000.0, 12000.0, 20, 30), ("EXHAUSTED", 1.2, 0.0, 18000.0)),
        "j_null_limit": ((None, 5000.0, 10, 30), ("UNKNOWN_LIMIT", None, None, 15000.0)),
        "k_zero_limit": ((0.0, 5000.0, 10, 30), ("UNKNOWN_LIMIT", None, None, 15000.0)),
        "l_neg_limit":  ((-1.0, 5000.0, 10, 30), ("UNKNOWN_LIMIT", None, None, 15000.0)),
        # A finished month projects to its actual total.
        "m_past_month": ((10000.0, 8000.0, 31, 31), ("WATCH", 0.80, 2000.0, 8000.0)),
    }

    def _run(self) -> dict:
        sql = code_only(rendered_view())
        query = ("WITH params AS (" + cte_body(sql, "params") + "), "
                 "scored AS (" + cte_body(sql, "scored") + "), "
                 "rated AS (" + cte_body(sql, "rated") + ") "
                 "SELECT user_id, status, pct_used, remaining_credits, "
                 "projected_month_end_credits FROM rated")
        con = sqlite3.connect(":memory:")
        try:
            con.execute(f"CREATE TABLE m ({', '.join(self.M_COLUMNS)})")
            for uid, ((limit, mtd, elapsed, days), _) in self.CASES.items():
                con.execute(f"INSERT INTO m VALUES ({', '.join('?' * len(self.M_COLUMNS))})",
                            ("2026-11-01", uid, "Power", limit, mtd, 0, 0.0, 0.0,
                             "2026-11-02", elapsed, days, "Yes"))
            return {r[0]: r[1:] for r in con.execute(query)}
        finally:
            con.close()

    def test_fixture_mirrors_the_m_cte(self):
        self.assertEqual(select_aliases(cte_body(VIEW_SQL, "m")), self.M_COLUMNS)

    def test_status_and_numbers_per_case(self):
        got = self._run()
        self.assertEqual(set(got), set(self.CASES))
        for uid, (_, (status, pct, remaining, projected)) in self.CASES.items():
            g_status, g_pct, g_remaining, g_projected = got[uid]
            with self.subTest(user=uid):
                self.assertEqual(g_status, status)
                self.assertAlmostEqual(g_projected, projected, places=6)
                if pct is None:
                    self.assertIsNone(g_pct)
                    self.assertIsNone(g_remaining)
                else:
                    self.assertAlmostEqual(g_pct, pct, places=9)
                    self.assertAlmostEqual(g_remaining, remaining, places=6)

    def test_unknown_limit_is_never_reported_as_full_headroom(self):
        got = self._run()
        for uid in ("j_null_limit", "k_zero_limit", "l_neg_limit"):
            with self.subTest(user=uid):
                self.assertEqual(got[uid][0], "UNKNOWN_LIMIT")
                self.assertIsNone(got[uid][2])


@unittest.skipIf(yaml is None, "PyYAML not installed")
class TestP8Template(unittest.TestCase):

    def setUp(self):
        self.tpl = _cfn_load(TEMPLATE_TEXT)
        self.res = self.tpl["Resources"]

    def test_dataset_reads_the_view_into_spice(self):
        ds = self.res["CreditHeadroomDataSet"]
        self.assertEqual(ds["Type"], "AWS::QuickSight::DataSet")
        p = ds["Properties"]
        self.assertEqual((p["DataSetId"].tag, p["DataSetId"].value), ("Sub", "${ResourcePrefix}-credit-headroom"))
        self.assertEqual(p["ImportMode"], "SPICE")
        rel = p["PhysicalTableMap"]["base"]["RelationalTable"]
        self.assertEqual(rel["Name"], "credit_headroom")
        self.assertEqual(_canon(p["Permissions"]),
                         _canon(self.res["WowMoversDataSet"]["Properties"]["Permissions"]))

    def test_input_columns_match_the_view_output(self):
        cols = self.res["CreditHeadroomDataSet"]["Properties"]["PhysicalTableMap"]["base"][
            "RelationalTable"]["InputColumns"]
        self.assertEqual([c["Name"] for c in cols], view_output_columns())
        types_ = {c["Name"]: c["Type"] for c in cols}
        for name in ("month", "as_of_date"):
            self.assertEqual(types_[name], "DATETIME")
        self.assertEqual(types_["overage_enabled"], "BOOLEAN")
        for name in ("days_elapsed", "days_in_month"):
            self.assertEqual(types_[name], "INTEGER")
        for name in ("user_id", "user_label", "idc_username", "idc_email", "user_tier",
                     "status", "is_latest_month"):
            self.assertEqual(types_[name], "STRING")
        for name in ("usage_limit", "credits_used_mtd", "remaining_credits", "pct_used",
                     "overage_cap", "overage_credits_used", "projected_month_end_credits"):
            self.assertEqual(types_[name], "DECIMAL")

    def _schedules(self) -> dict:
        out = {}
        for name, r in self.res.items():
            if r["Type"] == "AWS::QuickSight::RefreshSchedule":
                suffix = r["Properties"]["DataSetId"].value.split("}-", 1)[1]
                out[suffix] = (name, r)
        return out

    def test_refresh_runs_daily_after_every_existing_schedule(self):
        sched = self._schedules()
        name, r = sched.pop("credit-headroom")
        self.assertEqual(name, "CreditHeadroomRefreshSchedule")
        self.assertEqual(r["DependsOn"], "CreditHeadroomDataSet")
        s = r["Properties"]["Schedule"]
        self.assertEqual((s["RefreshType"], s["ScheduleFrequency"]["Interval"]), ("FULL_REFRESH", "DAILY"))
        existing = {k: v[1]["Properties"]["Schedule"]["ScheduleFrequency"]["TimeOfTheDay"]
                    for k, v in sched.items()}
        self.assertEqual(existing, PRE_P8_SCHEDULES)
        self.assertEqual(s["ScheduleFrequency"]["TimeOfTheDay"], "04:55")
        self.assertGreater(s["ScheduleFrequency"]["TimeOfTheDay"], max(existing.values()))

    def test_everything_else_in_the_template_is_unchanged(self):
        tpl = _canon(self.tpl)
        for r in P8_RESOURCES:
            del tpl["Resources"][r]
        self.assertEqual(_sha(tpl), PRE_P8_QS_TEMPLATE)


class TestP8Dashboard(unittest.TestCase):

    def _def(self, mapping=False):
        return cd.build_definition("123456789012", "us-east-1", "p", identity_mapping=mapping)

    def _visual(self, d, vid):
        econ = next(s for s in d["Sheets"] if s["SheetId"] == "economics")
        for v in econ["Visuals"]:
            inner = next(iter(v.values()))
            if inner["VisualId"] == vid:
                return next(iter(v)), inner
        self.fail(f"{vid} not on the Economics sheet")

    def test_dataset_is_declared(self):
        self.assertEqual(cd.DATASET_SUFFIXES["headroom"], "credit-headroom")
        decl = next(x for x in self._def()["DataSetIdentifierDeclarations"] if x["Identifier"] == "headroom")
        self.assertTrue(decl["DataSetArn"].endswith(":dataset/p-credit-headroom"))

    def test_kpi_counts_at_risk_and_exhausted_users_only(self):
        d = self._def()
        kind, kpi = self._visual(d, "e-headroom-at-risk")
        self.assertEqual(kind, "KPIVisual")
        field = kpi["ChartConfiguration"]["FieldWells"]["Values"][0]["CategoricalMeasureField"]
        self.assertEqual(field["Column"], {"DataSetIdentifier": "headroom", "ColumnName": "headroom_at_risk_user"})
        self.assertEqual(field["AggregationFunction"], "DISTINCT_COUNT")
        calc = next(c for c in d["CalculatedFields"] if c["Name"] == "headroom_at_risk_user")
        self.assertEqual(calc["DataSetIdentifier"], "headroom")
        statuses = set(re.findall(r"'([A-Z_]+)'", calc["Expression"]))
        self.assertEqual(statuses, {"AT_RISK", "EXHAUSTED"})
        self.assertIn("{user_id}", calc["Expression"])

    def test_table_lists_users_by_pct_used_with_remaining_credits(self):
        for mapping in (False, True):
            with self.subTest(identity_mapping=mapping):
                kind, t = self._visual(self._def(mapping), "e-headroom-users")
                self.assertEqual(kind, "TableVisual")
                wells = t["ChartConfiguration"]["FieldWells"]["TableAggregatedFieldWells"]
                dims = [g["CategoricalDimensionField"]["Column"]["ColumnName"] for g in wells["GroupBy"]]
                self.assertEqual(dims[0], "user_label")
                self.assertEqual(dims[-2:], ["user_tier", "status"])
                self.assertEqual("idc_username" in dims, mapping)
                vals = {v["NumericalMeasureField"]["Column"]["ColumnName"]: v["NumericalMeasureField"]
                        for v in wells["Values"]}
                for col in ("pct_used", "remaining_credits", "credits_used_mtd", "usage_limit",
                            "projected_month_end_credits"):
                    self.assertIn(col, vals)
                self.assertIn("PercentageDisplayFormatConfiguration",
                              json.dumps(vals["pct_used"]["FormatConfiguration"]))
                sort = t["ChartConfiguration"]["SortConfiguration"]["RowSort"][0]["ColumnSort"]
                self.assertEqual(sort["SortBy"], {"DataSetIdentifier": "headroom", "ColumnName": "pct_used"})
                self.assertEqual(sort["Direction"], "DESC")
                shown = vals["pct_used"]["AggregationFunction"]["SimpleNumericalAggregation"]
                self.assertEqual(
                    sort["AggregationFunction"]["NumericalAggregationFunction"]["SimpleNumericalAggregation"], shown)

    def test_visuals_are_pinned_to_the_latest_month_and_follow_the_tier_picker(self):
        fgs = {fg["FilterGroupId"]: fg for fg in self._def()["FilterGroups"]}
        latest = fgs["fg-latest-month-headroom"]
        f = latest["Filters"][0]["CategoryFilter"]
        self.assertEqual(f["Column"], {"DataSetIdentifier": "headroom", "ColumnName": "is_latest_month"})
        self.assertEqual(f["Configuration"]["CustomFilterConfiguration"]["CategoryValue"], "Yes")
        self.assertEqual(f["Configuration"]["CustomFilterConfiguration"]["MatchOperator"], "EQUALS")
        scope = latest["ScopeConfiguration"]["SelectedSheets"]["SheetVisualScopingConfigurations"]
        self.assertEqual(len(scope), 1)
        self.assertEqual((scope[0]["SheetId"], scope[0]["Scope"]), ("economics", "SELECTED_VISUALS"))
        self.assertEqual(set(scope[0]["VisualIds"]), P8_VISUALS)
        tier_fg = fgs["fg-tier-headroom"]
        tier = tier_fg["Filters"][0]["CategoryFilter"]
        self.assertEqual(tier["Column"], {"DataSetIdentifier": "headroom", "ColumnName": "user_tier"})
        self.assertEqual(tier["Configuration"]["CustomFilterConfiguration"]["ParameterName"], "SelectedTier")
        self.assertEqual(tier_fg["ScopeConfiguration"]["SelectedSheets"]["SheetVisualScopingConfigurations"],
                         [{"SheetId": "economics", "Scope": "ALL_VISUALS"}])
        for fg in (latest, tier_fg):
            self.assertEqual(fg["CrossDataset"], "SINGLE_DATASET")

    def test_no_date_range_filter_targets_the_headroom_dataset(self):
        for fg in self._def()["FilterGroups"]:
            f = fg["Filters"][0]
            if "TimeRangeFilter" in f:
                with self.subTest(group=fg["FilterGroupId"]):
                    self.assertNotEqual(f["TimeRangeFilter"]["Column"]["DataSetIdentifier"], "headroom")

    def test_subtitle_thresholds_match_the_view_constants(self):
        m = re.search(r"SELECT (0\.\d+) AS watch_pct, (0\.\d+) AS at_risk_pct", VIEW_SQL)
        watch, at_risk = (round(float(x) * 100) for x in m.groups())
        _, table = self._visual(self._def(), "e-headroom-users")
        _, kpi = self._visual(self._def(), "e-headroom-at-risk")
        sub = table["Subtitle"]["FormatText"]["PlainText"]
        self.assertIn(f"WATCH = >={watch}% used", sub)
        self.assertIn(f"AT_RISK = >={at_risk}% used", sub)
        self.assertIn(f"reached {at_risk}% of their monthly limit", kpi["Subtitle"]["FormatText"]["PlainText"])

    def test_everything_else_in_the_definition_is_unchanged(self):
        for mapping in (False, True):
            d = self._def(mapping)
            d["DataSetIdentifierDeclarations"] = [x for x in d["DataSetIdentifierDeclarations"]
                                                  if x["Identifier"] != "headroom"]
            for sheet in d["Sheets"]:
                sheet["Visuals"] = [v for v in sheet["Visuals"]
                                    if next(iter(v.values()))["VisualId"] not in P8_VISUALS]
                for layout in sheet["Layouts"]:
                    grid = layout["Configuration"]["GridLayout"]
                    grid["Elements"] = [e for e in grid["Elements"] if e["ElementId"] not in P8_VISUALS]
            d["FilterGroups"] = [fg for fg in d["FilterGroups"] if fg["FilterGroupId"] not in P8_FILTER_GROUPS]
            d["CalculatedFields"] = [c for c in d["CalculatedFields"] if c["Name"] not in P8_CALC_FIELDS]
            with self.subTest(identity_mapping=mapping):
                self.assertEqual(_sha(d), PRE_P8_DEFINITION[mapping])

    def test_new_tiles_sit_below_the_existing_ones_without_overlap(self):
        econ = next(s for s in self._def()["Sheets"] if s["SheetId"] == "economics")
        els = econ["Layouts"][0]["Configuration"]["GridLayout"]["Elements"]
        old_bottom = max(e["RowIndex"] + e["RowSpan"] for e in els if e["ElementId"] not in P8_VISUALS)
        new = [e for e in els if e["ElementId"] in P8_VISUALS]
        self.assertEqual({e["ElementId"] for e in new}, P8_VISUALS)
        self.assertTrue(all(e["RowIndex"] >= old_bottom for e in new))
        cells = set()
        for e in new:
            for r in range(e["RowIndex"], e["RowIndex"] + e["RowSpan"]):
                for c in range(e["ColumnIndex"], e["ColumnIndex"] + e["ColumnSpan"]):
                    self.assertNotIn((r, c), cells)
                    cells.add((r, c))


class TestP8DeployAndTeardown(unittest.TestCase):

    def _array(self, name: str) -> list[str]:
        return re.search(rf"{name}=\((.*?)\)", DEPLOY, re.S).group(1).split()

    def test_dataset_is_in_both_inventories(self):
        self.assertEqual(self._array("QS_ALL_DATASETS"), [
            "base-user-activity", "daily-trends", "user-totals", "tier-breakdown",
            "model-usage", "wow-movers", "activity-heatmap", "user-daily-dense",
            "credit-headroom"])
        self.assertEqual(self._array("QS_LABEL_DATASETS"), [
            "base-user-activity", "user-totals", "model-usage", "wow-movers",
            "user-daily-dense", "credit-headroom"])

    def test_deploy_sh_change_is_only_those_lines(self):
        # P12 later rewrote the 3-line AWSQuicksightAthenaAccess check. Put the
        # original 3 lines back at that spot first, so this test still proves
        # that outside the P8 lines and the P12 block deploy.sh is untouched;
        # tests/test_grep_pipefail_patch.py pins what the P12 block does.
        data = DEPLOY_BYTES
        if P12_START in data:
            s = data.index(P12_START)
            e = data.index(P12_END, s) + len(P12_END)
            data = data[:s] + P12_ORIGINAL + data[e:]
        lines = data.splitlines(keepends=True)
        self.assertEqual(sum(ln in P8_DEPLOY_LINES for ln in lines), 4)
        pre = b"".join(ln for ln in lines if ln not in P8_DEPLOY_LINES)
        self.assertEqual(hashlib.sha256(pre).hexdigest(), PRE_P8_DEPLOY_SH)

    def test_teardown_removes_it_with_the_quicksight_stack(self):
        """The dataset and its schedule are resources of the QS stack, which
        teardown deletes; nothing P8-specific is needed there."""
        self.assertIn("CreditHeadroomDataSet:", TEMPLATE_TEXT)
        self.assertIn("CreditHeadroomRefreshSchedule:", TEMPLATE_TEXT)
        self.assertIn('aws cloudformation delete-stack --stack-name "${QS_STACK}"', TEARDOWN)
        self.assertNotIn("credit", TEARDOWN.lower())


class TestP8Markers(unittest.TestCase):

    def test_every_patched_file_carries_the_marker(self):
        for path in (SCRIPTS / "normalize_report_lambda.py", SCRIPTS / "build_views.py",
                     SCRIPTS / "create_dashboard.py", SCRIPTS / "deploy.sh",
                     CFN / "02-quicksight.yaml", VIEW_FILE):
            with self.subTest(file=path.name):
                self.assertIn(MARKER, path.read_text())


if __name__ == "__main__":
    unittest.main()
