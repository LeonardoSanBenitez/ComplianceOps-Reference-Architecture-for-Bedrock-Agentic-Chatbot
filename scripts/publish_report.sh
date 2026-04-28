#!/usr/bin/env bash
# publish_report.sh — generate the compliance report and publish it to S3.
#
# Usage:
#   ./scripts/publish_report.sh [BUCKET_NAME]
#
# If BUCKET_NAME is not provided the script attempts to read it from
# terraform output (requires terraform to be initialised and applied).
#
# Prerequisites:
#   - AWS credentials configured (env vars or IAM role)
#   - Python 3.11+ with pyyaml and jinja2 installed
#   - aws CLI installed and in PATH
#   - Terraform installed (only needed when no bucket arg is provided)
#
# The published URL is printed at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="$REPO_ROOT/report"
REPORT_FILE="$REPORT_DIR/index.html"
TF_DIR="$REPO_ROOT/infra/terraform"

# ── Resolve bucket name ────────────────────────────────────────────────────────

if [ -n "${1:-}" ]; then
  BUCKET_NAME="$1"
  echo "Using provided bucket: $BUCKET_NAME"
else
  echo "No bucket name provided; reading from terraform output..."
  BUCKET_NAME="$(cd "$TF_DIR" && terraform output -raw report_bucket_name)"
  echo "Resolved bucket from terraform: $BUCKET_NAME"
fi

if [ -z "$BUCKET_NAME" ]; then
  echo "ERROR: could not determine report bucket name" >&2
  exit 1
fi

# ── Generate report ────────────────────────────────────────────────────────────

echo "Generating compliance report..."
python "$REPO_ROOT/scripts/generate_report.py" --output "$REPORT_FILE"

if [ ! -f "$REPORT_FILE" ]; then
  echo "ERROR: report file was not generated at $REPORT_FILE" >&2
  exit 1
fi

echo "Report generated: $(wc -c < "$REPORT_FILE") bytes"

# ── Publish to S3 ─────────────────────────────────────────────────────────────

echo "Publishing to s3://$BUCKET_NAME/index.html ..."
aws s3 cp "$REPORT_FILE" "s3://$BUCKET_NAME/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache"

# Derive the website URL (us-east-1 uses a different hostname pattern).
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
if [ "$AWS_REGION" = "us-east-1" ]; then
  REPORT_URL="http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com"
else
  REPORT_URL="http://$BUCKET_NAME.s3-website-$AWS_REGION.amazonaws.com"
fi

echo ""
echo "Published: $REPORT_URL"
