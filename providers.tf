# Provider configuration.
# Credentials are NEVER committed — they come from the environment, sourced from
# Vault (secret/platform/cloud-providers) at run time:
#   AWS   → AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (scoped IAM user — story #299)
#   Azure → ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
#           (Service Principal — story #299)

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project   = "minicloud"
      managedby = "terraform"
      repo      = "minicloud-terraform"
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id / tenant_id / client_id come from ARM_* env vars (Vault-sourced).
}
