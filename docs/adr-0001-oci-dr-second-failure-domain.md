# ADR-0001 — OCI always-free ARM node as a second failure domain (DR)

**Status:** Accepted (decision) · **provisioning BLOCKED on prerequisites** (see below)
**Date:** 2026-09-23
**Context:** Reliability remediation — the "Path to 9.5" item #3 (see the platform docs
*Reliability → Cluster Stability Assessment*). Realises the pre-vetted candidate in
`.claude/rules/cloud-adoption.md` (*Off-site DR / second-provider, DORA Art. 11–12*).

## Decision

Add a single **Oracle Cloud Infrastructure (OCI) always-free ARM VM** (`VM.Standard.A1.Flex`)
as a **second failure domain** for the minicloud platform. It exists in a *different provider,
region, power and network domain* from the on-prem cluster + controller, so a site/power/ISP
loss no longer takes out everything at once.

**Role (in priority order):**
1. **Off-site restore target / DR anchor** — a reachable place to restore Kine + Longhorn +
   Velero backups when the primary site is down (today the R2 object copy exists, but there is
   no *compute* off-site to restore *into*).
2. **Optional standby k3s node** — joins the cluster as an agent over Tailscale, giving a warm
   off-site node for the most critical stateless workloads if desired later.

## Why this passes the `cloud-adoption.md` gate

| Gate | Satisfied |
|---|---|
| Real need | Single-site / single-power SPOF is the #1 structural cap on cluster stability (only site-level DR is missing) |
| Justification | **DORA Art. 11–12** off-site business continuity + Art. 28–29 cloud-concentration (a *different* provider than the AWS/Azure LLM tier) |
| Free / in-cap | OCI **always-free** A1.Flex (up to 4 OCPU / 24 GB, 200 GB block) — €0; €1 budget alert set before first resource |
| Layer-routed | ktayl-IS layer (infrastructure DR), documented here in `minicloud-cloud` |
| Terraform + destroyable | OpenTofu module in this repo; teardown = `tofu destroy -target=module.oci_dr_node` |

## Design

- **Shape:** `VM.Standard.A1.Flex`, 2 OCPU / 12 GB to start (well inside always-free 4/24), Ubuntu
  22.04 ARM (resolved via an `oci_core_images` data source — no hard-coded OCID), 100 GB boot/block.
- **Networking:** minimal VCN + public subnet + internet gateway + a tight security list
  (egress all; ingress only what Tailscale needs — Tailscale is primarily outbound/UDP-hole-punched,
  so the node needs **no inbound public ports**). This keeps the attack surface ~zero.
- **Cluster join over Tailscale (not public):** the on-prem k3s API (`set-hog` 10.0.0.2:6443) is on
  the private LAN behind the controller. The OCI node installs **Tailscale** (same tailnet as the
  controller), then joins as a k3s **agent** via the server's Tailscale/`10.0.0.2` address + node-token.
  This mirrors how the controller already reaches the cluster — no public exposure of the API.
- **DR use without joining:** even if not joined as an agent, the node can `rclone`/`mc` restore from
  R2 (Kine `.db.gz`, Longhorn/Velero) and stand up a recovery k3s — it is the *compute landing zone*
  the R2 backups currently lack.
- **Guardrails:** OCI budget alert at **€1** (created before any resource, like the AWS/Azure ones);
  idle-reclaim caveat (keep the free VM lightly active); ARM capacity is scarce → apply may need
  region/retry attempts.

## Consequences

- **+** Genuine site-level DR; DORA Art. 11–12/28–29 story becomes real (multi-provider, deliberate).
- **+** €0 (always-free); fully destroyable IaC.
- **−** One more provider to hold credentials for (OCI API key → Vault `secret/platform/oci`).
- **−** ARM always-free capacity can be hard to get (retry/region-hop); idle instances can be reclaimed.

## ⛔ Prerequisites (the blocker — these need the platform owner, not automatable here)

Provisioning cannot proceed until:
1. **An OCI tenancy/account exists** (free tier signed up).
2. **An OCI API signing key** is generated and its creds stored in **Vault** `secret/platform/oci`
   (tenancy OCID, user OCID, fingerprint, private key, region) — same pattern as the AWS/Azure creds.
3. **A region with A1.Flex always-free capacity** is chosen (may require retries).
4. An **SSH public key** for node access + the current **k3s node-token** (for the agent-join path).

## Apply plan (once prerequisites are met)

1. Add the `oci` provider to `providers.tf` / `versions.tf` (creds from Vault, like AWS/Azure).
2. Add `module "oci_dr_node"` (a new `modules/oci-dr-node/`: VCN + subnet + IGW + security list +
   A1.Flex instance + cloud-init that installs Tailscale + optionally the k3s agent).
3. Add the OCI **€1 budget alert** to `budgets.tf`.
4. `tofu init && tofu plan` (validate against the real tenancy) → `tofu apply` (retry on ARM-capacity errors).
5. Verify: node reachable over Tailscale; if joined, `kubectl get node <oci>` Ready; run a **restore
   drill from R2 onto the OCI node** to prove it's a working DR landing zone.
6. Document the runbook (restore-into-OCI) alongside `AUTHENTIK_CNPG_CUTOVER_RUNBOOK.md` / the DR runbook.

> **I can build the `modules/oci-dr-node/` OpenTofu + the Tailscale/k3s cloud-init + the budget alert
> and drive the `tofu apply` as soon as the OCI account exists and its creds are in Vault.** Until then
> this ADR records the decision + design so the work is gated, justified, and ready.
