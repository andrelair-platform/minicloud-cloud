# AWS external heartbeat + status page (ADR-0002, Anchor 1) — the platform's EXTERNAL observability
# vantage, in a failure domain independent of the home site AND of the OCI DR node. A scheduled
# Lambda probes the public URLs, stores status in DynamoDB, emails on UP<->DOWN transitions, and a
# public Function URL renders the status page — so a total-site/power/ISP outage is detected and the
# status page stays up when all six laptops are down. Read-only observer, zero coupling to the cluster.
#
# ALWAYS-FREE by construction (per cloud-adoption.md 3-tier model — this is the PERMANENT tier):
#   Lambda 1M req/mo (5-min schedule ≈ 8.6k/mo) · DynamoDB PROVISIONED 1/1 (inside the 25 RCU/WCU
#   always-free, NOT on-demand which has no perpetual free req allotment) · SNS 1k emails/mo.
# Refines ADR-0002's "S3 + CloudFront" to a Lambda FUNCTION URL: strictly always-free (S3's 5 GB is
# only 12-month) and lower surface. A custom domain (status.devandre.sbs via CloudFront + ACM) is a
# deferred, optional enhancement — the Function URL already satisfies the "survives site loss" goal.
#
# GATED + INERT: enable_heartbeat=false (default) → count=0 → no resources, existing AWS/Azure/OCI
# plans unaffected, CI (tofu fmt/validate/tflint) passes. Enable + `tofu apply` on the controller
# (AWS creds from Vault via scripts/load-env.sh). Confirm the SNS email subscription after apply.

variable "enable_heartbeat" {
  type        = bool
  default     = false
  description = "Provision the external heartbeat + status page. false = inert (count 0)."
}

variable "heartbeat_alert_email" {
  type        = string
  default     = "kanmegnea@gmail.com"
  description = "Email for UP<->DOWN transition alerts (confirm the SNS subscription after apply)."
}

variable "heartbeat_schedule" {
  type        = string
  default     = "rate(5 minutes)"
  description = "EventBridge probe cadence."
}

variable "heartbeat_probe_timeout" {
  type        = number
  default     = 8
  description = "Per-target HTTP timeout (seconds)."
}

# Public URLs that represent 'the platform is up' (through Cloudflare -> tunnel -> ingress -> app).
# SSO-gated apps return 302/401 = still 'up' (the external path answered). Tune freely.
variable "heartbeat_targets" {
  type = list(object({
    name = string
    url  = string
  }))
  default = [
    { name = "ktayl-solution", url = "https://ktayl.devandre.sbs" },
    { name = "argocd", url = "https://argocd.devandre.sbs" },
    { name = "grafana", url = "https://grafana.devandre.sbs" },
    { name = "harbor", url = "https://harbor.devandre.sbs" },
  ]
  description = "Targets probed from outside. Whitelisted name/status only ever reach the public page."
}

locals {
  hb_enabled = var.enable_heartbeat ? 1 : 0
  hb_name    = "minicloud-heartbeat"
}

data "archive_file" "heartbeat" {
  count       = local.hb_enabled
  type        = "zip"
  source_file = "${path.module}/lambda/heartbeat/handler.py"
  output_path = "${path.module}/.build/heartbeat.zip"
}

# --- state (always-free provisioned 1/1) ---
resource "aws_dynamodb_table" "heartbeat" {
  count          = local.hb_enabled
  name           = "minicloud-status"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "target"

  attribute {
    name = "target"
    type = "S"
  }
}

# --- transition alerts ---
resource "aws_sns_topic" "heartbeat" {
  count = local.hb_enabled
  name  = "${local.hb_name}-alerts"
}

resource "aws_sns_topic_subscription" "heartbeat_email" {
  count     = local.hb_enabled
  topic_arn = aws_sns_topic.heartbeat[0].arn
  protocol  = "email"
  endpoint  = var.heartbeat_alert_email
}

# --- least-privilege role ---
resource "aws_iam_role" "heartbeat" {
  count = local.hb_enabled
  name  = "${local.hb_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "heartbeat" {
  count = local.hb_enabled
  name  = "${local.hb_name}-policy"
  role  = aws_iam_role.heartbeat[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.heartbeat[0].arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.heartbeat[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# --- the function (probe + render, one file, two triggers) ---
resource "aws_lambda_function" "heartbeat" {
  count            = local.hb_enabled
  function_name    = local.hb_name
  role             = aws_iam_role.heartbeat[0].arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.heartbeat[0].output_path
  source_code_hash = data.archive_file.heartbeat[0].output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      STATUS_TABLE  = aws_dynamodb_table.heartbeat[0].name
      SNS_TOPIC_ARN = aws_sns_topic.heartbeat[0].arn
      TARGETS       = jsonencode(var.heartbeat_targets)
      PROBE_TIMEOUT = tostring(var.heartbeat_probe_timeout)
    }
  }
}

# public status page (no custom domain yet — the *.lambda-url.<region>.on.aws host survives site loss)
resource "aws_lambda_function_url" "heartbeat" {
  count              = local.hb_enabled
  function_name      = aws_lambda_function.heartbeat[0].function_name
  authorization_type = "NONE"
}

# --- 5-min schedule -> probe ---
resource "aws_cloudwatch_event_rule" "heartbeat" {
  count               = local.hb_enabled
  name                = "${local.hb_name}-schedule"
  schedule_expression = var.heartbeat_schedule
}

resource "aws_cloudwatch_event_target" "heartbeat" {
  count = local.hb_enabled
  rule  = aws_cloudwatch_event_rule.heartbeat[0].name
  arn   = aws_lambda_function.heartbeat[0].arn
}

resource "aws_lambda_permission" "heartbeat_events" {
  count         = local.hb_enabled
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat[0].arn
}

output "heartbeat_status_url" {
  value       = local.hb_enabled == 1 ? aws_lambda_function_url.heartbeat[0].function_url : null
  description = "Public status page URL (append status.json for machine-readable output)."
}
