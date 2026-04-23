# ── Lambda: chat endpoint ──────────────────────────────────────────────────────
#
# Deploys the Strands-based compliance chatbot as a Lambda function with a
# Lambda Function URL (no API Gateway — reduces cost and complexity for a demo).
#
# Deployment model:
#   - Docker container image stored in ECR.
#   - The app CodeBuild project (cob-app-deploy) builds the image, pushes to ECR,
#     and updates the Lambda function. Triggered manually or on main branch push.
#
# The function URL is public (no IAM auth) for demo accessibility.
# For real use: add IAM auth or a Cognito authoriser.
#
# Session management: in-process (single instance).
# Scaling note: multiple Lambda instances do not share session state.
# For multi-instance session continuity, externalise to DynamoDB — tracked
# as a known gap in the project roadmap.

locals {
  lambda_function_name = "${var.project_name}-chat-${var.environment}"
  ecr_repo_name        = "${var.project_name}-app-${var.environment}"
}

# ── ECR repository ─────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  name                 = local.ecr_repo_name
  image_tag_mutability = "MUTABLE"  # allows "latest" tag to be overwritten on redeploy

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = {
    Name = local.ecr_repo_name
  }
}

# Lifecycle: keep only the 5 most recent images to limit storage cost.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ── Lambda function (container image) ─────────────────────────────────────────
#
# The Lambda function itself is NOT managed by Terraform. It is created and
# updated by the cob-app-deploy CodeBuild pipeline.
#
# Rationale: Lambda requires an image in a private ECR repository at creation
# time. Terraform cannot provision an ECR image, so the function lifecycle
# belongs to the app pipeline, not to the infrastructure pipeline.
#
# Bootstrap procedure (first-time only):
#   1. terraform apply (this file) — creates ECR repo and IAM roles.
#   2. aws codebuild start-build --project-name cob-app-deploy
#      The buildspec creates the Lambda function + Function URL on first run,
#      then updates it on subsequent runs.
#
# After the first CodeBuild run the function ARN and URL are stable.
# Run: aws lambda get-function-url-config --function-name cob-chat-dev
#      to retrieve the public URL.

# ── IAM: allow CodeBuild to deploy Lambda ─────────────────────────────────────

resource "aws_iam_role_policy" "codebuild_tf_lambda" {
  name = "lambda-deploy"
  role = aws_iam_role.codebuild_tf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaDeployAppFunction"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetFunctionUrlConfig",
          "lambda:ListFunctions",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:CreateFunctionUrlConfig",
          "lambda:UpdateFunctionUrlConfig",
          "lambda:DeleteFunctionUrlConfig",
          "lambda:TagResource",
          "lambda:ListTags"
        ]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.project_name}-*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_tf_ecr" {
  name = "ecr-push"
  role = aws_iam_role.codebuild_tf.id

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
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchDeleteImage",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DeleteLifecyclePolicy",
          "ecr:DeleteRepository",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:GetRepositoryPolicy",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:PutLifecyclePolicy",
          "ecr:SetRepositoryPolicy",
          "ecr:TagResource",
          "ecr:UploadLayerPart"
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.project_name}-*"
        ]
      }
    ]
  })
}

# ── CodeBuild: App deploy pipeline ─────────────────────────────────────────────
#
# Builds the Docker image, pushes to ECR, updates the Lambda function.
# Triggered manually or via GitHub webhook on push to main (separate webhook
# filter from the tf-plan webhook which fires on PR).

resource "aws_codebuild_project" "app_deploy" {
  name          = "${var.project_name}-app-deploy"
  description   = "Builds Docker image and deploys compliance chatbot Lambda"
  service_role  = aws_iam_role.codebuild_tf.arn
  build_timeout = 20  # minutes

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true  # required for Docker builds

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "ECR_REPO"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = local.lambda_function_name
    }
    environment_variable {
      name  = "LAMBDA_ROLE_ARN"
      value = aws_iam_role.lambda_execution.arn
    }
    environment_variable {
      name  = "KNOWLEDGE_BASE_ID"
      value = aws_bedrockagent_knowledge_base.main.id
    }
    environment_variable {
      name  = "AGENT_MODEL_ID"
      value = var.agent_foundation_model_id
    }
  }

  source {
    type            = "GITHUB"
    location        = local.github_repo_url
    git_clone_depth = 1

    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - echo "Logging in to ECR"
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO
            - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-8)
        build:
          commands:
            - echo "Building Docker image"
            - docker build -t $ECR_REPO:$IMAGE_TAG -t $ECR_REPO:latest -f app/Dockerfile .
        post_build:
          commands:
            - echo "Pushing image to ECR"
            - docker push $ECR_REPO:$IMAGE_TAG
            - docker push $ECR_REPO:latest
            - |
              echo "Creating or updating Lambda function $LAMBDA_FUNCTION_NAME"
              if aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_DEFAULT_REGION > /dev/null 2>&1; then
                echo "Function exists; updating code"
                aws lambda update-function-code \
                  --function-name $LAMBDA_FUNCTION_NAME \
                  --image-uri $ECR_REPO:$IMAGE_TAG \
                  --region $AWS_DEFAULT_REGION \
                  --no-cli-pager
              else
                echo "Function does not exist; creating"
                aws lambda create-function \
                  --function-name $LAMBDA_FUNCTION_NAME \
                  --package-type Image \
                  --code ImageUri=$ECR_REPO:$IMAGE_TAG \
                  --role $LAMBDA_ROLE_ARN \
                  --description "Compliance chatbot Lambda (Strands + Bedrock Nova Micro)" \
                  --timeout 60 \
                  --memory-size 512 \
                  --environment "Variables={KNOWLEDGE_BASE_ID=$KNOWLEDGE_BASE_ID,AGENT_MODEL_ID=$AGENT_MODEL_ID,CORS_ORIGIN=*,LOG_LEVEL=INFO}" \
                  --region $AWS_DEFAULT_REGION \
                  --no-cli-pager
                echo "Waiting for function to become active"
                aws lambda wait function-active-v2 --function-name $LAMBDA_FUNCTION_NAME --region $AWS_DEFAULT_REGION
                echo "Creating Function URL"
                aws lambda create-function-url-config \
                  --function-name $LAMBDA_FUNCTION_NAME \
                  --auth-type NONE \
                  --cors 'AllowOrigins=["*"]' \
                  --region $AWS_DEFAULT_REGION \
                  --no-cli-pager || echo "Function URL may already exist"
                echo "Adding public resource-based policy for Function URL (InvokeFunctionUrl)"
                aws lambda add-permission \
                  --function-name $LAMBDA_FUNCTION_NAME \
                  --statement-id FunctionURLAllowPublicAccess \
                  --action lambda:InvokeFunctionUrl \
                  --principal "*" \
                  --function-url-auth-type NONE \
                  --region $AWS_DEFAULT_REGION \
                  --no-cli-pager || echo "Permission may already exist"
                echo "Adding public resource-based policy (InvokeFunction, required since Oct 2025)"
                aws lambda add-permission \
                  --function-name $LAMBDA_FUNCTION_NAME \
                  --statement-id AllowPublicInvoke \
                  --action lambda:InvokeFunction \
                  --principal "*" \
                  --region $AWS_DEFAULT_REGION \
                  --no-cli-pager || echo "Permission may already exist"
              fi
            - echo "Deploy complete. Image tag $IMAGE_TAG"
            - aws lambda get-function-url-config --function-name $LAMBDA_FUNCTION_NAME --region $AWS_DEFAULT_REGION --no-cli-pager || true
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-app-deploy"
      stream_name = ""
      status      = "ENABLED"
    }
  }

  tags = {
    Name = "${var.project_name}-app-deploy"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "lambda_function_name" {
  description = "Name of the compliance chatbot Lambda function (created by cob-app-deploy CodeBuild)"
  value       = local.lambda_function_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the app container image"
  value       = aws_ecr_repository.app.repository_url
}

output "app_deploy_codebuild_project" {
  description = "CodeBuild project name for app deploy (manual trigger)"
  value       = aws_codebuild_project.app_deploy.name
}
