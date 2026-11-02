"""Tests for patch P7 (kiro-enterprise-monitoring): scoped Athena inline policy for QuickSight.

Offline: no AWS, no network. render_policy is pure; main() is only exercised
for input validation (exit 2 before any AWS call).
"""
from __future__ import annotations

import unittest

from _helpers import SCRIPTS, load

DEPLOY = (SCRIPTS / "deploy.sh").read_text()
TEARDOWN = (SCRIPTS / "teardown.sh").read_text()


class TestP7Policy(unittest.TestCase):
    def setUp(self):
        self.mod = load("grant_quicksight_athena")
        self.doc = self.mod.render_policy("aws", "ap-southeast-1", "111122223333", "kiro_x", "kiro_x")
        self.by_sid = {s["Sid"]: s for s in self.doc["Statement"]}

    def test_query_actions_only_on_this_workgroup(self):
        st = self.by_sid["AthenaOnWorkgroup"]
        self.assertIn("athena:StartQueryExecution", st["Action"])
        self.assertEqual(st["Resource"], "arn:aws:athena:ap-southeast-1:111122223333:workgroup/kiro_x")

    def test_glue_only_on_this_database(self):
        res = self.by_sid["GlueReadDatabase"]["Resource"]
        self.assertIn("arn:aws:glue:ap-southeast-1:111122223333:database/kiro_x", res)
        self.assertIn("arn:aws:glue:ap-southeast-1:111122223333:table/kiro_x/*", res)
        self.assertFalse(any(r.endswith(":database/*") or r == "*" for r in res))

    def test_no_write_actions(self):
        actions = [a for s in self.doc["Statement"] for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])]
        for bad in ("glue:Create", "glue:Delete", "glue:Update", "s3:", "iam:"):
            self.assertFalse([a for a in actions if a.startswith(bad)], bad)

    def test_star_resource_only_for_list_and_lakeformation(self):
        star = sorted(s["Sid"] for s in self.doc["Statement"] if s["Resource"] == "*")
        self.assertEqual(star, ["AthenaListOnly", "LakeFormationDataAccess"])

    def test_bad_input_exits_2_before_aws(self):
        base = ["--region", "ap-southeast-1", "--role-name", "r", "--policy-name", "p",
                "--workgroup", "w", "--database", "d"]
        for i, bad in ((9, "D;DROP"), (1, "nowhere"), (7, "w g")):
            argv = list(base)
            argv[i] = bad
            with self.subTest(argv=argv):
                self.assertEqual(self.mod.main(argv), 2)


class TestP7Scripts(unittest.TestCase):
    def test_deploy_calls_grant_with_apply_and_this_deployment(self):
        block = DEPLOY[DEPLOY.index("grant_quicksight_athena.py"):]
        block = block[: block.index('--database "${DATABASE}"')]
        self.assertIn("--apply", DEPLOY[DEPLOY.index("grant_quicksight_athena.py") - 40:][:120])
        self.assertIn('--workgroup "${WORKGROUP}"', block)
        self.assertIn('--policy-name "${STACK_PREFIX}-QuickSightAthenaAccess"', block)

    def test_grant_runs_before_quicksight_stack(self):
        self.assertLess(DEPLOY.index("grant_quicksight_athena.py"),
                        DEPLOY.index('--template-file "${ROOT}/cfn/02-quicksight.yaml"'))

    def test_teardown_removes_only_its_own_policy(self):
        self.assertIn('--policy-name "${STACK_PREFIX}-QuickSightAthenaAccess"', TEARDOWN)
        self.assertNotIn("detach-role-policy", TEARDOWN)


if __name__ == "__main__":
    unittest.main()
