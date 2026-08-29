# Contributing

## Branch strategy
- `main` — protected; changes land via **PR** (CI must pass: fmt + validate + tflint).
- Feature branches: `feat/…`, `fix/…`, `chore/…`.

## Commits
- Identity: `AndreLiar <andrelaurelyvan.kanmegnetabouguie@ynov.com>`, GPG-signed.
- Conventional commits (`feat:`, `fix:`, `chore:`).

## Rules
- **Never commit credentials or state.** Cloud creds come from the environment,
  sourced from Vault (`secret/platform/cloud-providers`). State lives in S3
  (story #298), never in git.
- `tofu fmt` before every commit (OpenTofu; HCL is Terraform-compatible).
- Every new resource must respect the **budget guardrails** (story #300) and the
  **model governance matrix** (story #301) — cost = AI tokens only.
