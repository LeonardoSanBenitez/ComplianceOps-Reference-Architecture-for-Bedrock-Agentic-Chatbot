# ── S3 buckets ─────────────────────────────────────────────────────────────────
#
# Three buckets:
#   1. knowledge-base-source  — stores the documents indexed by Bedrock KB
#   2. conversation-logs      — stores conversation transcripts (GDPR scope)
#   3. report                 — public static website hosting for compliance report
#
# Buckets 1 and 2 are private with SSE-KMS, versioning, and access logging.
# Bucket 3 is intentionally public (static website); default SSE-S3 (no CMK needed
# on a public bucket). All three use the newer BucketOwnerEnforced ownership model.
#
# Note on ACLs: all buckets use the newer S3 ownership controls model
# (BucketOwnerEnforced) and disable ACLs. All access is via bucket policies
# and IAM. This is the recommended posture for new buckets.

locals {
  kb_source_bucket_name   = "${var.project_name}-kb-source-${var.environment}"
  conv_log_bucket_name    = "${var.project_name}-conv-logs-${var.environment}"
  report_bucket_name      = "${var.project_name}-report-${var.environment}"
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
      },
      # S3 Vectors asynchronous indexing service requires KMS access.
      # Reference: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-vectors-encryption.html
      {
        Sid    = "AllowS3VectorsIndexing"
        Effect = "Allow"
        Principal = {
          Service = "indexing.s3vectors.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
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

# ── Report bucket (public static website) ─────────────────────────────────────
#
# Hosts the generated HTML compliance report.
# This bucket is intentionally public — it contains no personal data or secrets.
# SSE-S3 (default AES-256) is used; the project CMK is not needed on public content.

resource "aws_s3_bucket" "report" {
  bucket = local.report_bucket_name

  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_ownership_controls" "report" {
  bucket = aws_s3_bucket.report.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# All four public access block fields set to false — this bucket is intentionally public.
resource "aws_s3_bucket_public_access_block" "report" {
  bucket                  = aws_s3_bucket.report.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "report" {
  bucket = aws_s3_bucket.report.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"  # default SSE-S3; no CMK needed on a public bucket
    }
  }
}

resource "aws_s3_bucket_website_configuration" "report" {
  bucket = aws_s3_bucket.report.id

  index_document {
    suffix = "index.html"
  }
}

# Bucket policy: allow public read of all objects.
resource "aws_s3_bucket_policy" "report_public_read" {
  bucket = aws_s3_bucket.report.id

  # Depends on the public access block being applied first.
  depends_on = [aws_s3_bucket_public_access_block.report]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.report.arn}/*"
      }
    ]
  })
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "report_bucket_name" {
  description = "Name of the S3 bucket hosting the public compliance report"
  value       = aws_s3_bucket.report.id
}

output "report_bucket_url" {
  description = "S3 static website URL for the compliance report"
  value       = "http://${aws_s3_bucket.report.bucket}.s3-website-${var.aws_region}.amazonaws.com"
}
