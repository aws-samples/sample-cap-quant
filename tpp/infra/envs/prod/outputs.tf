# The apps layer (state 2) reads these outputs via terraform_remote_state.
# Names shared with envs/dev keep the apps code environment-agnostic; prod-only outputs are read with try().

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

# ---- Ledger (Aurora). Same output names as dev's RDS so LiteLLM's DATABASE_URL template is unchanged. ----
output "rds_address" {
  description = "Aurora writer endpoint"
  value       = module.aurora.address
}

output "rds_reader_address" {
  value = module.aurora.reader_address
}

output "rds_master_user_secret_arn" {
  value = module.aurora.master_user_secret_arn
}

# ---- Langfuse metadata (separate RDS) ----
output "langfuse_rds_address" {
  value = module.rds.address
}

output "langfuse_rds_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}

# ---- Redis ----
output "redis_endpoint" {
  description = "Compatibility alias: the router Redis"
  value       = module.redis_router.primary_endpoint
}

output "redis_router_endpoint" {
  value = module.redis_router.primary_endpoint
}

output "redis_queue_endpoint" {
  value = module.redis_queue.primary_endpoint
}

output "redis_tls_enabled" {
  value = true
}

output "secret_prefix" {
  description = "Secrets Manager prefix; the apps layer must use the same value (apps/envs/prod.tfvars)"
  value       = var.secret_prefix
}

output "langfuse_bucket" {
  value = module.s3.bucket_name
}

output "litellm_role_arn" {
  value = module.iam.litellm_role_arn
}

output "langfuse_role_arn" {
  value = module.iam.langfuse_role_arn
}

output "external_secrets_role_arn" {
  value = module.iam.external_secrets_role_arn
}

output "alb_controller_role_arn" {
  value = module.iam.alb_controller_role_arn
}

# ---- Karpenter ----
output "karpenter_iam_role_arn" {
  value = module.eks.karpenter_iam_role_arn
}

output "karpenter_node_iam_role_name" {
  value = module.eks.karpenter_node_iam_role_name
}

output "karpenter_queue_name" {
  value = module.eks.karpenter_queue_name
}
