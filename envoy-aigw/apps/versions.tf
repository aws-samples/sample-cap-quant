terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "aigw-tfstate-<ACCOUNT_ID>"
    key          = "apps/dev/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}
