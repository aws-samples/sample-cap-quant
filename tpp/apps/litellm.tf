# ---------- LiteLLM Proxy (M3) ----------
# Uses native K8s resources instead of the community Helm chart: fully controllable deployment, config isomorphic to the local/ validation environment.

resource "random_password" "litellm_master_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "litellm" {
  name = "tpp/litellm"
}

resource "aws_secretsmanager_secret_version" "litellm" {
  secret_id = aws_secretsmanager_secret.litellm.id
  secret_string = jsonencode({
    master_key = "sk-${random_password.litellm_master_key.result}"
  })
}

resource "kubernetes_namespace_v1" "litellm" {
  metadata {
    name = "litellm"
  }
}

# SA name must exactly match the IRSA subject in infra/modules/iam: litellm/litellm
resource "kubernetes_service_account_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = local.infra.litellm_role_arn
    }
  }
}

resource "kubernetes_config_map_v1" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }

  data = {
    "config.yaml" = file("${path.module}/values/litellm-config.yaml")
  }
}

# Sync from Secrets Manager and template the runtime env:
#   LITELLM_MASTER_KEY <- tpp/litellm
#   DATABASE_URL       <- RDS managed master password (rds!...) + RDS address from remote state
resource "kubernetes_manifest" "litellm_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "litellm-env"
      namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    }
    spec = {
      refreshInterval = "5m"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "litellm-env"
        template = {
          engineVersion = "v2"
          data = {
            LITELLM_MASTER_KEY  = "{{ .master_key }}"
            DATABASE_URL        = "postgresql://{{ .db_username }}:{{ .db_password | urlquery }}@${local.infra.rds_address}:5432/litellm"
            LANGFUSE_PUBLIC_KEY = "{{ .langfuse_public_key }}"
            LANGFUSE_SECRET_KEY = "{{ .langfuse_secret_key }}"
            LANGFUSE_HOST       = "http://langfuse-web.langfuse:3000"
          }
        }
      }
      data = [
        {
          secretKey = "master_key"
          remoteRef = { key = "tpp/litellm", property = "master_key" }
        },
        {
          secretKey = "langfuse_public_key"
          remoteRef = { key = "tpp/langfuse", property = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY" }
        },
        {
          secretKey = "langfuse_secret_key"
          remoteRef = { key = "tpp/langfuse", property = "LANGFUSE_INIT_PROJECT_SECRET_KEY" }
        },
        {
          secretKey = "db_username"
          remoteRef = { key = local.infra.rds_master_user_secret_arn, property = "username" }
        },
        {
          secretKey = "db_password"
          remoteRef = { key = local.infra.rds_master_user_secret_arn, property = "password" }
        },
      ]
    }
  }

  depends_on = [aws_secretsmanager_secret_version.litellm]
}

resource "kubernetes_deployment_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    labels    = { app = "litellm" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "litellm" }
    }

    template {
      metadata {
        labels = { app = "litellm" }
        annotations = {
          # Rolling restart on config changes
          "tpp/config-hash" = sha256(file("${path.module}/values/litellm-config.yaml"))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.litellm.metadata[0].name

        container {
          name  = "litellm"
          image = "ghcr.io/berriai/litellm:main-stable"
          args  = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

          port {
            name           = "http"
            container_port = 4000
          }

          env_from {
            secret_ref {
              name = "litellm-env"
            }
          }

          # Reloader updates this value with a Secret checksum to trigger a
          # rollout. Keep it first so Terraform can ignore only that dynamic
          # value while continuing to manage the application environment.
          env {
            name  = "STAKATER_LITELLM_ENV_SECRET"
            value = "managed-by-reloader"
          }
          env {
            name  = "REDIS_HOST"
            value = local.infra.redis_endpoint
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/litellm"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          # First startup includes prisma migrate, allow plenty of headroom
          startup_probe {
            http_get {
              path = "/health/readiness"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = 30
          }

          readiness_probe {
            http_get {
              path = "/health/readiness"
              port = "http"
            }
            period_seconds = 15
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = "http"
            }
            period_seconds    = 15
            failure_threshold = 4
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.litellm_config.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations["reloader.stakater.com/auto"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/auto"],
      spec[0].template[0].spec[0].container[0].env[0].value,
    ]
  }

  depends_on = [kubernetes_manifest.litellm_external_secret]
}

resource "kubernetes_service_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    labels    = { app = "litellm" }
  }

  spec {
    selector = { app = "litellm" }

    port {
      name        = "http"
      port        = 4000
      target_port = "http"
    }
  }
}

# Reloader restarts LiteLLM when External Secrets refreshes its environment
# secret after RDS password rotation.
resource "kubernetes_annotations" "litellm_reloader" {
  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = kubernetes_deployment_v1.litellm.metadata[0].name
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }

  annotations = {
    "reloader.stakater.com/auto" = "true"
  }

  template_annotations = {
    "reloader.stakater.com/auto" = "true"
  }

  depends_on = [helm_release.reloader]
}

# Prometheus scrapes /metrics (data source for the Scorer and Grafana)
resource "kubernetes_manifest" "litellm_service_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "litellm"
      namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = { app = "litellm" }
      }
      endpoints = [
        {
          port     = "http"
          path     = "/metrics/"
          interval = "15s"
          # /metrics is protected by LiteLLM auth, scrape with the master key
          authorization = {
            type = "Bearer"
            credentials = {
              name = "litellm-env"
              key  = "LITELLM_MASTER_KEY"
            }
          }
        }
      ]
    }
  }
}

output "litellm_master_key" {
  value     = "sk-${random_password.litellm_master_key.result}"
  sensitive = true
}
