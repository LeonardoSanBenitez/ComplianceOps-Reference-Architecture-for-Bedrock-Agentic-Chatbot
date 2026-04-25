output "bedrock_kb_id" {
  description = "Bedrock Knowledge Base ID"
  value       = aws_bedrockagent_knowledge_base.main.id
}

output "bedrock_kb_data_source_id" {
  description = "Bedrock Knowledge Base data source ID — required for start-ingestion-job calls"
  value       = aws_bedrockagent_data_source.readme.data_source_id
}

output "kb_source_bucket_name" {
  description = "S3 bucket name for KB source documents — upload docs here before syncing the KB"
  value       = aws_s3_bucket.kb_source.bucket
}

output "conv_log_bucket_name" {
  description = "S3 bucket name for conversation logs"
  value       = aws_s3_bucket.conv_logs.bucket
}

output "dynamodb_sessions_table_name" {
  description = "DynamoDB table name for conversation sessions"
  value       = aws_dynamodb_table.conversation_sessions.name
}

output "kms_key_arn" {
  description = "ARN of the main KMS key used for encryption at rest"
  value       = aws_kms_key.main.arn
}

output "bedrock_kb_role_arn" {
  description = "IAM role ARN for Bedrock Knowledge Base service"
  value       = aws_iam_role.bedrock_kb.arn
}

output "lambda_execution_role_arn" {
  description = "IAM role ARN for Lambda functions (action groups)"
  value       = aws_iam_role.lambda_execution.arn
}

output "cost_estimate_note" {
  description = "Monthly cost estimate for demo usage"
  value       = <<-EOT
    Estimated monthly cost at demo scale (100 requests/month):
      Nova Micro inference:   < $0.02 USD
      Titan Embed inference:  < $0.01 USD
      S3 Vectors storage:     < $0.01 USD
      S3 buckets:             < $0.01 USD
      DynamoDB (on-demand):   < $0.01 USD
      KMS API calls:          < $0.01 USD
      TOTAL:                  < $0.10 USD/month
    At 10,000 requests/month: still < $2 USD/month.
    Budget limit: $11/month (account-wide). This deployment leaves > $10 headroom.
    Note: costs increase linearly with usage. Monitor with Cost Explorer.
  EOT
}
