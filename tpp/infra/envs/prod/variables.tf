variable "env" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  description = "Distinct from dev (10.80.0.0/16) so both environments can be peered or share a corporate network"
  type        = string
  default     = "10.81.0.0/16"
}

# us-east-1e is deliberately excluded: it offers neither m7i/r7i (system and Karpenter pools) nor
# Aurora db.r7g, so a subnet there would only ever sit idle and break Multi-AZ placement.
variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "cluster_version" {
  type    = string
  default = "1.33"
}

# ---- EKS: one small managed node group for Karpenter, CoreDNS, and the controllers; everything else is Karpenter-provisioned ----
variable "system_node_instance_types" {
  type    = list(string)
  default = ["m7i.large"]
}

variable "system_node_desired_size" {
  type    = number
  default = 3
}

# ---- Ledger: Aurora PostgreSQL (writer + reader) ----
variable "aurora_instance_class" {
  type    = string
  default = "db.r7g.large"
}

variable "aurora_instance_count" {
  description = "1 writer + (n-1) readers; 2 gives Multi-AZ failover"
  type        = number
  default     = 2
}

# ---- Langfuse metadata: its own RDS instance, Multi-AZ ----
variable "langfuse_rds_instance_class" {
  type    = string
  default = "db.m7g.large"
}

# ---- Redis: router (request path, HA) and Langfuse ingestion queue (sized by tolerated worker lag) ----
variable "redis_router_node_type" {
  type    = string
  default = "cache.m7g.large"
}

variable "redis_queue_node_type" {
  description = "13 GiB class: queue_bytes = 40 RPS x 120 KB x 300 s tolerated lag = 1.4 GB, with ample headroom"
  type        = string
  default     = "cache.r7g.large"
}

variable "secret_prefix" {
  description = "Secrets Manager name prefix for this environment. Must stay under tpp/ because the External Secrets IRSA policy allows secret:tpp/*."
  type        = string
  default     = "tpp/prod"
}
