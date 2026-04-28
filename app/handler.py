"""
AWS Lambda handler for the compliance-ops-bedrock chatbot endpoint.

Accepts POST requests with body: {"message": "<user input>", "session_id": "<uuid>"}
Returns: {"response": "<agent reply>", "session_id": "<uuid>"}

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
from typing import Any

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Import the agent singleton. The import-time initialisation runs once per
# cold start; subsequent invocations reuse the already-initialised agent.
from app.agent import agent

_CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")

# ── Conversation logging configuration ────────────────────────────────────────

_DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "")
_CONV_LOG_BUCKET = os.environ.get("CONV_LOG_BUCKET", "")
_RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))

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


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Lambda entry point.

    Expected event shape (Lambda Function URL or API Gateway proxy):
        {
          "body": "{\"message\": \"...\", \"session_id\": \"...\"}",
          "httpMethod": "POST"   // or requestContext.http.method for Function URL
        }

    The session_id is optional; a new UUID is generated if omitted.
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
