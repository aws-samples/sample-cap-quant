provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "envoy-aigw"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
