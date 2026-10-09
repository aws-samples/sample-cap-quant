variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "SGs allowed to access port 5432 (EKS node SG)"
  type        = list(string)
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version; list with: aws rds describe-db-engine-versions --engine aurora-postgresql"
  type        = string
  default     = "16.13"
}

variable "instance_class" {
  type    = string
  default = "db.r7g.large"
}

variable "instance_count" {
  description = "Writer + readers. 2 = one writer, one reader (Multi-AZ failover target)."
  type        = number
  default     = 2
}

variable "db_name" {
  type    = string
  default = "litellm"
}

variable "master_username" {
  type    = string
  default = "tpp"
}

variable "backup_retention_period" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}
