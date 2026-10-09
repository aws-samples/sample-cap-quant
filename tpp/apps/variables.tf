variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

# ---- Names that must differ per environment when dev and prod share an AWS account ----
variable "secret_prefix" {
  description = "Secrets Manager prefix for secrets this layer creates and reads (litellm, langfuse, redis-*). Keep under tpp/ (ESO IAM policy)."
  type        = string
  default     = "tpp"
}

variable "ecr_prefix" {
  description = "ECR repository prefix for the Scorer and Dashboard images"
  type        = string
  default     = "tpp"
}

# ---- LiteLLM data plane ----
variable "litellm_image" {
  description = "Pin a specific tag in prod: with PgBouncer the pods skip schema migrations, and the migration Job re-runs only when this value or litellm_schema_revision changes."
  type        = string
  default     = "ghcr.io/berriai/litellm:main-stable"
}

variable "litellm_schema_revision" {
  description = "Bump to force the migration Job to re-run without changing the image"
  type        = string
  default     = "1"
}

variable "litellm_config_file" {
  description = "File under values/ mounted as the LiteLLM config"
  type        = string
  default     = "litellm-config.yaml"
}

variable "litellm_replicas" {
  description = "Initial replica count; ignored after creation when autoscaling is enabled (KEDA owns it)"
  type        = number
  default     = 2
}

variable "litellm_resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "250m", memory = "512Mi" }
    limits   = { memory = "2Gi" }
  }
}

variable "litellm_pdb_min_available" {
  type    = number
  default = 1
}

variable "litellm_autoscaling" {
  description = "KEDA ScaledObject on the Prometheus request rate. rps_per_replica derives from the in-flight target: 175 concurrent streams per pod / 35 s average stream = 5 RPS."
  type = object({
    enabled         = bool
    min_replicas    = optional(number, 2)
    max_replicas    = optional(number, 2)
    rps_per_replica = optional(number, 5)
  })
  default = { enabled = false }
}

variable "litellm_ingress" {
  description = "Internet-facing ALB for the LiteLLM API. Requires an ACM certificate; WAF is optional. UIs stay behind kubectl tunnels until OIDC lands (Phase 3)."
  type = object({
    enabled         = bool
    hostname        = optional(string, "")
    certificate_arn = optional(string, "")
    wafv2_acl_arn   = optional(string, "")
  })
  default = { enabled = false }
}

# ---- PgBouncer in front of the ledger (prerequisite for LiteLLM scale-out) ----
variable "pgbouncer" {
  description = "Transaction-mode pooler between LiteLLM and the ledger. default_pool_size x databases x users must stay below the DB max_connections; connection_limit is Prisma's per-pod pool."
  type = object({
    enabled            = bool
    replicas           = optional(number, 2)
    image              = optional(string, "edoburu/pgbouncer:v1.26.0-p0")
    default_pool_size  = optional(number, 20)
    max_client_conn    = optional(number, 2000)
    max_db_connections = optional(number, 150)
    connection_limit   = optional(number, 10)
  })
  default = { enabled = false }
}

# ---- Redis TLS + AUTH (prod ElastiCache). Reads ${secret_prefix}/redis-router and ${secret_prefix}/redis-queue. ----
variable "redis_tls_enabled" {
  type    = bool
  default = false
}

# ---- Autoscaling controllers ----
variable "karpenter" {
  type = object({
    enabled = bool
    version = optional(string, "1.14.1")
  })
  default = { enabled = false }
}

variable "keda" {
  type = object({
    enabled = bool
    version = optional(string, "2.21.0")
  })
  default = { enabled = false }
}

# ---- Node placement. Empty maps (dev) schedule anywhere. ----
variable "node_selectors" {
  type = object({
    data_plane    = optional(map(string), {})
    observability = optional(map(string), {})
    clickhouse    = optional(map(string), {})
  })
  default = {}
}

variable "clickhouse_tolerations" {
  type = list(object({
    key      = string
    operator = string
    value    = optional(string)
    effect   = string
  }))
  default = []
}

variable "clickhouse" {
  type = object({
    storage  = optional(string, "50Gi")
    requests = optional(map(string), { cpu = "500m", memory = "2Gi" })
    limits   = optional(map(string), { memory = "4Gi" })
  })
  default = {}
}

variable "prometheus_values_file" {
  type    = string
  default = "kube-prometheus-stack.yaml"
}

variable "langfuse" {
  type = object({
    web_replicas    = optional(number, 1)
    worker_replicas = optional(number, 1)
    # NEXTAUTH_URL: the browser-facing origin. With no Ingress this is the local tunnel port, so it must
    # match the environment's port block in scripts/tpp-tunnels.sh (dev 3010, prod 4010).
    nextauth_url = optional(string, "http://localhost:3010")
  })
  default = {}
}

# Jump links rendered by the TPP Dashboard header. These are resolved in the operator's browser, so they
# must point at *this* environment's tunnel ports -- otherwise the prod dashboard links to the dev UIs.
# Defaults are the dev port block (scripts/tpp-tunnels.sh); prod overrides them in envs/prod.tfvars.
variable "ui_links" {
  type = object({
    litellm    = optional(string, "http://localhost:14000/ui")
    grafana    = optional(string, "http://localhost:3000")
    langfuse   = optional(string, "http://localhost:3010")
    prometheus = optional(string, "http://localhost:9090")
  })
  default = {}
}
