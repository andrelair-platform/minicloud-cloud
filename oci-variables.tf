# OCI inputs — populated at run time from Vault secret/platform/oci via
# scripts/load-env.sh (TF_VAR_oci_*). Never hard-code creds here.
variable "oci_tenancy_ocid" {
  type    = string
  default = ""
}
variable "oci_user_ocid" {
  type    = string
  default = ""
}
variable "oci_fingerprint" {
  type    = string
  default = ""
}
variable "oci_private_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "oci_region" {
  type    = string
  default = "eu-paris-1"
}
variable "oci_compartment_ocid" {
  type    = string
  default = ""
}
variable "oci_ssh_public_key" {
  type    = string
  default = ""
}

# DR node (ADR-0001). enable=false tears it down cleanly; ocpus/mem stay inside the
# always-free A1 envelope (4 OCPU / 24 GB total).
variable "enable_oci_dr_node" {
  type    = bool
  default = true
}
variable "oci_dr_node_ocpus" {
  type    = number
  default = 2
}
variable "oci_dr_node_memory_gb" {
  type    = number
  default = 12
}
variable "oci_budget_email" {
  type    = string
  default = "kanmegnea@gmail.com"
}
