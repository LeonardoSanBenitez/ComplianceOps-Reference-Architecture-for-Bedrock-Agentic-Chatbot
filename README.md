# ComplianceOps Reference Architecture for Bedrock Agentic Chatbot

<some badges>

Example project deploying an agentic chatbot in AWS Bedrock, showcasing best practices for Compliance Operations, DevSecOps, Shift-Left Compliance, Regulatory Automation, Compliance as Code, and related practices.

This repository is a blueprint for more complex applications. It is meant to **demonstrate by example** how to build a system that follows best practices, and you are still responsible for adapting, hardening, and extending it for your own environment.



This repository includes:

* ✅ Infra as code required to deploy the architecture
* ✅ Demo agentic chat
* ✅ Compliance-as-code definitions of controls and related requirements
* ✅ Manual documents/entries indicating compliance evidence for a few controls
* ✅ Guidance on usage and adaptation of this reference architecture
* ✅ A public endpoint providing an automatically generated compliance report

This repository does **not** include (intentionally):

* ❌ Evaluating the chatbot against adversarial attacks
* ❌ Dynamic application security testing or pentesting
* ❌ Evaluating the overall compliance posture of the organization; the scope is limited to this chatbot application
* ❌ AI-based inference about whether infrastructure meets regulatory requirements
* ❌ AI-based polishing of the reports
* ❌ Landing zone or enterprise centralized controls of your cloud posture

Some of those points are clearly flagged in the report, with explicit “missing / not evidenced / requires manual confirmation” status. Other points, and especially topics not mentioned at all, still need to be assessed in the context of the organization.

> Disclaimer 1: this reference architecture was developed with heavy use of AI assistants.

> Disclaimer 2: learning AWS services and exploring RegOps is the main reason this project exists, so it is not production ready and not hardened for enterprise use. Use at your own discretion.

## What is RegOps

Software development is getting faster, and AI is being infused into nearly every aspect of software development. If compliance is to keep up, it must become code-based, testable, and highly automated.

RegOps is a combination of practices, culture, and tools that aims to make compliance easier to demonstrate to certification bodies, supervisory authorities, and similar entities, while reducing the load on the compliance team. The goal is to automate as much as possible, keep the evidence structured, and use terminology that is clear to engineers and auditors.

## Who is this repo for

Shipping products and services involves several teams inside an organization:

* Leadership: commitment, buy-in, objectives, resources, final decisions
* Legal and privacy: contracts, policy review, regulatory interpretation
* Governance, security, and risk management: policies, risk assessments, third-party risk management, audit preparation
* Product and engineering: architecture, development, operations

These groups should not work in silos. As much as possible, their decisions should be consolidated into code and structured evidence that can be checked automatically.

This repo assumes that everyone involved is both regulation-literate and technically proficient... That is not easy, but it is the right target for a serious implementation.


## Getting started

Clone the repo, adapt it to your organization, configure CI/CD in your cloud, and deploy.

## Architecture details

### Demo agentic chat

The chatbot exists only to demonstrate the architecture, so it is meant to be simple.

It is composed of:
* Bedrock-hosted Mistral model
* Agentic orchestration layer built with Strands
* RAG built with Bedrock Knowledge Base, whose content is this README
* Tools for querying policies, controls, and artifacts

The chatbot can talk about its own system architecture, but it should not be treated as the compliance system: this is just a demo application.

### Cloud architecture

[The cloud layer should be designed for top-notch security and governance.]

[this section currently just throw arround some ideas. We should filter what is really needed, what should be out of scope, then rephrase to a descriptive language instead of tentative]




automatically rotate database credentials

proper logging

Bedrock Guardrails

bedrock evaluations (be careful with costs, this is just to demonstrate the idea!)

all IAM policies and roles defined in a mindfull manner


everythign following naming conventions from AWS


I dont think AWS has a clear way of groupijg resources (like resource groups in azure)... sad... or maybe it does and I dont know about it, im not very good with AWS


dev-stag-prod separation (idk the best way to separate this in AWS; In Azure I would have one recourse group for each, all in the same subscription, because its a fairily easy but enough isolated setup)




Idk if AWS has options for exporting compliance-realted info to be used as evidence, nor if AWS can export this info as Oscal or similar macine readable formats...

Also, there are governance and security related services that we should consider using, like:
* CloudTrail Insights (maybe identified problems should be considered when generating the compliance report?)
* Cost allocation tags to track costs by dimensions of interest: by customer (only me, but prepare the tool), by use case (only one), etc
* AWS Config for historical configuration tracking and compliance evaluation
* AWS CloudFormation Guard... [but Im not sure if it makes sense if we are using terraform. I want terrafiorm, cloudformation is not a option]

[after we architecture, discuss, and implement the architecture, this section should be refactored into a clear description of the architecture]


## [Standards and tooling to decide before proceeding]

[TODO this has to be properly discussed. Using the right tooling is the very core of this reference architecture]

This repository should be based primarily on **open standards**. I think that the best fit for the compliance layer is **OSCAL**, because it is designed to represent controls, profiles, implementation statements, assessment artifacts, and control mappings in machine-readable XML/JSON/YAML. OpenControl/compliance-masonry can be used as a lighter, older, repo-first compatibility layer, but OSCAL should be the strategic target.

This project should not treat every standard as interchangeable. They solve different problems.

* **OSCAL** should be the primary format for control catalogs, profiles, implementation statements, assessment plans/results, and control mappings. It is the best fit for a machine-readable compliance backbone.
* **OpenControl / compliance-masonry** is useful if a simpler repo-based authoring workflow is needed, but it is more documentation-oriented and should probably be treated as a compatibility layer, not the long-term source of truth. It renders certification documentation from OpenControl schema content.
* **SPDX** and **CycloneDX** are for supply-chain transparency, not for control registries. SPDX is an open standard for SBOMs and related metadata and is ISO/IEC 5962:2021. CycloneDX is another open BOM standard and can also represent software, hardware, ML models, source code, and configurations. Pick one instead of inventing a third SBOM format.
* **OCSF** is for security telemetry normalization, not compliance controls. It is the right standard if you want a common schema for events and findings. AWS Security Lake converts ingested data to OCSF, and Security Hub findings are also aligned with OCSF.
* **OpenLineage** is for data and pipeline lineage, not compliance controls. It is a good fit for evidence about where model inputs came from, what transformed them, and what ran when. AWS SageMaker Unified Studio supports OpenLineage-compatible lineage capture.
* For AI-specific governance, the AWS features below are evidence sources and enforcement points, but they are not the compliance framework itself: Bedrock Guardrails, Bedrock Evaluations, SageMaker Model Registry, Model Monitor, Clarify, and lineage tracking.

[this whole section should be removed after we decide the tooling]


## CI/CD with shift-left focus

The CI/CD pipelines run in AWS itself using [CodePipeline or similars. Idk, Im just used to azure devops]


[again, after architecting this should be rephrased to describe the actual architecture instead of throwing around ideas]

pipeline to apply **terraform**. Static checks for a lot of security and complaince related things. Inspect or checkov looks good, idk which one is better, or if both are needed. Deploy the application / update AgentCore, with all proper automated tests (can be simple, but we should have something) and statics checks like mypy and pycodestyle [Maybe this should be a separate pipeline, or maybe it can be the same pipeline with multiple stages, idk you decice].

pipeline manually triggered (or maybe a lambda durable function, if pipelines cant handle this task but i want to keep this as minimal and simple as possibel) to **generate Oscal artifacts** [or whatever tool/standard we decide] given the existing infrastructure, and save results to S3

pipeline manually triggered (or maybe a lambda durable function, if pipelines cant handle this task but i want to keep this as minimal and simple as possibel) to **checks the oscal artifacts against the policies, generate simple reports** (see ahead the details about whatthis report should be), save to a S3 bucket exposed as public static webpage.

The policies are manually written and commited to the repo (See the next section defining what they are like), but Maybe we need another pipeline to save them to S3 if they change. Similar for the readme (if it cahnges, we need to update the knowledge base of the chatbot)

[I guess it makes sense to have these 4 things as independent pipelines]



## Definitions of policies and controls

[This is the core of the repo.]

The project should define:

* what requirements exist
* what internal controls are intended to satisfy each requirement
* what automated checks prove those controls
* what human processes are required
* what evidence is collected
* how each control maps to each regulation, standard, or framework

We should somehow define our set of controls and how they map to the regulations, but we should not treat the regulations themselves as the source of truth for the control registry. The controls are the source of truth, and they are mapped to the regulations.

The controls should cover both:

* technical implementations
* human processes

Human-process evidence should be modeled explicitly, not buried in prose. Examples:

* approved threat model completed
* human oversight performed
* DPO review completed
* annual internal audit performed
* stakeholder review completed
* use case classified as high-risk or not
* exception granted and time-bounded

The hard part is not the YAML syntax. The hard part is deciding how to represent manual attestations in a way that is reviewable, versioned, and auditable.

## Compliance evidence model

Evidence should come from two sources:

1. **Automatic evidence from running systems** [not sure if we gonnause all these services, but you get the idea]

   * AWS Config state and history
   * Security Hub findings
   * CloudTrail Lake queries
   * Security Lake events
   * Macie findings
   * Inspector findings
   * Bedrock Guardrails settings and results
   * Bedrock evaluation output
   * SageMaker Registry metadata
   * lineage events from OpenLineage-compatible systems

2. **Manual evidence from humans**

   * approvals
   * reviews
   * exceptions
   * risk acceptance
   * sign-offs
   * audit confirmations

The manual part should probably live as structured repo artifacts, not as free-form text only. A dedicated `evidence/` or `attestations/` tree with versioned YAML/JSON/Markdown is likely the right starting point, but the exact schema still needs to be decided.

The repo should probably define a clean separation between:

* **what the regulation requires**
* **what this system implements**
* **what evidence proves it**
* **what is still missing**

## Report

The report should be a single static HTML file.

It does not need to be pretty, but it does need to be structured, explicit, and deterministic. A Jinja template plus a generation script is enough.

The report should contain:

* scope
* standards covered
* control coverage status
* evidence summary
* missing controls
* partial controls
* exceptions
* risk acceptance items
* operational posture
* AI lifecycle summary
* data lineage summary
* security findings summary
* Skeleton of any document/report/whatever required by the regulation, with links to the evidence and controls that support each section
* next actions

The report should not be LLM-written. The source of truth must be structured artifacts; an LLM can be used by the user later only for optional narrative polishing. The main deliverable should stand on its own.

It's ok if to have some simple JS barchats and other visualizations, but most of the content should be text

For a public demo, the report can be public. For real customers, this will almost certainly need access control because the useful version of a compliance report usually contains sensitive gaps, exceptions, and internal operating details. Its ok to focus this repo in the public caxe if taht simplifies code.

## Questions, doubts, and things to decide

* Should OSCAL be the primary source of truth, with OpenControl used only for legacy compatibility?
* Should the project support both OSCAL and OpenControl output, or only one canonical format? Maybe even some otehr format
* Which SBOM format should be the default: SPDX or CycloneDX? Do we need this at all or can we go just with oscal/opencontrol/whatever?
* Which lineage standard should be used for the data/model side: OpenLineage only, or OpenLineage plus a custom AI lineage schema? Maybe we dont even need lineage, since the application is just a chatbot without training, but we should think how to do data lineage, and to which degree this can be automated in a more complex application with training and retraining loops.
* How should manual attestations be represented: repo files, signed JSON, OSCAL assessment results, or all three?
* How should control ownership, review frequency, and separation of duties be expressed?
* Do we indicate the name of specific people, like "reviewed by Alice on 2024-01-01"?
* What is the exact scope: chatbot application only, or the platform around it as well? I think only the chat, but we should be explicit about this, and the implications of the decision.
* What is the minimum viable set of regulations and standards for the demo? ISO/IEC 42001, ISO/IEC 27001, GDPR, EU AI Act, SOC 2, or some subset? I think GDPR+EU AI Act is a good starting point for the demo, but we should be able to easily add more regulations by just adding more mappings to the control registry.
* How should exceptions be modeled, approved, and expired?
* What is the plan for non-AWS evidence sources? Im fine doing a pure AWS implementation, but the architecture should be adaptable to other clouds and on-prem evidence sources as well.
* What should be private vs public in the generated report? Since this is just a demo, I tend to say it can befully public, with the only considerations it should not have any sensitive info, but for a real implementation we should have a clear separation between the public demo report and the internal report with all the details.
* How should evidence be signed, timestamped, and versioned? S3 versioning and metadata, git history, or something else?
* What is the acceptable level of manual work before the project stops being “RegOps” and becomes plain documentation?

## Gaps and things to think about more

* There is no single OSS tool that cleanly solves control registry, evidence collection, human attestations, dashboarding, and report generation end-to-end.
* OSCAL seems to be the best backbone, but it does not magically solve the semantics of each regulation. The content model still needs careful design.
* OpenControl is useful, but it is not the long-term strategic answer if the goal is maximum interoperability and machine-readability.
* SBOM, OCSF, and OpenLineage are complementary standards. They should not be mixed into the control registry layer.
* Human-process evidence is the hardest part to automate. It needs a deliberate design, not an afterthought.
* AI governance evidence should be tied to model registry, evaluation, guardrails, lineage, and monitoring, otherwise the “compliance” layer will be too abstract to be useful.
* The project should avoid turning into a GRC product clone. The goal is a reference architecture, not a full commercial platform.
* How to trigger the CICD from the repo? I do want to have the projects in github, but maybe we should add another remote for a aws-hosted remote, and triggers to it trigger the deployments... Or something else, think and disucss. Anyways, I want a good devops organization that is lean and clear.

## Contributing

Pull requests, questions, and critiques are welcome.
