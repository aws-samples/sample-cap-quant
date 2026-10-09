# ---------- Karpenter node pools (prod) ----------
# IAM roles, the interruption queue, and the karpenter.sh/discovery tags come from infra/modules/eks (enable_karpenter).
# This file installs the controller and declares three pools. Workloads choose a pool with nodeSelector
# tpp.io/pool=<name> (apps/envs/prod.tfvars -> node_selectors); ClickHouse additionally tolerates its taint.
#
# First prod apply: include helm_release.karpenter in the targeted first pass so the NodePool / EC2NodeClass CRDs
# exist before the kubernetes_manifest resources below are planned (apps/README.md).

resource "helm_release" "karpenter" {
  count = var.karpenter.enabled ? 1 : 0

  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  version          = var.karpenter.version
  timeout          = 600

  set {
    name  = "settings.clusterName"
    value = local.cluster_name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = local.infra.cluster_endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = local.infra.karpenter_queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.infra.karpenter_iam_role_arn
  }
  # The controller must not run on nodes it manages
  set {
    name  = "nodeSelector.tpp\\.io/pool"
    value = "system"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "500m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }
}

locals {
  karpenter_node_class = "tpp"
  karpenter_discovery  = { "karpenter.sh/discovery" = local.cluster_name }

  # name => { instance families/sizes, cpu limit, taints, consolidation }
  karpenter_pools = {
    # LiteLLM, PgBouncer, Scorer, Dashboard: latency-sensitive, stateless, consolidate freely
    data-plane = {
      families      = ["m7i"]
      sizes         = ["xlarge", "2xlarge"]
      cpu_limit     = "96"
      taints        = []
      consolidation = "WhenEmptyOrUnderutilized"
    }
    # Prometheus, Grafana, Alertmanager, Langfuse web + worker: stateful PVCs, only consolidate empty nodes
    observability = {
      families      = ["m7i"]
      sizes         = ["2xlarge", "4xlarge"]
      cpu_limit     = "48"
      taints        = []
      consolidation = "WhenEmpty"
    }
    # ClickHouse: memory-heavy, dedicated via taint
    clickhouse = {
      families      = ["r7i"]
      sizes         = ["2xlarge", "4xlarge"]
      cpu_limit     = "32"
      taints        = [{ key = "tpp.io/clickhouse", value = "true", effect = "NoSchedule" }]
      consolidation = "WhenEmpty"
    }
  }
}

resource "kubernetes_manifest" "karpenter_node_class" {
  count = var.karpenter.enabled ? 1 : 0

  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = local.karpenter_node_class
    }
    spec = {
      role = local.infra.karpenter_node_iam_role_name
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      subnetSelectorTerms        = [{ tags = local.karpenter_discovery }]
      securityGroupSelectorTerms = [{ tags = local.karpenter_discovery }]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize = "80Gi"
            volumeType = "gp3"
            encrypted  = true
          }
        }
      ]
      metadataOptions = {
        httpPutResponseHopLimit = 1 # pods use IRSA, never the node role
        httpTokens              = "required"
      }
      tags = {
        Project     = "tpp"
        Environment = var.env
        ManagedBy   = "karpenter"
      }
    }
  }

  depends_on = [helm_release.karpenter]
}

resource "kubernetes_manifest" "karpenter_node_pool" {
  for_each = var.karpenter.enabled ? local.karpenter_pools : {}

  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = each.key
    }
    spec = {
      template = {
        metadata = {
          labels = { "tpp.io/pool" = each.key }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.karpenter_node_class
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = each.value.families },
            { key = "karpenter.k8s.aws/instance-size", operator = "In", values = each.value.sizes },
          ]
          taints      = each.value.taints
          expireAfter = "720h"
        }
      }
      limits = {
        cpu = each.value.cpu_limit
      }
      disruption = {
        consolidationPolicy = each.value.consolidation
        consolidateAfter    = "2m"
      }
    }
  }

  depends_on = [kubernetes_manifest.karpenter_node_class]
}
