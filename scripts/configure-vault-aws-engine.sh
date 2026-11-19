#!/usr/bin/env bash
# Configure Vault's AWS secrets engine for the data-lake (ADR-008). IDEMPOTENT — safe to re-run.
#
# WHAT IT DOES (all reversible — `vault secrets disable aws` undoes the engine):
#   1. enables the `aws` secrets engine
#   2. config/root ← the scoped `vault-data-lake` IAM user (from `tofu output`, NOT the admin key)
#   3. two assumed_role roles: data-lake-read (DuckDB) + data-lake-write (producers)
#   4. a Vault policy per role + a Kubernetes-auth role binding the workload ServiceAccount, so the
#      Job/producer get short-lived STS creds at runtime with NO static key in k8s/Git.
#
# PREREQUISITES (this is a BREAK-GLASS step — run on the controller):
#   - `tofu apply` has created data-lake.tf + data-lake-vault-auth.tf (bucket, policies, roles, vault user)
#   - VAULT_ADDR set and VAULT_TOKEN = a PRIVILEGED (root/admin) token (sys/mounts + auth/kubernetes write)
#   - run from the minicloud-cloud repo root so `tofu output` resolves
#
# Usage:
#   export VAULT_ADDR=https://vault.devandre.sbs           # or https://127.0.0.1:8200 on-controller
#   export VAULT_TOKEN=<break-glass root/admin token>      # from Vaultwarden controller-break-glass
#   bash scripts/configure-vault-aws-engine.sh
set -euo pipefail

MOUNT="aws"
REGION="${AWS_LAKE_REGION:-eu-west-1}"
# Workload ServiceAccounts (created by the k8s manifests in minicloud-gitops, ns data-platform):
READER_NS="data-platform";  READER_SA="dp-duckdb"   # the DuckDB transform Job
WRITER_NS="data-platform";  WRITER_SA="dp-ingest"   # the Parquet→S3 producer

echo "[vault-aws] reading tofu outputs…"
ak=$(tofu output -raw vault_data_lake_access_key_id)
sk=$(tofu output -raw vault_data_lake_secret_access_key)
reader_arn=$(tofu output -raw data_lake_reader_role_arn)
writer_arn=$(tofu output -raw data_lake_writer_role_arn)

echo "[vault-aws] enabling the aws secrets engine (idempotent)…"
vault secrets list -format=json | grep -q "\"${MOUNT}/\"" || vault secrets enable -path="${MOUNT}" aws

echo "[vault-aws] writing config/root (scoped vault-data-lake principal)…"
vault write "${MOUNT}/config/root" access_key="${ak}" secret_key="${sk}" region="${REGION}"
# Default STS TTL for assumed_role creds (1h; Job runs minutes).
vault write "${MOUNT}/config/lease" lease=1h lease_max=4h 2>/dev/null || true

echo "[vault-aws] roles (assumed_role → the scoped IAM roles)…"
vault write "${MOUNT}/roles/data-lake-read" \
  credential_type=assumed_role role_arns="${reader_arn}" default_sts_ttl=1h max_sts_ttl=4h
vault write "${MOUNT}/roles/data-lake-write" \
  credential_type=assumed_role role_arns="${writer_arn}" default_sts_ttl=1h max_sts_ttl=4h

echo "[vault-aws] Vault policies (read the STS creds for each role)…"
printf 'path "%s/sts/data-lake-read"  { capabilities = ["read","update"] }\n' "${MOUNT}" \
  | vault policy write data-lake-read -
printf 'path "%s/sts/data-lake-write" { capabilities = ["read","update"] }\n' "${MOUNT}" \
  | vault policy write data-lake-write -

echo "[vault-aws] Kubernetes-auth roles (bind the workload ServiceAccounts)…"
vault write auth/kubernetes/role/data-lake-reader \
  bound_service_account_names="${READER_SA}" \
  bound_service_account_namespaces="${READER_NS}" \
  policies=data-lake-read ttl=1h
vault write auth/kubernetes/role/data-lake-writer \
  bound_service_account_names="${WRITER_SA}" \
  bound_service_account_namespaces="${WRITER_NS}" \
  policies=data-lake-write ttl=1h

echo "[vault-aws] DONE. Verify a reader cred mints:  vault read ${MOUNT}/sts/data-lake-read"
