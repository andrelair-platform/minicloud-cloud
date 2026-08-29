# S3 + DynamoDB remote-state backend (story #298).
# Bootstrap: created with LOCAL state, then backend.tf's s3 block is activated
# and the state migrated in (`tofu init -migrate-state`). Cost ≈ pennies
# (tiny state object + DynamoDB free tier).

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "minicloud-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table   = "minicloud-tofu-locks"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true # this bucket holds our own state — never auto-delete
  }

  tags = { purpose = "opentofu-state" }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST" # free tier / pennies — no fixed cost
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { purpose = "opentofu-state-lock" }
}
