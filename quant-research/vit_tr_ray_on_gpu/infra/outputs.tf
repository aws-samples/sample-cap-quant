output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${local.name}"
}

output "elastic_cache_redis_cluster_arn" {
  description = "Cluster arn of the cache cluster"
  value       = module.elasticache.cluster_arn
}

output "elastic_cache_redis_endpoint" {
  description = "Cluster endpoint of the cache cluster"
  value       = module.elasticache.cluster_cache_nodes[0].address
}


output "raw_data_s3bucket_https_endpoint_url" {
  value = var.raw_data_s3bucket_https_endpoint_url
}

output "name" {
  value = var.name
}

output "region_id" {
  value = var.region
}

output "aws_account_id" {
  value = var.aws_account_id
}

output "ecr_url" {
  value = var.ecr_url
}

output "ray_pod_role_arn" {
  description = "ARN of the IAM role for Ray pods"
  value       = aws_iam_role.ray_pod_role.arn
}

output "ray_service_account_name" {
  description = "Name of the Kubernetes service account"
  value       = kubernetes_service_account.ray_service_account.metadata[0].name
}
