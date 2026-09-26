# Education subscription budget (acct 3) — the Azure Education account is a SEPARATE
# subscription/tenant from the PAYG one that budgets.tf covers, so it needs its OWN alert.
# The $100 credit can't overshoot into a bank account, but this is the tripwire that tells
# you the credit is DRAINING too fast (a runaway burst experiment) — a month over ~the
# $100/12 ≈ $8/mo burn rate means something is billing harder than "burst fuel".
#
# GATED + INERT until the owner enables it: set TF_VAR_azure_education_subscription_id
# (+ ARM_EDU_* creds via scripts/load-env.sh ← Vault secret/platform/cloud-providers).
# While empty → count=0, the aliased provider is never used, existing PAYG/AWS/OCI plans
# are unaffected. CI (tofu fmt/validate/tflint, no auth) passes inert.
#
# See .claude/rules/cloud-adoption.md (*Our accounts*) — Education is burst-fuel-only and
# MUST be pinned to this subscription id, never azurerm_subscription.current (that = PAYG).

variable "azure_education_subscription_id" {
  type        = string
  default     = ""
  description = "Azure Education subscription id (acct 3). Empty = budget disabled (inert)."
}

variable "azure_education_tenant_id" {
  type        = string
  default     = ""
  description = "Azure Education tenant id (school AAD — usually different from the PAYG tenant)."
}

variable "azure_education_client_id" {
  type        = string
  default     = ""
  description = "Service-principal client id for the Education subscription (Vault; env ARM_EDU_CLIENT_ID)."
}

variable "azure_education_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Service-principal secret for the Education subscription (Vault; env ARM_EDU_CLIENT_SECRET)."
}

locals {
  # ~ the $100/12 ≈ $8/mo burn rate; a month over this = burning credit too fast.
  azure_edu_enabled       = var.azure_education_subscription_id != "" ? 1 : 0
  azure_edu_monthly_alert = 10
}

# Separate provider — Education is its own subscription/tenant with its own SP. Creds come
# from TF_VAR_azure_education_* (Vault-sourced env), never committed. Only instantiated when
# a resource references it (count>0), so it stays inert while the subscription id is empty.
provider "azurerm" {
  alias           = "education"
  subscription_id = var.azure_education_subscription_id
  tenant_id       = var.azure_education_tenant_id
  client_id       = var.azure_education_client_id
  client_secret   = var.azure_education_client_secret
  features {}
}

resource "azurerm_consumption_budget_subscription" "education" {
  count           = local.azure_edu_enabled
  provider        = azurerm.education
  name            = "minicloud-education-monthly"
  subscription_id = "/subscriptions/${var.azure_education_subscription_id}"
  amount          = local.azure_edu_monthly_alert
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-10-01T00:00:00Z"
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
