# TPP infrastructure sized for 500 seats (docs/scaling-500-users.md). Differences from envs/dev:
#   - one NAT gateway per AZ
#   - EKS: a small 'system' managed node group plus Karpenter IAM; the data-plane / observability / clickhouse
#     node pools are Karpenter NodePools defined in apps/karpenter.tf
#   - ledger on Aurora PostgreSQL (writer + reader); Langfuse metadata on its own Multi-AZ RDS instance
#   - two Redis replication groups (router / Langfuse queue), each primary + replica, TLS + AUTH
# Bedrock quota (cross-account sharding, Provisioned Throughput) is a business workstream and is not modeled here.

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

  single_nat_gateway = false # one NAT per AZ: a single-AZ NAT failure must not take down egress for the whole site

  extra_private_subnet_tags = {
    "karpenter.sh/discovery" = local.name
  }
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  cluster_version    = var.cluster_version
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  enable_karpenter = true

  # The system group only hosts Karpenter, CoreDNS, the ALB controller, External Secrets, Reloader, KEDA.
  # Workloads carry nodeSelector tpp.io/pool=<data-plane|observability|clickhouse> and land on Karpenter nodes.
  node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      min_size       = 2
      max_size       = 4
      desired_size   = var.system_node_desired_size
      labels         = { "tpp.io/pool" = "system" }
    }
  }
}

# ---- Ledger: Aurora PostgreSQL ----
module "aurora" {
  source = "../../modules/aurora"

  name                       = "${local.name}-ledger"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  instance_class = var.aurora_instance_class
  instance_count = var.aurora_instance_count
  db_name        = "litellm"

  deletion_protection = true
  skip_final_snapshot = false
}

# ---- Langfuse metadata: separate RDS instance so trace writes never contend with the ledger ----
module "rds" {
  source = "../../modules/rds"

  name                       = "${local.name}-langfuse"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  db_name                 = "langfuse"
  instance_class          = var.langfuse_rds_instance_class
  allocated_storage       = 100
  max_allocated_storage   = 500
  backup_retention_period = 14

  multi_az            = true
  deletion_protection = true
  skip_final_snapshot = false
}

# ---- Redis AUTH tokens. ElastiCache has no managed-password equivalent of RDS, so the token is generated here and
#      handed to the apps layer only through Secrets Manager (External Secrets reads tpp/*). ----
resource "random_password" "redis_router_auth" {
  length  = 48
  special = false # ElastiCache forbids @ " / in AUTH tokens; alphanumeric keeps the URL-encoding question moot
}

resource "random_password" "redis_queue_auth" {
  length  = 48
  special = false
}

# Router Redis: LiteLLM router state, per-key rpm/tpm counters, cooldowns, Scorer EWMA state.
# Hard dependency on the request path, so primary + replica across AZs with automatic failover.
module "redis_router" {
  source = "../../modules/elasticache"

  name                       = "${local.name}-router"
  description                = "TPP router Redis: LiteLLM router state + rate limits + Scorer state"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  node_type          = var.redis_router_node_type
  num_nodes          = 2
  multi_az_enabled   = true
  transit_encryption = true
  auth_token         = random_password.redis_router_auth.result
}

# Queue Redis: Langfuse ingestion queue. noeviction turns "queue full" into loud ingestion errors instead of
# silently dropped traces, which is the failure mode the shared dev instance has.
resource "aws_elasticache_parameter_group" "queue" {
  name   = "${local.name}-queue-noeviction"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

module "redis_queue" {
  source = "../../modules/elasticache"

  name                       = "${local.name}-queue"
  description                = "TPP queue Redis: Langfuse ingestion queue"
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  node_type            = var.redis_queue_node_type
  num_nodes            = 2
  multi_az_enabled     = true
  transit_encryption   = true
  auth_token           = random_password.redis_queue_auth.result
  parameter_group_name = aws_elasticache_parameter_group.queue.name
}

resource "aws_secretsmanager_secret" "redis_router" {
  name = "${var.secret_prefix}/redis-router"
}

resource "aws_secretsmanager_secret_version" "redis_router" {
  secret_id = aws_secretsmanager_secret.redis_router.id
  secret_string = jsonencode({
    auth_token = random_password.redis_router_auth.result
    host       = module.redis_router.primary_endpoint
    port       = "6379"
  })
}

resource "aws_secretsmanager_secret" "redis_queue" {
  name = "${var.secret_prefix}/redis-queue"
}

resource "aws_secretsmanager_secret_version" "redis_queue" {
  secret_id = aws_secretsmanager_secret.redis_queue.id
  secret_string = jsonencode({
    auth_token = random_password.redis_queue_auth.result
    host       = module.redis_queue.primary_endpoint
    port       = "6379"
  })
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
