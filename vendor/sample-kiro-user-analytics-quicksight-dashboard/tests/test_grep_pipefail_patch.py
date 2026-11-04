"""P12: membership checks that read a list must not crash or false-negative.

Two defects, both of which answered "not there" for something that was there:

1. GNU grep 3.0 in Git for Windows aborts (exit 134) on `-F` together with `-i`.
   deploy.sh used `grep -Fixq` for AWSQuicksightAthenaAccess, so every deploy
   printed "NOT attached" and attached the policy again.
2. Under `set -o pipefail`, `list | grep -q` ends the grep at the first match,
   the writer gets SIGPIPE and the whole pipeline fails. With a long list that
   reads as "not found". preflight.sh used it for the QuickSight principal.

Offline: no AWS, no network. The behaviour tests run the real blocks, cut out of
the scripts, under a real bash (skipped when only the WSL launcher is on PATH).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import unittest

from _helpers import SCRIPTS

DEPLOY = (SCRIPTS / "deploy.sh").read_text()
PREFLIGHT = (SCRIPTS / "preflight.sh").read_text()
RUNCHECKS = (SCRIPTS / "run-checks.sh").read_text()

BASH = shutil.which("bash")
HAS_BASH = bool(BASH) and "system32" not in BASH.lower()
ARN = "arn:aws:iam::aws:policy/service-role/AWSQuicksightAthenaAccess"


def code_lines(text: str) -> list[tuple[int, str]]:
    return [(i, ln) for i, ln in enumerate(text.splitlines(), 1) if not ln.strip().startswith("#")]


class TestStatic(unittest.TestCase):
    def test_no_fixed_string_plus_ignore_case_grep_left(self):
        """-F with -i is the pair that aborts. Any order, any other letters."""
        bad = []
        for name, text in (("deploy.sh", DEPLOY), ("preflight.sh", PREFLIGHT), ("teardown.sh", (SCRIPTS / "teardown.sh").read_text())):
            for i, ln in code_lines(text):
                for m in re.finditer(r"\bgrep\s+(-[A-Za-z]+\s+)*-([A-Za-z]*)", ln):
                    flags = "".join(re.findall(r"\s-([A-Za-z]+)", " " + m.group(0)))
                    if "F" in flags and "i" in flags:
                        bad.append(f"{name}:{i}: {ln.strip()}")
        self.assertEqual(bad, [])

    def test_list_checks_do_not_pipe_into_grep_q(self):
        """The three list lookups hand grep a string, not a pipe."""
        for name, text in (("deploy.sh", DEPLOY), ("preflight.sh", PREFLIGHT)):
            for i, ln in code_lines(text):
                if re.search(r"\|\s*grep\s+-[A-Za-z]*q\b", ln) and "STACK_PREFIX" not in ln:
                    self.fail(f"{name}:{i} still pipes a list into grep -q: {ln.strip()}")

    def test_the_two_short_string_checks_are_left_alone(self):
        """Piping one short, already-written string cannot SIGPIPE; not touched."""
        self.assertIn("printf '%s' \"${STACK_PREFIX}\" | grep -Eq '^[a-z][a-z0-9-]{0,19}$'", DEPLOY)
        self.assertIn("head -1 | grep -q 'version 3'", RUNCHECKS)

    def test_patch_is_marked(self):
        self.assertIn("PATCH P12 (kiro-enterprise-monitoring)", DEPLOY)
        self.assertIn("PATCH P12 (kiro-enterprise-monitoring)", PREFLIGHT)

    def test_still_matches_whole_lines_case_insensitively(self):
        helper = DEPLOY[DEPLOY.index("has_line_ci() {"):]
        helper = helper[:helper.index("\n}\n") + 3]
        self.assertIn("tr 'A-Z' 'a-z'", helper)
        self.assertIn("grep -Fxq", helper)
        self.assertNotRegex(helper, r"grep[^\n]*-[A-Za-z]*i")


def _deploy_block() -> str:
    start = DEPLOY.index("has_line_ci() {")
    mid = DEPLOY.index('    echo "   already attached"', start)
    return DEPLOY[start:mid] + '    echo "   already attached"\nelse\n    echo "NOT-ATTACHED"\nfi\n'


@unittest.skipUnless(HAS_BASH, "needs a real bash (not the WSL launcher in System32); put Git Bash first on PATH")
class TestDeployBlockRuns(unittest.TestCase):
    """The real deploy.sh block, with a fake `aws`, under the script's own options."""

    def _run(self, listing: str | None, *, aws_fails: bool = False) -> subprocess.CompletedProcess:
        script = (
            "set -euo pipefail\n"
            f'QS_IAM_ROLE_NAME=role\nATHENA_POLICY_ARN="{ARN}"\n'
            'aws() { if [[ "${FAKE_FAIL:-0}" == 1 ]]; then return 255; fi; printf "%s" "${FAKE_LIST}"; }\n'
            + _deploy_block() + 'echo "SCRIPT-CONTINUED"\n'
        )
        env = dict(os.environ, FAKE_LIST=listing or "", FAKE_FAIL="1" if aws_fails else "0")
        return subprocess.run([BASH, "-c", script], capture_output=True, text=True, env=env, timeout=60)

    def _ok(self, r, word):
        self.assertIn(word, r.stdout, r.stderr)
        self.assertIn("SCRIPT-CONTINUED", r.stdout, r.stderr)
        self.assertNotIn("Aborted", r.stderr)

    def test_attached_is_seen(self):
        self._ok(self._run("arn:aws:iam::1:policy/a\t" + ARN + "\tarn:aws:iam::1:policy/b"), "already attached")

    def test_attached_under_other_case_is_seen(self):
        self._ok(self._run("arn:aws:iam::1:policy/a\t" + ARN.replace("Quicksight", "QuickSight")), "already attached")

    def test_only_the_whole_line_counts(self):
        self._ok(self._run(ARN + "Extra\tprefix" + ARN), "NOT-ATTACHED")

    def test_missing_is_reported(self):
        self._ok(self._run("arn:aws:iam::1:policy/a\tarn:aws:iam::1:policy/b"), "NOT-ATTACHED")

    def test_empty_list_is_reported(self):
        self._ok(self._run(""), "NOT-ATTACHED")

    def test_failed_aws_call_means_not_attached_and_does_not_stop_the_script(self):
        self._ok(self._run("", aws_fails=True), "NOT-ATTACHED")

    def test_long_list_with_the_match_first_is_still_seen(self):
        listing = "\t".join([ARN] + [f"arn:aws:iam::1:policy/p{i}" for i in range(5000)])
        self._ok(self._run(listing), "already attached")


def _preflight_helper() -> str:
    line = next(ln for ln in PREFLIGHT.splitlines() if ln.strip().startswith("has_line()"))
    return line.strip() + "\n"


@unittest.skipUnless(HAS_BASH, "needs a real bash (not the WSL launcher in System32); put Git Bash first on PATH")
class TestPreflightHelperRuns(unittest.TestCase):
    PRINCIPAL = "arn:aws:quicksight:us-east-1:111122223333:user/default/someone"

    def _has(self, listing: str) -> int:
        script = "set -uo pipefail\n" + _preflight_helper() + f'has_line "{self.PRINCIPAL}" "$LISTING"\n'
        return subprocess.run([BASH, "-c", script], capture_output=True, text=True,
                              env=dict(os.environ, LISTING=listing), timeout=60).returncode

    def test_found(self):
        self.assertEqual(self._has("a\n" + self.PRINCIPAL + "\nb"), 0)

    def test_not_found(self):
        self.assertEqual(self._has("a\nb"), 1)

    def test_case_is_significant_here_as_before(self):
        self.assertEqual(self._has(self.PRINCIPAL.upper()), 1)

    def test_only_the_whole_line_counts(self):
        self.assertEqual(self._has(self.PRINCIPAL + "x"), 1)

    def test_long_list_with_the_match_first_is_found(self):
        self.assertEqual(self._has("\n".join([self.PRINCIPAL] + [f"u{i}" for i in range(20000)])), 0)

    def test_preflight_uses_the_helper_for_users_and_groups(self):
        self.assertEqual(PREFLIGHT.count('has_line "${QS_PRINCIPAL_ARN}"'), 2)


if __name__ == "__main__":
    unittest.main()
