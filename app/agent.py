"""
Strands agent for the compliance-ops-bedrock chatbot.

The agent is initialised once at module load so it is reused across
Lambda invocations (warm starts). It uses Amazon Nova Micro as the
orchestration model, which is the same model used by the Bedrock Agent.

EU AI Act Art. 50(1) compliance: the system prompt explicitly identifies
this as an AI system and instructs the agent to self-identify on request.
"""
import os

from strands import Agent
from strands.models import BedrockModel

from app.tools import list_eu_ai_act_controls, list_gdpr_controls, retrieve_compliance_info

# ── System prompt ───────────────────────────────────────────────────────────────
# Satisfies EU AI Act Art. 50(1): AI system must disclose its nature.
_SYSTEM_PROMPT = """\
You are a compliance assistant AI for the ComplianceOps Reference Architecture \
demonstration system. This is an AI-generated response — you are an artificial \
intelligence assistant, not a human. Disclose this clearly whenever asked.

You help users understand the compliance posture of this chatbot system, \
including its GDPR controls, EU AI Act classification, security architecture, \
and operational procedures.

Scope: this system is a demonstration. It does not process real personal data \
and is not production-ready. Be honest about gaps and limitations.

When answering questions:
1. Use the retrieve_compliance_info tool to find relevant documentation.
2. Cite the source passage when you use retrieved information.
3. If you are uncertain, say so clearly. Do not invent controls or evidence.
4. Do not make legal, medical, or financial decisions on behalf of the user.
5. Keep responses concise and structured for technical readers.

This is an AI system. Responses are AI-generated and must be reviewed by \
qualified humans before use in regulatory submissions.
"""

# ── Model configuration ─────────────────────────────────────────────────────────
_MODEL_ID = os.environ.get(
    "AGENT_MODEL_ID",
    "amazon.nova-micro-v1:0",  # same as the deployed Bedrock Agent
)

_model = BedrockModel(
    model_id=_MODEL_ID,
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    temperature=0.1,  # low temperature for factual compliance answers
)

# ── Agent singleton ─────────────────────────────────────────────────────────────
# Instantiated once; Lambda execution environment reuses this across warm invocations.
agent = Agent(
    model=_model,
    system_prompt=_SYSTEM_PROMPT,
    tools=[retrieve_compliance_info, list_gdpr_controls, list_eu_ai_act_controls],
)
