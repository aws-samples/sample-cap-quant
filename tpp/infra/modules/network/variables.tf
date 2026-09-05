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
