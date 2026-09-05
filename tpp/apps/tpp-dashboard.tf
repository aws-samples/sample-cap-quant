# ---------- TPP Dashboard: standalone operations view (M7) ----------
# Single container = FastAPI aggregation backend (Prometheus + LiteLLM Management API) + static single-page frontend.
# Displays: user quotas (editable, written back) / channel spend, health, weight / channel performance percentiles / links to 4 dashboards.
# Same security model as Prometheus: no built-in auth, no Ingress exposure, accessed via kubectl tunnel (local port 3020).

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

# LiteLLM master key (user quota reads/writes go through the Management API)
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

# The channel registry shares the same values file as the scorer, keeping the dashboard's channel definitions consistent
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
    replicas = 1 # Read-only view + low-frequency quota writes, a single replica is enough

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
