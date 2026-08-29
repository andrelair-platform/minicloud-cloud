# Terraform + provider versions for the minicloud CLOUD IaC.
# (On-prem/MAAS stays in minicloud-opentofu. This repo = public-cloud only.)
terraform {
  required_version = ">= 1.9.0"

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
