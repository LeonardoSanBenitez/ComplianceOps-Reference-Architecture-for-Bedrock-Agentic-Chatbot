# Human Oversight Procedure
## compliance-ops-bedrock — AI System Oversight

**Document ID:** HOP-001
**Version:** 1.0
**Effective date:** 2026-04-25
**Owner:** Principal Engineer
**Review cadence:** Annually or before any material change to the system's intended use
**Scope:** This procedure applies to the compliance-ops-bedrock Bedrock chatbot and
covers the deployer's obligations under EU AI Act Art. 26 (obligations for deployers)
and the conditions for meaningful human oversight.

---

## 1. Purpose

This procedure defines how human oversight of the compliance-ops-bedrock AI system
is maintained. It satisfies the deployer-side obligation to put "appropriate human
oversight measures" in place under EU AI Act Art. 26(1) and documents that oversight
is genuine rather than ceremonial.

**Current system status:** The system is classified as limited-risk (not high-risk)
under the EU AI Act. This procedure is maintained as a demonstration of good practice
and to document the basis for the risk classification.

---

## 2. Scope of Oversight

Human oversight applies to:

- Outputs produced by the Strands agent (responses to compliance queries)
- System behaviour over time (response quality, hallucination incidents)
- Any incidents flagged by users or detected via monitoring

Human oversight does **not** require reviewing every individual response; it requires
monitoring at a level proportionate to the risk level (limited-risk).

---

## 3. Designated Oversight Role

| Role | Responsibility | Contact |
|------|---------------|---------|
| Principal Engineer | Monitors system behaviour, reviews flagged responses, decides on corrective action | leofloripa1020@gmail.com |

**Note for production deployment:** If this system is made available to external users,
a dedicated person must be assigned to the oversight role (separate from the developer).
For the current prototype (developer-only users), the single-person team fills all roles.

---

## 4. Monitoring Activities

### 4.1 Ongoing (automated)
- GuardDuty and CloudTrail alerts are routed to `zoo-security-alerts` SNS topic
- Lambda CloudWatch logs capture all requests, responses, and errors
- Any unhandled exceptions are visible in CloudWatch Logs Insights

### 4.2 Periodic (manual)
- **Weekly during active use:** Review CloudWatch logs for anomalous responses,
  error spikes, or unexpected content
- **Before any public deployment:** Full review of a sample of 20–50 responses
  across different query categories

### 4.3 Incident-triggered
- Any user report of a problematic response triggers immediate review
- GuardDuty HIGH/CRITICAL findings trigger the IRP-001 incident response procedure

---

## 5. User Feedback Mechanism

### For the current prototype (developer access only)
- Feedback is provided directly by the engineering team during development
- No separate feedback channel is required at this phase

### For a future user-facing deployment
- A `feedback` endpoint or email address must be provided before launch
- Users must be able to flag responses they consider inaccurate, inappropriate,
  or potentially harmful
- Flagged responses must be reviewed within 2 business days
- A record of flagged responses and resolutions must be maintained

---

## 6. Scope of Human Override Authority

The oversight role has authority to:

1. **Halt the service:** Take the Lambda function offline by removing the Function URL
   resource policy or updating the function concurrency to 0
2. **Update the system prompt:** Modify `app/agent.py` to change the agent's instructions
   and redeploy via `cob-app-deploy` CodeBuild
3. **Update the knowledge base:** Add, remove, or update documents in `cob-kb-source-dev`
   and trigger re-ingestion
4. **Escalate:** Contact AWS Support or legal/DPO if an incident has regulatory implications

---

## 7. Known Limitations Requiring Human Judgment

The following system characteristics require humans to exercise judgment that the
AI system cannot provide for itself:

| Characteristic | Why human judgment is needed |
|---------------|------------------------------|
| Hallucination | The model may state GDPR or EU AI Act provisions incorrectly. Responses must not be used for regulatory submissions without human review. |
| Knowledge cutoff | The model's training data has a cutoff; recent regulatory changes (e.g. delegated acts under the EU AI Act) may not be reflected. |
| Scope limitations | The system covers only this chatbot's compliance; users may ask about broader regulatory questions outside its scope. |
| Jurisdictional variation | GDPR and EU AI Act implementation varies by member state; the system does not reflect DPA-specific guidance. |

These limitations are disclosed in the system prompt and the API response's `ai_disclosure` field.

---

## 8. AI Literacy Record

The following record documents that the individuals operating this system understand
its nature, capabilities, and limitations.

| Name / Role | Date | Acknowledged |
|-------------|------|--------------|
| Principal Engineer (Leonardo Benitez) | 2026-04-25 | I have read this procedure, the system prompt in app/agent.py, the risk classification in attestations/initial-attestations.yaml, and the EU AI Act Art. 50 disclosure section of the README. I understand that this system can hallucinate, has a knowledge cutoff, and must not be used as a substitute for qualified legal advice. |

**Update this table** whenever a new person is granted access to operate the system.

---

## 9. Relationship to EU AI Act Controls

| Control | Requirement | How this procedure satisfies it |
|---------|-------------|--------------------------------|
| euaia-deployer-1 | "put in place appropriate human oversight measures" | Sections 3–7 of this document |
| euaia-4 | AI literacy for persons operating AI systems | Section 8 (literacy record) |
| euaia-50-1 | AI system transparency disclosure to users | See app/handler.py and README |

---

## 10. Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | 2026-04-25 | Priya | Initial version — closes gaps in euaia-deployer-1 and euaia-4 attestations |
