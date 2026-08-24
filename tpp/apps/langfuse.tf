# ---------- Langfuse(M4:trace)----------
# 外部依赖全部指向 AWS 托管资源(RDS/ElastiCache/S3),ClickHouse 自管单节点 StatefulSet。

resource "kubernetes_namespace_v1" "langfuse" {
  metadata {
    name = "langfuse"
  }
}

# ---- headless init 凭据:org/project/API keys/管理员,存 Secrets Manager ----
resource "random_password" "langfuse_pk" {
  length  = 24
  special = false
}

resource "random_password" "langfuse_sk" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_admin_pw" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "langfuse" {
  name = "tpp/langfuse"
}

resource "aws_secretsmanager_secret_version" "langfuse" {
  secret_id = aws_secretsmanager_secret.langfuse.id
  secret_string = jsonencode({
    LANGFUSE_INIT_ORG_ID             = "tpp"
    LANGFUSE_INIT_ORG_NAME           = "TPP"
    LANGFUSE_INIT_PROJECT_ID         = "tpp-proxy"
    LANGFUSE_INIT_PROJECT_NAME       = "TPP Proxy"
    LANGFUSE_INIT_PROJECT_PUBLIC_KEY = "pk-lf-${random_password.langfuse_pk.result}"
    LANGFUSE_INIT_PROJECT_SECRET_KEY = "sk-lf-${random_password.langfuse_sk.result}"
    LANGFUSE_INIT_USER_EMAIL         = "admin@tpp.local"
    LANGFUSE_INIT_USER_NAME          = "admin"
    LANGFUSE_INIT_USER_PASSWORD      = random_password.langfuse_admin_pw.result
  })
}

resource "kubernetes_manifest" "langfuse_init_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "langfuse-init"
      namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      target          = { name = "langfuse-init" }
      dataFrom        = [{ extract = { key = "tpp/langfuse" } }]
    }
  }

  depends_on = [aws_secretsmanager_secret_version.langfuse]
}

# ---- RDS 密码同步(langfuse 命名空间自己的副本)----
resource "kubernetes_manifest" "langfuse_postgres_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "langfuse-postgres"
      namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      target          = { name = "langfuse-postgres" }
      data = [
        {
          secretKey = "password"
          remoteRef = { key = local.infra.rds_master_user_secret_arn, property = "password" }
        }
      ]
    }
  }
}

# ---- 建库 Job:RDS 上创建 langfuse 库(幂等)----
resource "kubernetes_job_v1" "langfuse_db_bootstrap" {
  metadata {
    name      = "langfuse-db-bootstrap"
    namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { app = "langfuse-db-bootstrap" }
      }

      spec {
        restart_policy = "Never"

        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["sh", "-c"]
          args = [
            "psql -tc \"SELECT 1 FROM pg_database WHERE datname='langfuse'\" | grep -q 1 || psql -c 'CREATE DATABASE langfuse'"
          ]

          env {
            name  = "PGHOST"
            value = local.infra.rds_address
          }
          env {
            name  = "PGUSER"
            value = "tpp"
          }
          env {
            name  = "PGDATABASE"
            value = "litellm"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "langfuse-postgres"
                key  = "password"
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [kubernetes_manifest.langfuse_postgres_external_secret]
}

# ---- 自管单节点 ClickHouse(trace 数据,可再生,EBS PVC)----
resource "random_password" "clickhouse" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "clickhouse" {
  metadata {
    name      = "langfuse-clickhouse"
    namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
  }

  data = {
    password = random_password.clickhouse.result
  }
}

resource "kubernetes_stateful_set_v1" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
    labels    = { app = "clickhouse" }
  }

  spec {
    service_name = "clickhouse"
    replicas     = 1

    selector {
      match_labels = { app = "clickhouse" }
    }

    template {
      metadata {
        labels = { app = "clickhouse" }
      }

      spec {
        container {
          name  = "clickhouse"
          image = "clickhouse/clickhouse-server:26.4"

          env {
            name  = "CLICKHOUSE_USER"
            value = "default"
          }
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "langfuse-clickhouse"
                key  = "password"
              }
            }
          }

          port {
            name           = "http"
            container_port = 8123
          }
          port {
            name           = "native"
            container_port = 9000
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              memory = "4Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = "http"
            }
            period_seconds = 10
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "gp3"
        resources {
          requests = {
            storage = "50Gi"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
    labels    = { app = "clickhouse" }
  }

  spec {
    selector = { app = "clickhouse" }

    port {
      name        = "http"
      port        = 8123
      target_port = "http"
    }
    port {
      name        = "native"
      port        = 9000
      target_port = "native"
    }
  }
}

# ---- Langfuse chart ----
resource "helm_release" "langfuse" {
  name       = "langfuse"
  repository = "https://langfuse.github.io/langfuse-k8s"
  chart      = "langfuse"
  namespace  = kubernetes_namespace_v1.langfuse.metadata[0].name
  version    = "2.0.0"
  timeout    = 900

  values = [
    templatefile("${path.module}/values/langfuse-values.yaml.tftpl", {
      langfuse_role_arn = local.infra.langfuse_role_arn
      rds_address       = local.infra.rds_address
      redis_endpoint    = local.infra.redis_endpoint
      bucket            = local.infra.langfuse_bucket
      region            = var.region
    })
  ]

  depends_on = [
    kubernetes_job_v1.langfuse_db_bootstrap,
    kubernetes_stateful_set_v1.clickhouse,
    kubernetes_manifest.langfuse_init_external_secret,
  ]
}

output "langfuse_admin_password" {
  value     = random_password.langfuse_admin_pw.result
  sensitive = true
}
