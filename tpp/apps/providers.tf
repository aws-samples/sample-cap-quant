data "aws_caller_identity" "current" {}

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = "tpp-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "infra/${var.env}/terraform.tfstate"
    # The state bucket lives in us-west-2 and is shared by every environment, so this is deliberately not
    # var.region: prod runs in us-east-1 but still reads its state from the us-west-2 bucket.
    region = "us-west-2"
  }
}

locals {
  infra        = data.terraform_remote_state.infra.outputs
  cluster_name = local.infra.cluster_name
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "tpp"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
    }
  }
}
