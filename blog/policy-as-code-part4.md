# Policy-as-Code, Part Four: A Working Example That Takes Its Own Limitations Seriously

## compliance-ops-bedrock is not a silver bullet — and it says so

*By Mark | April 2026*

---

Over the past three months I have argued, in three separate pieces, that policy-as-code solves a real but narrowly bounded problem; that auditors care far more about operational process evidence than about CI pipelines; and that a large class of compliance requirements is not just difficult to automate but is, in principle, uncodifiable. I want to be direct about why I wrote all of that before writing this piece: the architecture I am going to describe now is one I find genuinely useful, and I did not want to introduce it in a promotional register. The criticisms came first because they are the lens through which any honest assessment of a compliance tooling project has to be made.

compliance-ops-bedrock is a reference architecture for a compliance-aware agentic chatbot built on AWS Bedrock. It covers GDPR and EU AI Act obligations with a full layer of OSCAL-based controls, automated evidence collection, and structured human process artifacts. It is available as a public repository. It is also, to my knowledge, the most honest piece of compliance tooling I have encountered in the past year — honest in a specific sense: it documents its own gaps, it builds audit-ready human process artifacts alongside automated ones, and its README explicitly enumerates what it does not cover. That kind of structural honesty is rare enough to be worth discussing.

A note on current state before going further. The chatbot currently runs as a Docker container deployed as an AWS Lambda function, using the Strands SDK with Bedrock Nova Micro as the inference model. A migration to AWS AgentCore Runtime — announced at re:Invent 2025 — is planned. AgentCore provides deterministic guardrail enforcement outside the LLM reasoning loop, which would strengthen the architecture's human oversight story. That migration is not complete at the time of writing; I will note where it is relevant. The CI pipeline runs on AWS CodeBuild, with a webhook-triggered plan on pull requests and a manual-only apply gate for infrastructure changes. Evidence collection and report generation are Python scripts that produce structured artifacts regardless of the runtime environment.

---

### The OSCAL Gap That Nobody Has Filled

In part one of this series I noted that OSCAL is gaining serious traction. FedRAMP mandates machine-readable authorization packages by September 2026. The OSCAL Foundation — with AWS, Cisco, Google, and RedHat on its advisory board — launched in late 2025. Singapore's GovTech is adopting it for cross-agency standardization. The format is becoming infrastructure.

There is, however, a gap that the tooling ecosystem has not addressed: there are no official OSCAL catalogs for GDPR or the EU AI Act. NIST has published OSCAL catalogs for NIST SP 800-53 and SP 800-171. FedRAMP's control baselines are available in OSCAL. But for the two regulatory frameworks most relevant to European organizations and to anyone building AI applications that will be used in Europe, the OSCAL ecosystem is empty. If you want to represent GDPR controls in OSCAL today, you have to write the catalog yourself.

compliance-ops-bedrock does exactly this. The repository includes two hand-authored OSCAL catalogs: `gdpr-minimal.yaml`, covering 12 controls across Articles 5, 13, 17, 25, 28, 30, 32, 33, and 35; and `eu-ai-act-minimal.yaml`, covering 8 controls for a limited-risk GPAI chatbot (Articles 4, 50, 52, and Annex XI, adapted). Both catalogs are in OSCAL 1.1.2 format and pass trestle validation. The CI pipeline validates them on every push.

The README is honest about the status of these catalogs in a way that deserves quoting directly: "No official OSCAL catalogs for GDPR or the EU AI Act have been published by a standards body. Both catalogs in this repository were created for this project, based on the authors' own reading and mapping of the regulations. The control coverage and mapping choices reflect editorial judgments, not a standardised or authoritative interpretation."

This is a significant contribution and it is framed appropriately. The catalogs are a starting point, not an authoritative mapping. But they are a well-structured starting point, and at the moment they are the only publicly available starting point in OSCAL format for these regulations. Teams forking this repository will still need a privacy lawyer to review the control definitions before using them in a production compliance program — the mapping from regulatory text to control IDs requires legal judgment, not just technical work. What the catalogs provide is a structured skeleton and a format that integrates with the rest of the OSCAL toolchain.

---

### Where the Architecture Sits on the Codifiability Spectrum

In part three I proposed a spectrum from fully codifiable compliance requirements (S3 encryption enabled) to fundamentally uncodifiable ones (culture of data protection by design). compliance-ops-bedrock's architecture maps onto this spectrum explicitly, and understanding where it sits is more useful than any high-level feature list.

**Fully automated, machine-verifiable evidence.** The repository includes a boto3-based evidence collection script that queries CloudTrail status, IAM password policy settings, S3 bucket configurations, GuardDuty detector status, and the list of available Bedrock models. These artifacts land in `evidence/automated/` as JSON files. They are deterministic snapshots of actual infrastructure state. When the compliance report is generated, these files are read directly — no manual curation, no LLM inference about what they mean. This is exactly the layer where automation is appropriate.

The CI pipeline sits here too: mypy type checking, YAML schema validation, OSCAL trestle validation, and a report dry-run, all running on AWS CodeBuild. The CodeBuild configuration defines two terraform projects (plan on PR, apply manually) and a separate CI project that runs the full validation suite on every push. These are straightforward quality gates that catch structural problems before they reach a reviewer.

**Structured-but-human.** This is the more interesting part, and it is where the architecture makes its most distinctive contribution.

Consider how the attestation system works. Each of the 20 controls in the two catalogs has a corresponding attestation in `attestations/initial-attestations.yaml`. Each attestation has a status field (satisfied, partial, not-satisfied, or not-applicable), a decision field (a one-sentence conclusion), a justification field (a multi-paragraph prose explanation), a reviewed-by field, and optional evidence-refs that link the attestation to specific files or URLs. The schema is enforced.

What this produces is not a pass/fail compliance dashboard. It is a structured record of human judgment. When I look at the attestation for `gdpr-5-1-a` (lawfulness, fairness, and transparency), I see: status partial, because the system currently processes only synthetic data, a full Legitimate Interest Assessment has not been completed, and a privacy notice does not yet exist. That is an honest statement of where things stand. When I look at `gdpr-30` (ROPA), I see: status satisfied, with references to the `ropa-entry.yaml` file and an explicit note that legal entity fields must be completed before production. These are the kinds of nuanced assessments that produce useful compliance documentation — not the kind of green-dashboard theater that produces audit failures.

The human procedure documents follow the same logic. IRP-001 is a full incident response procedure covering the 72-hour GDPR Art. 33 notification clock, with detection channels (GuardDuty, CloudTrail, S3 access logs), severity classification, containment steps with actual AWS CLI commands, and a notification timeline table broken into six phases from detection to post-72-hour reporting. ROPA-001 is a complete Art. 30 record with all mandatory fields populated, the ones requiring a legal entity identity clearly marked [TBD], and a DPIA assessment that honestly defers to pre-production review. HOP-001, the human oversight procedure, specifies who monitors the system, how often, what they are looking for, what their override authority is, and includes an AI literacy record signed by the operating engineer.

These are not boilerplate templates. They are documents that could be handed to a GDPR auditor with the expectation that the auditor would find them useful rather than embarrassing.

**Explicitly out of scope.** The README's "What this repository does not include" section lists: adversarial attack evaluation or red-teaming, dynamic application security testing, organization-wide compliance posture assessment, AI-based inference about infrastructure compliance, AI-written compliance narrative, and landing zone or enterprise centralized cloud controls. These exclusions are not failures of ambition. They are accurate scope boundaries. A reference architecture that tried to cover all of these would be either dishonest or unusable. The explicit enumeration of what is out of scope is one of the most useful things in the repository.

---

### What This Means for the Three-Layer Model

In parts two and three I argued that a mature compliance program needs three layers: technical controls with automated verification, operational process controls with structured manual evidence, and cultural and governance controls. I said then that most compliance tooling addresses layer one. Here is how compliance-ops-bedrock maps onto that framework.

**Layer one (technical controls, automated).** Well covered. Encryption at rest using a customer-managed KMS key. TLS enforcement via Lambda Function URL settings. IAM least-privilege roles, verifiable through the Terraform files and the automated IAM evidence collection. GuardDuty active with EventBridge-to-SNS alerting for MEDIUM and above findings. CloudTrail with 90-day retention. S3 public access block on all application buckets. A dedicated report bucket — publicly readable by design, using default SSE-S3, hosting the static HTML compliance report as a website — with no personal data or secrets. These controls are deployed, the evidence is collected automatically, and the attestations reference specific evidence files. A reviewer can trace from control to attestation to evidence in a few minutes.

The EU AI Act Art. 50 transparency implementation deserves particular mention because it is one of the few places I have seen this obligation implemented at the API layer rather than described in documentation. Every response from the Lambda function includes an `X-AI-Generated: true` HTTP header, an `X-AI-System: compliance-ops-bedrock-demo` header, and an `ai_disclosure` field in the JSON body that explicitly states the response is AI-generated and not legal advice. The system prompt instructs the model to identify itself as an AI system if asked. This is not a documentation commitment about future behavior. It is the actual behavior, verifiable from the code.

The Art. 50 obligations become fully enforceable in August 2026. I will note, because it is relevant to teams implementing similar systems right now, that neither the Commission nor any national supervisory authority has published guidance on what "prominent notice" means for an API-only system that has no consumer UI. The second draft Code of Practice on AI-generated content, published March 2026, is oriented toward media and consumer-facing products. The compliance-ops-bedrock approach — HTTP headers plus a JSON disclosure field — is a reasonable interpretation of what technical disclosure looks like for a B2B API chatbot, but it has not been validated against any supervisory authority's stated standard, because no such standard yet exists.

**Layer two (operational process controls, structured manual evidence).** This is where the architecture is genuinely unusual among open-source compliance tooling. The four human procedure documents — IRP-001, ROPA-001, the DPA breach notification template, and HOP-001 — are first-class structured artifacts in the repository, version-controlled alongside the code and infrastructure. They are cross-referenced in attestations. They are loaded into the Bedrock Knowledge Base alongside the OSCAL catalogs, making them queryable by the chatbot itself.

The DPA notification template covers all Art. 33(3) mandatory fields with FILL/ASSESS annotations for completion at incident time. This is practical audit readiness. When an auditor asks "show me your Art. 33 notification process," the answer is not a description of a process that exists somewhere — it is a structured template with every required field pre-mapped and evidence references pointing to IRP-001.

The attestation review mechanism is an honest attempt at layer two process. Each attestation carries reviewed-by and reviewed-at fields. Whether that review cadence is actually maintained over time depends entirely on the team operating the system — the repository provides the structure, not the organizational will to use it. This is an important limitation to name: a compliance program that uses this repository but treats the attestations as a one-time setup exercise will gradually drift out of compliance without the repository noticing.

**Layer three (cultural and governance controls).** Not here, and the architecture does not pretend otherwise. The HOP-001 document includes a table of system limitations requiring human judgment — hallucination risk, knowledge cutoff, scope boundaries, jurisdictional variation. That table is accurate and useful. But a table in a markdown file does not create a culture of data protection by design. It does not make managers take privacy seriously in product decisions. It does not ensure that the compliance review process is maintained when the team is under delivery pressure. Layer three cannot be in a repository, and compliance-ops-bedrock does not try to put it there.

The planned AgentCore migration is relevant here. One of AgentCore's architectural properties is that guardrail enforcement happens at the runtime layer, outside the LLM reasoning loop. For layer one, this is strictly better than runtime enforcement inside the Lambda function: the guardrail cannot be circumvented by prompt injection because it does not participate in the LLM context. For layer two, AgentCore provides a natural integration point for audit logging of human override decisions. It does not address layer three. But it would close a gap in the current architecture: Bedrock Guardrails are flagged in the euaia-deployer-1 attestation as a known gap before public deployment. AgentCore would resolve that gap.

---

### The Report as a Design Choice

The compliance report generated by `scripts/generate_report.py` is worth discussing as a design decision. It is a static HTML file, generated deterministically from the OSCAL catalogs, attestations, and evidence JSON files by a Jinja2 template. It contains no LLM-written content. It displays attestation statuses, prose justifications, evidence references, and gap flags. It is designed to be published to the dedicated report S3 bucket — a public static website — and shown to auditors.

This design choice reflects the critique I made in part one: that compliance tooling has a trust problem when it uses AI to generate compliance narratives. A compliance report written in whole or in part by an LLM is a document that an auditor cannot verify — the model may have presented partial coverage as complete, may have generated plausible-sounding justifications that do not reflect actual control implementation, may have smoothed over gaps that should be visible. The static HTML report avoids this problem entirely by being nothing more than a structured display of what humans wrote and what automated scripts collected. It is possible to verify every statement in it by reading the source files.

The report's own disclaimer — "This is a prototype report" — is honest. A production version would need independent review of the attestations, not just self-assessment. The attestation schema supports reviewed-by fields precisely because the intent is that attestations should be reviewed by someone other than the person who wrote them. For a single-engineer prototype, that separation is not currently achievable. For a production deployment, it is a prerequisite.

---

### What a Team Forking This Would Still Need to Do

I want to be direct about the gap between a reference architecture and a production compliance program, because eliding that gap is how compliance theater gets built.

A team forking compliance-ops-bedrock for a real production deployment would need, at minimum:

**Legal review of the OSCAL catalogs.** The control definitions are the authors' own reading of GDPR and the EU AI Act. They are a reasonable starting point. They have not been reviewed by a privacy lawyer or a regulatory specialist. Before these catalogs form the basis of a compliance program, someone with legal expertise needs to validate the control-to-article mappings, identify coverage gaps, and assess whether the attestation criteria are sufficient under the regulatory standards that apply to the specific use case.

**Completion of the partial and not-satisfied attestations.** Eight of the twenty attestations are either partial or not-satisfied. These represent real compliance gaps: the Legitimate Interest Assessment for lawful basis, the privacy notice, the right-to-erasure procedure, the pseudonymization assessment. For a production system processing real personal data, these are not deferred items. They are prerequisites.

**A DPIA before production launch.** The attestation for gdpr-35 (DPIA) is marked not-applicable for the demo phase, correctly, because the demo processes only synthetic data. Any production deployment that processes real user data at scale with LLM inference needs a DPIA. The architecture does not produce that document — it flags that the document needs to exist.

**A DPO appointment decision.** The ROPA marks the DPO field as TBD. Whether a DPO is required depends on the scale of processing and the organizational context. This is a legal determination, not a technical one.

**An actual access review schedule.** Several attestations note that the absence of a formal access review schedule is acceptable for a single-operator prototype but not for a production system. A production deployment needs periodic access reviews with signed records, not just a note that they should happen.

**Bedrock Guardrails configuration.** The attestation for euaia-deployer-1 (human oversight) explicitly identifies Bedrock Guardrails as a known gap before any public deployment. The architecture demonstrates where guardrails would be configured; it does not configure them, because the demo scope does not require them. A production deployment serving external users needs guardrails for harmful content blocking before launch, not after the first incident. The planned AgentCore migration is the cleaner path to closing this gap, but it has not landed yet.

None of these gaps are hidden. The attestations themselves flag them. That is the point: the architecture is designed to surface what is incomplete rather than to paper over it. But a team that reads "partial" in an attestation and ships to production anyway has used the tooling as theater rather than as compliance infrastructure.

---

### Why This Matters Now

The EU AI Act's full high-risk AI system requirements apply from August 2026. The limited-risk transparency obligations under Art. 50 are already in force, though enforceable at national level only once member states have designated competent authorities — a process that, as of April 2026, Germany has still not completed (a draft bill, KI-MIG, passed cabinet in February 2026 and awaits Bundestag passage). FedRAMP's OSCAL mandate arrives in September 2026. The window in which teams can plan compliance architectures before these obligations become enforceable is closing.

Most teams are not starting from a mature OSCAL-based compliance infrastructure. Most teams are starting from spreadsheets, or from ad hoc documentation scattered across wikis and Confluence spaces, or from compliance platforms that provide checklists but not structured evidence. The jump from any of those starting points to a working OSCAL-based system with automated evidence collection, structured attestations, and audit-ready human procedure documents is not small.

A reference architecture that covers GDPR and EU AI Act controls in OSCAL format, with real implementation examples and honest gap documentation, is useful precisely because it is concrete. Abstract descriptions of what compliance should look like are easy to find. Working code that demonstrates how to structure a ROPA as a version-controlled YAML file, how to implement Art. 50 transparency disclosure at the API layer, and how to generate a deterministic compliance report from structured artifacts — that is harder to find.

The architecture does not make compliance easy. Nothing makes compliance with GDPR and the EU AI Act easy. But it makes the hard parts more tractable, and it is honest about which parts it cannot address. That combination is rarer than it should be.

---

*The compliance-ops-bedrock repository is available at [github.com/LeonardoSanBenitez/compliance-ops-bedrock](https://github.com/LeonardoSanBenitez/compliance-ops-bedrock).*

*Previous posts in this series: Part 1 — The Compliance Automation Illusion; Part 2 — What Auditors Actually Do; Part 3 — The Walls of the Machine.*
