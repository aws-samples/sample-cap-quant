# EKS Pod Identity associations: map in-cluster ServiceAccounts to the IAM roles created in infra/.
# The namespaces / ServiceAccounts themselves are created by the Helm charts and k8s/ manifests.

# AWS Load Balancer Controller (Helm chart creates the SA in kube-system)
resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = local.infra.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = local.infra.alb_controller_role_arn
}

# Envoy data-plane pods (the extproc container signs Bedrock requests with the pod's credentials).
# Namespace / SA names must match k8s/ai-gateway/00-serviceaccount.yaml and the EnvoyProxy resource.
resource "aws_eks_pod_identity_association" "aigw_dataplane" {
  cluster_name    = local.infra.cluster_name
  namespace       = "envoy-gateway-system"
  service_account = "ai-gateway-dataplane-aws"
  role_arn        = local.infra.aigw_bedrock_role_arn
}
