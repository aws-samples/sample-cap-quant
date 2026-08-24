variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.80.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "cluster_version" {
  type    = string
  default = "1.33"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i.large"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}
