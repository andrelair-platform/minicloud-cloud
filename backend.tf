terraform {
  backend "s3" {
    bucket         = "minicloud-tfstate-625830750465"
    key            = "cloud/state.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "minicloud-tofu-locks"
    encrypt        = true
  }
}
