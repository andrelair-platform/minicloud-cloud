# €1 account-wide OCI budget + alert (ADR-0001 guardrail). Everything provisioned here is
# Always Free, so steady-state OCI spend is €0. This is the tripwire: if anything ever starts
# billing (a non-always-free resource, or exceeding the A1 free envelope), it emails immediately.
# Budgets must live in the ROOT compartment (= tenancy OCID). Gated with the DR node so it
# exists whenever OCI is in use.
resource "oci_budget_budget" "oci" {
  count          = local.oci_enabled
  compartment_id = var.oci_tenancy_ocid # root — account-wide
  amount         = 1
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.oci_tenancy_ocid]
  display_name   = "minicloud-oci-monthly"
  description    = "minicloud OCI always-free tripwire (1/mo)"
}

resource "oci_budget_alert_rule" "oci_actual" {
  count          = local.oci_enabled
  budget_id      = oci_budget_budget.oci[0].id
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  display_name   = "minicloud-oci-actual-100"
  recipients     = var.oci_budget_email
  message        = "minicloud OCI actual spend reached the 1/mo budget — something is billing. Check the OCI console."
}
