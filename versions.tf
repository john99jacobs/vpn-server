terraform {
  required_version = ">= 1.14"

  # State lives in S3 so more than one machine can run plan/apply against the
  # same truth. Partial configuration: bucket and region come from backend.hcl
  # (gitignored; written by ./init-state-bucket), because the bucket name
  # contains the account ID and this repo is public. use_lockfile is S3-native
  # locking, so there is no DynamoDB table to manage.
  backend "s3" {
    key          = "vpn-server/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
