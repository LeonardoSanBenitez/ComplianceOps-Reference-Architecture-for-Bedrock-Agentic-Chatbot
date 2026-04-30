# ── Bedrock AgentCore Runtime ──────────────────────────────────────────────────
#
# Deploys the compliance chatbot as an Amazon Bedrock AgentCore Runtime,
# which provides AWS-managed container hosting with automatic scaling,
# observability, and IAM-integrated invocation.
#
# The runtime wraps app/agentcore_app.py (BedrockAgentCoreApp entrypoint).
# The same ECR image used by the Lambda function is reused here — both
# entry points (Lambda handler and AgentCore entrypoint) live in the same
# container image.
#
# Deployment model:
#   - Container image from the same ECR repo as the Lambda function.
#   - Public network mode (demo; switch to VPC for production).
#
# Invocation (AgentCore Runtime):
#   POST https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<id>/invocations
#   Body: {"prompt": "<message>", "session_id": "<uuid>"}
#   Auth: SigV4 (unlike the Lambda Function URL which is public)
#
# Provider note: this file uses the native hashicorp/aws provider resource
# aws_bedrockagentcore_agent_runtime (available from v6.18.0).  The awscc
# Cloud Control API approach was evaluated but rejected because
# AWS::BedrockAgentCore::AgentRuntime is not yet registered as a public
# CloudFormation type in us-east-1.
#
# Known issue: aws_bedrockagentcore_agent_runtime can leave dangling ENIs on
# destroy when using VPC network mode.  This deployment uses PUBLIC mode so
# no ENIs are created and the issue does not apply.
#
# References:
#   https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime

locals {
  # agent_runtime_name must match ^[a-zA-Z][a-zA-Z0-9_]{0,47}$ — no hyphens.
  # Replace hyphens with underscores for the AgentCore name while keeping the
  # kebab-case convention everywhere else in the project.
  agentcore_runtime_name = replace("${var.project_name}_runtime_${var.environment}", "-", "_")
}

# ── IAM role: AgentCore Runtime execution ─────────────────────────────────────
#
# AgentCore assumes this role to pull the container image from ECR and write
# logs to CloudWatch.  The trust policy follows the confused-deputy mitigation
# pattern: SourceAccount + SourceArn conditions narrow the scope to resources
# owned by this account.

resource "aws_iam_role" "agentcore_runtime" {
  name = "${var.project_name}-agentcore-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAgentCoreAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.aws_account_id}:*"
          }
        }
      }
    ]
  })
}

# Permission: pull the container image from ECR.
resource "aws_iam_role_policy" "agentcore_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRImagePull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [aws_ecr_repository.app.arn]
      }
    ]
  })
}

# Permission: write runtime logs to CloudWatch.
resource "aws_iam_role_policy" "agentcore_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CreateLogGroup"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:*",
        ]
      },
      {
        Sid    = "PutLogEvents"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"
        ]
      }
    ]
  })
}

# Permission: emit CloudWatch metrics under the bedrock-agentcore namespace.
resource "aws_iam_role_policy" "agentcore_metrics" {
  name = "cloudwatch-metrics"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PutMetricData"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      }
    ]
  })
}

# Permission: invoke the foundation model (Strands uses BedrockModel internally).
resource "aws_iam_role_policy" "agentcore_bedrock" {
  name = "bedrock-invoke-model"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeFoundationModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [local.agent_model_arn]
      },
      {
        # Strands retrieve_compliance_info tool calls bedrock-agent-runtime.retrieve().
        Sid    = "KBRetrieve"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate",
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:knowledge-base/*"
        ]
      }
    ]
  })
}

# ── AgentCore Runtime resource ─────────────────────────────────────────────────

resource "aws_bedrockagentcore_agent_runtime" "main" {
  agent_runtime_name = local.agentcore_runtime_name
  description        = "Compliance chatbot runtime (Strands + Nova Micro, AgentCore)"
  role_arn           = aws_iam_role.agentcore_runtime.arn

  agent_runtime_artifact {
    container_configuration {
      # Use the :agentcore tag which points to the plain-Python uvicorn image
      # (app/Dockerfile.agentcore).  AgentCore Runtime does NOT use the Lambda
      # bootstrap protocol; it requires a plain HTTP server on port 8080.
      # The Lambda function uses :latest (app/Dockerfile, Lambda base image).
      container_uri = "${aws_ecr_repository.app.repository_url}:agentcore"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    KNOWLEDGE_BASE_ID  = aws_bedrockagent_knowledge_base.main.id
    AGENT_MODEL_ID     = var.agent_foundation_model_id
    AWS_DEFAULT_REGION = var.aws_region
    DYNAMODB_TABLE     = aws_dynamodb_table.conversation_sessions.name
    CONV_LOG_BUCKET    = local.conv_log_bucket_name
    RETENTION_DAYS     = tostring(var.s3_log_expiration_days)
  }

  depends_on = [
    aws_iam_role_policy.agentcore_ecr,
    aws_iam_role_policy.agentcore_logs,
    aws_iam_role_policy.agentcore_metrics,
    aws_iam_role_policy.agentcore_bedrock,
  ]
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "agentcore_runtime_arn" {
  description = "ARN of the Bedrock AgentCore Runtime"
  value       = aws_bedrockagentcore_agent_runtime.main.agent_runtime_arn
}

output "agentcore_runtime_id" {
  description = "ID of the Bedrock AgentCore Runtime (used in invocation URLs)"
  value       = aws_bedrockagentcore_agent_runtime.main.agent_runtime_id
}
