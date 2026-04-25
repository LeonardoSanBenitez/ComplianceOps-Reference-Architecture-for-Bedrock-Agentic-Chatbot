# Incident Response Procedure
## compliance-ops-bedrock — Personal Data Breach Response

**Document ID:** IRP-001  
**Version:** 1.0  
**Effective date:** 2026-04-23  
**Owner:** Principal Engineer (Priya)  
**Review cadence:** Before production launch; then annually or after any incident  
**Scope:** This procedure covers the compliance-ops-bedrock Bedrock chatbot application and its supporting AWS infrastructure. It does NOT cover the broader organisational landing zone or other projects.

---

## 1. Purpose and Legal Basis

This procedure defines how the team responds to a personal data breach affecting the compliance-ops-bedrock system, in accordance with GDPR Art. 33 (notification to supervisory authority within 72 hours) and Art. 34 (communication to data subjects where required).

**Current status note:** The system currently processes no real personal data (prototype phase, synthetic data only). This procedure must be in place and reviewed before any production deployment that handles real user conversation data.

---

## 2. Definitions

| Term | Definition |
|------|-----------|
| Personal data breach | A security incident leading to accidental or unlawful destruction, loss, alteration, unauthorised disclosure of, or access to, personal data (GDPR Art. 4(12)) |
| DPA | Data Protection Authority — supervisory authority in the relevant EU member state |
| Controller | The legal entity operating the compliance-ops-bedrock system |
| Processor | AWS (data processing agreement in place as part of AWS account terms) |
| Incident register | `compliance/evidence/incident-register.yaml` (created at first incident) |

---

## 3. Detection and Initial Triage

### 3.1 Automated detection channels

The following automated signals may indicate a breach:

| Source | Signal type | Alert channel |
|--------|-------------|---------------|
| AWS GuardDuty | Unauthorized API calls, credential compromise, unusual access patterns | SNS: `zoo-security-alerts` (email + future integrations) |
| AWS CloudTrail | Anomalous data access, privilege escalation, region-unusual activity | CloudWatch alarms → SNS |
| S3 access logs | Unexpected read on `cob-kb-source-*` or `cob-conv-logs-*` buckets | Manual review or CloudWatch Logs Insights query |
| DynamoDB | Unusual volume of `GetItem`/`Scan` on `cob-sessions-*` | CloudWatch metrics |

**GuardDuty severity threshold for immediate response:** MEDIUM and above triggers an automated SNS notification. LOW findings are reviewed during the next business day.

### 3.2 Manual detection channels

- Customer reports of unexpected data disclosure
- Internal team member discovers misconfigurations (e.g., accidental public S3 bucket policy)
- Third-party security researcher disclosure
- AWS abuse notification

### 3.3 Triage — within 1 hour of detection

Upon receiving an alert:

1. Acknowledge receipt in the SNS topic (respond to notification email or ticket system if integrated).
2. Log the raw alert in `compliance/evidence/incident-register.yaml` with fields: `detected-at`, `source`, `raw-signal`.
3. Determine whether the event involves personal data (see Section 4).
4. Assign a severity level (Section 5).
5. Page the incident lead if severity is HIGH or CRITICAL.

---

## 4. Personal Data Scope Assessment

Not every security event constitutes a personal data breach. The following questions guide the assessment:

**Q1: Does the affected resource contain or process personal data?**

| Resource | Personal data? | Notes |
|----------|---------------|-------|
| `cob-conv-logs-*` S3 bucket | YES (once production) | Conversation transcripts may contain user-provided text |
| `cob-sessions-*` DynamoDB table | YES (once production) | `user_id` field (pseudonymised) + session metadata |
| `cob-kb-source-*` S3 bucket | NO | Contains compliance documentation only (README, catalogs) |
| S3 Vectors index | NO | Contains embedding vectors only, not raw personal data |
| CloudTrail / GuardDuty logs | INDIRECT | May contain IP addresses and user ARNs |

**Q2: Was personal data accessed, copied, modified, destroyed, or disclosed to unauthorised parties?**

If YES to both Q1 and Q2: this is a **personal data breach** and GDPR Art. 33 applies.

If Q1 is YES but Q2 is NO (e.g., availability issue with no data exfiltration): record in the incident register, no DPA notification required unless circumstances change.

---

## 5. Severity Classification

| Severity | Criteria | Response time |
|----------|----------|---------------|
| CRITICAL | Confirmed exfiltration of personal data; credential compromise; ransomware | Immediate; page incident lead |
| HIGH | Suspected breach; unauthorised access confirmed but scope unclear | Within 2 hours |
| MEDIUM | GuardDuty finding with potential data access; misconfiguration discovered | Within 4 hours during business hours |
| LOW | Anomalous signal, no confirmed data access, no personal data affected | Next business day review |

---

## 6. Containment

For HIGH and CRITICAL incidents, execute the following containment steps in order:

1. **Isolate:** If credentials are suspected compromised, rotate or invalidate them immediately.
   ```bash
   # Revoke IAM session tokens (replace ROLE_NAME and ACCOUNT_ID)
   aws iam delete-role-policy --role-name ROLE_NAME --policy-name POLICY_NAME
   # Or attach an explicit Deny all policy as an emergency brake:
   aws iam put-role-policy --role-name ROLE_NAME \
     --policy-name EMERGENCY_DENY_ALL \
     --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'
   ```

2. **Preserve evidence:** Before any remediation, take a CloudTrail query snapshot for the affected time window.
   ```bash
   # Query CloudTrail for the past 24 hours around the incident
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=GetObject \
     --start-time <ISO8601> --end-time <ISO8601> \
     --region us-east-1 > incident-evidence-$(date +%Y%m%d%H%M%S).json
   ```

3. **Restrict:** Apply a bucket policy or S3 Block Public Access enforcement if an S3 misconfiguration is involved.

4. **Revoke sessions:** If a Bedrock agent session is implicated, the DynamoDB TTL is 30 days; force-delete the session record immediately.

---

## 7. Assessment — Determining Notification Obligations

Once contained, answer the following to determine notification obligations:

### 7.1 Is DPA notification required? (Art. 33)

Notification is required **unless** the breach is unlikely to result in a risk to the rights and freedoms of natural persons. The following factors increase risk:

- Large volume of individuals affected
- Sensitive categories of data (none currently in scope for this system)
- Data re-identification risk (pseudonymised `user_id` — low risk if hashing key is secure)
- Data sold or posted publicly

**Default position for this system:** Any confirmed unauthorised access to `cob-conv-logs-*` or `cob-sessions-*` should be treated as requiring DPA notification unless there is a clear documented reason why the risk to data subjects is negligible (e.g., the accessed data is demonstrably only test/synthetic data).

### 7.2 Is data subject notification required? (Art. 34)

Required only when the breach is likely to result in a HIGH risk to individuals. Given this system's limited data scope (no special category data, no financial data), Art. 34 notification is an unlikely outcome for most plausible incident scenarios, but must be assessed case-by-case.

---

## 8. Notification — 72-Hour Clock

The 72-hour clock starts from the moment the controller becomes **aware** of the breach (not from detection by a monitoring tool, but from human awareness and initial confirmation).

### 8.1 Notification timeline

| Hours from awareness | Action |
|---------------------|--------|
| 0 | Log in incident register; assign incident lead |
| 0–4 | Containment (Section 6) |
| 4–24 | Scope assessment; determine notification obligation |
| 24–48 | Draft DPA notification (if required) |
| 48–72 | Submit DPA notification; if not submitted, document why and expected date |
| >72 (if late) | Submit with documented reasons for delay; Art. 33(1) allows late notification with reasons |

### 8.2 DPA notification content (Art. 33(3))

The notification must include:

1. Nature of the breach (categories and approximate number of data subjects; categories and approximate number of records)
2. Contact details of the DPO or other contact point
3. Likely consequences of the breach
4. Measures taken or proposed to address the breach and mitigate its possible adverse effects

**Template:** `compliance/procedures/dpa-notification-template.yaml` (available — complete the FILL/ASSESS fields at incident time)

---

## 9. Recovery and Post-Incident

1. **Remediate root cause:** Document the fix applied.
2. **Restore service:** Re-deploy from clean Terraform state if infrastructure is compromised.
3. **Update attestations:** Revise the relevant `attestations/*.yaml` entries to reflect the incident and remediation.
4. **Post-incident review:** Conduct within 5 business days. Outcome: updated threat model, control improvements, or procedure revisions.
5. **Close incident register entry:** Mark as closed with `closed-at` timestamp and resolution summary.

---

## 10. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| Incident lead (Principal Engineer) | Overall incident coordination; final decision on DPA notification |
| AWS account owner | IAM/credential rotation; infrastructure isolation |
| Legal/DPO (future role) | DPA notification drafting and submission; Art. 34 determination |

**Note:** For the current demo/prototype phase with a single engineer, all roles are filled by the same person. A production deployment requires separation of these responsibilities.

---

## 11. Contact Information

| Contact | Details |
|---------|---------|
| AWS account email | leofloripa1020@gmail.com |
| AWS Support | Via AWS Console → Support Center (current plan: Basic) |
| SNS alert topic | zoo-security-alerts (configured in landing zone) |
| EU DPA (if needed) | Depends on controller's establishment; identify before production |

---

## 12. Evidence References

This procedure satisfies the following control requirements:

| Control ID | Requirement | Status |
|-----------|-------------|--------|
| gdpr-33 | Written incident response procedure covering detection, 72-hour notification | SATISFIED by this document |
| gdpr-32 | Technical and organisational measures for breach detection | PARTIAL — automated detection in place; this document provides the organisational layer |

**Evidence artifact:** This file (`compliance/procedures/incident-response.md`) is committed to the repository and referenced in the attestation for `gdpr-33-incident-response-001`.

---

## 13. Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | 2026-04-23 | Priya | Initial version — closes gap identified in gdpr-33-incident-response-001 attestation |
