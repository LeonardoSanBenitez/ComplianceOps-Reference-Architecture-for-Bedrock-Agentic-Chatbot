"""
Strands tools for the compliance-ops-bedrock chatbot.

Each function decorated with @tool is available to the Strands Agent as
an action it can invoke during orchestration. Tool functions must be typed,
take only primitive arguments (str, int, float, bool), and return a string
that the agent uses as tool output.
"""
import json
import logging

import boto3
from strands import tool

logger = logging.getLogger(__name__)

# ── Bedrock Agent Runtime client ────────────────────────────────────────────────
# Initialised once at module load; Lambda execution context reuses it.
_bedrock_runtime = boto3.client("bedrock-agent-runtime", region_name="us-east-1")

# Knowledge Base ID — injected via environment variable at Lambda deploy time.
import os
_KB_ID = os.environ.get("KNOWLEDGE_BASE_ID", "3TVGH0TAFE")


@tool
def retrieve_compliance_info(query: str) -> str:
    """Retrieve relevant compliance documentation from the knowledge base.

    Use this tool when the user asks about:
    - GDPR controls, articles, or requirements
    - EU AI Act requirements or classifications
    - Incident response procedures
    - System attestations or evidence
    - Architecture decisions or security controls

    Args:
        query: Natural-language question or topic to search in the knowledge base.

    Returns:
        Relevant passages from compliance documentation, or a message indicating
        nothing was found.
    """
    try:
        response = _bedrock_runtime.retrieve(
            knowledgeBaseId=_KB_ID,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {
                    "numberOfResults": 5,
                }
            },
        )
        results = response.get("retrievalResults", [])
        if not results:
            return "No relevant compliance documentation found for this query."

        passages = []
        for i, result in enumerate(results, start=1):
            content = result.get("content", {}).get("text", "")
            source_uri = (
                result.get("location", {})
                .get("s3Location", {})
                .get("uri", "unknown source")
            )
            score = result.get("score", 0.0)
            passages.append(
                f"[{i}] (score={score:.3f}, source={source_uri})\n{content}"
            )

        return "\n\n---\n\n".join(passages)

    except Exception as exc:
        logger.exception("retrieve_compliance_info failed: %s", exc)
        return f"Knowledge base retrieval failed: {exc}"


@tool
def list_gdpr_controls() -> str:
    """List the GDPR control identifiers and their titles from the catalog.

    Use this when the user asks what GDPR articles are covered, what controls
    exist, or wants an overview of the compliance scope.

    Returns:
        A formatted list of control IDs and titles, or an error message.
    """
    # We retrieve a broad query to get the catalog structure.
    return retrieve_compliance_info(
        "List all GDPR control identifiers, article numbers, and titles"
    )


@tool
def list_eu_ai_act_controls() -> str:
    """List the EU AI Act control identifiers and their titles from the catalog.

    Use this when the user asks about EU AI Act requirements, the system's AI
    risk classification, or what AI Act articles apply to this chatbot.

    Returns:
        A formatted list of EU AI Act control IDs and titles, or an error message.
    """
    return retrieve_compliance_info(
        "List all EU AI Act control identifiers, article numbers, and titles"
    )
