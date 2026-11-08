# Data lake (ktayl Data Platform — ADR-008) — the raw-data landing/replay layer on S3.
#
#   S3 raw lake  →  DuckDB transform (reads Parquet directly)  →  CNPG serving  →  Metabase
#
# This file provisions ONLY the AWS side (OpenTofu, per the repo-split rule): the bucket, its
# security controls, a data-lake-scoped budget, and the scoped IAM policies the in-cluster workload
# uses. The DuckDB Job gets short-lived STS creds via the **Vault AWS secrets engine** (ADR-008):
# Vault references the managed policies below — NO static AWS keys land in k8s, Git, or tofu state.
# The loader/transform code lives in ktayl-data-platform; its k8s runtime is deployed by ArgoCD.

locals {
  # account id via the existing data.aws_caller_identity.current (declared in state-backend.tf)
  data_lake_bucket = "minicloud-data-lake-${data.aws_caller_identity.current.account_id}"
  data_lake_budget = 10 # USD/month — scoped tripwire for the lake (the global $15 budget still applies)
}

# ---- the bucket -------------------------------------------------------------
resource "aws_s3_bucket" "data_lake" {
  bucket = local.data_lake_bucket
  tags   = { component = "data-platform", layer = "raw-lake" }
}

# Block ALL public access (defence in depth — the bucket is private by design).
resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt at rest — SSE-S3 (AES256) to start (ADR-008: KMS is a later upgrade, not MVP).
resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

# Versioning — the lake is a REPLAYABLE archive; keep prior object versions.
resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration { status = "Enabled" }
}

# Lifecycle — bound cost without touching the hot data (ADR-008: no auto-Glacier for small data):
#   - expire NONCURRENT versions after 90 days (don't keep superseded copies forever)
#   - abort incomplete multipart uploads after 7 days (orphaned-part cost leak)
resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

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
}

# Enforce HTTPS — deny any non-TLS request (ADR-008 security posture).
resource "aws_s3_bucket_policy" "data_lake_tls_only" {
  bucket = aws_s3_bucket.data_lake.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.data_lake.arn, "${aws_s3_bucket.data_lake.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---- scoped IAM (what Vault's dynamic creds reference — ADR-008) ------------
# Producer/reader split (ADR-008): producers may WRITE under raw/*, the DuckDB transform reads
# everything. Vault attaches these managed policies to the short-lived identities it mints.

# READER — the DuckDB transform Job: list + get only.
resource "aws_iam_policy" "data_lake_read" {
  name        = "ktayl-data-lake-read"
  description = "Read-only access to the ktayl data-lake bucket (DuckDB transform; via Vault STS)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.data_lake.arn
      },
      {
        Sid      = "ReadObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.data_lake.arn}/*"
      }
    ]
  })
}

# WRITER — domain producers: put under raw/* only (no delete, no read of others' prefixes).
resource "aws_iam_policy" "data_lake_write" {
  name        = "ktayl-data-lake-write"
  description = "Write access to raw/* of the ktayl data-lake bucket (domain producers; via Vault STS)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListBucket"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.data_lake.arn
        Condition = { StringLike = { "s3:prefix" = ["raw/*"] } }
      },
      {
        Sid      = "WriteRawObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data_lake.arn}/raw/*"
      }
    ]
  })
}

# ---- data-lake-scoped budget (the global $15 budget in budgets.tf still applies) ----
# A tripwire filtered to S3 only, so lake growth is visible separately. Alerts at $5/$8/$10 actual.
resource "aws_budgets_budget" "data_lake" {
  name         = "minicloud-data-lake"
  budget_type  = "COST"
  limit_amount = tostring(local.data_lake_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Simple Storage Service"]
  }

  dynamic "notification" {
    for_each = [50, 80, 100] # = $5 / $8 / $10 on a $10 budget
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [local.budget_alert_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [local.budget_alert_email]
  }
}

# ---- outputs ----------------------------------------------------------------
output "data_lake_bucket" {
  description = "The ktayl data-lake S3 bucket name."
  value       = aws_s3_bucket.data_lake.id
}

output "data_lake_read_policy_arn" {
  description = "Managed policy ARN the Vault AWS secrets engine attaches for DuckDB read access."
  value       = aws_iam_policy.data_lake_read.arn
}

output "data_lake_write_policy_arn" {
  description = "Managed policy ARN the Vault AWS secrets engine attaches for producer write access."
  value       = aws_iam_policy.data_lake_write.arn
}
