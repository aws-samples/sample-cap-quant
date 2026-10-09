# ---------- PgBouncer: connection pooler between LiteLLM and the ledger (prod) ----------
# Why (docs/scaling-500-users.md §5): Prisma opens its own pool per LiteLLM pod; 20 pods would saturate the database's
# connection limit on the first scale-out. PgBouncer in transaction mode multiplexes them onto a fixed server pool.
#
# Consequences handled here:
#   - Prisma must be told it is behind a transaction pooler (?pgbouncer=true in DATABASE_URL, see litellm.tf locals)
#   - Prisma Migrate needs a direct connection, so LiteLLM pods set DISABLE_SCHEMA_UPDATE=true and this file runs
#     the migration as a one-shot Job against DATABASE_URL_DIRECT before the Deployment rolls
#   - PgBouncer reads the same rotated RDS credentials as LiteLLM (Secret litellm-env) and is restarted by Reloader

locals {
  # Kept out of /etc/pgbouncer: mounting there would shadow the pgbouncer.ini the entrypoint generates.
  pgbouncer_auth_dir = "/etc/pgbouncer-auth"
}

resource "kubernetes_deployment_v1" "pgbouncer" {
  count = var.pgbouncer.enabled ? 1 : 0

  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    labels    = { app = "pgbouncer" }
  }

  spec {
    replicas = var.pgbouncer.replicas

    selector {
      match_labels = { app = "pgbouncer" }
    }

    template {
      metadata {
        labels = { app = "pgbouncer" }
      }

      spec {
        node_selector = var.node_selectors.data_plane

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = "pgbouncer" }
          }
        }

        container {
          name  = "pgbouncer"
          image = var.pgbouncer.image

          port {
            name           = "postgres"
            container_port = 5432
          }

          # Reloader checksum slot; must stay env[0] (see lifecycle below)
          env {
            name  = "STAKATER_LITELLM_ENV_SECRET"
            value = "managed-by-reloader"
          }
          # Upstream: the direct ledger URL rendered by External Secrets (rotates with the RDS master password)
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "litellm-env"
                key  = "DATABASE_URL_DIRECT"
              }
            }
          }
          env {
            name  = "POOL_MODE"
            value = "transaction"
          }
          env {
            name  = "MAX_CLIENT_CONN"
            value = tostring(var.pgbouncer.max_client_conn)
          }
          env {
            name  = "DEFAULT_POOL_SIZE"
            value = tostring(var.pgbouncer.default_pool_size)
          }
          env {
            name  = "MIN_POOL_SIZE"
            value = "5"
          }
          env {
            name  = "RESERVE_POOL_SIZE"
            value = "5"
          }
          env {
            name  = "MAX_DB_CONNECTIONS"
            value = tostring(var.pgbouncer.max_db_connections)
          }
          # Aurora PostgreSQL 15+ enforces rds.force_ssl=1
          env {
            name  = "SERVER_TLS_SSLMODE"
            value = "require"
          }
          env {
            name  = "IGNORE_STARTUP_PARAMETERS"
            value = "extra_float_digits"
          }
          # Use the userlist rendered by External Secrets instead of the one the entrypoint would derive
          # from DATABASE_URL (see the "userlist.txt" comment in litellm.tf). The entrypoint honours
          # AUTH_FILE and skips generation when the user is already present in that file.
          env {
            name  = "AUTH_FILE"
            value = "${local.pgbouncer_auth_dir}/userlist.txt"
          }
          # The mounted userlist holds the password in plaintext, which scram-sha-256 requires; it also
          # keeps the client handshake off md5, which Aurora PG16 no longer accepts upstream.
          env {
            name  = "AUTH_TYPE"
            value = "scram-sha-256"
          }

          volume_mount {
            name       = "pgbouncer-auth"
            mount_path = local.pgbouncer_auth_dir
            read_only  = true
          }

          readiness_probe {
            tcp_socket {
              port = "postgres"
            }
            period_seconds = 10
          }

          liveness_probe {
            tcp_socket {
              port = "postgres"
            }
            period_seconds    = 15
            failure_threshold = 3
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "pgbouncer-auth"

          secret {
            secret_name = "litellm-env"

            items {
              key  = "userlist.txt"
              path = "userlist.txt"
            }
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

resource "kubernetes_service_v1" "pgbouncer" {
  count = var.pgbouncer.enabled ? 1 : 0

  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    labels    = { app = "pgbouncer" }
  }

  spec {
    selector = { app = "pgbouncer" }

    port {
      name        = "postgres"
      port        = 5432
      target_port = "postgres"
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "pgbouncer" {
  count = var.pgbouncer.enabled ? 1 : 0

  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }

  spec {
    min_available = "1"
    selector {
      match_labels = { app = "pgbouncer" }
    }
  }
}

resource "kubernetes_annotations" "pgbouncer_reloader" {
  count = var.pgbouncer.enabled ? 1 : 0

  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = kubernetes_deployment_v1.pgbouncer[0].metadata[0].name
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

# ---- Schema migration Job: `litellm --skip_server_startup` runs prisma migrate deploy and exits ----
# Re-runs (new Job name) whenever the image or litellm_schema_revision changes; kubernetes_deployment_v1.litellm depends on it.
resource "kubernetes_job_v1" "litellm_migrate" {
  count = var.pgbouncer.enabled ? 1 : 0

  metadata {
    name      = "litellm-migrate-${substr(sha256("${var.litellm_image}|${var.litellm_schema_revision}"), 0, 10)}"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    labels    = { app = "litellm-migrate" }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = { app = "litellm-migrate" }
      }

      spec {
        restart_policy = "Never"
        node_selector  = var.node_selectors.data_plane

        container {
          name  = "migrate"
          image = var.litellm_image
          args  = ["--config", "/etc/litellm/config.yaml", "--skip_server_startup"]

          env_from {
            secret_ref {
              name = "litellm-env"
            }
          }
          # Explicit env wins over envFrom: migrations bypass PgBouncer
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "litellm-env"
                key  = "DATABASE_URL_DIRECT"
              }
            }
          }
          env {
            name  = "REDIS_HOST"
            value = local.redis_router_host
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          dynamic "env" {
            for_each = var.redis_tls_enabled ? [1] : []
            content {
              name  = "REDIS_SSL"
              value = "True"
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/litellm"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "1Gi"
            }
            limits = {
              memory = "2Gi"
            }
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

  wait_for_completion = true

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [kubernetes_manifest.litellm_external_secret]
}
