variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.33"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

# ---- Single managed node group (dev shape). Ignored when node_groups is set. ----
variable "node_instance_types" {
  type    = list(string)
  default = ["m7i.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "node_desired_size" {
  type    = number
  default = 3
}

# ---- Multiple managed node groups (prod shape) ----
variable "node_groups" {
  description = "Managed node groups keyed by name. When null, a single 'general' group is built from the node_* variables (dev)."
  type = map(object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = optional(number, 80)
    labels         = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
  }))
  default = null
}

variable "enable_karpenter" {
  description = "Create the Karpenter controller IAM role (IRSA), node IAM role + access entry, and SQS interruption queue, and tag the node SG for discovery. The controller itself is installed by the apps layer."
  type        = bool
  default     = false
}
