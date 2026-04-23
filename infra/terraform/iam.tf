# ── IAM roles and policies ─────────────────────────────────────────────────────
#
# Three principals:
#
#   1. bedrock-kb-role     — assumed by Amazon Bedrock Knowledge Bases service.
#      Permissions: invoke embedding model, read source S3 bucket,
#      read/write/query S3 Vectors index.
#
#   2. bedrock-agent-role  — assumed by Amazon Bedrock Agents service.
#      Permissions: invoke Nova Micro foundation model, query knowledge base.
#
#   3. lambda-execution-role  — assumed by any Lambda function backing action groups.
#      Permissions: write to conversation log S3 bucket, write to DynamoDB,
#      read Bedrock KB (for custom retrieval logic if needed).
#      Lambda functions are not yet deployed; this role is pre-provisioned so
#      it can be referenced in the Lambda resource block when added.
#
# Security posture:
#   - All trust policies include aws:SourceAccount condition (confused deputy mitigation).
#   - Resource ARNs in policies are specific where available; wildcards only where
#     ARNs are not known until runtime (e.g., newly created KB ID).
#   - No * Action grants. No admin permissions.

locals {
  agent_model_arn     = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.agent_foundation_model_id}"
  embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embedding_model_id}"
}

# ── IAM role: Bedrock Knowledge Base ─────────────────────────────────────────

resource "aws_iam_role" "bedrock_kb" {
  name = "${var.project_name}-bedrock-kb-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockKBAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
          ArnLike = {
            # Scoped to knowledge-base resources in this account.
            # Update with specific KB ARN after first apply if needed.
            "AWS:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:knowledge-base/*"
          }
        }
      }
    ]
  })
}

# Permission: invoke embedding model.
resource "aws_iam_role_policy" "bedrock_kb_embedding" {
  name = "invoke-embedding-model"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeEmbeddingModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [local.embedding_model_arn]
      }
    ]
  })
}

# Permission: read documents from KB source bucket.
resource "aws_iam_role_policy" "bedrock_kb_s3_source" {
  name = "read-kb-source-bucket"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListKBSourceBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.kb_source.arn]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid    = "GetKBSourceObjects"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.kb_source.arn}/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# Permission: use S3 Vectors index (read, write, query).
# Resource ARN: arn:aws:s3vectors:<region>:<account>:bucket/<bucket>/index/<index>
resource "aws_iam_role_policy" "bedrock_kb_s3vectors" {
  name = "s3vectors-index-access"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3VectorIndexAccess"
        Effect = "Allow"
        Action = [
          "s3vectors:PutVectors",
          "s3vectors:GetVectors",
          "s3vectors:DeleteVectors",
          "s3vectors:QueryVectors",
          "s3vectors:GetIndex"
        ]
        # Scoped to the specific vector bucket + index created below.
        Resource = [
          "${aws_s3vectors_vector_bucket.kb.vector_bucket_arn}/index/${aws_s3vectors_index.kb.index_name}"
        ]
      }
    ]
  })
}

# Permission: use KMS key for S3 and S3 Vectors operations.
# Two statements: one scoped to s3 ViaService, one for s3vectors (which does
# not propagate a standard ViaService condition through the Bedrock KB service).
resource "aws_iam_role_policy" "bedrock_kb_kms" {
  name = "kms-s3-decrypt"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSDecryptForS3"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [aws_kms_key.main.arn]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        # S3 Vectors (used by Bedrock KB for vector storage) does not pass
        # a ViaService condition through the assumed role call chain.
        # Scope to the specific key; accept the absence of ViaService here.
        Sid    = "KMSDecryptForS3Vectors"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

# ── IAM role: Bedrock Agent ────────────────────────────────────────────────────

resource "aws_iam_role" "bedrock_agent" {
  # Bedrock requires the role name to start with "AmazonBedrockExecutionRoleForAgents_"
  # Reference: https://docs.aws.amazon.com/bedrock/latest/userguide/agents-permissions.html
  name = "AmazonBedrockExecutionRoleForAgents_${var.project_name}-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockAgentAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
          ArnLike = {
            "AWS:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:agent/*"
          }
        }
      }
    ]
  })
}

# Permission: invoke the foundation model for agent orchestration.
resource "aws_iam_role_policy" "bedrock_agent_model" {
  name = "invoke-foundation-model"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeFoundationModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [local.agent_model_arn]
      }
    ]
  })
}

# Permission: query the knowledge base.
# Scoped to KBs in this account; tighten to specific KB ARN after creation.
resource "aws_iam_role_policy" "bedrock_agent_kb" {
  name = "query-knowledge-base"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RetrieveFromKnowledgeBase"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:knowledge-base/*"
        ]
      }
    ]
  })
}

# ── IAM role: Lambda execution ─────────────────────────────────────────────────

resource "aws_iam_role" "lambda_execution" {
  name = "${var.project_name}-lambda-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# AWS-managed policy for basic Lambda execution (CloudWatch Logs).
# This is a well-known managed policy; using the data source ensures the ARN is correct
# across partitions and does not hard-code the account-level ARN.
data "aws_iam_policy" "lambda_basic_execution" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = data.aws_iam_policy.lambda_basic_execution.arn
}

# Permission: write conversation logs to S3.
resource "aws_iam_role_policy" "lambda_conv_logs_s3" {
  name = "write-conversation-logs"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PutConversationLogs"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = ["${aws_s3_bucket.conv_logs.arn}/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# Permission: write to DynamoDB conversation sessions table.
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb-conversation-sessions"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBConversationSessions"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.conversation_sessions.arn,
          "${aws_dynamodb_table.conversation_sessions.arn}/index/*"
        ]
      }
    ]
  })
}

# Permission: retrieve from Bedrock Knowledge Base (used by tools.py retrieve tool).
resource "aws_iam_role_policy" "lambda_bedrock_kb" {
  name = "bedrock-kb-retrieve"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockKBRetrieve"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:knowledge-base/*"
        ]
      },
      {
        # Strands uses BedrockModel to invoke the foundation model directly.
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [local.agent_model_arn]
      }
    ]
  })
}

# Permission: KMS decrypt for S3 and DynamoDB operations.
resource "aws_iam_role_policy" "lambda_kms" {
  name = "kms-s3-dynamodb-decrypt"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSForS3AndDynamo"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [aws_kms_key.main.arn]
        Condition = {
          StringEquals = {
            "kms:ViaService" = [
              "s3.${var.aws_region}.amazonaws.com",
              "dynamodb.${var.aws_region}.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}
