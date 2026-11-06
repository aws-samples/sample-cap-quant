variable "env" {
  type    = string
  default = "dev"
}

# ---- Public ingress (ALB + ACM + Route 53). Disabled until a Route 53 hosted zone is chosen. ----
variable "ingress" {
  type = object({
    enabled        = bool
    hostname       = optional(string, "")
    hosted_zone_id = optional(string, "")
    # Flip to true after `scripts/deploy.sh ingress` has created the ALB; then the Route 53 alias is created.
    alb_ready = optional(bool, false)
  })
  default = { enabled = false }
}

variable "ops_admin_email" {
  description = "First Cognito user allowed through the ALB login in front of Prometheus"
  type        = string
  default     = "weishiyang1@gmail.com"
}
