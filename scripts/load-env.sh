# Load cloud credentials from Vault into the environment for OpenTofu.
#
#   source scripts/load-env.sh   # then: tofu plan / tofu apply
#
# SECURITY: this file contains **no secrets** — credentials live ONLY in Vault
# (secret/platform/cloud-providers) and are fetched at run time. Never commit
# creds, *.tfvars, or state (see .gitignore). Run this on a host that has a
# Vault token (the controller: ~/.vault-ops-token, read-only on secret/platform/*).
#
# Identities loaded:
#   AWS  → minicloud-tofu (provisioning; the old ROOT key is deactivated)
#   Azure→ Service Principal minicloud-tofu-azure (ARM_* vars)

_vault_addr="${VAULT_ADDR:-https://vault.10.0.0.200.nip.io}"
_vault_tok="$(cat "$HOME/.vault-ops-token" 2>/dev/null || cat "$HOME/.vault-root-token" 2>/dev/null)"

if [ -z "$_vault_tok" ]; then
  echo "load-env: no Vault token found (~/.vault-ops-token). Run on the controller." >&2
else
  _cp_json="$(curl -sk -H "X-Vault-Token: $_vault_tok" "$_vault_addr/v1/secret/data/platform/cloud-providers")"
  _cp_get() { printf '%s' "$_cp_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['$1'])"; }

  # AWS (provisioning identity — never the root key, which is deactivated)
  export AWS_ACCESS_KEY_ID="$(_cp_get aws-tofu-access-key-id)"
  export AWS_SECRET_ACCESS_KEY="$(_cp_get aws-tofu-secret-access-key)"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"

  # Azure (Service Principal → azurerm reads ARM_* env vars)
  export ARM_CLIENT_ID="$(_cp_get azure-client-id)"
  export ARM_CLIENT_SECRET="$(_cp_get azure-client-secret)"
  export ARM_TENANT_ID="$(_cp_get azure-tenant-id)"
  export ARM_SUBSCRIPTION_ID="$(_cp_get azure-subscription-id)"

  # OCI (API key → oci provider reads TF_VAR_oci_* vars). Creds in secret/platform/oci.
  _oci_json="$(curl -sk -H "X-Vault-Token: $_vault_tok" "$_vault_addr/v1/secret/data/platform/oci")"
  if printf '%s' "$_oci_json" | grep -q '"private_key"'; then
    _oci_get() { printf '%s' "$_oci_json" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['$1'])"; }
    export TF_VAR_oci_tenancy_ocid="$(_oci_get tenancy_ocid)"
    export TF_VAR_oci_user_ocid="$(_oci_get user_ocid)"
    export TF_VAR_oci_fingerprint="$(_oci_get fingerprint)"
    export TF_VAR_oci_region="$(_oci_get region)"
    export TF_VAR_oci_compartment_ocid="$(_oci_get compartment_ocid)"
    export TF_VAR_oci_private_key="$(_oci_get private_key)"
    export TF_VAR_oci_ssh_public_key="$(_oci_get ssh_public_key)"
    echo "load-env: OCI creds loaded (secret/platform/oci) — ready for tofu"
  else
    echo "load-env: no OCI creds in Vault yet (secret/platform/oci) — OCI resources will no-op"
  fi

  # Azure Education (acct 3, ynov.com tenant) → the gated azure-education-budget.tf.
  # SEPARATE subscription/tenant from the PAYG SP above (never azurerm_subscription.current).
  # Keys are OPTIONAL: absent → the four TF_VARs stay empty → the budget's count=0 (inert).
  # Add all four (azure-edu-subscription-id / -tenant-id / -client-id / -client-secret) to
  # secret/platform/cloud-providers to activate. See .claude/rules/cloud-adoption.md (*Our accounts*).
  if printf '%s' "$_cp_json" | grep -q '"azure-edu-subscription-id"'; then
    export TF_VAR_azure_education_subscription_id="$(_cp_get azure-edu-subscription-id)"
    export TF_VAR_azure_education_tenant_id="$(_cp_get azure-edu-tenant-id)"
    export TF_VAR_azure_education_client_id="$(_cp_get azure-edu-client-id)"
    export TF_VAR_azure_education_client_secret="$(_cp_get azure-edu-client-secret)"
    echo "load-env: Azure Education creds loaded (azure-edu-*) — Education budget will provision"
  else
    echo "load-env: no Azure Education creds yet (azure-edu-* in secret/platform/cloud-providers) — Education budget stays inert"
  fi

  unset _cp_json _oci_json _vault_tok
  echo "load-env: creds loaded from Vault (AWS=minicloud-tofu · Azure SP) — ready for tofu"
fi
