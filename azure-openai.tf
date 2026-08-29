# Azure OpenAI — EU-resident enterprise-governed LLM tier (story #304 / E2).
# Data residency: Sweden Central (EU) with a REGIONAL Standard deployment (NOT
# GlobalStandard — regional keeps inference data in-region). Contractual
# no-training + EU residency → governance class P2/Confidential
# (docs/ai-governance/model-governance-matrix.md). Cost = tokens only (Standard,
# no PTU). Provisioned by the Service Principal minicloud-tofu-azure.

resource "azurerm_resource_group" "ai" {
  name     = "minicloud-ai"
  location = "swedencentral" # EU; broadest Azure OpenAI model coverage
  tags     = { project = "minicloud", purpose = "ai-gateway" }
}

resource "azurerm_cognitive_account" "openai" {
  name                  = "minicloud-openai"
  resource_group_name   = azurerm_resource_group.ai.name
  location              = azurerm_resource_group.ai.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "minicloud-openai" # required for the OpenAI data-plane endpoint

  # Least-exposure: no public network rules relaxation beyond default; key-based
  # auth used by LiteLLM (fetched from Vault). No PrivateLink (would add cost).
  tags = { project = "minicloud", data_class = "P2-confidential" }
}

# gpt-4.1-mini — current cheap/capable workhorse (gpt-4o-mini 2024-07-18 was
# deprecated 03/2026). Standard (regional) deployment = EU residency.
resource "azurerm_cognitive_deployment" "gpt4o_mini" {
  name                 = "gpt-4.1-mini"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1-mini"
    version = "2025-04-14"
  }

  sku {
    name     = "Standard" # regional Standard (NOT GlobalStandard) → in-region data
    capacity = 10         # 10K tokens/min — low, budget-friendly
  }
}

output "azure_openai_endpoint" {
  description = "Azure OpenAI data-plane endpoint (→ LiteLLM api_base)."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "azure_openai_deployment" {
  description = "Deployment name to use as the LiteLLM model."
  value       = azurerm_cognitive_deployment.gpt4o_mini.name
}
