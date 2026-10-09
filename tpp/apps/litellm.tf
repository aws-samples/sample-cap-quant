# ---------- LiteLLM Proxy (M3) ----------
# Uses native K8s resources instead of the community Helm chart: fully controllable deployment, config isomorphic to the local/ validation environment.
# dev and prod share this file; the prod shape (PgBouncer, KEDA, Redis TLS, ALB) is switched on from apps/envs/prod.tfvars.

resource "random_password" "litellm_master_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "litellm" {
  name = "${var.secret_prefix}/litellm"
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
    "config.yaml" = file("${path.module}/values/${var.litellm_config_file}")
  }
}

locals {
  # prod exposes a dedicated router Redis; dev has one shared instance
  redis_router_host = try(local.infra.redis_router_endpoint, local.infra.redis_endpoint)

  # Direct ledger URL (Aurora writer in prod, RDS in dev). Prisma needs URL-encoded credentials: RDS managed
  # passwords include reserved URI characters.
  litellm_db_direct = "postgresql://{{ .db_username }}:{{ .db_password | urlquery }}@${local.infra.rds_address}:5432/litellm"
  # Pooled URL: pgbouncer=true makes Prisma skip prepared statements (required in transaction mode);
  # connection_limit is the per-pod Prisma pool and must be sized together with DEFAULT_POOL_SIZE in pgbouncer.tf.
  litellm_db_pooled = "postgresql://{{ .db_username }}:{{ .db_password | urlquery }}@pgbouncer.litellm:5432/litellm?pgbouncer=true&connection_limit=${var.pgbouncer.connection_limit}&pool_timeout=30"

  litellm_env_template = merge(
    {
      LITELLM_MASTER_KEY  = "{{ .master_key }}"
      DATABASE_URL        = var.pgbouncer.enabled ? local.litellm_db_pooled : local.litellm_db_direct
      DATABASE_URL_DIRECT = local.litellm_db_direct # PgBouncer upstream and the migration Job
      LANGFUSE_PUBLIC_KEY = "{{ .langfuse_public_key }}"
      LANGFUSE_SECRET_KEY = "{{ .langfuse_secret_key }}"
      LANGFUSE_HOST       = "http://langfuse-web.langfuse:3000"
    },
    # PgBouncer's auth file, mounted via AUTH_FILE in pgbouncer.tf. It cannot be left to the edoburu
    # entrypoint: that parses DATABASE_URL with `cut -d: -f2` and never URL-decodes, so it stores a hash
    # of the *percent-encoded* password while Prisma sends the decoded one, and every client login fails
    # with "password authentication failed". Rendered from the raw password (deliberately no urlquery) so
    # the stored value is the password clients actually send. Plaintext is required here anyway: Aurora
    # PG16 negotiates scram-sha-256, which PgBouncer can only answer from a plaintext secret.
    var.pgbouncer.enabled ? { "userlist.txt" = "\"{{ .db_username }}\" \"{{ .db_password }}\"\n" } : {},
    var.redis_tls_enabled ? { REDIS_PASSWORD = "{{ .redis_password }}" } : {},
  )

  litellm_env_data = concat(
    [
      {
        secretKey = "master_key"
        remoteRef = { key = "${var.secret_prefix}/litellm", property = "master_key" }
      },
      {
        secretKey = "langfuse_public_key"
        remoteRef = { key = "${var.secret_prefix}/langfuse", property = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY" }
      },
      {
        secretKey = "langfuse_secret_key"
        remoteRef = { key = "${var.secret_prefix}/langfuse", property = "LANGFUSE_INIT_PROJECT_SECRET_KEY" }
      },
      {
        secretKey = "db_username"
        remoteRef = { key = local.infra.rds_master_user_secret_arn, property = "username" }
      },
      {
        secretKey = "db_password"
        remoteRef = { key = local.infra.rds_master_user_secret_arn, property = "password" }
      },
    ],
    var.redis_tls_enabled ? [
      {
        secretKey = "redis_password"
        remoteRef = { key = "${var.secret_prefix}/redis-router", property = "auth_token" }
      }
    ] : [],
  )
}

# Sync from Secrets Manager and template the runtime env:
#   LITELLM_MASTER_KEY <- <prefix>/litellm
#   DATABASE_URL       <- RDS/Aurora managed master password (rds!...) + address from remote state
#   REDIS_PASSWORD     <- <prefix>/redis-router (prod only)
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
          data          = local.litellm_env_template
        }
      }
      data = local.litellm_env_data
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
    replicas = var.litellm_replicas

    selector {
      match_labels = { app = "litellm" }
    }

    template {
      metadata {
        labels = { app = "litellm" }
        annotations = {
          # Rolling restart on config changes
          "tpp/config-hash" = sha256(file("${path.module}/values/${var.litellm_config_file}"))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.litellm.metadata[0].name
        node_selector        = var.node_selectors.data_plane

        # Spread replicas across AZs; ScheduleAnyway so a single-AZ dev cluster still schedules
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = "litellm" }
          }
        }

        container {
          name  = "litellm"
          image = var.litellm_image
          # One uvicorn worker per pod; scale by replicas (multiple workers duplicate Python memory and coarsen autoscaling)
          args = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

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
            value = local.redis_router_host
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          # LiteLLM builds rediss:// from REDIS_SSL; the AUTH token arrives as REDIS_PASSWORD via litellm-env
          dynamic "env" {
            for_each = var.redis_tls_enabled ? [1] : []
            content {
              name  = "REDIS_SSL"
              value = "True"
            }
          }
          # Behind PgBouncer the pods must not run prisma migrate deploy at startup (see pgbouncer.tf)
          dynamic "env" {
            for_each = var.pgbouncer.enabled ? [1] : []
            content {
              name  = "DISABLE_SCHEMA_UPDATE"
              value = "true"
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/litellm"
            read_only  = true
          }

          resources {
            requests = var.litellm_resources.requests
            limits   = var.litellm_resources.limits
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
      # KEDA owns the replica count once autoscaling is on; without this every apply would fight the autoscaler.
      # To change replicas in dev: edit var.litellm_replicas and `kubectl scale`, or taint the resource.
      spec[0].replicas,
    ]
  }

  depends_on = [
    kubernetes_manifest.litellm_external_secret,
    kubernetes_job_v1.litellm_migrate,
    kubernetes_deployment_v1.pgbouncer,
  ]
}

resource "kubernetes_pod_disruption_budget_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }

  spec {
    min_available = tostring(var.litellm_pdb_min_available)
    selector {
      match_labels = { app = "litellm" }
    }
  }
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

# Prometheus scrapes /metrics (data source for the Scorer and Grafana).
# Cardinality is controlled in the LiteLLM config (prometheus_metrics_config), not here: a labeldrop relabel would
# merge series inside one scrape and Prometheus would silently keep only the first sample.
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

# ---- Autoscaling (prod): KEDA ScaledObject on the proxy request rate ----
# Streaming is I/O-bound, so CPU lags real pressure. The true capacity unit is concurrent streams; with no in-flight
# gauge exported by LiteLLM, request rate x average stream duration is the stand-in (5 RPS/pod ~= 175 streams/pod).
resource "kubernetes_manifest" "litellm_scaled_object" {
  count = var.keda.enabled && var.litellm_autoscaling.enabled ? 1 : 0

  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "litellm"
      namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    }
    spec = {
      scaleTargetRef  = { name = "litellm" }
      minReplicaCount = var.litellm_autoscaling.min_replicas
      maxReplicaCount = var.litellm_autoscaling.max_replicas
      pollingInterval = 15
      cooldownPeriod  = 300
      advanced = {
        horizontalPodAutoscalerConfig = {
          behavior = {
            scaleUp = {
              stabilizationWindowSeconds = 0
              policies                   = [{ type = "Pods", value = 4, periodSeconds = 60 }]
            }
            scaleDown = {
              # Agent turns hold connections for tens of seconds; drain slowly so in-flight streams finish
              stabilizationWindowSeconds = 300
              policies                   = [{ type = "Percent", value = 25, periodSeconds = 60 }]
            }
          }
        }
      }
      triggers = [
        {
          type = "prometheus"
          metadata = {
            serverAddress       = "http://kube-prometheus-stack-prometheus.monitoring:9090"
            query               = "sum(rate(litellm_proxy_total_requests_metric_total[2m]))"
            threshold           = tostring(var.litellm_autoscaling.rps_per_replica)
            activationThreshold = "0.5"
          }
        }
      ]
    }
  }

  depends_on = [helm_release.keda, kubernetes_deployment_v1.litellm]
}

# ---- Ingress (prod): internet-facing ALB for the API only ----
resource "kubernetes_ingress_v1" "litellm" {
  count = var.litellm_ingress.enabled ? 1 : 0

  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    annotations = merge(
      {
        "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"      = "ip"
        "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
        "alb.ingress.kubernetes.io/certificate-arn"  = var.litellm_ingress.certificate_arn
        "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
        "alb.ingress.kubernetes.io/healthcheck-path" = "/health/liveliness"
        # Agent streams stay open for minutes; the ALB default of 60 s would cut them
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=600"
        "alb.ingress.kubernetes.io/target-group-attributes"  = "deregistration_delay.timeout_seconds=90"
      },
      var.litellm_ingress.wafv2_acl_arn != "" ? {
        "alb.ingress.kubernetes.io/wafv2-acl-arn" = var.litellm_ingress.wafv2_acl_arn
      } : {},
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.litellm_ingress.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.litellm.metadata[0].name
              port {
                number = 4000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller]
}

output "litellm_master_key" {
  value     = "sk-${random_password.litellm_master_key.result}"
  sensitive = true
}
