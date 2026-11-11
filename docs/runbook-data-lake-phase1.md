# Runbook — Data Lake Phase-1 (as-applied) + Vault ops-token renewal

**Status:** Phase-1 APPLIED 2026-11-11 · **Scope:** AWS side of the ktayl Data Platform hybrid lakehouse
(`ktayl-data-platform` ADR-008). On-cluster runtime (DuckDB Job, Slice-2 MDM) is **not** here — it's
deployed by ArgoCD from `ktayl-data-platform` per the repo-split rule.

## What is live in AWS (account 625830750465, eu-west-1)

Provisioned by `data-lake.tf` (`tofu apply` — 9 resources):

| Resource | Value / note |
|---|---|
| S3 bucket | `minicloud-data-lake-625830750465` — versioning **Enabled**, **block-all-public**, SSE-S3 (+bucket-key), TLS-only bucket policy |
| Lifecycle | expire noncurrent versions 90d · abort incomplete multipart 7d |
| IAM policy (read) | `arn:aws:iam::625830750465:policy/ktayl-data-lake-read` — list+get (DuckDB transform) |
| IAM policy (write) | `arn:aws:iam::625830750465:policy/ktayl-data-lake-write` — put `raw/*` (producers) |
| Budget | `minicloud-data-lake` — S3-filtered, $10/mo, alerts $5/$8/$10 + forecast (atop the global $15 budget) |

These IAM policy ARNs are what the **Vault AWS secrets engine** attaches to the short-lived identities it
mints for the DuckDB Job / producers (ADR-008 — no static AWS keys). That wiring is the next build step.

## How it was applied (reproduce / extend)

Runs **on the controller** (where Vault-sourced creds live — `minicloud-cloud` is controller-only):

```bash
cd ~/minicloud-cloud
source scripts/load-env.sh        # exports AWS_* (minicloud-tofu) + ARM_* from Vault
~/.local/bin/tofu init -input=false
~/.local/bin/tofu plan            # review: must show "N to add, 0 to destroy"
~/.local/bin/tofu apply
```

**GOTCHA — use a TARGETED apply for the data lake.** A full `apply` of this repo also plans
`oci_core_instance.dr[0]` (an OCI DR node, ADR-0001 — not yet applied) and errors on the **azurerm**
provider (`az`/ARM auth not loaded in this environment). To apply *only* the data lake, target its 9
resources:

```bash
T="-target=aws_s3_bucket.data_lake -target=aws_s3_bucket_public_access_block.data_lake \
-target=aws_s3_bucket_server_side_encryption_configuration.data_lake -target=aws_s3_bucket_versioning.data_lake \
-target=aws_s3_bucket_lifecycle_configuration.data_lake -target=aws_s3_bucket_policy.data_lake_tls_only \
-target=aws_iam_policy.data_lake_read -target=aws_iam_policy.data_lake_write -target=aws_budgets_budget.data_lake"
~/.local/bin/tofu plan  $T     # confirm 9 to add, 0 to destroy
~/.local/bin/tofu apply $T -auto-approve
```

Verify: `aws s3api head-bucket --bucket minicloud-data-lake-625830750465`.

## GOTCHA — renewing the Vault ops token (break-glass)

`scripts/load-env.sh` fetches cloud creds from Vault using `~/.vault-ops-token`. **That token expires**
(TTL), and when it does, `load-env.sh` silently exports nothing → tofu/aws falls back to stale creds →
`STS … InvalidClientTokenId`. Symptom: a clean-looking repo but every AWS call 403s.

**There is NO `vault` CLI on the controller** — only `vault-snapshot`. All Vault interaction is **curl to
the HTTP API**. To mint a fresh ops token you need a token that can create tokens; the only one is the
**root token** (plaintext in **Vaultwarden** → folder `VAULT break-glass` → entry *Vault Root Token*; the
on-disk `~/.vault-root-token.age` is age-encrypted and the age identity is itself only in Vault/Vaultwarden).

```bash
# on the controller — mint a fresh 30-day ops token via the Vault HTTP API
R='<root token from Vaultwarden>'; V=https://vault.10.0.0.200.nip.io
NEW=$(curl -sk -H "X-Vault-Token: $R" -X POST \
  -d '{"policies":["platform-ops"],"ttl":"720h","display_name":"ops-renewed"}' \
  $V/v1/auth/token/create | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')
printf '%s' "$NEW" > ~/.vault-ops-token && chmod 600 ~/.vault-ops-token
# sanity: can it read the creds load-env needs?
curl -sk -H "X-Vault-Token: $NEW" $V/v1/secret/data/platform/cloud-providers \
  | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)["data"]["data"].keys()))'
```

- The ops policy is **`platform-ops`** (NOT `vault-ops`). List policies:
  `curl -sk -H "X-Vault-Token: $R" "$V/v1/sys/policies/acl?list=true"`.
- `secret/platform/cloud-providers` holds `aws-tofu-access-key-id` / `-secret-access-key` (the
  `minicloud-tofu` IAM user tofu uses) — **not** the deactivated root `AWS_ADMIN_*` key.
- **Security:** never paste the root token anywhere it persists (chat, history, shared files). If it
  leaks, rotate it (`sys/generate-root` with the unseal keys → update Vaultwarden → revoke the old).

## Next build steps (not done — on-cluster, `ktayl-data-platform` + ArgoCD)

1. **Vault AWS secrets engine** — configure a role that attaches `ktayl-data-lake-read` (DuckDB) /
   `ktayl-data-lake-write` (producers) → short-lived STS creds (ADR-008 workload-auth decision).
2. **DuckDB transform Job** — `dbt-duckdb` reads `s3://minicloud-data-lake-…` Parquet → CNPG serving marts.
3. **Slice-2 MDM** — the dependency-ordered first step of the warehouse (ADR-007).
