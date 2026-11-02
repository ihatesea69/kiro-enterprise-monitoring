"""Tests for patch P5 (kiro-enterprise-monitoring): optional permissions boundary.

P5  cfn/01-data-layer.yaml + cfn/03-identity-mapping.yaml + scripts/deploy.sh:
    a PermissionsBoundaryArn parameter (default empty) is set as the
    PermissionsBoundary of every IAM role the stacks create, for accounts whose
    IAM policy denies iam:CreateRole without a specific boundary. Empty keeps
    upstream behaviour (AWS::NoValue).

Offline: no AWS, no network.
"""
from __future__ import annotations

import re
import unittest

from _helpers import CFN, SCRIPTS
from test_crossaccount_patches import _cfn_load, _Tag, yaml

TEMPLATES = {
    "01-data-layer.yaml": "NormalizerLambdaRole",
    "03-identity-mapping.yaml": "IdentityMapLambdaRole",
}
DEPLOY = (SCRIPTS / "deploy.sh").read_text()


@unittest.skipIf(yaml is None, "PyYAML not installed")
class TestP5Templates(unittest.TestCase):
    def test_parameter_is_optional_and_policy_shaped(self):
        for name in TEMPLATES:
            with self.subTest(template=name):
                p = _cfn_load((CFN / name).read_text())["Parameters"]["PermissionsBoundaryArn"]
                self.assertEqual(p["Default"], "")
                pattern = re.compile(p["AllowedPattern"])
                self.assertTrue(pattern.fullmatch(""))
                self.assertTrue(pattern.fullmatch("arn:aws:iam::111122223333:policy/boundary"))
                self.assertFalse(pattern.fullmatch("arn:aws:iam::111122223333:role/x"))

    def test_every_role_gets_the_boundary_or_novalue(self):
        for name, expected_role in TEMPLATES.items():
            with self.subTest(template=name):
                tpl = _cfn_load((CFN / name).read_text())
                roles = {k: r for k, r in tpl["Resources"].items() if r["Type"] == "AWS::IAM::Role"}
                self.assertEqual(sorted(roles), [expected_role])
                pb = roles[expected_role]["Properties"]["PermissionsBoundary"]
                self.assertIsInstance(pb, _Tag)
                self.assertEqual(pb.tag, "If")  # _cfn_load stores tags without the "!"
                cond, when_set, when_empty = pb.value
                self.assertEqual(cond, "HasPermissionsBoundary")
                self.assertEqual((when_set.tag, when_set.value), ("Ref", "PermissionsBoundaryArn"))
                self.assertEqual((when_empty.tag, when_empty.value), ("Ref", "AWS::NoValue"))
                self.assertIn("HasPermissionsBoundary", tpl["Conditions"])


class TestP5Deploy(unittest.TestCase):
    def test_env_var_defaults_empty(self):
        self.assertIn('PERMISSIONS_BOUNDARY_ARN="${PERMISSIONS_BOUNDARY_ARN:-}"', DEPLOY)

    def test_passed_to_every_stack_that_creates_a_role(self):
        # Two data-layer deploys (first create + code update) and the identity-map deploy.
        self.assertEqual(DEPLOY.count('"PermissionsBoundaryArn=${PERMISSIONS_BOUNDARY_ARN}"'), 3)

    def test_not_passed_to_quicksight_stack(self):
        qs = DEPLOY[DEPLOY.index('--template-file "${ROOT}/cfn/02-quicksight.yaml"'):]
        qs = qs[: qs.index('ThemeMode=${THEME_MODE}')]
        self.assertNotIn("PermissionsBoundaryArn", qs)


if __name__ == "__main__":
    unittest.main()
