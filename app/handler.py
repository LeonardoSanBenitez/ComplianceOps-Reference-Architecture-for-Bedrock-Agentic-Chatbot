"""
AWS Lambda handler for the compliance-ops-bedrock chatbot endpoint.

Routes:
  POST /         — chatbot: {"message": "<user input>", "session_id": "<uuid>"}
                   Returns: {"response": "<agent reply>", "session_id": "<uuid>"}
  POST /report   — generate compliance report and upload to the report S3 bucket.
                   Returns: {"url": "<s3-website-url>", "bytes": <n>}

Session persistence: conversation history is managed in-process by the Strands
agent (it maintains a message list per agent instance). For multi-Lambda-instance
scaling, session history would need to be externalised to DynamoDB; this is
acceptable for the demo which runs at low concurrency.

EU AI Act Art. 50(1): the system prompt and every response header includes a
disclosure that responses are AI-generated. The "x-ai-generated" response header
makes this machine-readable for downstream integrations.

Conversation logging: after each successful invocation the handler writes a
session record to DynamoDB (TTL-controlled) and a JSON log entry to S3 (lifecycle-
controlled). Both writes are best-effort — logging failures do not affect the
response returned to the caller.
"""
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Import the agent singleton. The import-time initialisation runs once per
# cold start; subsequent invocations reuse the already-initialised agent.
from app.agent import agent

# Import report generation functions (no subprocess — runs in-process).
from scripts.generate_report import (
    assemble_report,
    load_attestations,
    load_catalogs,
    load_evidence,
    REPORT_TEMPLATE,
)

_CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")

# ── Conversation logging configuration ────────────────────────────────────────

_DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "")
_CONV_LOG_BUCKET = os.environ.get("CONV_LOG_BUCKET", "")
_RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
_REPORT_BUCKET = os.environ.get("REPORT_BUCKET", "")

# Lazy boto3 clients — initialised once per cold start.
_dynamodb_client: Any = None
_s3_client: Any = None


def _get_dynamodb() -> Any:
    global _dynamodb_client
    if _dynamodb_client is None:
        _dynamodb_client = boto3.client("dynamodb")
    return _dynamodb_client


def _get_s3() -> Any:
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _log_to_dynamodb(
    session_id: str,
    timestamp_iso: str,
    message_length: int,
    response_length: int,
) -> None:
    """Write a session record to DynamoDB (best-effort)."""
    if not _DYNAMODB_TABLE:
        logger.warning("DYNAMODB_TABLE not set; skipping DynamoDB logging")
        return
    ttl_epoch = int(time.time()) + _RETENTION_DAYS * 86400
    try:
        _get_dynamodb().put_item(
            TableName=_DYNAMODB_TABLE,
            Item={
                "session_id": {"S": session_id},
                "created_at": {"S": timestamp_iso},
                "ttl_epoch": {"N": str(ttl_epoch)},
                "message_length": {"N": str(message_length)},
                "response_length": {"N": str(response_length)},
            },
        )
    except Exception as exc:
        logger.error("DynamoDB write failed for session=%s: %s", session_id, exc)


def _log_to_s3(
    session_id: str,
    timestamp_iso: str,
    message: str,
    response_text: str,
) -> None:
    """Write a JSON conversation log entry to S3 (best-effort)."""
    if not _CONV_LOG_BUCKET:
        logger.warning("CONV_LOG_BUCKET not set; skipping S3 logging")
        return
    key = f"logs/{session_id}/{timestamp_iso}.json"
    log_entry = {
        "session_id": session_id,
        "timestamp": timestamp_iso,
        # Truncate to 512 chars to limit PII exposure in stored logs.
        "message_preview": message[:512],
        "response_preview": response_text[:512],
    }
    try:
        _get_s3().put_object(
            Bucket=_CONV_LOG_BUCKET,
            Key=key,
            Body=json.dumps(log_entry).encode("utf-8"),
            ContentType="application/json",
        )
    except Exception as exc:
        logger.error("S3 write failed for session=%s key=%s: %s", session_id, key, exc)

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

    Expected event shapes:
      POST /        — chatbot request:
                      body: {"message": "...", "session_id": "..."}
                      Returns: {"response": "...", "session_id": "..."}
      POST /report  — generate and publish compliance report.
                      Returns: {"url": "<s3-website-url>", "bytes": <n>}
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

    # Route dispatch — POST /report generates and publishes the compliance report.
    raw_path = (
        event.get("path")
        or event.get("rawPath")
        or event.get("requestContext", {}).get("http", {}).get("path", "/")
        or "/"
    )
    if raw_path.rstrip("/") == "/report":
        return _handle_report()

    # Default route: chatbot
    # Parse request body
    raw_body = event.get("body") or "{}"
    try:
        body = json.loads(raw_body)
    except json.JSONDecodeError:
        return _err(400, "Request body must be valid JSON.")

    message: str = body.get("message", "").strip()
    if not message:
        return _err(400, "'message' field is required and must not be empty.")

    session_id: str = body.get("session_id") or str(uuid.uuid4())

    logger.info("session=%s message_length=%d", session_id, len(message))

    # Invoke the Strands agent
    try:
        result = agent(message)
        # Strands returns an AgentResult; str() gives the final text response.
        response_text = str(result)
    except Exception as exc:
        logger.exception("Agent invocation failed for session=%s: %s", session_id, exc)
        return _err(500, f"Agent error: {exc}")

    logger.info("session=%s response_length=%d", session_id, len(response_text))

    # Conversation logging — best-effort; failures do not affect the response.
    timestamp_iso = datetime.now(timezone.utc).isoformat()
    _log_to_dynamodb(session_id, timestamp_iso, len(message), len(response_text))
    _log_to_s3(session_id, timestamp_iso, message, response_text)

    return _ok(
        {
            "response": response_text,
            "session_id": session_id,
            # EU AI Act Art. 50 disclosure in response body as well
            "ai_disclosure": (
                "This response was generated by an AI system "
                "(ComplianceOps Reference Architecture demo). "
                "It is not legal advice and must be reviewed by qualified humans."
            ),
        }
    )
