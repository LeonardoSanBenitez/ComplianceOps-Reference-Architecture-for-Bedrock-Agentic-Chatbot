#!/usr/bin/env python3
"""
Automated evidence collector for compliance-ops-bedrock.

Queries AWS services and saves structured JSON evidence artifacts
to evidence/automated/. Each artifact is a snapshot of current
AWS configuration relevant to one or more compliance controls.

Usage:
    python scripts/collect_evidence.py [--region REGION] [--output-dir DIR]

Requirements:
    pip install boto3

AWS permissions needed (minimum):
    - guardduty:GetDetector, guardduty:ListDetectors
    - cloudtrail:GetTrail, cloudtrail:GetTrailStatus, cloudtrail:DescribeTrails
    - iam:GetAccountPasswordPolicy
    - bedrock:ListFoundationModels
    - s3:ListBuckets, s3:GetBucketEncryption, s3:GetBucketVersioning
    - kms:ListKeys (optional, for encryption evidence)
    - budgets:DescribeBudgets
    - cloudwatch:DescribeAlarms
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

logger = logging.getLogger(__name__)

EVIDENCE_SCHEMA_VERSION = "1"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def make_artifact(
    collector_id: str,
    description: str,
    controls: list[str],
    data: dict[str, Any],
    status: str = "collected",
) -> dict[str, Any]:
    """Wrap raw AWS data in a standard evidence artifact envelope."""
    return {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "collector_id": collector_id,
        "description": description,
        "collected_at": now_iso(),
        "status": status,
        "controls": controls,
        "data": data,
    }


def collect_guardduty(session: boto3.Session, region: str) -> dict[str, Any]:
    """Collect GuardDuty detector status."""
    client = session.client("guardduty", region_name=region)
    try:
        detector_ids = client.list_detectors()["DetectorIds"]
        detectors = []
        for did in detector_ids:
            det = client.get_detector(DetectorId=did)
            detectors.append({
                "detector_id": did,
                "status": det.get("Status"),
                "finding_publishing_frequency": det.get("FindingPublishingFrequency"),
                "service_role": det.get("ServiceRole"),
                "created_at": det.get("CreatedAt", ""),
                "updated_at": det.get("UpdatedAt", ""),
            })
        return make_artifact(
            collector_id="guardduty-status",
            description="GuardDuty detector status. Provides evidence for threat detection controls (GDPR Art. 32, 33).",
            controls=["gdpr-32", "gdpr-33"],
            data={"region": region, "detectors": detectors},
        )
    except ClientError as e:
        return make_artifact(
            collector_id="guardduty-status",
            description="GuardDuty detector status — collection failed.",
            controls=["gdpr-32", "gdpr-33"],
            data={"error": str(e), "region": region},
            status="error",
        )


def collect_cloudtrail(session: boto3.Session, region: str) -> dict[str, Any]:
    """Collect CloudTrail configuration."""
    client = session.client("cloudtrail", region_name=region)
    try:
        trails_response = client.describe_trails(includeShadowTrails=False)
        trails = []
        for trail in trails_response.get("trailList", []):
            trail_arn = trail.get("TrailARN", "")
            try:
                status = client.get_trail_status(Name=trail_arn)
            except ClientError:
                status = {}
            trails.append({
                "name": trail.get("Name"),
                "arn": trail_arn,
                "home_region": trail.get("HomeRegion"),
                "is_multi_region": trail.get("IsMultiRegionTrail"),
                "log_file_validation_enabled": trail.get("LogFileValidationEnabled"),
                "cloud_watch_logs_log_group_arn": trail.get("CloudWatchLogsLogGroupArn"),
                "is_logging": status.get("IsLogging"),
                "latest_delivery_time": str(status.get("LatestDeliveryTime", "")),
            })
        return make_artifact(
            collector_id="cloudtrail-status",
            description="CloudTrail configuration. Evidence for audit logging (GDPR Art. 5(1)(f), 32).",
            controls=["gdpr-5-1-f", "gdpr-32"],
            data={"region": region, "trails": trails},
        )
    except ClientError as e:
        return make_artifact(
            collector_id="cloudtrail-status",
            description="CloudTrail configuration — collection failed.",
            controls=["gdpr-5-1-f", "gdpr-32"],
            data={"error": str(e), "region": region},
            status="error",
        )


def collect_iam_password_policy(session: boto3.Session) -> dict[str, Any]:
    """Collect IAM account password policy."""
    client = session.client("iam")
    try:
        policy = client.get_account_password_policy()["PasswordPolicy"]
        return make_artifact(
            collector_id="iam-password-policy",
            description="IAM account password policy. Evidence for access control strength (GDPR Art. 32).",
            controls=["gdpr-32"],
            data={"policy": policy},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            return make_artifact(
                collector_id="iam-password-policy",
                description="IAM account password policy — no policy set.",
                controls=["gdpr-32"],
                data={"policy": None, "note": "No IAM password policy configured."},
                status="warning",
            )
        return make_artifact(
            collector_id="iam-password-policy",
            description="IAM account password policy — collection failed.",
            controls=["gdpr-32"],
            data={"error": str(e)},
            status="error",
        )


def collect_s3_buckets(session: boto3.Session) -> dict[str, Any]:
    """Collect S3 bucket inventory with encryption and versioning status."""
    client = session.client("s3")
    try:
        response = client.list_buckets()
        buckets = []
        for bucket in response.get("Buckets", []):
            name = bucket["Name"]
            bucket_info: dict[str, Any] = {"name": name, "created": str(bucket.get("CreationDate", ""))}

            # Encryption
            try:
                enc = client.get_bucket_encryption(Bucket=name)
                rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
                bucket_info["encryption"] = [r["ApplyServerSideEncryptionByDefault"] for r in rules]
            except ClientError as e:
                bucket_info["encryption"] = None
                bucket_info["encryption_error"] = e.response["Error"]["Code"]

            # Public access block
            try:
                pab = client.get_public_access_block(Bucket=name)["PublicAccessBlockConfiguration"]
                bucket_info["public_access_block"] = pab
            except ClientError:
                bucket_info["public_access_block"] = None

            # Versioning
            try:
                ver = client.get_bucket_versioning(Bucket=name)
                bucket_info["versioning"] = ver.get("Status", "Disabled")
            except ClientError:
                bucket_info["versioning"] = None

            buckets.append(bucket_info)

        return make_artifact(
            collector_id="s3-buckets",
            description="S3 bucket inventory with encryption and access control status.",
            controls=["gdpr-5-1-f", "gdpr-32"],
            data={"buckets": buckets, "count": len(buckets)},
        )
    except ClientError as e:
        return make_artifact(
            collector_id="s3-buckets",
            description="S3 bucket inventory — collection failed.",
            controls=["gdpr-5-1-f", "gdpr-32"],
            data={"error": str(e)},
            status="error",
        )


def collect_bedrock_models(session: boto3.Session, region: str) -> dict[str, Any]:
    """Collect available Bedrock foundation models."""
    client = session.client("bedrock", region_name=region)
    try:
        response = client.list_foundation_models()
        models = [
            {
                "model_id": m.get("modelId"),
                "model_name": m.get("modelName"),
                "provider": m.get("providerName"),
                "status": m.get("modelLifecycle", {}).get("status"),
                "input_modalities": m.get("inputModalities", []),
                "output_modalities": m.get("outputModalities", []),
            }
            for m in response.get("modelSummaries", [])
        ]
        return make_artifact(
            collector_id="bedrock-model-list",
            description="Available Bedrock foundation models. Evidence for GPAI model selection documentation (EU AI Act Art. 52).",
            controls=["euaia-52-1"],
            data={"region": region, "models": models, "count": len(models)},
        )
    except ClientError as e:
        return make_artifact(
            collector_id="bedrock-model-list",
            description="Bedrock model list — collection failed.",
            controls=["euaia-52-1"],
            data={"error": str(e), "region": region},
            status="error",
        )


def collect_billing_alarms(session: boto3.Session, region: str) -> dict[str, Any]:
    """Collect CloudWatch billing alarms (security posture hygiene)."""
    client = session.client("cloudwatch", region_name="us-east-1")  # billing always us-east-1
    try:
        paginator = client.get_paginator("describe_alarms")
        alarms = []
        for page in paginator.paginate(AlarmNamePrefix="billing"):
            for alarm in page.get("MetricAlarms", []):
                alarms.append({
                    "name": alarm.get("AlarmName"),
                    "state": alarm.get("StateValue"),
                    "threshold": alarm.get("Threshold"),
                    "comparison": alarm.get("ComparisonOperator"),
                })
        return make_artifact(
            collector_id="billing-alarms",
            description="CloudWatch billing alarms status.",
            controls=[],
            data={"alarms": alarms},
        )
    except ClientError as e:
        return make_artifact(
            collector_id="billing-alarms",
            description="Billing alarms — collection failed.",
            controls=[],
            data={"error": str(e)},
            status="error",
        )


def write_artifact(artifact: dict[str, Any], output_dir: Path) -> None:
    collector_id = artifact["collector_id"]
    outfile = output_dir / f"{collector_id}.json"
    outfile.write_text(json.dumps(artifact, indent=2, default=str))
    logger.info("Written: %s (status=%s)", outfile, artifact["status"])


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    parser = argparse.ArgumentParser(description="Collect AWS compliance evidence artifacts.")
    parser.add_argument("--region", default="us-east-1", help="AWS region for service queries")
    parser.add_argument(
        "--output-dir",
        default="evidence/automated",
        help="Directory to write evidence artifacts (default: evidence/automated)",
    )
    args = parser.parse_args(argv)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        session = boto3.Session()
        # Verify credentials are available
        session.client("sts").get_caller_identity()
    except NoCredentialsError:
        logger.error("No AWS credentials found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.")
        return 1
    except ClientError as e:
        logger.error("AWS credential check failed: %s", e)
        return 1

    collectors = [
        lambda: collect_guardduty(session, args.region),
        lambda: collect_cloudtrail(session, args.region),
        lambda: collect_iam_password_policy(session),
        lambda: collect_s3_buckets(session),
        lambda: collect_bedrock_models(session, args.region),
        lambda: collect_billing_alarms(session, args.region),
    ]

    errors = 0
    for collector in collectors:
        artifact = collector()
        write_artifact(artifact, output_dir)
        if artifact["status"] == "error":
            errors += 1

    # Write a manifest
    manifest = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "collected_at": now_iso(),
        "region": args.region,
        "artifacts": [f.name for f in sorted(output_dir.glob("*.json")) if f.name != "manifest.json"],
        "collection_errors": errors,
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    logger.info("Manifest written. %d collector(s) had errors.", errors)

    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
