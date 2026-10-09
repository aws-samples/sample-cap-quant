variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  description = "dev uses a single NAT to save cost; false recommended for prod (one per AZ)"
  type        = bool
  default     = true
}

variable "extra_private_subnet_tags" {
  description = "Additional tags on private subnets, e.g. karpenter.sh/discovery so Karpenter can find them"
  type        = map(string)
  default     = {}
}
