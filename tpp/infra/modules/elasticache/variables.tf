variable "name" {
  type = string
}

variable "description" {
  type    = string
  default = "TPP shared Redis"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  type = list(string)
}

variable "engine_version" {
  type    = string
  default = "7.1"
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "num_nodes" {
  type    = number
  default = 1
}

variable "multi_az_enabled" {
  description = "Place primary and replica in different AZs; only meaningful with num_nodes > 1"
  type        = bool
  default     = false
}

variable "transit_encryption" {
  type    = bool
  default = false
}

variable "auth_token" {
  description = "Redis AUTH token (16-128 printable chars, no @ \" or /). Requires transit_encryption = true. null disables AUTH (dev)."
  type        = string
  default     = null
  sensitive   = true
}

variable "parameter_group_name" {
  description = "Custom parameter group, e.g. maxmemory-policy=noeviction for a queue. null uses the engine default."
  type        = string
  default     = null
}
