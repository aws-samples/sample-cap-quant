variable "name" {
  description = "Name of the VPC and EKS Cluster"
  type        = string
  default     = "mc8"
}

variable "region" {
  description = "region"
  type        = string
  default     = "us-west-2"
}

variable "aws_account_id" {
  description = "aws_account+id"
  type        = string
  default     = "<specific aws account id>"
}

variable "raw_data_s3bucket_https_endpoint_url" {
  description = "raw_data_s3bucket_https_endpoint_url"
  type        = string
  default     = "https://s3.us-west-2.amazonaws.com/nov6-vit-2"
}

variable "ray_cluster_result_s3bucket_url" {
  description = "ray_cluster_result_s3bucket_url"
  type        = string
  default     = "s3://cnn-training-data-vir/ray-results"
}

variable "ecr_url" {
  description = "ecr_url"
  type        = string
  default     = "<aws-account-id>.dkr.ecr.us-west-2.amazonaws.com/kuberay_cnn_gpu:latest"
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "VPC CIDR. This should be a valid private (RFC 1918) CIDR range"
  type        = string
  default     = "10.1.0.0/21"
}

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

variable "trn1_32xl_min_size" {
  description = "trn1 Worker node minimum size"
  type        = number
  default     = 2
}

variable "trn1_32xl_desired_size" {
  description = "trn1 Worker node desired size"
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

# New variables for pod identity
variable "service_account_name" {
  description = "Name of the Kubernetes service account for pod identity"
  type        = string
  default     = "ray-service-account"
}
