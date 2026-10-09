# apps layer, 500-user shape. Pair with infra/envs/prod:
#   terraform init -backend-config="key=apps/prod/terraform.tfstate"
#   terraform apply -var-file=envs/prod.tfvars   (three passes on first deploy, see apps/README.md)

env    = "prod"
region = "us-east-1"

secret_prefix = "tpp/prod" # must equal infra/envs/prod secret_prefix
ecr_prefix    = "tpp-prod"

# In-house images live in tpp-prod/scorer and tpp-prod/dashboard. The Scorer build must include Redis TLS support
# (services/scorer/scorer/config.py: REDIS_SSL / REDIS_PASSWORD); see docs/deploy-prod-500-users.md step 2.
scorer_image_tag    = "0.2.0"
dashboard_image_tag = "0.1.3" # must be built and pushed before applying; see docs/deploy-prod-500-users.md step 2

# ---- LiteLLM: 1 vCPU / 4Gi per pod as LiteLLM's production guide recommends, one uvicorn worker, scale by pods ----
litellm_config_file = "litellm-config-prod.yaml"
# Pinned to the version dev has run since 2026-08-22 (digest sha256:20b5044b…), so the metric family names in
# litellm-config-prod.yaml are validated against a version we have actually operated. Do not use main-stable: it is
# identical to :latest and moved to v1.104.0 on 2026-10-03, and with DISABLE_SCHEMA_UPDATE=true on the pods a moving
# tag can pull an image expecting a schema the migration Job never applied. Upgrade dev and prod together, and bump
# litellm_schema_revision when you do.
litellm_image           = "ghcr.io/berriai/litellm:v1.98.0"
litellm_schema_revision = "1"
litellm_replicas        = 4
litellm_resources = {
  requests = { cpu = "1", memory = "4Gi" }
  limits   = { cpu = "2", memory = "4Gi" }
}
litellm_pdb_min_available = 2
litellm_autoscaling = {
  enabled         = true
  min_replicas    = 4
  max_replicas    = 20
  rps_per_replica = 5
}
# Flip enabled to true once the ACM certificate and hostname exist (Phase 3 open items)
litellm_ingress = {
  enabled         = false
  hostname        = "llm.example.internal"
  certificate_arn = ""
  wafv2_acl_arn   = ""
}

# ---- PgBouncer: 2 replicas x 20 server connections per db/user pair stays far below Aurora r7g.large's limits ----
pgbouncer = {
  enabled            = true
  replicas           = 2
  default_pool_size  = 20
  max_client_conn    = 2000
  max_db_connections = 150
  connection_limit   = 10
}

redis_tls_enabled = true

karpenter = { enabled = true }
keda      = { enabled = true }

node_selectors = {
  data_plane    = { "tpp.io/pool" = "data-plane" }
  observability = { "tpp.io/pool" = "observability" }
  clickhouse    = { "tpp.io/pool" = "clickhouse" }
}
clickhouse_tolerations = [
  { key = "tpp.io/clickhouse", operator = "Equal", value = "true", effect = "NoSchedule" }
]
clickhouse = {
  storage  = "500Gi"
  requests = { cpu = "4", memory = "16Gi" }
  limits   = { memory = "28Gi" }
}

prometheus_values_file = "kube-prometheus-stack-prod.yaml"

langfuse = {
  web_replicas    = 3
  worker_replicas = 4
  # Prod's tunnel port block (scripts/tpp-tunnels.sh): Langfuse on 4010, not dev's 3010. NEXTAUTH_URL
  # binds the local port, so this and the tunnel port must be changed together or auth breaks on redirect.
  nextauth_url = "http://localhost:4010"
}

# Prod tunnel port block, so dev and prod can be tunneled simultaneously and the port names the environment.
ui_links = {
  litellm    = "http://localhost:24000/ui"
  grafana    = "http://localhost:4000"
  langfuse   = "http://localhost:4010"
  prometheus = "http://localhost:9091"
}
