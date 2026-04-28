# ── Dev environment variable overrides ─────────────────────────────────────────
# Apply: terraform apply -var-file=environments/dev.tfvars -var="aws_account_id=<ID>"
environment            = "dev"
project_name           = "cob"
aws_region             = "us-east-1"
s3_log_expiration_days = 30
alert_email            = "lsbenitezpereira@gmail.com"
