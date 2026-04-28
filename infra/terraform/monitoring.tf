# ── Security alerting: GuardDuty MEDIUM+ findings -> SNS ──────────────────────
#
# Implements the alert routing referenced in attestations gdpr-5-1-f,
# gdpr-32, and gdpr-33:
#   GuardDuty finding (severity >= 4.0 = MEDIUM) -> EventBridge rule
#   -> SNS topic -> email subscription.
#
# Severity thresholds:
#   LOW    0.1 – 3.9   (review on next business day)
#   MEDIUM 4.0 – 6.9   (trigger this alert)
#   HIGH   7.0 – 8.9   (also captured — higher value satisfies >=4 condition)
#   CRITICAL 9.0+      (also captured)
#
# The SNS subscription will be in PendingConfirmation state until the
# email address owner clicks the confirmation link sent by AWS.

# ── SNS topic ─────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "security_alerts" {
  name = "${var.project_name}-security-alerts-${var.environment}"

  tags = {
    Name = "${var.project_name}-security-alerts-${var.environment}"
  }
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow EventBridge (events.amazonaws.com) to publish to this SNS topic.
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

# ── EventBridge rule: GuardDuty findings severity >= 4 ────────────────────────

resource "aws_cloudwatch_event_rule" "guardduty_medium_plus" {
  name        = "${var.project_name}-guardduty-medium-plus-${var.environment}"
  description = "Matches GuardDuty findings with severity 4.0 (MEDIUM) and above"

  # EventBridge content-based filtering: the numeric severity field must be >= 4.
  # GuardDuty finding severity is a float; EventBridge supports numeric-range matching.
  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [
        { numeric = [">=", 4] }
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_medium_plus.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "security_alerts_topic_arn" {
  description = "ARN of the SNS topic for GuardDuty security alerts"
  value       = aws_sns_topic.security_alerts.arn
}
