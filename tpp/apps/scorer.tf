# ---------- Scorer:智能渠道权重调度(M5)----------

variable "scorer_image_tag" {
  type    = string
  default = "0.1.0"
}

resource "aws_ecr_repository" "scorer" {
  name                 = "tpp/scorer"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "kubernetes_namespace_v1" "scorer" {
  metadata {
    name = "scorer"
  }
}

# LiteLLM master key(Management API 认证)
resource "kubernetes_manifest" "scorer_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "scorer-env"
      namespace = kubernetes_namespace_v1.scorer.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      target          = { name = "scorer-env" }
      data = [
        {
          secretKey = "LITELLM_MASTER_KEY"
          remoteRef = { key = "tpp/litellm", property = "master_key" }
        }
      ]
    }
  }
}

resource "kubernetes_config_map_v1" "scorer_channels" {
  metadata {
    name      = "scorer-channels"
    namespace = kubernetes_namespace_v1.scorer.metadata[0].name
  }

  data = {
    "channels.yaml" = file("${path.module}/values/scorer-channels.yaml")
  }
}

resource "kubernetes_deployment_v1" "scorer" {
  metadata {
    name      = "scorer"
    namespace = kubernetes_namespace_v1.scorer.metadata[0].name
    labels    = { app = "scorer" }
  }

  spec {
    replicas = 1 # 不在请求路径上,单副本足够;挂了权重只是冻结

    selector {
      match_labels = { app = "scorer" }
    }

    template {
      metadata {
        labels = { app = "scorer" }
        annotations = {
          "tpp/channels-hash" = sha256(file("${path.module}/values/scorer-channels.yaml"))
        }
      }

      spec {
        container {
          name  = "scorer"
          image = "${aws_ecr_repository.scorer.repository_url}:${var.scorer_image_tag}"

          env {
            name  = "PROMETHEUS_URL"
            value = "http://kube-prometheus-stack-prometheus.monitoring:9090"
          }
          env {
            name  = "LITELLM_URL"
            value = "http://litellm.litellm:4000"
          }
          env {
            name  = "REDIS_HOST"
            value = local.infra.redis_endpoint
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          env {
            name  = "CHANNELS_FILE"
            value = "/etc/scorer/channels.yaml"
          }
          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = "scorer-env"
                key  = "LITELLM_MASTER_KEY"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 9100
          }

          volume_mount {
            name       = "channels"
            mount_path = "/etc/scorer"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "channels"
          config_map {
            name = kubernetes_config_map_v1.scorer_channels.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.scorer_external_secret]
}

resource "kubernetes_service_v1" "scorer" {
  metadata {
    name      = "scorer"
    namespace = kubernetes_namespace_v1.scorer.metadata[0].name
    labels    = { app = "scorer" }
  }

  spec {
    selector = { app = "scorer" }

    port {
      name        = "metrics"
      port        = 9100
      target_port = "metrics"
    }
  }
}

resource "kubernetes_manifest" "scorer_service_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "scorer"
      namespace = kubernetes_namespace_v1.scorer.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = { app = "scorer" }
      }
      endpoints = [
        {
          port     = "metrics"
          interval = "30s"
        }
      ]
    }
  }
}
