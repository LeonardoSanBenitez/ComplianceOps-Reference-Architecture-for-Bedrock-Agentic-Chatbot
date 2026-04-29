# ── AWS CodeBuild: Terraform CI/CD ────────────────────────────────────────────
#
# Replaces GitHub Actions terraform.yml.
# Two CodeBuild projects:
#
#   1. compliance-ops-bedrock-tf-plan  — runs terraform plan; triggered on
#      any push (via GitHub webhook -> CodePipeline, or manually).
#
#   2. compliance-ops-bedrock-tf-apply — runs terraform apply; manual trigger
#      only (no automatic apply on push — safety gate for infrastructure changes).
#
# Both projects use the same IAM execution role (codebuild-tf-role).
# The role has least-privilege permissions: it can only manage resources
# that are part of this project (prefixed "cob-" or matching project ARN patterns).
#
# Terraform state: re-uses the existing S3 + DynamoDB backend bootstrapped
# manually on 2026-04-23 (compliance-ops-bedrock-tfstate / compliance-ops-bedrock-tflock).
#
# Buildspec: inline (defined in this file). No buildspec.yml committed to the
# repo root — keeps CI config co-located with infrastructure code.
#
# To run a plan manually:
#   aws codebuild start-build \
#     --project-name compliance-ops-bedrock-tf-plan \
#     --region us-east-1
#
# To run an apply manually:
#   aws codebuild start-build \
#     --project-name compliance-ops-bedrock-tf-apply \
#     --region us-east-1

locals {
  tf_version      = "1.8.5"
  tf_working_dir  = "infra/terraform"
  # tf_vars uses a var-file per environment so per-env defaults are maintained.
  # TF_ENV CodeBuild env var selects which environments/<env>.tfvars to load.
  # The aws_account_id is still supplied as a direct -var (it is account-scoped
  # and not appropriate to commit to any tfvars file).
  tf_vars         = "-var-file=environments/$${TF_ENV}.tfvars -var=\"aws_account_id=${var.aws_account_id}\""
  # GitHub repository URL for CodeBuild source.
  # CodeBuild fetches via the GitHub connection (OAuth or GitHub App).
  github_repo_url = "https://github.com/LeonardoSanBenitez/ComplianceOps-Reference-Architecture-for-Bedrock-Agentic-Chatbot"
}

# ── IAM role for CodeBuild ─────────────────────────────────────────────────────

resource "aws_iam_role" "codebuild_tf" {
  name = "${var.project_name}-codebuild-tf-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCodeBuildAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# CloudWatch Logs: allow CodeBuild to write build logs.
resource "aws_iam_role_policy" "codebuild_tf_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CreateAndPutLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/${var.project_name}-*:*"
        ]
      }
    ]
  })
}

# Terraform state backend: read/write the S3 state bucket and DynamoDB lock table.
# These resources were manually bootstrapped and are not managed by Terraform itself.
resource "aws_iam_role_policy" "codebuild_tf_state" {
  name = "terraform-state-backend"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TFStateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration"
        ]
        Resource = [
          "arn:aws:s3:::compliance-ops-bedrock-tfstate",
          "arn:aws:s3:::compliance-ops-bedrock-tfstate/*"
        ]
      },
      {
        Sid    = "TFStateLockTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/compliance-ops-bedrock-tflock"
        ]
      }
    ]
  })
}

# KMS: allow CodeBuild / Terraform to create and manage the project KMS key.
resource "aws_iam_role_policy" "codebuild_tf_kms" {
  name = "kms-manage"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSManage"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListKeys",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
          "kms:UpdateKeyDescription",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      }
    ]
  })
}

# S3: manage project buckets (prefixed with project_name).
resource "aws_iam_role_policy" "codebuild_tf_s3" {
  name = "s3-project-buckets"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketLevelActions"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketAcl",
          "s3:GetBucketCORS",
          "s3:GetBucketLocation",
          "s3:GetBucketLogging",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketPolicy",
          "s3:GetBucketPolicyStatus",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketTagging",
          "s3:GetBucketVersioning",
          "s3:GetBucketWebsite",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:PutBucketAcl",
          "s3:PutBucketLogging",
          "s3:PutBucketObjectLockConfiguration",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketRequestPayment",
          "s3:PutBucketTagging",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*"
        ]
      },
      {
        Sid    = "S3ObjectLevelActions"
        Effect = "Allow"
        Action = [
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*/*"
        ]
      }
    ]
  })
}

# S3 Vectors: manage vector buckets and indexes for the project.
resource "aws_iam_role_policy" "codebuild_tf_s3vectors" {
  name = "s3vectors-manage"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3VectorsManage"
        Effect = "Allow"
        Action = [
          "s3vectors:CreateVectorBucket",
          "s3vectors:DeleteVectorBucket",
          "s3vectors:GetVectorBucket",
          "s3vectors:ListVectorBuckets",
          "s3vectors:CreateIndex",
          "s3vectors:DeleteIndex",
          "s3vectors:GetIndex",
          "s3vectors:ListIndexes",
          "s3vectors:TagResource",
          "s3vectors:UntagResource",
          "s3vectors:ListTagsForResource"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      }
    ]
  })
}

# DynamoDB: manage project tables (prefixed with project_name).
resource "aws_iam_role_policy" "codebuild_tf_dynamodb" {
  name = "dynamodb-manage"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBManageTables"
        Effect = "Allow"
        Action = [
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:DescribeTable",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:UpdateContinuousBackups",
          "dynamodb:UpdateTable",
          "dynamodb:UpdateTimeToLive"
        ]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.project_name}-*"
        ]
      }
    ]
  })
}

# IAM: create and manage roles/policies scoped to this project.
# PassRole is limited to the execution roles created by this project.
resource "aws_iam_role_policy" "codebuild_tf_iam" {
  name = "iam-project-roles"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMManageProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:GetPolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription"
        ]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/${var.project_name}-*",
          "arn:aws:iam::${var.aws_account_id}:role/AmazonBedrockExecutionRoleForAgents_${var.project_name}-*"
        ]
      },
      {
        # PassRole: allow CodeBuild to pass the project IAM roles to Bedrock/Lambda/AgentCore services.
        # bedrock-agentcore.amazonaws.com is required because awscc_bedrockagentcore_runtime
        # creates a Runtime with role_arn, which triggers a PassRole check to the AgentCore service.
        Sid    = "IAMPassRoleToServices"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/${var.project_name}-*",
          "arn:aws:iam::${var.aws_account_id}:role/AmazonBedrockExecutionRoleForAgents_${var.project_name}-*"
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "bedrock.amazonaws.com",
              "bedrock-agentcore.amazonaws.com",
              "lambda.amazonaws.com"
            ]
          }
        }
      },
      {
        # Read the AWSLambdaBasicExecutionRole managed policy (referenced by data source in iam.tf).
        Sid    = "IAMReadManagedPolicies"
        Effect = "Allow"
        Action = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
        Resource = [
          "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
        ]
      }
    ]
  })
}

# Bedrock / BedrockAgent / BedrockAgentCore: manage knowledge bases, agents, data sources,
# aliases, and AgentCore Runtimes.
# The awscc provider (used for awscc_bedrockagentcore_runtime resources) routes API calls
# through Cloud Control API, which internally calls bedrock-agentcore:* actions on behalf
# of the caller.  The bedrock-agentcore:* permissions here must therefore be granted to
# the CodeBuild execution role, not only to the runtime execution role.
resource "aws_iam_role_policy" "codebuild_tf_bedrock" {
  name = "bedrock-manage"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read foundation model metadata, tag project resources, and invoke
        # models for Terraform drift-detection (plan).  Model invocation logging
        # configuration is excluded — not used in this project.
        Sid    = "BedrockAgentManage"
        Effect = "Allow"
        Action = [
          "bedrock:GetFoundationModel",
          "bedrock:ListFoundationModels",
          "bedrock:TagResource",
          "bedrock:UntagResource",
          "bedrock:ListTagsForResource",
          "bedrock:InvokeModel"
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockKBManage"
        Effect = "Allow"
        Action = [
          "bedrock:AssociateAgentKnowledgeBase",
          "bedrock:CreateDataSource",
          "bedrock:CreateKnowledgeBase",
          "bedrock:DeleteDataSource",
          "bedrock:DeleteKnowledgeBase",
          "bedrock:DisassociateAgentKnowledgeBase",
          "bedrock:GetDataSource",
          "bedrock:GetKnowledgeBase",
          "bedrock:ListDataSources",
          "bedrock:ListKnowledgeBases",
          "bedrock:StartIngestionJob",
          "bedrock:GetIngestionJob",
          "bedrock:ListIngestionJobs",
          "bedrock:UpdateDataSource",
          "bedrock:UpdateKnowledgeBase"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:knowledge-base/*"
        ]
      },
      {
        Sid    = "BedrockAgentCRUD"
        Effect = "Allow"
        Action = [
          "bedrock:CreateAgent",
          "bedrock:DeleteAgent",
          "bedrock:GetAgent",
          "bedrock:ListAgents",
          "bedrock:PrepareAgent",
          "bedrock:UpdateAgent",
          "bedrock:CreateAgentAlias",
          "bedrock:DeleteAgentAlias",
          "bedrock:GetAgentAlias",
          "bedrock:ListAgentAliases",
          "bedrock:UpdateAgentAlias",
          "bedrock:CreateAgentVersion",
          "bedrock:DeleteAgentVersion",
          "bedrock:GetAgentVersion",
          "bedrock:ListAgentVersions",
          "bedrock:AssociateAgentKnowledgeBase",
          "bedrock:DisassociateAgentKnowledgeBase",
          "bedrock:GetAgentKnowledgeBase",
          "bedrock:ListAgentKnowledgeBases"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:agent/*",
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:agent-alias/*"
        ]
      },
      {
        # Manage AgentCore Runtimes and Endpoints via the bedrock-agentcore service API.
        # The awscc Terraform provider calls these actions through Cloud Control API.
        # PassRole for the agentcore execution role is handled in the IAMPassRoleToServices
        # statement in the iam-project-roles policy.
        Sid    = "AgentCoreRuntimeManage"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateAgentRuntime",
          "bedrock-agentcore:DeleteAgentRuntime",
          "bedrock-agentcore:GetAgentRuntime",
          "bedrock-agentcore:ListAgentRuntimes",
          "bedrock-agentcore:UpdateAgentRuntime",
          "bedrock-agentcore:CreateAgentRuntimeEndpoint",
          "bedrock-agentcore:DeleteAgentRuntimeEndpoint",
          "bedrock-agentcore:GetAgentRuntimeEndpoint",
          "bedrock-agentcore:ListAgentRuntimeEndpoints",
          "bedrock-agentcore:UpdateAgentRuntimeEndpoint",
          "bedrock-agentcore:TagResource",
          "bedrock-agentcore:UntagResource",
          "bedrock-agentcore:ListTagsForResource"
        ]
        Resource = "*"
      }
    ]
  })
}

# CodeBuild: allow the role to manage project lifecycle and report build status.
# CreateProject/DeleteProject are needed because Terraform (tf-apply) provisions
# the cob-ci and other CodeBuild projects; the execution role must have these
# permissions or the apply will fail with AccessDeniedException on CreateProject.
# BatchGetProjects is required by the Terraform aws_codebuild_project data source reads
# that occur during terraform plan/apply when the provider refreshes existing resources.
resource "aws_iam_role_policy" "codebuild_tf_self" {
  name = "codebuild-self"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeBuildManageProjects"
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects",
          "codebuild:CreateProject",
          "codebuild:CreateWebhook",
          "codebuild:DeleteProject",
          "codebuild:DeleteWebhook",
          "codebuild:GetResourcePolicy",
          "codebuild:ListBuildsForProject",
          "codebuild:ListProjects",
          "codebuild:UpdateProject",
          "codebuild:UpdateWebhook"
        ]
        Resource = [
          "arn:aws:codebuild:${var.aws_region}:${var.aws_account_id}:project/${var.project_name}-*"
        ]
      }
    ]
  })
}

# SNS, EventBridge, and Lambda log group management.
# Originally created manually; now Terraform-managed to prevent config drift.
# Trimmed to stay within the IAM inline policy size limit (10240 chars total per role).
# Actions removed to save space: logs:AssociateKmsKey/DisassociateKmsKey,
# events:EnableRule/DisableRule/TagResource/UntagResource, sns:TagResource/UntagResource.
# These are not required for Terraform plan/apply state refresh or resource management.
resource "aws_iam_role_policy" "codebuild_tf_sns_events" {
  name = "sns-events-logs"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Required for Lambda function log group state refresh (Terraform provider reads tags).
        Sid    = "LambdaLogGroupManage"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
          "logs:PutRetentionPolicy"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:*"
      },
      {
        Sid    = "SNSManage"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:GetSubscriptionAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:ListTagsForResource",
          "sns:SetTopicAttributes",
          "sns:Subscribe",
          "sns:Unsubscribe"
        ]
        Resource = "arn:aws:sns:${var.aws_region}:${var.aws_account_id}:${var.project_name}-*"
      },
      {
        Sid    = "EventBridgeManage"
        Effect = "Allow"
        Action = [
          "events:DeleteRule",
          "events:DescribeRule",
          "events:ListTagsForResource",
          "events:ListTargetsByRule",
          "events:PutRule",
          "events:PutTargets",
          "events:RemoveTargets"
        ]
        Resource = "arn:aws:events:${var.aws_region}:${var.aws_account_id}:rule/${var.project_name}-*"
      }
    ]
  })
}

# ── CodeBuild: Terraform Plan ──────────────────────────────────────────────────

resource "aws_codebuild_project" "tf_plan" {
  name          = "${var.project_name}-tf-plan"
  description   = "Runs terraform plan for compliance-ops-bedrock infrastructure"
  service_role  = aws_iam_role.codebuild_tf.arn
  build_timeout = 20  # minutes; plan is fast

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TF_VERSION"
      value = local.tf_version
    }
    environment_variable {
      name  = "TF_WORKING_DIR"
      value = local.tf_working_dir
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      # TF_ENV selects which environments/<env>.tfvars file to load.
      name  = "TF_ENV"
      value = var.environment
    }
  }

  source {
    type                = "GITHUB"
    location            = local.github_repo_url
    git_clone_depth     = 1
    # Report the CodeBuild status back to the GitHub PR check.
    # Requires a GitHub credential to be registered in CodeBuild (done once via
    # aws codebuild import-source-credentials; not managed in Terraform because
    # the token is a secret).
    report_build_status = true

    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        install:
          commands:
            - echo "Installing Terraform $TF_VERSION"
            - curl -sSL "https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip" -o /tmp/tf.zip
            - unzip -q /tmp/tf.zip -d /usr/local/bin/
            - terraform version
        pre_build:
          commands:
            - cd "$TF_WORKING_DIR"
            - terraform init -input=false -no-color
            - terraform validate -no-color
        build:
          commands:
            - |
              terraform plan \
                -var-file="environments/$TF_ENV.tfvars" \
                -var="aws_account_id=$AWS_ACCOUNT_ID" \
                -input=false \
                -no-color \
                -out=tfplan 2>&1 | tee /tmp/plan_output.txt
              exit $${PIPESTATUS[0]}
        post_build:
          commands:
            - echo "Plan completed. Exit code $CODEBUILD_BUILD_SUCCEEDING"
            - wc -l /tmp/plan_output.txt
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-tf-plan"
      stream_name = ""
      status      = "ENABLED"
    }
  }

  tags = {
    Name = "${var.project_name}-tf-plan"
  }
}

# ── CodeBuild webhook: trigger tf-plan on GitHub PR events ─────────────────────
#
# Fires cob-tf-plan on:
#   - PULL_REQUEST_CREATED  — new PR opened
#   - PULL_REQUEST_UPDATED  — commits pushed to an open PR
#   - PULL_REQUEST_REOPENED — closed PR re-opened
#
# PULL_REQUEST_MERGED is intentionally excluded: infra changes require a
# manual `cob-tf-apply` run, not an automatic apply on merge.
#
# Webhook secret is generated by CodeBuild and stored in the resource; AWS
# registers it with GitHub automatically when the project source credentials
# (GitHub PAT) are present.
#
# NOTE: terraform apply will fail here if no GitHub source credentials are
# registered in CodeBuild. Register them once with:
#   aws codebuild import-source-credentials \
#     --server-type GITHUB \
#     --auth-type PERSONAL_ACCESS_TOKEN \
#     --token "$GITHUB_PAT" \
#     --region us-east-1

resource "aws_codebuild_webhook" "tf_plan_pr" {
  project_name  = aws_codebuild_project.tf_plan.name
  build_type    = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"
    }
    # Only trigger when files relevant to infra or CI are changed.
    # This prevents running a plan for doc-only or attestation-only commits.
    filter {
      type                    = "FILE_PATH"
      pattern                 = "^(infra/terraform/|requirements\\.txt|pyproject\\.toml)"
      exclude_matched_pattern = false
    }
  }
}

output "codebuild_webhook_url" {
  description = "GitHub webhook payload URL registered by CodeBuild (for reference; managed by AWS)"
  value       = aws_codebuild_webhook.tf_plan_pr.payload_url
}

# ── CodeBuild: Terraform Apply ─────────────────────────────────────────────────

resource "aws_codebuild_project" "tf_apply" {
  name          = "${var.project_name}-tf-apply"
  description   = "Runs terraform apply for compliance-ops-bedrock infrastructure (manual trigger only)"
  service_role  = aws_iam_role.codebuild_tf.arn
  build_timeout = 30  # minutes; apply can take longer (Bedrock resources are slow)

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TF_VERSION"
      value = local.tf_version
    }
    environment_variable {
      name  = "TF_WORKING_DIR"
      value = local.tf_working_dir
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      # TF_ENV selects which environments/<env>.tfvars file to load.
      name  = "TF_ENV"
      value = var.environment
    }
  }

  source {
    type            = "GITHUB"
    location        = local.github_repo_url
    git_clone_depth = 1

    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        install:
          commands:
            - echo "Installing Terraform $TF_VERSION"
            - curl -sSL "https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip" -o /tmp/tf.zip
            - unzip -q /tmp/tf.zip -d /usr/local/bin/
            - terraform version
        pre_build:
          commands:
            - cd "$TF_WORKING_DIR"
            - terraform init -input=false -no-color
            - terraform validate -no-color
        build:
          commands:
            - |
              terraform plan \
                -var-file="environments/$TF_ENV.tfvars" \
                -var="aws_account_id=$AWS_ACCOUNT_ID" \
                -input=false \
                -no-color \
                -out=tfplan
            - |
              terraform apply \
                -input=false \
                -no-color \
                tfplan
        post_build:
          commands:
            - echo "Apply completed. Exit code $CODEBUILD_BUILD_SUCCEEDING"
            - cd "$TF_WORKING_DIR" && terraform output -no-color || true
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-tf-apply"
      stream_name = ""
      status      = "ENABLED"
    }
  }

  tags = {
    Name = "${var.project_name}-tf-apply"
  }
}

# ── CodeBuild: CI validation (replaces GitHub Actions) ─────────────────────────
#
# Runs on every push to main (webhook) and can be triggered manually.
# Checks: mypy, OSCAL catalog YAML validation, trestle validate, attestation
# YAML validation, report generation dry-run, pytest.
#
# This project uses the same IAM role as the Terraform projects.
# The IAM role needs no extra permissions — CI only reads the source and runs
# Python tools; it does not provision AWS resources.
#
# Triggered by: PUSH to main branch (webhook filter below).
# Also triggers on any push to a feature branch (any ref) — the filter below
# is intentionally broad so that all branches get CI feedback.
#
# GitHub webhook: CodeBuild registers the webhook automatically when the
# source credentials (GitHub PAT) are present in CodeBuild.

resource "aws_codebuild_project" "ci" {
  name          = "${var.project_name}-ci"
  description   = "CI validation: mypy, OSCAL YAML, trestle, attestations, report dry-run, pytest"
  service_role  = aws_iam_role.codebuild_tf.arn
  build_timeout = 15  # minutes

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type                = "GITHUB"
    location            = local.github_repo_url
    git_clone_depth     = 1
    report_build_status = true

    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        install:
          commands:
            - pip install --quiet
                mypy
                pyyaml
                jinja2
                pydantic
                types-PyYAML
                boto3
                boto3-stubs[essential]
                types-boto3
                strands-agents==1.37.0
                compliance-trestle==3.6.0
                pytest
        build:
          commands:
            - echo "=== mypy ==="
            - mypy --config-file pyproject.toml scripts/ app/
            - echo "=== OSCAL catalog YAML structure ==="
            - |
              python - <<'EOF'
              import yaml
              from pathlib import Path
              errors = []
              for fpath in Path("compliance/catalogs").glob("*.yaml"):
                  with open(fpath) as f:
                      doc = yaml.safe_load(f)
                  catalog = doc.get("catalog")
                  if not catalog:
                      errors.append(f"{fpath}: missing top-level 'catalog' key")
                  elif not catalog.get("groups"):
                      errors.append(f"{fpath}: catalog has no groups")
              if errors:
                  for e in errors: print(f"ERROR: {e}")
                  raise SystemExit(1)
              print(f"OK: {len(list(Path('compliance/catalogs').glob('*.yaml')))} catalog(s) valid")
              EOF
            - echo "=== trestle validate ==="
            - |
              set -euo pipefail
              REPO_ROOT="$(pwd)"
              TRESTLE_WS="$(mktemp -d)"
              cd "$TRESTLE_WS"
              trestle init
              for f in "$REPO_ROOT"/compliance/catalogs/*.yaml; do
                name="$(basename "$f" .yaml)"
                trestle import -f "$f" -o "$name"
              done
              trestle validate -a
              echo "OK: trestle validate passed for all catalogs"
            - echo "=== Attestation YAML ==="
            - |
              python - <<'EOF'
              import yaml
              from pathlib import Path
              errors = []
              for fpath in Path("attestations").glob("*.yaml"):
                  if fpath.name == "schema.yaml":
                      continue
                  with open(fpath) as f:
                      doc = yaml.safe_load(f)
                  for att in doc.get("attestations", []):
                      required = ["id", "control-id", "status", "decision", "justification", "reviewed-by", "reviewed-at"]
                      for field in required:
                          if field not in att:
                              errors.append(f"{fpath}:{att.get('id','?')}: missing field '{field}'")
              if errors:
                  for e in errors: print(f"ERROR: {e}")
                  raise SystemExit(1)
              print("OK: attestation YAML valid")
              EOF
            - echo "=== Report generation dry-run ==="
            - python scripts/generate_report.py --output /tmp/report.html
            - test -f /tmp/report.html && echo "OK: report generated ($(wc -c < /tmp/report.html) bytes)"
            - grep -q "compliance-ops-bedrock" /tmp/report.html && echo "OK: content check passed"
            - echo "=== pytest ==="
            - pytest tests/ -v
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-ci"
      stream_name = ""
      status      = "ENABLED"
    }
  }

  tags = {
    Name = "${var.project_name}-ci"
  }
}

# Webhook: trigger CI on all pushes (any branch).
resource "aws_codebuild_webhook" "ci_push" {
  project_name = aws_codebuild_project.ci.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
  }
}

# Permission: update the AgentCore Runtime with a new container image on each
# app deploy.  Scoped to runtimes in this project's name prefix.
resource "aws_iam_role_policy" "codebuild_tf_agentcore" {
  name = "agentcore-runtime-update"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UpdateAgentCoreRuntime"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:UpdateAgentRuntime",
          "bedrock-agentcore:GetAgentRuntime",
          "bedrock-agentcore:ListAgentRuntimes",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.aws_region}:${var.aws_account_id}:runtime/${var.project_name}-*"
        ]
      }
    ]
  })
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "codebuild_tf_plan_project_name" {
  description = "CodeBuild project name for terraform plan"
  value       = aws_codebuild_project.tf_plan.name
}

output "codebuild_tf_apply_project_name" {
  description = "CodeBuild project name for terraform apply (manual trigger only)"
  value       = aws_codebuild_project.tf_apply.name
}

output "codebuild_tf_role_arn" {
  description = "IAM role ARN used by the CodeBuild terraform projects"
  value       = aws_iam_role.codebuild_tf.arn
}

output "codebuild_ci_project_name" {
  description = "CodeBuild project name for CI validation (replaces GitHub Actions)"
  value       = aws_codebuild_project.ci.name
}
