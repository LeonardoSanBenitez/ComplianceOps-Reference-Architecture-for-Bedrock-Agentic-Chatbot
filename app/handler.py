"""
AWS Lambda handler for the compliance-ops-bedrock report endpoint.

Routes:
  POST /report   — generate compliance report and upload to the report S3 bucket.
                   Returns: {"url": "<s3-website-url>", "bytes": <n>}

The chatbot (POST /) route has been removed.  Chat is now handled by the
Amazon Bedrock AgentCore Runtime (see app/agentcore_app.py and
infra/terraform/agentcore.tf).  The Lambda function is retained solely to
serve the /report endpoint, which generates and publishes the static HTML
compliance report.

EU AI Act Art. 50(1): the response headers include a disclosure that the
system is AI-powered.  The "X-AI-Generated" response header makes this
machine-readable for downstream integrations.
"""
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Ensure the repo root is on sys.path so that the `scripts` package is
# importable regardless of how the Lambda runtime sets up PYTHONPATH.
# In the container image, LAMBDA_TASK_ROOT=/var/task and all directories
# are copied there, but the runtime only guarantees /var/task is in
# sys.path when the handler module is at the root — not inside a package.
_TASK_ROOT = Path(__file__).parent.parent  # app/ -> repo root in container
if str(_TASK_ROOT) not in sys.path:
    sys.path.insert(0, str(_TASK_ROOT))

# Import report generation functions (no subprocess — runs in-process).
from scripts.generate_report import (
    assemble_report,
    load_attestations,
    load_catalogs,
    load_evidence,
    REPORT_TEMPLATE,
)

_CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")
_REPORT_BUCKET = os.environ.get("REPORT_BUCKET", "")

# Lazy boto3 S3 client — initialised once per cold start.
_s3_client: Any = None


def _get_s3() -> Any:
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client

_RESPONSE_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": _CORS_ORIGIN,
    # EU AI Act Art. 50 machine-readable disclosure
    "X-AI-Generated": "true",
    "X-AI-System": "compliance-ops-bedrock-demo",
}


def _ok(body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": 200,
        "headers": _RESPONSE_HEADERS,
        "body": json.dumps(body),
    }


def _err(status: int, message: str) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": _RESPONSE_HEADERS,
        "body": json.dumps({"error": message}),
    }


def _handle_report() -> dict[str, Any]:
    """Generate the HTML compliance report in-process and upload it to the report S3 bucket.

    The report S3 bucket is a static website (see infra/terraform/s3.tf).
    This function is called when a POST request is made to /report.

    Returns a 200 response with {"url": "<s3-website-url>", "bytes": <n>} on success,
    or a 5xx response on failure.
    """
    if not _REPORT_BUCKET:
        logger.warning("REPORT_BUCKET not set; cannot publish report")
        return _err(500, "REPORT_BUCKET environment variable is not configured.")

    # Resolve paths relative to the Lambda working directory.
    # In the container image the repo root is at /var/task.
    repo_root = Path(__file__).parent.parent
    catalog_dir = repo_root / "compliance" / "catalogs"
    attestation_dir = repo_root / "attestations"
    evidence_dir = repo_root / "evidence" / "automated"

    if not catalog_dir.exists():
        logger.error("Catalog directory not found at %s", catalog_dir)
        return _err(500, f"Catalog directory not found: {catalog_dir}")

    try:
        from jinja2 import Environment as JinjaEnv
        catalogs_raw = load_catalogs(catalog_dir)
        attestations = load_attestations(attestation_dir) if attestation_dir.exists() else {}
        evidence = load_evidence(evidence_dir) if evidence_dir.exists() else []
        report_data = assemble_report(catalogs_raw, attestations, evidence)

        env = JinjaEnv(autoescape=True)
        env.filters["replace"] = lambda s, old, new: str(s).replace(old, new)
        template = env.from_string(REPORT_TEMPLATE)
        html = template.render(**report_data)
    except Exception as exc:
        logger.exception("Report generation failed: %s", exc)
        return _err(500, f"Report generation failed: {exc}")

    html_bytes = html.encode("utf-8")
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    report_url = f"http://{_REPORT_BUCKET}.s3-website-{region}.amazonaws.com"

    try:
        _get_s3().put_object(
            Bucket=_REPORT_BUCKET,
            Key="index.html",
            Body=html_bytes,
            ContentType="text/html; charset=utf-8",
        )
    except Exception as exc:
        logger.exception("Failed to upload report to S3 bucket %s: %s", _REPORT_BUCKET, exc)
        return _err(500, f"Failed to upload report to S3: {exc}")

    logger.info("Report uploaded to s3://%s/index.html (%d bytes)", _REPORT_BUCKET, len(html_bytes))
    return _ok({"url": report_url, "bytes": len(html_bytes)})


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Lambda entry point.

    Only one route is handled:
      POST /report  — generate and publish compliance report.
                      Returns: {"url": "<s3-website-url>", "bytes": <n>}

    The chatbot route (POST /) has been removed; chat requests are now
    handled by the Bedrock AgentCore Runtime (app/agentcore_app.py).
    """
    # Handle CORS pre-flight
    method = (
        event.get("httpMethod")
        or event.get("requestContext", {}).get("http", {}).get("method", "")
    ).upper()
    if method == "OPTIONS":
        return {"statusCode": 204, "headers": _RESPONSE_HEADERS, "body": ""}

    if method not in ("POST", ""):
        return _err(405, "Method not allowed. Use POST.")

    raw_path = (
        event.get("path")
        or event.get("rawPath")
        or event.get("requestContext", {}).get("http", {}).get("path", "/")
        or "/"
    )
    if raw_path.rstrip("/") == "/report":
        return _handle_report()

    return _err(
        404,
        "Not found. This endpoint only handles POST /report. "
        "For chat, use the Bedrock AgentCore Runtime endpoint.",
    )
