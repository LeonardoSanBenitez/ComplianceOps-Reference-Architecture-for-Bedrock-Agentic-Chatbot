# ── DynamoDB table: conversation sessions ─────────────────────────────────────
#
# Stores per-session conversation state for the Bedrock Agent.
# Schema design:
#   PK: session_id (String)  — Bedrock session UUID
#   SK: created_at (String)  — ISO 8601, for ordering within session
#   Attributes:
#     user_id       — pseudonymised user identifier (SHA-256 of real ID)
#     ttl_epoch     — Unix timestamp for DynamoDB TTL (GDPR Art. 5(1)(e))
#
# TTL: records expire automatically after conversation_log_retention_days.
# This satisfies the GDPR storage limitation requirement without requiring
# a separate cleanup job.
#
# On-demand billing: appropriate for unpredictable demo traffic.
# Switch to provisioned if usage becomes predictable and cost matters.

resource "aws_dynamodb_table" "conversation_sessions" {
  name         = "${var.project_name}-sessions-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "created_at"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # TTL configuration (GDPR Art. 5(1)(e) — storage limitation)
  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}
