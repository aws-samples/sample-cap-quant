output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC issuer (without the https:// prefix), used by the IRSA assume policy"
  value       = module.eks.oidc_provider
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

# ---- Karpenter (null when enable_karpenter = false) ----
output "karpenter_iam_role_arn" {
  description = "IRSA role for the Karpenter controller (ServiceAccount karpenter/karpenter)"
  value       = try(module.karpenter[0].iam_role_arn, null)
}

output "karpenter_node_iam_role_name" {
  description = "IAM role Karpenter-launched nodes assume; referenced by EC2NodeClass.spec.role"
  value       = try(module.karpenter[0].node_iam_role_name, null)
}

output "karpenter_queue_name" {
  description = "SQS queue for spot interruption and health events"
  value       = try(module.karpenter[0].queue_name, null)
}
