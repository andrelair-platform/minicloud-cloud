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

# OCI — API-key auth; all values come from TF_VAR_oci_* env vars, which
# scripts/load-env.sh exports from Vault secret/platform/oci at run time.
provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  private_key  = var.oci_private_key
  region       = var.oci_region
}
