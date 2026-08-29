# Remote state backend.
#
# Bootstrap note: the S3 bucket + DynamoDB lock table are created in story #298.
# Until they exist, Terraform runs on LOCAL state (this file's block stays
# commented). Once #298 lands, uncomment + `terraform init -migrate-state`.
#
# terraform {
#   backend "s3" {
#     bucket         = "minicloud-terraform-state"   # created in #298 (EU region)
#     key            = "cloud/terraform.tfstate"
#     region         = "eu-west-1"
#     dynamodb_table = "minicloud-terraform-locks"   # state locking (free tier)
#     encrypt        = true
#   }
# }
