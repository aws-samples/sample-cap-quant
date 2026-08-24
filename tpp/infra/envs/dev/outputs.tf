# apps 层(state 2)经 terraform_remote_state 读取这些 output

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

output "rds_address" {
  value = module.rds.address
}

output "rds_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}

output "redis_endpoint" {
  value = module.elasticache.primary_endpoint
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
