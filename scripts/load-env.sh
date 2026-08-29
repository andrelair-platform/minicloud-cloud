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

  unset _cp_json _vault_tok
  echo "load-env: creds loaded from Vault (AWS=minicloud-tofu · Azure SP) — ready for tofu"
fi
