# ── Bedrock: S3 Vectors (vector store) ────────────────────────────────────────
#
# S3 Vectors is used instead of OpenSearch Serverless for cost reasons:
#   OpenSearch Serverless minimum: ~$175/month
#   S3 Vectors for this demo: < $1/month (see cost estimate in COST.md)
#
# Limitation: S3 Vectors supports semantic search only (no hybrid/keyword search).
# For a compliance demo chatbot this is sufficient.
#
# Terraform resources require AWS provider >= 6.27.0 (see versions.tf).

resource "aws_s3vectors_vector_bucket" "kb" {
  vector_bucket_name = "${var.project_name}-vectors-${var.environment}"

  # Use the existing CMK for encryption.
  # If omitted, AWS uses an AWS-managed key (SSE-S3Vectors).
  encryption_configuration {
    sse_type    = "aws:kms"
    kms_key_arn = aws_kms_key.main.arn
  }
}

resource "aws_s3vectors_index" "kb" {
  vector_bucket_name = aws_s3vectors_vector_bucket.kb.vector_bucket_name
  index_name         = "bedrock-kb-index"

  # Titan Text Embeddings V2 produces 1024-dimensional vectors.
  # Dimension must match the embedding model; changing it requires recreating the index.
  data_type       = "float32"
  dimension       = 1024
  distance_metric = "cosine"

  # Bedrock KB stores the original text chunk and document metadata in
  # AMAZON_BEDROCK_TEXT and AMAZON_BEDROCK_METADATA respectively.
  # Text chunks can be several KB; keeping them as filterable metadata would
  # violate the S3 Vectors 2048-byte filterable-metadata limit.
  # Declare them non-filterable so up to 40KB of metadata is allowed per vector.
  # Reference: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-vectors-bedrock-kb.html
  metadata_configuration {
    non_filterable_metadata_keys = ["AMAZON_BEDROCK_TEXT", "AMAZON_BEDROCK_METADATA"]
  }
}

# ── Bedrock Knowledge Base ─────────────────────────────────────────────────────
#
# The KB indexes documents from the S3 source bucket and stores embeddings
# in the S3 Vectors index above.
#
# Data source: S3 bucket containing the README, compliance catalogs, and any
# other documents we want the agent to be able to retrieve.
#
# Chunking strategy: fixed-size (512 tokens, 10% overlap) is the simplest
# option and well-suited for structured compliance documents.

resource "aws_bedrockagent_knowledge_base" "main" {
  name        = "${var.project_name}-kb-${var.environment}"
  description = "RAG knowledge base for compliance-ops-bedrock chatbot"
  role_arn    = aws_iam_role.bedrock_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn
    }
  }

  storage_configuration {
    type = "S3_VECTORS"
    s3_vectors_configuration {
      index_arn = aws_s3vectors_index.kb.index_arn
    }
  }

  # IAM role creation has eventual consistency; give it a moment.
  depends_on = [
    aws_iam_role_policy.bedrock_kb_embedding,
    aws_iam_role_policy.bedrock_kb_s3_source,
    aws_iam_role_policy.bedrock_kb_s3vectors,
    aws_iam_role_policy.bedrock_kb_kms,
  ]
}

resource "aws_bedrockagent_data_source" "readme" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name              = "readme-and-compliance-docs"
  description       = "Project README and compliance documentation"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.kb_source.arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 512
        overlap_percentage = 10
      }
    }
  }
}

# ── Bedrock Agent ──────────────────────────────────────────────────────────────
#
# The agent uses Nova Micro as the orchestration model.
# System prompt (instruction) satisfies two compliance requirements:
#   - EU AI Act Art. 50(1): agent identifies itself as an AI system
#   - EU AI Act Art. 50(2): agent responses are tagged as AI-generated
#
# The agent is associated with the knowledge base after creation.
# An alias is created so callers use a stable reference; the agent
# can be updated (new version prepared) without changing the alias ARN.

resource "aws_bedrockagent_agent" "main" {
  agent_name              = "${var.project_name}-agent-${var.environment}"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  description             = "Compliance-ops-bedrock reference chatbot"
  foundation_model        = var.agent_foundation_model_id

  # Instruction constitutes the system prompt for every session.
  # Fulfils EU AI Act Art. 50(1) AI identity disclosure requirement.
  instruction = <<-EOT
    You are an AI compliance assistant for the compliance-ops-bedrock demo system.
    You must always identify yourself as an AI assistant when asked.
    You answer questions about the system's architecture, security controls,
    GDPR compliance posture, and EU AI Act classification.
    You retrieve information from the compliance knowledge base.
    You do not make medical, legal, financial, or employment decisions.
    When you are uncertain, say so clearly rather than inventing an answer.
    This system is a demonstration and does not process real personal data.
  EOT

  # idle_session_ttl_in_seconds: 600 seconds (10 minutes) balances usability
  # with GDPR principle of data minimisation.
  idle_session_ttl_in_seconds = 600

  # Guardrails configuration: omitted for initial demo.
  # Add aws_bedrockagent_guardrail resource before handling any real user data.
}

resource "aws_bedrockagent_agent_knowledge_base_association" "main" {
  agent_id             = aws_bedrockagent_agent.main.agent_id
  description          = "Compliance documentation knowledge base"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.main.id
  knowledge_base_state = "ENABLED"
}

# Agent alias: stable ARN for callers.
# Routing configuration points to the DRAFT version by default.
# When promoting to a tested version, update the alias here.
resource "aws_bedrockagent_agent_alias" "main" {
  agent_id         = aws_bedrockagent_agent.main.agent_id
  agent_alias_name = "${var.environment}-latest"
  description      = "Latest prepared version of the ${var.environment} agent"

  # No routing_configuration block = AWS automatically routes to DRAFT.
  # Add explicit routing to a pinned version before production use.
}
