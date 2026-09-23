# OCI always-free A1.Flex DR node — the platform's SECOND FAILURE DOMAIN (ADR-0001,
# docs/adr-0001-oci-dr-second-failure-domain.md). Different provider/region/power/network
# than the on-prem cluster + controller → survives a site/power/ISP loss. Role: off-site
# restore-target / DR landing zone (k3s-agent-join is a later, optional enhancement).
# €0 — always-free tier. Teardown: -var=enable_oci_dr_node=false (or tofu destroy).

locals {
  oci_enabled = var.enable_oci_dr_node ? 1 : 0
  oci_name    = "minicloud-dr"
}

data "oci_identity_availability_domains" "ads" {
  count          = local.oci_enabled
  compartment_id = var.oci_tenancy_ocid
}

# Latest Ubuntu 22.04 ARM (aarch64) image for the A1.Flex shape.
data "oci_core_images" "ubuntu_arm" {
  count                    = local.oci_enabled
  compartment_id           = var.oci_compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_vcn" "dr" {
  count          = local.oci_enabled
  compartment_id = var.oci_compartment_ocid
  cidr_blocks    = ["10.10.0.0/24"]
  display_name   = "${local.oci_name}-vcn"
  dns_label      = "minidr"
}

resource "oci_core_internet_gateway" "dr" {
  count          = local.oci_enabled
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.dr[0].id
  display_name   = "${local.oci_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "dr" {
  count          = local.oci_enabled
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.dr[0].id
  display_name   = "${local.oci_name}-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.dr[0].id
  }
}

resource "oci_core_security_list" "dr" {
  count          = local.oci_enabled
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.dr[0].id
  display_name   = "${local.oci_name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  # NO inbound public ports — a DR restore-target needs none. Initial access is via the OCI
  # Cloud Shell / serial console; ongoing access via Tailscale (ADR-0001). This keeps the
  # attack surface ~zero (and avoids a world-open SSH finding). Add a Tailscale-scoped or
  # your-IP ingress rule here only if you truly need direct SSH.
}

resource "oci_core_subnet" "dr" {
  count             = local.oci_enabled
  compartment_id    = var.oci_compartment_ocid
  vcn_id            = oci_core_vcn.dr[0].id
  cidr_block        = "10.10.0.0/24"
  display_name      = "${local.oci_name}-subnet"
  route_table_id    = oci_core_route_table.dr[0].id
  security_list_ids = [oci_core_security_list.dr[0].id]
  dns_label         = "minidrsub"
}

resource "oci_core_instance" "dr" {
  count               = local.oci_enabled
  compartment_id      = var.oci_compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads[0].availability_domains[0].name
  display_name        = "${local.oci_name}-node"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.oci_dr_node_ocpus
    memory_in_gbs = var.oci_dr_node_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm[0].images[0].id
    boot_volume_size_in_gbs = 100
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.dr[0].id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.oci_ssh_public_key
    user_data = base64encode(<<-EOT
      #!/bin/bash
      set -e
      apt-get update -y
      apt-get install -y rclone postgresql-client gzip curl ca-certificates
      echo "minicloud DR node (OCI ${var.oci_region}) ready $(date -u)" > /etc/minicloud-dr-node
    EOT
    )
  }

  freeform_tags = {
    project   = "minicloud"
    role      = "dr-second-failure-domain"
    managedby = "opentofu"
  }
}

output "oci_dr_node_public_ip" {
  value       = local.oci_enabled == 1 ? oci_core_instance.dr[0].public_ip : null
  description = "Public IP of the OCI DR node (SSH in with the key from Vault secret/platform/oci ssh_private_key)"
}
