terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "tpp-tfstate-<aws account>"
    key          = "infra/prod/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true # S3 native locking, no DynamoDB needed (requires TF >= 1.10)
  }
}
