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

# NOTE: Bedrock Managed Agent removed.
#
# The application uses the Strands SDK (app/agent.py) to orchestrate
# Nova Micro directly via BedrockModel. The Bedrock Knowledge Base is
# queried by the Strands agent tools via bedrock-agent-runtime.retrieve().
# A separate aws_bedrockagent_agent resource is not used and was removed
# to eliminate the redundant parallel implementation.
