# Cost Estimate — compliance-ops-bedrock

**Before running `terraform apply`, review this document.**  
Last updated: 2026-04-23 | Region: us-east-1 | Account budget: $11/month

---

## Summary

| Scenario | Estimated monthly cost |
|----------|----------------------|
| Idle (no requests) | ~$0.09/month |
| Demo (100 requests/month) | ~$0.12/month |
| Active (10,000 requests/month) | ~$1.50/month |
| Budget limit (account-wide) | $11.00/month |

The deployment is safe within the $11/month budget at all realistic demo usage levels.

---

## Per-Service Breakdown

### AWS Bedrock — Nova Micro inference (agent orchestration)
- Model: `amazon.nova-micro-v1:0`
- Pricing: $0.000035 / 1K input tokens, $0.00014 / 1K output tokens (on-demand, us-east-1)
- Typical demo request: ~1,000 input tokens + ~300 output tokens
- 100 requests/month: (100 × 1 × $0.035) + (100 × 0.3 × $0.14) = $0.0035 + $0.0042 ≈ **< $0.01/month**
- 10,000 requests/month: ≈ **$0.77/month**

### AWS Bedrock — Titan Embed Text V2 (knowledge base ingestion)
- Model: `amazon.titan-embed-text-v2:0`
- Pricing: $0.00002 / 1K tokens (on-demand)
- Ingestion runs at KB sync time, not per user query
- README (~5K tokens) + catalogs (~10K tokens) = ~15K tokens per full re-ingestion
- Monthly syncs (assuming 10): 10 × 15K × $0.00002 = **< $0.01/month**

### Amazon S3 Vectors — vector storage
- Pricing: $0.024 / GB-month (vectors stored), $0.00025 / 1K query operations
- Stored vectors: ~15K tokens → ~200 chunks × 1024 floats × 4 bytes ≈ 0.8 MB
- Storage cost: 0.0008 GB × $0.024 = **< $0.01/month**
- 100 queries/month: 100 × $0.00000025 = **negligible**

### Amazon S3 — KB source bucket + conversation log bucket
- Pricing: $0.023 / GB-month (Standard); free tier: 5 GB first 12 months
- KB source content: < 1 MB (README + compliance docs)
- Conversation logs (100 requests × ~2KB): < 0.2 MB
- **< $0.01/month** (likely within free tier)

### Amazon DynamoDB — conversation sessions table
- Billing mode: PAY_PER_REQUEST
- Free tier: 25 GB storage, 2.5M read/write requests per month (always free)
- 100 sessions/month: well within free tier
- **$0.00/month**

### AWS KMS — customer-managed key
- Pricing: $1.00/month per CMK + $0.03 / 10K API calls
- 1 CMK shared across all resources: **$1.00/month base cost**
- API calls at demo volume: < 1K/month = **< $0.01/month**
- **Total KMS: ~$1.00/month**

  > **Note:** KMS is the dominant cost at low usage. At idle, total monthly spend is
  > ~$1.00 (just the CMK). This is well within the $11/month budget.
  > If even this cost is a concern, switch KMS encryption to `aws:kms` with
  > the AWS-managed key (remove the `aws_kms_key` resource and reference
  > `alias/aws/s3` and `alias/aws/dynamodb`). This reduces costs to near $0
  > but gives less control over key rotation and access auditing.

### Bedrock Agent + Knowledge Base — service fees
- Bedrock Agents: no per-agent fee; charges are per invocation (inference tokens only)
- Knowledge Base: no per-KB fee; charges are per sync (embedding tokens) and per retrieval
- **$0.00 base cost**

---

## Total Estimates

| Component | Idle | 100 req/mo | 10K req/mo |
|-----------|------|------------|------------|
| Nova Micro inference | $0.00 | $0.01 | $0.77 |
| Titan Embed (syncs) | $0.00 | $0.00 | $0.01 |
| S3 Vectors | $0.00 | $0.00 | $0.01 |
| S3 buckets | $0.00 | $0.00 | $0.01 |
| DynamoDB | $0.00 | $0.00 | $0.00 |
| KMS (1 CMK) | $1.00 | $1.00 | $1.00 |
| **TOTAL** | **~$1.00** | **~$1.02** | **~$1.80** |

Budget headroom at 10K req/mo: **$11.00 - $1.80 = $9.20 remaining**

---

## Cost Controls Already in Place

1. **Nova Micro** is the cheapest Nova model; costs are ~10x lower than Nova Lite.
2. **S3 Vectors** replaces OpenSearch Serverless (minimum ~$175/month) — critical cost decision.
3. **DynamoDB PAY_PER_REQUEST** with free tier absorbs demo traffic.
4. **S3 log lifecycle** (30-day expiration) prevents unbounded storage growth.
5. **AWS Budget alarm** at $11/month (account-wide) will alert before overspend.

---

## Deployment Pre-Check

Before `terraform apply`:

1. Confirm Terraform AWS provider version >= 6.27.0 is available locally.
2. Confirm Bedrock model access is enabled in the AWS Console:
   - `amazon.nova-micro-v1:0` — verify in Bedrock > Model access
   - `amazon.titan-embed-text-v2:0` — verify in Bedrock > Model access
3. Review the outputs:
   ```bash
   cd infra/terraform
   terraform init
   terraform plan -var="aws_account_id=725533536670"
   ```
4. Apply:
   ```bash
   terraform apply -var="aws_account_id=725533536670"
   ```
5. After apply, upload KB source documents:
   ```bash
   aws s3 cp README.md s3://$(terraform output -raw kb_source_bucket_name)/
   aws s3 cp compliance/ s3://$(terraform output -raw kb_source_bucket_name)/compliance/ --recursive
   ```
6. Trigger initial KB sync via AWS Console or CLI:
   ```bash
   aws bedrock-agent start-ingestion-job \
     --knowledge-base-id $(terraform output -raw bedrock_kb_id) \
     --data-source-id <DATA_SOURCE_ID>
   ```

---

## Cost Monitoring

- CloudWatch dashboard `zoo-ops-health` shows account-wide metrics.
- AWS Cost Explorer: filter by `Project=compliance-ops-bedrock` tag.
- Budget alert at $11/month is account-wide (SNS: zoo-security-alerts).
- **Recommend:** add a project-level budget alert at $3/month for this project specifically.
