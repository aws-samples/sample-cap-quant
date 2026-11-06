data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "aigw-tfstate-<ACCOUNT_ID>"
    key    = "infra/${var.env}/terraform.tfstate"
    region = "us-east-2"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}

provider "aws" {
  region = local.infra.region

  default_tags {
    tags = {
      Project     = "envoy-aigw"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}
