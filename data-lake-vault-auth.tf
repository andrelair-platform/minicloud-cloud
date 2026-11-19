# Data-lake workload auth (ADR-008 "Workload authentication — Vault AWS secrets engine").
#
# The DuckDB transform Job + domain producers need SHORT-LIVED, SCOPED S3 creds with NO static keys in
# k8s/Git. Vault's AWS secrets engine mints them via sts:AssumeRole. This file provisions the AWS side of
# that path, LEAST-PRIVILEGE:
#
#   Vault (holds ONE scoped principal: the `vault-data-lake` IAM user, key in Vault aws/config/root)
#     └─ sts:AssumeRole ──▶ ktayl-data-lake-reader  (→ ktayl-data-lake-read  policy)  → DuckDB transform
#     └─ sts:AssumeRole ──▶ ktayl-data-lake-writer  (→ ktayl-data-lake-write policy)  → domain producers
#
# Vault does NOT get the admin (minicloud-tofu) key — only a principal that can assume these two roles and
# nothing else. The roles carry the exact S3 scopes already defined in data-lake.tf. Disable path = delete
# this file + `vault secrets disable aws` (fully reversible; touches nothing else).

# ---- the one principal Vault holds (config/root) ----------------------------
resource "aws_iam_user" "vault_data_lake" {
  name = "vault-data-lake"
  tags = { component = "data-platform", purpose = "vault-aws-secrets-engine" }
}

resource "aws_iam_access_key" "vault_data_lake" {
  user = aws_iam_user.vault_data_lake.name
}

# Its ONLY permission: assume the two data-lake roles (no direct S3, no IAM).
resource "aws_iam_user_policy" "vault_data_lake_assume" {
  name = "assume-data-lake-roles"
  user = aws_iam_user.vault_data_lake.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeDataLakeRoles"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = [aws_iam_role.data_lake_reader.arn, aws_iam_role.data_lake_writer.arn]
    }]
  })
}

# ---- trust policy: only the vault-data-lake user may assume these roles ------
data "aws_iam_policy_document" "data_lake_assume_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.vault_data_lake.arn]
    }
  }
}

# ---- READER role (DuckDB transform) → attaches the read policy --------------
resource "aws_iam_role" "data_lake_reader" {
  name                 = "ktayl-data-lake-reader"
  description          = "Assumed (via Vault) by the DuckDB transform Job for read-only S3 lake access."
  assume_role_policy   = data.aws_iam_policy_document.data_lake_assume_trust.json
  max_session_duration = 3600
  tags                 = { component = "data-platform", layer = "raw-lake" }
}

resource "aws_iam_role_policy_attachment" "data_lake_reader" {
  role       = aws_iam_role.data_lake_reader.name
  policy_arn = aws_iam_policy.data_lake_read.arn # defined in data-lake.tf
}

# ---- WRITER role (domain producers) → attaches the raw/* write policy -------
resource "aws_iam_role" "data_lake_writer" {
  name                 = "ktayl-data-lake-writer"
  description          = "Assumed (via Vault) by domain producers to write Parquet under raw/* of the lake."
  assume_role_policy   = data.aws_iam_policy_document.data_lake_assume_trust.json
  max_session_duration = 3600
  tags                 = { component = "data-platform", layer = "raw-lake" }
}

resource "aws_iam_role_policy_attachment" "data_lake_writer" {
  role       = aws_iam_role.data_lake_writer.name
  policy_arn = aws_iam_policy.data_lake_write.arn # defined in data-lake.tf
}

# ---- outputs: what the Vault engine config consumes -------------------------
output "vault_data_lake_access_key_id" {
  description = "Access key id for the vault-data-lake principal → Vault aws/config/root."
  value       = aws_iam_access_key.vault_data_lake.id
}

output "vault_data_lake_secret_access_key" {
  description = "Secret for the vault-data-lake principal → Vault aws/config/root."
  value       = aws_iam_access_key.vault_data_lake.secret
  sensitive   = true
}

output "data_lake_reader_role_arn" {
  description = "Role ARN Vault assumes for DuckDB read creds (aws/roles/data-lake-read)."
  value       = aws_iam_role.data_lake_reader.arn
}

output "data_lake_writer_role_arn" {
  description = "Role ARN Vault assumes for producer write creds (aws/roles/data-lake-write)."
  value       = aws_iam_role.data_lake_writer.arn
}
