# ADR-0003 — Immutable Cyber-Recovery vault for the crown jewels (AWS S3 + Object Lock)

**Status:** Accepted · **IaC written, NOT applied** (plan only — the owner runs `tofu apply`; cloud is an outward action)
**Date:** 2026-11-26 · **Impl:** `s3-cyber-recovery.tf`
**Context:** A 2026-11-26 DR review (ground-truthed against the live platform) confirmed the three-layer
object-storage picture and found the real gap. **MinIO** (controller, LAN) is the *operational* layer;
**Cloudflare R2** is the *Disaster-Recovery* off-site layer and it genuinely works — the crown jewels
(kine + the Vault raft snapshot) DO mirror to R2 `minicloud-backup-offsite/db-backups/` via the
`backup-offsite-mirror` CronJob, which is alerted (`MinioR2MirrorStale`) and restore-verified
(`offsite-restore-verify`). **But every off-site copy is `STANDARD` — deletable by anyone holding the
MinIO/R2 creds.** So the platform survives a *dead controller/site* (DR) but **not** a *compromised
operator or ransomware that deletes the backups themselves* (Cyber Recovery). That second failure needs
**immutable** copies on an **independent provider** — which nothing provides today.

> **DR ≠ Cyber Recovery.** DR answers "my site is destroyed, rebuild it." Cyber Recovery answers "my
> infrastructure is compromised and my backups may be deleted — recover a known-good state anyway."

## Decision

Add a **third storage layer**: an **immutable Cyber-Recovery vault** on **AWS S3 with Object Lock (WORM)**
holding only the crown jewels (Vault raft snapshot + kine; later +1 critical CNPG — ~650 MiB total).

- **Object Lock, GOVERNANCE → COMPLIANCE.** Start in GOVERNANCE (a privileged identity can bypass to fix
  a mistake while retention/cadence is validated), 35-day default retention; flip to **COMPLIANCE** (no
  one, including root, can delete before retention) once a restore drill proves the cadence. **Object Lock
  ONLY on this self-managed vault — never on the tool-GC'd stores** (Velero/Longhorn/barman must delete old
  backups to manage incremental chains; a lock would break their GC).
- **Independent provider (AWS ≠ Cloudflare)** so it also survives a Cloudflare-account compromise — true
  two-provider defence-in-depth, not a second copy on the same vendor.
- **Scoped IAM via the Vault AWS secrets engine (short-lived STS, no static keys).** A *Writer* policy
  (add-only: `PutObject`, no `Delete*`, no `BypassGovernanceRetention`, no retention/legal-hold edits) for
  the push CronJob; a *Reader* policy (read + lock-state) for disaster restore + the offline break-glass kit.
- **S3 Standard, NOT Glacier.** Glacier Deep Archive (9–48 h retrieval + 180-day minimum) would trade RTO
  for pennies at this volume — wrong for a recovery vault. Standard = immediate retrieval.

## Why this passes the `cloud-adoption.md` gate

| Gate | Satisfied |
|---|---|
| Real need | No immutable backup exists today — every off-site copy (R2) is `STANDARD`/deletable (verified 2026-11-26) |
| Justification | **DORA Art. 11–12** (business continuity) + cyber-resilience: a backup a compromised operator / ransomware cannot erase |
| Free / in-cap | ~650 MiB on S3 Standard ≈ **$0.02/mo** — covered by the existing account-wide **$15 budget** (`budgets.tf`); no dedicated tripwire (fixed-size, doesn't grow) |
| Layer-routed | ktayl-IS layer (DR for the platform/IS); documented here in `minicloud-cloud`; **EU region** `eu-west-1` (data residency) |
| Terraform + destroyable | OpenTofu in this repo; **exit test below** (immutable by design → not one-command wipeable, deliberately) |

## Options considered (per `ai-native-engineering.md` — recommend, owner decides)

- **Option A — AWS S3 + Object Lock (CHOSEN).** Mature Compliance-mode WORM + strong IAM isolation + an
  independent provider + real AWS skills (IAM, Object Lock, OpenTofu). Costs cents.
- **Option B — Cloudflare R2 Bucket Locks.** R2 *does* offer object retention now, so immutability alone
  does not strictly require AWS. **Rejected as the primary:** it keeps all eggs on one provider (no
  independence from a Cloudflare compromise), has less mature Compliance-grade guarantees, and adds no new
  competency. (R2 stays the DR layer; it is not also the cyber layer.)
- **Option C — do nothing (accept R2 as "good enough").** Rejected: R2 objects are deletable with the
  creds, so a credential compromise or ransomware takes the backups with the cluster — the exact scenario
  Cyber Recovery exists for.

## The credential circularity (the trap, handled)

The creds to **restore Vault** must not live **only in Vault** (circular) — and not only in
Vaultwarden-on-cluster either (it dies with the cluster). Vault **auto-unseals via AWS KMS**, so a
"lost AWS" scenario also needs the **offline Shamir recovery keys**. Therefore the **break-glass kit**
(Reader STS creds / an offline static Reader key + the Shamir recovery keys + the age identity) lives
**off-cluster, off-Vault** (password manager / offline copy). The Reader IAM policy exists for this.

## Follow-up (tracked, not in this file)

1. **Push CronJob** `crown-jewels-cyber-copy` (ns `velero`, sibling of `backup-offsite-mirror`): `rclone
   copy` MinIO `db-backups/{kine,vault}` → the vault, **timestamped keys** (one locked object/day), Writer
   STS from the Vault AWS secrets engine. → `minicloud-gitops/platform/storage/backup-dr/`.
2. **Vault AWS secrets-engine role** referencing `cyber_recovery_write_policy_arn` (STS for the CronJob).
3. **Restore drill** (Reader): pull the newest Vault snapshot from S3 → restore into a throwaway Vault →
   **measure RTO**. Then flip Object Lock to COMPLIANCE. An immutable backup never restored is a hypothesis.
4. Document in the **DR RTO/RPO matrix** (`minicloud-platform-docs/.../07-dr-rto-rpo-matrix.md`) — the
   three-layer model is already recorded there; mark the S3 layer live once applied + drilled.

## Exit test (cloud-adoption gate #5, written down)

`force_destroy = false` by design — an immutable vault must not be one-command wipeable. **Teardown:** in
GOVERNANCE, a `BypassGovernanceRetention` delete of the objects then `tofu destroy`; in COMPLIANCE, wait
out the retention window first. The non-trivial teardown IS the point. **Laptop cluster unaffected either
way** (the vault is a pure destination; nothing on-prem depends on it to run).

## Consequences

- **Gain:** a WORM, independent-provider copy of the crown jewels → survives credential compromise /
  ransomware / a Cloudflare-account loss. Cert evidence for **BC02/BC03** + DORA Art. 11–12.
- **Cost:** ~$0.02/mo; a little IAM/Vault-STS wiring; the discipline of GOVERNANCE→COMPLIANCE + a drill.
- **Residual:** COMPLIANCE mode means a genuine mistake is unrecoverable before retention — mitigated by
  validating in GOVERNANCE first and keeping retention modest (35 d). The break-glass kit must be
  **tested** (reachable off-cluster), or the immutability is theatre.
