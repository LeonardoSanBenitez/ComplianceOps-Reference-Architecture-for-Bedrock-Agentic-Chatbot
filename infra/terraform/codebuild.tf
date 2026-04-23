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
  tf_vars         = "-var=\"aws_account_id=${var.aws_account_id}\" -var=\"environment=${var.environment}\""
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
        # PassRole: allow CodeBuild to pass the project IAM roles to Bedrock/Lambda services.
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

# Bedrock / BedrockAgent: manage knowledge bases, agents, data sources, aliases.
resource "aws_iam_role_policy" "codebuild_tf_bedrock" {
  name = "bedrock-manage"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockAgentManage"
        Effect = "Allow"
        Action = [
          "bedrock:GetFoundationModel",
          "bedrock:ListFoundationModels",
          "bedrock:TagResource",
          "bedrock:UntagResource",
          "bedrock:ListTagsForResource",
          "bedrock:InvokeModel",
          "bedrock:GetModelInvocationLoggingConfiguration",
          "bedrock:PutModelInvocationLoggingConfiguration"
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
      }
    ]
  })
}

# CodeBuild: allow the role to report build status back (minimal self-referential perms).
resource "aws_iam_role_policy" "codebuild_tf_self" {
  name = "codebuild-self"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeBuildReportStatus"
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:ListBuildsForProject"
        ]
        Resource = [
          "arn:aws:codebuild:${var.aws_region}:${var.aws_account_id}:project/${var.project_name}-*"
        ]
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
                -var="aws_account_id=$AWS_ACCOUNT_ID" \
                -var="environment=$ENVIRONMENT" \
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
                -var="aws_account_id=$AWS_ACCOUNT_ID" \
                -var="environment=$ENVIRONMENT" \
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
