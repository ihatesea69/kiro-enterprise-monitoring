"""Compare the Kiro report bucket with its backup bucket (read only).

The raw report is the only copy of the history, so before anything that could
lose data (a stack delete, a migration) every report object must exist in the
backup with the same size and ETag. Replication copies only objects written
after the rule exists; copy the older ones once with `aws s3 sync` and run this.

  python tools/verify_backup.py --source kiro-user-report-<acct> --backup kiro-mon-backup-<acct> \
      --prefix kiro/ --profile <profile> --region us-east-1

Exit code 0 only when every source object is in the backup. Extra objects in
the backup are reported but are not an error (the backup is never pruned).
It lists and heads objects; it never reads their content.
"""
from __future__ import annotations

import argparse
import sys


def list_objects(client, bucket: str, prefix: str) -> dict[str, tuple[int, str]]:
    """key -> (size, etag) of the current version of every object under prefix."""
    out: dict[str, tuple[int, str]] = {}
    token = None
    while True:
        kw = {"Bucket": bucket, "Prefix": prefix}
        if token:
            kw["ContinuationToken"] = token
        page = client.list_objects_v2(**kw)
        for o in page.get("Contents", []):
            out[o["Key"]] = (int(o["Size"]), o["ETag"].strip('"'))
        if not page.get("IsTruncated"):
            return out
        token = page["NextContinuationToken"]


def compare(source: dict, backup: dict) -> dict:
    missing = sorted(k for k in source if k not in backup)
    differ = sorted(k for k in source if k in backup and source[k] != backup[k])
    extra = sorted(k for k in backup if k not in source)
    return {"missing": missing, "differ": differ, "extra": extra, "ok": not missing and not differ}


def main(argv=None, client=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True)
    ap.add_argument("--backup", required=True)
    ap.add_argument("--prefix", default="kiro/")
    ap.add_argument("--profile")
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--min-objects", type=int, default=1,
                    help="Fail when the source has fewer objects than this (an empty source proves nothing).")
    args = ap.parse_args(argv)

    if client is None:
        import boto3

        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("s3")

    source = list_objects(client, args.source, args.prefix)
    backup = list_objects(client, args.backup, args.prefix)
    res = compare(source, backup)

    print(f"source objects: {len(source)}  backup objects: {len(backup)}")
    print(f"missing in backup: {len(res['missing'])}  size/ETag differ: {len(res['differ'])}  extra in backup: {len(res['extra'])}")
    for label in ("missing", "differ"):
        for k in res[label][:10]:
            print(f"  {label}: {k}")
    if len(source) < args.min_objects:
        print(f"FAIL: source has {len(source)} objects, expected at least {args.min_objects}")
        return 2
    print("OK: every source object is in the backup" if res["ok"] else "FAIL: backup is incomplete")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
