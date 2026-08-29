variable "aws_region" {
  description = "AWS region for cloud resources. EU for data residency (DORA/ACPR/GDPR). Bedrock model availability varies by region — confirm per model in story #303 (E1)."
  type        = string
  default     = "eu-west-1" # Ireland — broadest Bedrock coverage in the EU
}

# Budget variables (budget_alert_email, monthly_budget_eur) are added in story
# #300 together with the AWS Budgets / Azure Cost resources that consume them —
# tflint flags unused declarations, so they're intentionally not declared yet.
