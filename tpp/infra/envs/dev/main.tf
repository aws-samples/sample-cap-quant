data "aws_caller_identity" "current" {}

locals {
  name       = "tpp-${var.env}"
  account_id = data.aws_caller_identity.current.account_id
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.region
  vpc_cidr = var.vpc_cidr
  azs      = var.azs

  single_nat_gateway = true # cost saving for dev
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  cluster_version    = var.cluster_version
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
}

module "rds" {
  source = "../../modules/rds"

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  # dev sizing; prod overrides: multi_az=true, deletion_protection=true, skip_final_snapshot=false
  instance_class      = "db.t4g.medium"
  multi_az            = false
  deletion_protection = false
  skip_final_snapshot = true
}

module "elasticache" {
  source = "../../modules/elasticache"

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  node_type = "cache.t4g.micro"
  num_nodes = 1
}

module "s3" {
  source = "../../modules/s3"

  bucket_name = "${local.name}-langfuse-${local.account_id}"
}

module "iam" {
  source = "../../modules/iam"

  name_prefix         = local.name
  region              = var.region
  account_id          = local.account_id
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider       = module.eks.oidc_provider
  langfuse_bucket_arn = module.s3.bucket_arn
}
