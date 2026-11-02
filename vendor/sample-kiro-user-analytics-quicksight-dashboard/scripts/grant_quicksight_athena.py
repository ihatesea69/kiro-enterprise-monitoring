#!/usr/bin/env python3
"""PATCH P7 (kiro-enterprise-monitoring): scoped Athena + Glue access for QuickSight.

Writes one inline policy, <STACK_PREFIX>-QuickSightAthenaAccess, on the
QuickSight service role. It grants Athena query actions on THIS deployment's
workgroup and Glue read on THIS deployment's database only.

Why: upstream relies on the account-wide managed policy AWSQuicksightAthenaAccess.
That attachment is shared by every project in the account, and another
project's Terraform detached it (2026-11-02), breaking every SPICE refresh
here. With this inline policy the dashboard no longer depends on it.

    python3 grant_quicksight_athena.py --region R --role-name ROLE \\
        --policy-name kiro-x-QuickSightAthenaAccess --workgroup W --database D [--apply]

Exit codes: 0 policy already matches (or applied), 1 missing and not applied, 2 bad input.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

_NAME_RE = re.compile(r"^[A-Za-z0-9_.@+=,-]{1,128}$")
_GLUE_RE = re.compile(r"^[a-z0-9_]{1,255}$")
_REGION_RE = re.compile(r"^[a-z]{2}(-[a-z]+)+-[0-9]$")


def render_policy(partition: str, region: str, account: str, workgroup: str, database: str) -> dict:
    athena = f"arn:{partition}:athena:{region}:{account}"
    glue = f"arn:{partition}:glue:{region}:{account}"
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AthenaOnWorkgroup",
                "Effect": "Allow",
                "Action": [
                    "athena:StartQueryExecution", "athena:StopQueryExecution",
                    "athena:GetQueryExecution", "athena:BatchGetQueryExecution",
                    "athena:GetQueryResults", "athena:GetQueryResultsStream",
                    "athena:GetWorkGroup",
                ],
                "Resource": f"{athena}:workgroup/{workgroup}",
            },
            {
                "Sid": "AthenaCatalogMetadata",
                "Effect": "Allow",
                "Action": [
                    "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
                    "athena:ListDatabases", "athena:ListTableMetadata",
                ],
                "Resource": f"{athena}:datacatalog/AwsDataCatalog",
            },
            {
                "Sid": "AthenaListOnly",
                "Effect": "Allow",
                "Action": ["athena:ListWorkGroups", "athena:ListDataCatalogs", "athena:ListEngineVersions"],
                "Resource": "*",
            },
            {
                "Sid": "GlueReadDatabase",
                "Effect": "Allow",
                "Action": [
                    "glue:GetDatabase", "glue:GetTable", "glue:GetTables",
                    "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
                ],
                "Resource": [f"{glue}:catalog", f"{glue}:database/{database}", f"{glue}:table/{database}/*"],
            },
            {
                "Sid": "LakeFormationDataAccess",
                "Effect": "Allow",
                "Action": "lakeformation:GetDataAccess",
                "Resource": "*",
            },
        ],
    }


def _canonical(doc: dict) -> str:
    return json.dumps(doc, sort_keys=True)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--region", required=True)
    p.add_argument("--role-name", required=True)
    p.add_argument("--policy-name", required=True)
    p.add_argument("--workgroup", required=True)
    p.add_argument("--database", required=True)
    p.add_argument("--apply", action="store_true")
    a = p.parse_args(argv)

    if not _REGION_RE.match(a.region):
        print(f"invalid region: {a.region!r}", file=sys.stderr)
        return 2
    for label, value in (("role-name", a.role_name), ("policy-name", a.policy_name), ("workgroup", a.workgroup)):
        if not _NAME_RE.match(value):
            print(f"invalid {label}: {value!r}", file=sys.stderr)
            return 2
    if not _GLUE_RE.match(a.database):
        print(f"invalid database: {a.database!r}", file=sys.stderr)
        return 2

    import boto3  # imported here so tests can call render_policy without boto3
    from botocore.exceptions import ClientError

    # Region on the session: an `aws login` profile without a configured region
    # otherwise fails credential refresh with NoRegionError.
    session = boto3.Session(region_name=a.region)
    ident = session.client("sts").get_caller_identity()
    partition = ident["Arn"].split(":")[1]
    desired = render_policy(partition, a.region, ident["Account"], a.workgroup, a.database)
    iam = session.client("iam")
    try:
        current = iam.get_role_policy(RoleName=a.role_name, PolicyName=a.policy_name)["PolicyDocument"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "NoSuchEntity":
            raise
        current = None
    if current is not None and _canonical(current) == _canonical(desired):
        print(f"[OK] {a.policy_name} on {a.role_name} already matches.")
        return 0
    action = "UPDATE" if current else "CREATE"
    print(f"[{action}] inline policy {a.policy_name} on {a.role_name}: Athena on workgroup "
          f"{a.workgroup}, Glue read on database {a.database}.")
    if not a.apply:
        return 1
    iam.put_role_policy(RoleName=a.role_name, PolicyName=a.policy_name, PolicyDocument=json.dumps(desired))
    print(f"[OK] wrote {a.policy_name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
