"""Tests for tools/verify_backup.py. Offline: a fake S3 client."""
from __future__ import annotations

import contextlib
import io
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import verify_backup as vb  # noqa: E402


class FakeS3:
    def __init__(self, buckets: dict[str, dict[str, tuple[int, str]]], page: int = 2):
        self.buckets, self.page = buckets, page

    def list_objects_v2(self, Bucket, Prefix, ContinuationToken=None):  # noqa: N803 - boto3 names
        keys = sorted(k for k in self.buckets[Bucket] if k.startswith(Prefix))
        start = int(ContinuationToken or 0)
        chunk = keys[start:start + self.page]
        resp = {"Contents": [{"Key": k, "Size": self.buckets[Bucket][k][0], "ETag": f'"{self.buckets[Bucket][k][1]}"'} for k in chunk]}
        if start + self.page < len(keys):
            resp.update(IsTruncated=True, NextContinuationToken=str(start + self.page))
        else:
            resp["IsTruncated"] = False
        return resp


def run(source, backup, extra_args=()):
    client = FakeS3({"src": source, "bak": backup})
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = vb.main(["--source", "src", "--backup", "bak", *extra_args], client=client)
    return rc, out.getvalue()


A = {"kiro/a.csv": (10, "e1"), "kiro/b.csv": (20, "e2"), "kiro/c.csv": (30, "e3")}


class VerifyBackup(unittest.TestCase):
    def test_identical_is_ok_across_pages(self):
        rc, out = run(A, dict(A))
        self.assertEqual(rc, 0)
        self.assertIn("source objects: 3  backup objects: 3", out)

    def test_missing_object_fails(self):
        b = dict(A)
        del b["kiro/b.csv"]
        rc, out = run(A, b)
        self.assertEqual(rc, 1)
        self.assertIn("missing in backup: 1", out)
        self.assertIn("missing: kiro/b.csv", out)

    def test_etag_difference_fails(self):
        b = dict(A)
        b["kiro/c.csv"] = (30, "other")
        rc, out = run(A, b)
        self.assertEqual(rc, 1)
        self.assertIn("size/ETag differ: 1", out)

    def test_size_difference_fails(self):
        b = dict(A)
        b["kiro/a.csv"] = (11, "e1")
        self.assertEqual(run(A, b)[0], 1)

    def test_extra_in_backup_is_not_an_error(self):
        b = dict(A)
        b["kiro/old.csv"] = (5, "x")
        rc, out = run(A, b)
        self.assertEqual(rc, 0)
        self.assertIn("extra in backup: 1", out)

    def test_empty_source_proves_nothing(self):
        rc, out = run({}, {})
        self.assertEqual(rc, 2)
        self.assertIn("expected at least 1", out)

    def test_prefix_limits_the_comparison(self):
        a = dict(A)
        a["other/x.csv"] = (1, "z")
        rc, _ = run(a, dict(A))
        self.assertEqual(rc, 0)

    def test_never_reads_content(self):
        self.assertFalse(hasattr(FakeS3, "get_object"))
        src = pathlib.Path(vb.__file__).read_text(encoding="utf-8")
        self.assertNotIn("get_object", src)
        self.assertNotIn("delete_", src)
        self.assertNotIn("put_object", src)


if __name__ == "__main__":
    unittest.main()
