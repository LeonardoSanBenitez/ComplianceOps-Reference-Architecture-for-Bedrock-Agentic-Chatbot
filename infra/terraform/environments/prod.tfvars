# ── Production environment variable overrides ───────────────────────────────────
# Apply: terraform apply -var-file=environments/prod.tfvars -var="aws_account_id=<ID>"
environment            = "prod"
project_name           = "cob"
aws_region             = "us-east-1"
s3_log_expiration_days = 90
alert_email            = "lsbenitezpereira@gmail.com"
