variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider" {
  description = "OIDC issuer,不含 https:// 前缀"
  type        = string
}

variable "langfuse_bucket_arn" {
  type = string
}
