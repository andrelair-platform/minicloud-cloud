# Budget guardrails (story #300) — GLOBAL per provider.
# These cap the TOTAL account/subscription spend (AI tokens + Lightsail + storage
# + everything) — the real "no surprises" safety net, matching the ~€15/month
# per-provider principle. Creating budgets is free; alerts go to email.
# (An AI-service-scoped sub-budget can be added later for granular Bedrock/Azure
#  OpenAI visibility — this global one is the essential guardrail.)

locals {
  budget_alert_email = "kanmegnea@gmail.com"
  monthly_budget     = 15
}

# ---- AWS: account-wide monthly cost budget ----
resource "aws_budgets_budget" "monthly" {
  name         = "minicloud-monthly"
  budget_type  = "COST"
  limit_amount = tostring(local.monthly_budget)
  limit_unit   = "USD" # account billing currency (personal accounts default USD; ~€15)
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [local.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [local.budget_alert_email]
  }
}

# ---- Azure: subscription-wide monthly budget ----
data "azurerm_subscription" "current" {}

resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "minicloud-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = local.monthly_budget
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-08-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [local.budget_alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [local.budget_alert_email]
  }
}
