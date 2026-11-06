variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "vpc_cidr" {
  description = "Must not overlap the account default VPC (172.31.0.0/16) or TPP (10.80/10.81.0.0/16)"
  type        = string
  default     = "10.90.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "cluster_version" {
  type    = string
  default = "1.34"
}

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
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM principals granted cluster-admin via EKS access entries (the Terraform caller is added automatically)"
  type        = list(string)
  default     = []
}
