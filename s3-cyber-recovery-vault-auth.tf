# Cyber-recovery push auth (ADR-0003) — the crown-jewels copy job gets SHORT-LIVED, add-only S3 creds
# with NO static key, via Vault's AWS secrets engine (same path as the data lake, ADR-008):
#
#   Vault (reuses the existing `vault-data-lake` config/root principal)
#     └─ sts:AssumeRole ──▶ ktayl-cyber-recovery-writer (→ ktayl-cyber-recovery-write policy) → the push job
#
# Reuses the vault-data-lake IAM user (data-lake-vault-auth.tf) rather than a second Vault config/root
# (the aws/ engine has ONE config/root). This file only ADDS a role + a second assume-permission on that
# user — it does NOT modify the data-lake file. Disable path = delete this file + the aws/roles/cyber-*
# Vault role (fully reversible; touches nothing else).

# ---- WRITER role Vault assumes to push the crown jewels (add-only) ----------
resource "aws_iam_role" "cyber_recovery_writer" {
  name        = "ktayl-cyber-recovery-writer"
  description = "Assumed (via Vault) by the crown-jewels push job - add-only write to the cyber-recovery vault. No delete, no lock-bypass."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "VaultDataLakeMayAssume"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = aws_iam_user.vault_data_lake.arn } # the existing Vault config/root principal
    }]
  })
  max_session_duration = 3600
  tags                 = { component = "backup-dr", layer = "cyber-recovery" }
}

resource "aws_iam_role_policy_attachment" "cyber_recovery_writer" {
  role       = aws_iam_role.cyber_recovery_writer.name
  policy_arn = aws_iam_policy.cyber_recovery_write.arn # defined in s3-cyber-recovery.tf (add-only)
}

# ---- extend the vault-data-lake principal to ALSO assume THIS role ----------
# A SECOND inline policy on the same user (IAM allows many) — keeps this change out of data-lake-vault-auth.tf.
resource "aws_iam_user_policy" "vault_assume_cyber_recovery" {
  name = "assume-cyber-recovery-writer"
  user = aws_iam_user.vault_data_lake.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeCyberRecoveryWriter"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.cyber_recovery_writer.arn
    }]
  })
}

output "cyber_recovery_writer_role_arn" {
  description = "Role ARN Vault assumes for the crown-jewels push STS creds (aws/roles/cyber-recovery-write)."
  value       = aws_iam_role.cyber_recovery_writer.arn
}
