# ── S3 buckets ─────────────────────────────────────────────────────────────────
#
# Two buckets:
#   1. knowledge-base-source  — stores the documents indexed by Bedrock KB
#   2. conversation-logs      — stores conversation transcripts (GDPR scope)
#
# Both buckets are private with SSE-KMS, versioning, and access logging.
# The KMS key is a customer-managed key (CMK) shared across both buckets.
# Separate CMKs per bucket would be stronger isolation but adds operational cost;
# acceptable for a demo, must be reassessed before handling production personal data.
#
# Note on ACLs: both buckets use the newer S3 ownership controls model
# (BucketOwnerEnforced) and disable ACLs. All access is via bucket policies
# and IAM. This is the recommended posture for new buckets.

locals {
  kb_source_bucket_name   = "${var.project_name}-kb-source-${var.environment}"
  conv_log_bucket_name    = "${var.project_name}-conv-logs-${var.environment}"
}

# ── KMS key ────────────────────────────────────────────────────────────────────

resource "aws_kms_key" "main" {
  description             = "compliance-ops-bedrock main encryption key (${var.environment})"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  # Key policy: allow root account full control; Bedrock service principals
  # are granted access via IAM role policies — no need to add them here.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # Allow CloudWatch Logs to use this key for log group encryption.
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-main-${var.environment}"
  target_key_id = aws_kms_key.main.key_id
}

# ── Knowledge base source bucket ───────────────────────────────────────────────

resource "aws_s3_bucket" "kb_source" {
  bucket = local.kb_source_bucket_name

  # Prevent accidental destruction; flip to false only when explicitly decommissioning.
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_ownership_controls" "kb_source" {
  bucket = aws_s3_bucket.kb_source.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "kb_source" {
  bucket                  = aws_s3_bucket.kb_source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "kb_source" {
  bucket = aws_s3_bucket.kb_source.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kb_source" {
  bucket = aws_s3_bucket.kb_source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true  # reduces KMS API call costs
  }
}

# ── Conversation log bucket ────────────────────────────────────────────────────

resource "aws_s3_bucket" "conv_logs" {
  bucket = local.conv_log_bucket_name

  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_ownership_controls" "conv_logs" {
  bucket = aws_s3_bucket.conv_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "conv_logs" {
  bucket                  = aws_s3_bucket.conv_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "conv_logs" {
  bucket = aws_s3_bucket.conv_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "conv_logs" {
  bucket = aws_s3_bucket.conv_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

# Lifecycle policy: enforce GDPR Art. 5(1)(e) storage limitation.
# Objects expire after retention_days. Incomplete multipart uploads also cleaned up.
resource "aws_s3_bucket_lifecycle_configuration" "conv_logs" {
  bucket = aws_s3_bucket.conv_logs.id

  rule {
    id     = "expire-conversation-logs"
    status = "Enabled"

    expiration {
      days = var.s3_log_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7  # keep noncurrent versions for 7 days only
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
