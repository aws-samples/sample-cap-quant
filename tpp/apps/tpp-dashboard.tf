# ---------- TPP Dashboard:独立运营视图(M7)----------
# 单容器 = FastAPI 聚合后端(Prometheus + LiteLLM Management API)+ 静态单页前端。
# 展示:用户配额(可改写回)/ 渠道消费·健康度·权重 / 渠道性能分位数 / 4 个 dashboard 链接。
# 与 Prometheus 相同的安全模型:无自身认证,不暴露 Ingress,经 kubectl 隧道访问(本地 3020)。

variable "dashboard_image_tag" {
  type    = string
  default = "0.1.2"
}

resource "aws_ecr_repository" "dashboard" {
  name                 = "tpp/dashboard"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "kubernetes_namespace_v1" "dashboard" {
  metadata {
    name = "dashboard"
  }
}

# LiteLLM master key(用户配额读写走 Management API)
resource "kubernetes_manifest" "dashboard_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "dashboard-env"
      namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      target          = { name = "dashboard-env" }
      data = [
        {
          secretKey = "LITELLM_MASTER_KEY"
          remoteRef = { key = "tpp/litellm", property = "master_key" }
        }
      ]
    }
  }
}

# 渠道注册表与 scorer 共用同一份 values 文件,保证 dashboard 展示的渠道口径一致
resource "kubernetes_config_map_v1" "dashboard_channels" {
  metadata {
    name      = "dashboard-channels"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
  }

  data = {
    "channels.yaml" = file("${path.module}/values/scorer-channels.yaml")
  }
}

resource "kubernetes_deployment_v1" "dashboard" {
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
    labels    = { app = "dashboard" }
  }

  spec {
    replicas = 1 # 只读视图 + 低频配额写,单副本足够

    selector {
      match_labels = { app = "dashboard" }
    }

    template {
      metadata {
        labels = { app = "dashboard" }
        annotations = {
          "tpp/channels-hash" = sha256(file("${path.module}/values/scorer-channels.yaml"))
        }
      }

      spec {
        container {
          name  = "dashboard"
          image = "${aws_ecr_repository.dashboard.repository_url}:${var.dashboard_image_tag}"

          env {
            name  = "PROMETHEUS_URL"
            value = "http://kube-prometheus-stack-prometheus.monitoring:9090"
          }
          env {
            name  = "LITELLM_URL"
            value = "http://litellm.litellm:4000"
          }
          env {
            name  = "CHANNELS_FILE"
            value = "/etc/dashboard/channels.yaml"
          }
          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = "dashboard-env"
                key  = "LITELLM_MASTER_KEY"
              }
            }
          }

          port {
            name           = "http"
            container_port = 8080
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          volume_mount {
            name       = "channels"
            mount_path = "/etc/dashboard"
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
            name = kubernetes_config_map_v1.dashboard_channels.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.dashboard_external_secret]
}

resource "kubernetes_service_v1" "dashboard" {
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
    labels    = { app = "dashboard" }
  }

  spec {
    selector = { app = "dashboard" }

    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }
}
