# minicloud-terraform

[![CI](https://github.com/andrelair-platform/minicloud-terraform/actions/workflows/ci.yml/badge.svg)](https://github.com/andrelair-platform/minicloud-terraform/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Terraform](https://img.shields.io/badge/Terraform-1.9-blue)](https://developer.hashicorp.com/terraform)

> Public-cloud IaC (**Terraform**) for the minicloud platform — provisions the **enterprise-governed LLM tier** (AWS Bedrock + Azure OpenAI) that sits behind the on-cluster LiteLLM gateway. On-prem/MAAS stays in [`minicloud-opentofu`](https://github.com/andrelair-platform/minicloud-opentofu) (OpenTofu). Part of the **AI Gateway Enterprise Hardening** epic (platform-backlog #296).

**Platform docs:** <https://andrelair-platform.github.io/minicloud-platform-docs/>

---

## Why a separate repo
| | Tool | Repo | Scope |
|---|---|---|---|
| **On-prem** | OpenTofu | `minicloud-opentofu` | MAAS, réseau, machines (bare-metal) |
| **Cloud** | **Terraform** | `minicloud-terraform` (this repo) | AWS Bedrock, Azure OpenAI |

Split state = isolated blast-radius, and the industry-standard Terraform for public cloud.

## Cost model
**AI tokens only.** All resources use on-demand / Standard tiers. **No** fixed-cost
constructs (no Azure PTU, no AWS PrivateLink, no cloud-native monitoring, no
managed Knowledge Bases). Budget guardrails (AWS Budgets + Azure Cost alert at
€8) are provisioned in story #300 **before** any paid model is enabled.

## Architecture (target)
```
        on-cluster LiteLLM gateway
                 │
      ┌──────────┼───────────────┐
      ▼          ▼               ▼
  vLLM/self   direct APIs    THIS REPO (Terraform)
                             ├── AWS Bedrock   (Claude/Llama/Mistral, EU)
                             └── Azure OpenAI  (GPT-4o/Claude, EU)
```
Credentials never live in code — sourced from **Vault** (`secret/platform/cloud-providers`) at run time. State in **S3 + DynamoDB** (EU, story #298).

## Layout
```
versions.tf     # terraform + provider pins (aws ~>5, azurerm ~>4)
providers.tf    # provider config (creds via env ← Vault)
backend.tf      # S3 remote state (activated in #298; local until then)
variables.tf    # region, budget email/amount
modules/        # bedrock, azure-openai (added in #303/#304)
.github/workflows/ci.yml   # L0: fmt + validate + tflint
```

## Getting started
```bash
terraform fmt -recursive
terraform init -backend=false
terraform validate
tflint --recursive
```
Real runs require Vault-sourced creds (scoped AWS IAM user + Azure Service
Principal — story #299) and the S3 backend (#298).

## Roadmap (platform-backlog milestone #17)
- **#297** repo scaffold *(this)* · **#298** S3+DynamoDB state · **#299** creds (IAM+SP) · **#300** budgets
- **#303** AWS Bedrock · **#304** Azure OpenAI → wired into LiteLLM

## License
MIT — see [LICENSE](LICENSE).
