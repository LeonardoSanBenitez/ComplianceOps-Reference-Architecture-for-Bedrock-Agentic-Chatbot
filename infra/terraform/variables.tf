variable "aws_region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev / staging / prod)"
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID (used in IAM policy ARN conditions)"
}

variable "project_name" {
  type        = string
  description = "Project name slug; used as a prefix for all resource names"
  default     = "cob"  # compliance-ops-bedrock, abbreviated to stay under name limits
}

# ── Bedrock model configuration ────────────────────────────────────────────────

variable "agent_foundation_model_id" {
  type        = string
  description = "Foundation model ID for the Strands agent (Lambda). Injected as AGENT_MODEL_ID env var."
  # Amazon Nova Micro — lowest cost on-demand text model, sufficient for demo.
  # To switch model: change this value only; IAM policy references this variable.
  default     = "amazon.nova-micro-v1:0"
}

variable "embedding_model_id" {
  type        = string
  description = "Foundation model ID for Knowledge Base embeddings"
  # Titan Text Embeddings V2 — 1024-dimensional, on-demand, cost-effective.
  default     = "amazon.titan-embed-text-v2:0"
}

# ── Retention / lifecycle ──────────────────────────────────────────────────────

variable "conversation_log_retention_days" {
  type        = number
  description = "DynamoDB TTL in days for conversation logs (GDPR Art. 5(1)(e))"
  default     = 30

  validation {
    condition     = var.conversation_log_retention_days >= 7 && var.conversation_log_retention_days <= 365
    error_message = "conversation_log_retention_days must be between 7 and 365"
  }
}

variable "s3_log_expiration_days" {
  type        = number
  description = "S3 lifecycle expiration for conversation log objects"
  default     = 30
}
