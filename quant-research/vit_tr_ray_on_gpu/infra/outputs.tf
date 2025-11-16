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

output "accesskey" {
  value = var.accesskey
}

output "secrectkey" {
  value = var.secrectkey
}

output "raw_data_s3bucket_https_endpoint_url" {
  value = var.raw_data_s3bucket_https_endpoint_url
}

output "region_id" {
  value = var.region
}

output "ecr_url" {
  value = var.ecr_url
}
