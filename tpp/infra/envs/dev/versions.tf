terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  backend "s3" {
    bucket       = "tpp-tfstate-<aws account>"
    key          = "infra/dev/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true # S3 native locking, no DynamoDB needed (requires TF >= 1.10)
  }
}
