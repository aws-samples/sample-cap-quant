terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  backend "s3" {
    bucket       = "tpp-tfstate-135709585800"
    key          = "infra/dev/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true # S3 原生锁,免 DynamoDB(需 TF >= 1.10)
  }
}
