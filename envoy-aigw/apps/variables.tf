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

# ---- AWS WAF on the ALB (apps/waf.tf). Only takes effect when var.ingress is enabled. ----
variable "waf" {
  type = object({
    enabled = optional(bool, true)
    # true: every rule only counts (rollout / tuning). false: managed rules and the rate limit block.
    count_only = optional(bool, false)
    # Requests per source IP per 5 min. 50 users can share one office NAT IP, each agent doing tens of
    # requests per minute, so keep this well above per-client Envoy limits (300 req/min per API key).
    rate_limit_per_5min = optional(number, 6000)
    log_retention_days  = optional(number, 30)
  })
  default = {}
}
