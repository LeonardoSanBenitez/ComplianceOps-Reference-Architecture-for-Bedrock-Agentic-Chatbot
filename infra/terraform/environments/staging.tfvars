# ── Staging environment variable overrides ─────────────────────────────────────
# Apply: terraform apply -var-file=environments/staging.tfvars -var="aws_account_id=<ID>"
environment            = "staging"
project_name           = "cob"
aws_region             = "us-east-1"
s3_log_expiration_days = 60
alert_email            = "lsbenitezpereira@gmail.com"
