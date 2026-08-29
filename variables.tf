variable "aws_region" {
  description = "AWS region for cloud resources. EU for data residency (DORA/ACPR/GDPR). Bedrock model availability varies by region — confirm per model in story #303 (E1)."
  type        = string
  default     = "eu-west-1" # Ireland — broadest Bedrock coverage in the EU
}

variable "budget_alert_email" {
  description = "Email that receives AWS Budgets / Azure Cost alerts (story #300)."
  type        = string
  default     = "kanmegnea@gmail.com"
}

variable "monthly_budget_eur" {
  description = "Per-provider soft cap; alert fires at this amount (story #300)."
  type        = number
  default     = 8
}
