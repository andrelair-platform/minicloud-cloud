# Cyber Recovery vault (ktayl IS — ADR-0003) — an IMMUTABLE, independent-provider copy of the
# crown jewels (Vault raft snapshot + kine/K3s state), on AWS S3 with Object Lock.
#
#   MinIO (operational) → Cloudflare R2 (Disaster Recovery, off-site, DELETABLE)
#                       → AWS S3 + Object Lock (Cyber Recovery, IMMUTABLE)   ← this file
#
# WHY this is a THIRD layer, not a duplicate of R2 (ADR-0003):
#   - DR (R2) answers "the controller/site is physically lost" — but its objects are DELETABLE by
#     anyone holding the MinIO/R2 creds, so it does NOT survive a compromised operator / ransomware
#     that wipes the backups.
#   - Cyber Recovery (this) answers exactly that: Object Lock (WORM) means an object CANNOT be deleted
#     or overwritten until its retention expires — not by a leaked key, not by the writer, not (in
#     Compliance mode) by root. On an INDEPENDENT provider (AWS ≠ Cloudflare) so it also survives a
#     Cloudflare account compromise. Scope = the crown jewels only (~650 MiB): kine + the Vault raft
#     snapshot (+ later 1 critical CNPG). DORA Art. 11–12 (business continuity) evidence.
#
# GOVERNANCE → COMPLIANCE (intentional, see ADR-0003): we start in GOVERNANCE mode so a privileged
# identity can still correct a mistake while the retention/cadence is being validated. Once proven by
# a restore drill, flip the lock to COMPLIANCE (nobody — including root — can delete before retention).
#
# OBJECT LOCK ONLY ON THIS SELF-MANAGED VAULT — never on the tool-GC'd stores (Velero/Longhorn/barman),
# whose tools MUST delete old backups to manage incremental chains (Object Lock would break their GC).
#
# WHAT THIS FILE PROVISIONS (AWS side only, per the repo-split rule): the locked bucket, its security
# controls, and the two scoped managed IAM policies. The push path (step 2) is a k8s CronJob that gets
# SHORT-LIVED STS creds via the Vault AWS secrets engine referencing the Writer policy below — NO static
# AWS key lands in k8s, Git, or tofu state (same pattern as the data lake, ADR-008).
#
# EXIT TEST (cloud-adoption.md gate #5): `force_destroy = false` by design — an immutable vault must not
# be one-command wipeable. To tear down: in GOVERNANCE, a BypassGovernanceRetention delete of the objects
# then `tofu destroy`; in COMPLIANCE, wait out the retention window first. This non-trivial teardown IS
# the point of a cyber-recovery vault, and is documented in ADR-0003.

locals {
  cyber_recovery_bucket = "minicloud-cyber-recovery-${data.aws_caller_identity.current.account_id}"
  # Default WORM retention for every object written. 35 days > the daily snapshot cadence + a comfortable
  # recovery window, and > the 90-day noncurrent-version lifecycle floor so lifecycle never fights the lock.
  cyber_recovery_retention_days = 35
}

# ---- the bucket (Object Lock MUST be enabled at creation — it cannot be added later) --------------
resource "aws_s3_bucket" "cyber_recovery" {
  bucket              = local.cyber_recovery_bucket
  object_lock_enabled = true
  force_destroy       = false # immutable vault — never auto-empty on destroy
  tags                = { component = "backup-dr", layer = "cyber-recovery", immutable = "object-lock" }
}

# Versioning — REQUIRED for Object Lock (a locked object is a locked version).
resource "aws_s3_bucket_versioning" "cyber_recovery" {
  bucket = aws_s3_bucket.cyber_recovery.id
  versioning_configuration { status = "Enabled" }
}

# Object Lock — default retention on EVERY put. **COMPLIANCE** (since 2026-11-26, after the restore drill
# proved the cadence): NO one — not the Writer, not an admin, not root — can delete or shorten retention
# before it expires. This is the anti-ransomware guarantee. Consequence: the bucket cannot be `tofu
# destroy`ed while COMPLIANCE-locked objects < 35d exist (exit = stop writes, wait out retention, destroy).
# (Was GOVERNANCE during validation; the flip is a one-way door.)
resource "aws_s3_bucket_object_lock_configuration" "cyber_recovery" {
  bucket = aws_s3_bucket.cyber_recovery.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = local.cyber_recovery_retention_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.cyber_recovery]
}

# Block ALL public access (defence in depth — a backup vault is private by construction).
resource "aws_s3_bucket_public_access_block" "cyber_recovery" {
  bucket                  = aws_s3_bucket.cyber_recovery.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt at rest — SSE-S3 (AES256). The payload is a Vault raft snapshot (already sensitive); AES256 is
# the MVP (a KMS CMK with a separate key policy is a later upgrade, same call as the data lake).
resource "aws_s3_bucket_server_side_encryption_configuration" "cyber_recovery" {
  bucket = aws_s3_bucket.cyber_recovery.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

# Lifecycle — bound cost without touching the hot window. The writer uses TIMESTAMPED keys (one object
# per day, no overwrite), so growth is linear + tiny; expire NONCURRENT versions after 90 days (> the
# 35-day lock, so a lock never blocks the rule) and abort orphaned multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "cyber_recovery" {
  bucket = aws_s3_bucket.cyber_recovery.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }

  depends_on = [aws_s3_bucket_versioning.cyber_recovery]
}

# Enforce HTTPS — deny any non-TLS request (same posture as the data lake).
resource "aws_s3_bucket_policy" "cyber_recovery_tls_only" {
  bucket = aws_s3_bucket.cyber_recovery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.cyber_recovery.arn, "${aws_s3_bucket.cyber_recovery.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---- scoped IAM (what the Vault AWS secrets engine attaches to short-lived identities — ADR-0003) --
# Writer/Reader split. The push CronJob mints Writer STS; a disaster restore mints Reader STS. NEITHER
# can delete — deletion before retention is impossible under Object Lock, and least-privilege IAM is the
# defence-in-depth on top (a leaked Writer key can ADD a backup, never remove one).

# WRITER — the crown-jewels push CronJob: list + PUT (+ the HEAD GetObject rclone issues before a copy)
# + multipart cleanup. Explicitly NO Delete*, NO BypassGovernanceRetention, NO PutObjectRetention/
# LegalHold (it must not be able to shorten/lift a lock). This is what makes "immutable" true, not nominal.
resource "aws_iam_policy" "cyber_recovery_write" {
  name        = "ktayl-cyber-recovery-write"
  description = "Add-only access to the ktayl cyber-recovery vault (crown-jewels push; via Vault STS). No delete, no lock-bypass."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.cyber_recovery.arn
      },
      {
        Sid      = "AddObjectsOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${aws_s3_bucket.cyber_recovery.arn}/*"
      }
    ]
  })
}

# READER — the disaster restore identity (and the OFFLINE break-glass copy of these creds). Read-only,
# incl. the retention/legal-hold metadata so a restorer can see the lock state. NEVER stored only in
# Vault/Vaultwarden-on-cluster (circular — you need these to recover Vault itself); the break-glass kit
# holds them off-cluster (ADR-0003).
resource "aws_iam_policy" "cyber_recovery_read" {
  name        = "ktayl-cyber-recovery-read"
  description = "Read-only recovery access to the ktayl cyber-recovery vault (disaster restore + break-glass; via Vault STS / offline kit)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.cyber_recovery.arn
      },
      {
        Sid      = "ReadObjectsAndLockState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectRetention", "s3:GetObjectLegalHold"]
        Resource = "${aws_s3_bucket.cyber_recovery.arn}/*"
      }
    ]
  })
}

# NOTE on the 4 identities (ADR-0003): Infra-Admin = the existing tofu-runner IAM (manages this via
# OpenTofu + holds BypassGovernanceRetention for a GOVERNANCE-mode correction) — no new policy here.
# Break-glass = the Reader creds kept OFFLINE (not a separate AWS identity). No per-service dedicated
# budget: the crown jewels are ~650 MiB fixed, so the account-wide $15 budget (budgets.tf) covers the
# ~$0.02/mo — a growth tripwire (like the data lake's) would be noise here.

# ---- outputs ---------------------------------------------------------------
output "cyber_recovery_bucket" {
  description = "The ktayl cyber-recovery (Object Lock) S3 bucket name."
  value       = aws_s3_bucket.cyber_recovery.id
}

output "cyber_recovery_write_policy_arn" {
  description = "Managed policy ARN the Vault AWS secrets engine attaches for the crown-jewels push (add-only)."
  value       = aws_iam_policy.cyber_recovery_write.arn
}

output "cyber_recovery_read_policy_arn" {
  description = "Managed policy ARN for disaster-restore / break-glass read access."
  value       = aws_iam_policy.cyber_recovery_read.arn
}

output "cyber_recovery_lock_mode" {
  description = "Current Object Lock mode — GOVERNANCE during validation, flip to COMPLIANCE once drill-proven."
  value       = aws_s3_bucket_object_lock_configuration.cyber_recovery.rule[0].default_retention[0].mode
}
