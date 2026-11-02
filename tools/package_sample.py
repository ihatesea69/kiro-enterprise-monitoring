#!/usr/bin/env python3
"""Package the patched layer 3 sample for CloudShell (task 5.7, agent part).

    python tools/package_sample.py            # writes dist/kiro-sample-<short sha>.zip

The zip holds the files git tracks under vendor/sample-kiro-user-analytics-quicksight-dashboard/,
read from the index (so a stray local edit or a CRLF checkout never gets in).
Entries are sorted with a fixed timestamp, so the same tree gives the same zip.
deploy.sh and preflight.sh are stored executable. A SHA256 of the zip is printed
and written next to it; the operator compares it after the upload.

Then, in CloudShell (ap-southeast-1):
    unzip kiro-sample-<sha>.zip && cd sample-kiro-user-analytics-quicksight-dashboard
    STACK_PREFIX=kiro-<slug> KIRO_LOGS_BUCKET=<bucket> KIRO_LOGS_PREFIX=kiro/ \
    KIRO_SOURCE_ACCOUNT_ID=<kiro account> AWS_REGION=ap-southeast-1 QS_PRINCIPAL_ARN=<arn> \
    PROJECTION_START=<yyyy-MM-dd the Kiro report was enabled> \
    [IDENTITY_MAPPING=true IDENTITY_STORE_ID=<d-...> IDC_REGION=<r> IDC_ROLE_ARN=<arn> IDC_EXTERNAL_ID=<id>] \
    scripts/deploy.sh
"""
from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import zipfile

VENDOR = "vendor/sample-kiro-user-analytics-quicksight-dashboard"
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
EXECUTABLE = {"scripts/deploy.sh", "scripts/preflight.sh", "scripts/teardown.sh", "scripts/run-checks.sh"}


def git(repo: pathlib.Path, *args: str) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True).stdout


def build(repo: pathlib.Path, out_dir: pathlib.Path) -> pathlib.Path:
    paths = sorted(p for p in git(repo, "ls-files", "-z", "--", VENDOR).decode().split("\0") if p)
    if not paths:
        raise SystemExit(f"nothing tracked under {VENDOR}")
    short = git(repo, "rev-parse", "--short", "HEAD").decode().strip()
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"kiro-sample-{short}.zip"
    top = VENDOR.split("/")[-1]
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p in paths:
            rel = p[len(VENDOR) + 1:]
            data = git(repo, "show", f":{p}")
            if rel.endswith(".sh") and b"\r\n" in data:
                raise SystemExit(f"{rel} has CRLF in the index; bash would fail")
            info = zipfile.ZipInfo(f"{top}/{rel}", date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if rel in EXECUTABLE else 0o644) << 16
            zf.writestr(info, data)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    (out.parent / (out.name + ".sha256")).write_text(f"{digest}  {out.name}\n", encoding="utf-8")
    print(f"{out} files={len(paths)} bytes={out.stat().st_size} sha256={digest}")
    return out


def main() -> int:
    repo = pathlib.Path(git(pathlib.Path("."), "rev-parse", "--show-toplevel").decode().strip())
    build(repo, repo / "dist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
