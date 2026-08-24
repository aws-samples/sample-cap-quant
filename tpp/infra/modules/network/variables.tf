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
  description = "dev 用单 NAT 省成本;prod 建议 false(每 AZ 一个)"
  type        = bool
  default     = true
}
