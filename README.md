# ComplianceOps Reference Architecture — Bedrock Chatbot

A reference architecture for building a compliance-aware agentic chatbot on AWS Bedrock.
Demonstrates RegOps, Compliance-as-Code, and Shift-Left Compliance practices in a single deployable repository.

**This is a blueprint, not a production system.** It demonstrates by example how to structure compliance controls, evidence, and tooling for an AI application governed by GDPR and the EU AI Act. You are responsible for adapting, hardening, and extending it for your own environment.

**Manual attestations are self-assessed and have not been independently audited. They are starting points, not conclusions.** See [Compliance scope](#compliance-scope) for a precise statement of what this repository does and does not cover.

---

> **Disclaimer:** This project was developed with AI assistance and is not hardened for enterprise production use. Use at your own discretion.

---

## What this repository includes

- Infrastructure-as-code (Terraform) for all deployed AWS resources
- A working agentic chat endpoint on Amazon Bedrock AgentCore Runtime (Strands SDK + Nova Micro)
- Compliance report Lambda endpoint (POST /report) — deterministic static HTML generation
- RAG over compliance documentation via Bedrock Knowledge Base (S3 Vectors backend)
- OSCAL-based control catalogs for GDPR (12 controls) and EU AI Act (8 controls)
- Prose attestations with gap assessments for all 20 defined controls
- Automated evidence collection (CloudTrail, IAM, S3 configuration)
- Static compliance report generation (Jinja2, deterministic, no LLM-written content)
- CI pipeline (GitHub Actions): mypy, YAML validation, OSCAL schema validation
- Incident response procedure (IRP-001) and human oversight procedure (HOP-001)
- GDPR Art. 30 Record of Processing Activities entry (ROPA-001)
- GDPR Art. 33 DPA breach notification template
- Cost estimate at demo and moderate scale

## What this repository does not include (by design)

- Adversarial attack evaluation or red-teaming
- Dynamic application security testing or penetration testing
- Organization-wide compliance posture assessment (scope is this chatbot only)
- AI-based inference about infrastructure compliance
- AI-written compliance narrative
- Landing zone or enterprise centralized cloud controls

Gaps that require manual confirmation are flagged explicitly in the generated compliance report.

---

## What is RegOps

Software development is accelerating, and AI is being integrated into every part of the stack. If compliance is to keep up, it must become code-based, testable, and highly automated.

RegOps applies DevOps principles to regulatory compliance: controls are defined in version-controlled files, evidence is collected automatically from running systems, and reports are generated deterministically from structured artifacts. The goal is to reduce the manual burden on compliance teams while producing audit-ready artifacts continuously.

## Who this is for

- A **DevOps engineer** who wants a concrete example of how OSCAL control catalogs map to Terraform resources and CI checks
- A **compliance engineer** who needs to explain to leadership what Compliance-as-Code looks like in practice, with a working repo to point at
- A **software architect** evaluating whether AWS Bedrock is a viable foundation for a GDPR- or EU-AI-Act-governed application
- A **security engineer** who wants to see how automated evidence collection (CloudTrail, IAM, S3 config) integrates with structured attestations

This repository is not useful for reading — it is useful for forking, adapting, and deploying.

---

## Architecture

### Application layer

The application has two runtime components that share the same container image:

**Chat endpoint — Amazon Bedrock AgentCore Runtime:**

```
Caller (SigV4) → AgentCore Runtime → Strands Agent (Nova Micro) → Bedrock Knowledge Base
                                                  ↓
                                        GDPR / EU AI Act tools
```

**Report endpoint — AWS Lambda Function URL:**

```
Caller (public) → Lambda Function URL (POST /report) → generate HTML → S3 report bucket
```

Components:

| Component | Technology | Notes |
|-----------|-----------|-------|
| Model | Amazon Nova Micro (`amazon.nova-micro-v1:0`) | Lowest-cost on-demand text model; swap to Nova Lite or Pro for more complex tasks |
| Orchestration | [Strands SDK](https://github.com/strands-ai/strands) | Lightweight Python agent framework, AWS-originated but not an AWS managed service; evaluate maturity before production adoption |
| AgentCore Runtime | `app/agentcore_app.py` | Wraps the Strands agent with `BedrockAgentCoreApp`; SigV4 auth, not public |
| RAG | Bedrock Knowledge Base (S3 Vectors) | Documents chunked and indexed for semantic retrieval |
| Agent tools | `app/tools.py` | `retrieve_compliance_info`, `list_gdpr_controls`, `list_eu_ai_act_controls` |
| Lambda handler | `app/handler.py` | POST /report only; generates and uploads the static HTML compliance report |

The same container image is used by both the Lambda function and the AgentCore Runtime. The `CMD` in the Dockerfile points to the Lambda handler; AgentCore overrides the entry point to `python -m app.agentcore_app` at runtime. This dual-runtime pattern avoids maintaining two images for what is logically one application.

### Compliance layer

Controls are defined in OSCAL YAML. Two catalogs are included:

| Catalog | File | Controls |
|---------|------|----------|
| GDPR | `compliance/catalogs/gdpr-minimal.yaml` | 12 controls — Arts. 5, 13, 17, 25, 32, 33 |
| EU AI Act | `compliance/catalogs/eu-ai-act-minimal.yaml` | 8 controls — limited-risk chatbot (Arts. 4, 50, and deployer obligations) |

**Note on catalog provenance:** No official OSCAL catalogs for GDPR or the EU AI Act have been published by a standards body. Both catalogs were authored for this project based on a direct reading of the regulations. The control coverage and mapping choices are editorial judgments, not authoritative interpretations. One of the contributions of this project is to provide a structured starting point for community-developed OSCAL catalogs for these regulations.

The compliance posture as of the last attested state:

| Status | Count | Controls |
|--------|-------|---------|
| satisfied | 13 | Core security, logging, transparency, human oversight controls |
| partial | 3 | gdpr-5-1-a, gdpr-5-1-b, gdpr-25 — require a full LIA/DPIA for production |
| not-satisfied | 2 | gdpr-13 (privacy notice), gdpr-17 (erasure) — require a real user-facing UI |
| not-applicable | 2 | gdpr-35 (DPIA not required at demo scale), euaia-deployer-3 |

Attestations (`attestations/`) provide prose justification for each control, including an honest assessment of gaps. Evidence artifacts (`evidence/automated/`) are collected by `scripts/collect_evidence.py` using boto3.

The compliance report is a static HTML file generated by `scripts/generate_report.py` from Jinja2 templates. It is deterministic, contains no LLM-written content, and is published to a public S3 static website.

### Infrastructure

All infrastructure is managed by Terraform (`infra/terraform/`), with the exception of the Lambda function (see note below).

| Resource | Purpose |
|----------|---------|
| ECR repository | Container images for both Lambda and AgentCore Runtime |
| Lambda function | Report endpoint — POST /report (created by `cob-app-deploy` CodeBuild, not Terraform) |
| AgentCore Runtime | Chat endpoint — managed container runtime (`agentcore.tf`) |
| AgentCore Runtime Endpoint | Default SigV4 invocation endpoint |
| Bedrock Knowledge Base | RAG index (S3 Vectors backend) |
| S3 — KB source | Compliance documents for KB ingestion |
| S3 — Conversation logs | Conversation log storage (30-day retention) |
| S3 — Report | Public static website hosting for the generated compliance report |
| DynamoDB | Session metadata (30-day TTL) |
| KMS | Encryption at rest for all persistent data |
| CodeBuild — `cob-tf-plan` | Terraform plan, triggered on PR open/update via GitHub webhook |
| CodeBuild — `cob-tf-apply` | Terraform apply, manually triggered |
| CodeBuild — `cob-app-deploy` | Docker build + Lambda deploy + AgentCore Runtime update |

**Why is Lambda not in Terraform?** Terraform cannot provision a Lambda container function without an existing ECR image. The function is created on first run of `cob-app-deploy` and updated on subsequent runs. This is a bootstrap constraint inherent to container-based Lambda; it is not a design preference.

### CI/CD

```
GitHub PR open/update  →  cob-tf-plan (CodeBuild)   →  terraform plan (review before merge)
After merge to main    →  manual: cob-tf-apply       →  terraform apply
                       →  manual: cob-app-deploy      →  docker build + lambda + agentcore update
```

GitHub Actions (`.github/workflows/ci.yml`) runs on every push:
- `mypy` type checking on the application layer
- YAML schema validation on OSCAL catalogs and attestations
- `compliance-trestle validate` on OSCAL catalogs

Terraform plan and apply run in AWS CodeBuild, not in GitHub Actions. This keeps AWS credentials out of GitHub and ensures CodeBuild runs inside the account's IAM boundary.

---

## Key design decisions

These decisions represent explicit trade-offs made for this reference architecture. Understand them before adopting or adapting.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Compliance format | OSCAL YAML | Machine-readable, compliance-trestle toolchain, FedRAMP alignment |
| Agent framework | Strands SDK | Open source, Python-native, avoids Bedrock Managed Agent overhead for a simple RAG+tool setup |
| Chatbot runtime | AgentCore Runtime | Managed container infrastructure with SigV4 auth and AWS-enforced execution isolation |
| Report generation | Jinja2, no LLM | Deterministic output is essential for audit artifacts; LLM generation cannot be reproduced |
| IaC tool | Terraform | Ecosystem maturity; CodeBuild-hosted to keep AWS creds out of GitHub |
| Model | Nova Micro | Cost optimization for demo; easily swapped via Terraform variable |
| Report visibility | Public S3 website | Demo context; production deployments must restrict access |
| SBOM | Deferred | No training loop; not required for this deployment model at demo scale |
| Attestation format | Prose justification required | Boolean status alone provides no audit value; prose documents the reasoning |

---

## EU AI Act Art. 50 Transparency Disclosure

**Risk classification:** This system does not fall under any of the high-risk categories listed in Annex III of the EU AI Act and is not covered by Art. 6(2).

**Transparency obligation:** Independently of risk class, this system is an AI system intended to interact directly with natural persons. It is therefore subject to Art. 50(1) transparency obligations, requiring that users be informed they are interacting with an AI system.

Every response from this chatbot:
- Carries an `X-AI-Generated: true` HTTP response header (machine-readable disclosure)
- Includes an `ai_disclosure` field in the JSON response body identifying the system as AI-generated
- Is generated by a system prompt that instructs the model to identify itself as an AI when asked

These disclosures are implemented in `app/agentcore_app.py` (chat responses) and `app/handler.py` (report endpoint headers). Any deployment of this reference architecture must preserve or strengthen them.

---

## Getting started

### Prerequisites

- AWS account with Bedrock model access enabled for `amazon.nova-micro-v1:0` and `amazon.titan-embed-text-v2:0`
- Terraform >= 1.7
- Docker (for local testing only; production deploys run in CodeBuild)
- Python >= 3.12

### 1. Deploy infrastructure

```bash
cd infra/terraform
terraform init
terraform plan -var="aws_account_id=<your-account-id>"
terraform apply -var="aws_account_id=<your-account-id>"
```

### 2. Populate the Knowledge Base

```bash
# Get bucket and data source IDs from Terraform outputs
KB_SOURCE=$(cd infra/terraform && terraform output -raw kb_source_bucket_name)
KB_ID=$(cd infra/terraform && terraform output -raw bedrock_kb_id)
DS_ID=$(cd infra/terraform && terraform output -raw bedrock_kb_data_source_id)

aws s3 cp README.md s3://${KB_SOURCE}/README.md
aws s3 cp compliance/catalogs/gdpr-minimal.yaml s3://${KB_SOURCE}/catalogs/gdpr-minimal.yaml
aws s3 cp compliance/catalogs/eu-ai-act-minimal.yaml s3://${KB_SOURCE}/catalogs/eu-ai-act-minimal.yaml
aws s3 cp attestations/ s3://${KB_SOURCE}/attestations/ --recursive
aws s3 cp compliance/procedures/ s3://${KB_SOURCE}/procedures/ --recursive

aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID
```

### 3. Deploy the application

Trigger the `cob-app-deploy` CodeBuild project. On first run it creates the Lambda function and Function URL; on subsequent runs it updates the image and AgentCore Runtime.

```bash
aws codebuild start-build --project-name cob-app-deploy
```

### 4. Invoke the chatbot

The chatbot is served by the AgentCore Runtime. Authentication is SigV4.

```bash
RUNTIME_ID=$(cd infra/terraform && terraform output -raw agentcore_runtime_id)
REGION=us-east-1

aws bedrock-agentcore invoke-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --region "$REGION" \
  --body '{"prompt": "What GDPR controls are implemented for this system?"}' \
  --cli-binary-format raw-in-base64-out \
  output.json
cat output.json
```

The response contains `{"response": "...", "session_id": "...", "ai_disclosure": "..."}`.

The Lambda Function URL (public) accepts POST /report but does not handle chat.

### 5. Publish the compliance report

```bash
# Generate and upload to the public S3 report bucket
./scripts/publish_report.sh

# Or specify the bucket name explicitly
./scripts/publish_report.sh cob-report-dev
```

The script generates `report/index.html` and uploads it. The published URL follows the pattern:
`http://<bucket-name>.s3-website-<region>.amazonaws.com`

To generate the report locally only:

```bash
python scripts/generate_report.py --output report/index.html
```

---

## Adapting this architecture

The reference architecture is designed to be forked and extended. Key extension points:

**Extend the control catalog.** The OSCAL catalogs cover a minimal set of GDPR and EU AI Act controls. For a production system, you will need to extend them to cover your actual risk profile. Add controls to `compliance/catalogs/` following the existing OSCAL structure, add corresponding attestation entries, and update the evidence collection script to gather relevant artifacts.

**Add regulations.** The architecture supports multiple catalogs. To add a new regulation (e.g., ISO 27001, NIS2), create a new OSCAL catalog file in `compliance/catalogs/`, add a profile that references it, and update `scripts/generate_report.py` to include it in the report.

**Harden attestations.** The current attestations are self-assessed. For production use, replace self-assessed entries with evidence-backed ones, and consider integrating a third-party audit workflow. The `built-by` field in the attestation schema supports distinguishing self-attested from externally verified entries.

**Replace the model.** Swap `amazon.nova-micro-v1:0` for a higher-capability model by changing the Terraform variable `bedrock_model_id`. The Strands agent and tools are model-agnostic.

**Restrict the report endpoint.** The report bucket is configured as a public S3 static website for demo purposes. For production, replace the S3 website endpoint with CloudFront + a signed URL or IAM-gated access, and update the S3 bucket policy in `infra/terraform/s3.tf`.

**Implement erasure (GDPR Art. 17).** The gdpr-17 control is currently not-satisfied because there is no real user data. In a production deployment, implement a deletion endpoint and update the attestation with a reference to the implementation.

---

## Compliance scope

This reference architecture demonstrates compliance for a **single chatbot application** in a **demonstration environment**. It does not cover:

- The AWS account or landing zone
- Any other application or service
- Production personal data (the demo does not process real personal data)

Regulated entities deploying a real system must:
1. Extend the control catalog to cover their actual risk profile
2. Complete a full DPIA for any processing of personal data
3. Engage a qualified DPO and legal counsel for GDPR Art. 37 assessment
4. Re-classify AI risk under EU AI Act Art. 6 based on their specific use case

---

## Cost

At demonstration scale (100 requests/month): under $0.10/month.
At moderate scale (10,000 requests/month): under $2/month.

Full breakdown: [COST.md](COST.md).

---

## Repository structure

```
compliance-ops-bedrock/
├── app/
│   ├── agent.py                   # Strands agent singleton (model + tools)
│   ├── agentcore_app.py           # AgentCore Runtime entry point (BedrockAgentCoreApp)
│   ├── handler.py                 # Lambda handler (POST /report only)
│   ├── tools.py                   # Strands tools (KB retrieve, catalog list)
│   ├── Dockerfile                 # Container image for both Lambda and AgentCore Runtime
│   └── requirements-lambda.txt
├── attestations/
│   ├── initial-attestations.yaml  # Prose attestations for all 20 controls
│   └── schema.yaml                # Attestation schema definition
├── blog/
│   └── policy-as-code-part4.md   # External analysis: limitations and contributions of this architecture
├── compliance/
│   ├── catalogs/                  # OSCAL YAML control catalogs (GDPR, EU AI Act)
│   └── procedures/                # IRP-001, HOP-001, ROPA-001, DPA notification template
├── evidence/
│   └── automated/                 # Evidence artifacts from collect_evidence.py
├── infra/
│   └── terraform/                 # All infrastructure definitions
│       ├── agentcore.tf           # AgentCore Runtime + Endpoint
│       ├── codebuild.tf           # CI/CD pipelines (inline buildspecs)
│       └── ...
├── report/                        # Output directory (index.html generated at runtime, served from S3)
├── scripts/
│   ├── collect_evidence.py        # Automated evidence collection (CloudTrail, IAM, S3)
│   ├── generate_report.py         # Compliance report generator (Jinja2)
│   └── publish_report.sh          # Generate + upload report to S3
├── tests/
│   └── test_report_generator.py   # Unit tests for report generation
├── COST.md                        # Cost estimate at demo and moderate scale
└── pyproject.toml                 # Python project metadata and tool config (mypy, pytest)
```

---

## Further reading

- [Policy-as-Code Is Real Progress, Just Not the Progress You Think](https://medium.com/@lsbenitezpereira/policy-as-code-is-real-progress-just-not-the-progress-you-think-38345bd8b780) — Honest analysis of this architecture: its limitations, its contribution to the OSCAL ecosystem gap for GDPR and EU AI Act, and how it compares to other compliance tooling approaches.
- [COST.md](COST.md) — Detailed per-service cost breakdown.
- [compliance/procedures/incident-response.md](compliance/procedures/incident-response.md) — IRP-001: incident response procedure.
- [compliance/procedures/human-oversight-procedure.md](compliance/procedures/human-oversight-procedure.md) — HOP-001: human oversight procedure (EU AI Act Art. 14).
- [compliance/procedures/ropa-entry.yaml](compliance/procedures/ropa-entry.yaml) — ROPA-001: Art. 30 record of processing activities.

---

## Contributing

Pull requests, questions, and critiques are welcome.
