locals {
  node_groups = var.node_groups != null ? var.node_groups : {
    general = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      disk_size      = 80
      labels         = {}
      taints         = {}
    }
  }

  # Karpenter finds subnets and the node security group by this tag (EC2NodeClass selector terms in apps/karpenter.tf)
  discovery_tags = var.enable_karpenter ? { "karpenter.sh/discovery" = var.cluster_name } : {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access = true

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  enable_irsa = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  node_security_group_tags = local.discovery_tags

  eks_managed_node_groups = {
    for name, ng in local.node_groups : name => {
      instance_types = ng.instance_types
      min_size       = ng.min_size
      max_size       = ng.max_size
      desired_size   = ng.desired_size
      disk_size      = ng.disk_size
      labels         = ng.labels
      taints         = ng.taints
    }
  }
}

# IRSA for the EBS CSI driver (Prometheus/ClickHouse PVCs depend on it)
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ---- Karpenter (prod): controller role via IRSA, node role + access entry, interruption queue ----
# The Helm chart, EC2NodeClass, and NodePools live in the apps layer so a NodePool change never touches this state.
module "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions = true

  # Same credential model as the rest of the platform: IRSA, not EKS Pod Identity
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]
  enable_pod_identity             = false
  create_pod_identity_association = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
