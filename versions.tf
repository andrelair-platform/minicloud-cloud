# OpenTofu + provider versions for the minicloud CLOUD IaC.
# (On-prem/MAAS stays in minicloud-opentofu. This repo = public-cloud only.)
# The top-level block stays `terraform {}` — OpenTofu keeps it for compatibility.
terraform {
  required_version = ">= 1.8.0" # OpenTofu (its version track differs from Terraform's)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
