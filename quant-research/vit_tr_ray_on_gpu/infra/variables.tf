variable "name" {
  description = "Name of the VPC and EKS Cluster"
  type        = string
  default     = "mc5"  # needs update accordingly
}

variable "region" {
  description = "region"
  type        = string
  default     = "us-east-1"  # needs update accordingly
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  type        = string
  default     = "1.31"
}

# VPC with 2046 IPs (10.1.0.0/21) and 2 AZs
variable "vpc_cidr" {
  description = "VPC CIDR. This should be a valid private (RFC 1918) CIDR range"
  type        = string
  default     = "10.1.0.0/21"
}

# RFC6598 range 100.64.0.0/10
# Note you can only /16 range to VPC. You can add multiples of /16 if required
variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks to be attached to VPC"
  type        = list(string)
  default     = ["100.64.0.0/16"]
}

variable "enable_jupyterhub" {
  description = "Enable JupyterHub deployment"
  type        = bool
  default     = false
}

variable "enable_mpi_operator" {
  description = "Flag to enable the MPI Operator deployment"
  type        = bool
  default     = false
}

variable "enable_volcano" {
  description = "Flag to enable the Volcano batch scheduler"
  type        = bool
  default     = true
}

variable "enable_torchx_etcd" {
  description = "Flag to enable etcd deployment for torchx"
  type        = bool
  default     = false
}

variable "enable_fsx_for_lustre" {
  description = "Flag to enable resources for FSx for Lustre"
  type        = bool
  default     = true
}

variable "g6_2xl_min_size" {
  description = "g6 Worker node minimum size"
  type        = number
  default     = 2
}

variable "g6_2xl_desired_size" {
  description = "g6 Worker node desired size"
  type        = number
  default     = 2
}

variable "enable_kuberay_operator" {
  description = "Flag to enable kuberay operator"
  type        = bool
  default     = true
}

variable "kms_key_admin_roles" {
  description = "list of role ARNs to add to the KMS policy"
  type        = list(string)
  default     = []
}

variable "enable_elastic_cache_redis" {
  description = "Flag to enable Elastic Cache for Redis"
  type        = bool
  default     = true
}


variable "access_entries" {
  description = "Map of access entries to add to the cluster"
  type        = any
  default     = {}
}
