# AWS WAF (regional WAFv2) in front of the shared "aigw" ALB: API, Grafana, Prometheus, dashboard.
# The ACL is created here; the ALB controller attaches it through the `wafv2-acl-arn` annotation on the `aigw`
# Ingress (k8s/ingress/alb-ingress.yaml.tmpl, rendered by `scripts/deploy.sh ingress`). The annotation is
# "Exclusive" in an IngressGroup, so it lives on that one Ingress only and covers every host on the ALB.
# Not using aws_wafv2_web_acl_association: the controller owns the ALB, and two owners would fight.
#
# LLM traffic is the hard part: request bodies are large prompts full of code, HTML, file paths and URLs.
# The ALB only passes the first 8 KB of a body to WAF, and the managed *_BODY rules match normal agent
# prompts (XSS on "<script>", LFI on "../", RFI on URLs, SizeRestrictions on anything > 8 KB). Those rules
# run in COUNT so they show up in the logs and metrics without blocking. Header, URI and query-string rules,
# the IP reputation list and the per-IP rate limit block.

locals {
  waf_on = local.ingress_on && var.waf.enabled
  # Managed-rule actions: everything in COUNT while tuning, otherwise the managed default (block).
  waf_override = var.waf.count_only ? "count" : "none"

  # Body-inspecting rules that false-positive on prompts. Always COUNT, regardless of count_only.
  waf_common_body_rules = [
    "SizeRestrictions_BODY",
    "CrossSiteScripting_BODY",
    "GenericLFI_BODY",
    "GenericRFI_BODY",
    "EC2MetaDataSSRF_BODY",
  ]
  waf_badinputs_body_rules = [
    "Log4JRCE_BODY",
    "JavaDeserializationRCE_BODY",
  ]
}

resource "aws_wafv2_web_acl" "aigw" {
  count = local.waf_on ? 1 : 0

  name        = "aigw-${var.env}"
  description = "aigw ALB - IP reputation, known bad inputs, common rule set with body rules in count, per-IP rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # 1. Amazon IP reputation list (botnets, scanners, known attackers)
  rule {
    name     = "AWS-IpReputation"
    priority = 10
    override_action {
      dynamic "none" {
        for_each = var.waf.count_only ? [] : [1]
        content {}
      }
      dynamic "count" {
        for_each = var.waf.count_only ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "aigw-${var.env}-ip-reputation"
    }
  }

  # 2. Per-source-IP flood protection. Runs before the content rules so floods are cut off cheaply.
  #    Per-client token / request limits stay in Envoy (keyed on the API key); this only stops one IP
  #    hammering the ALB, including unauthenticated requests that Envoy would reject anyway.
  rule {
    name     = "RateLimit-PerIP"
    priority = 20
    action {
      dynamic "block" {
        for_each = var.waf.count_only ? [] : [1]
        content {
          custom_response {
            response_code = 429
          }
        }
      }
      dynamic "count" {
        for_each = var.waf.count_only ? [1] : []
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf.rate_limit_per_5min
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "aigw-${var.env}-rate-per-ip"
    }
  }

  # 3. Known bad inputs (Log4Shell, Java deserialization, bad Host headers, ...). Body variants in COUNT.
  rule {
    name     = "AWS-KnownBadInputs"
    priority = 30
    override_action {
      dynamic "none" {
        for_each = var.waf.count_only ? [] : [1]
        content {}
      }
      dynamic "count" {
        for_each = var.waf.count_only ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"

        dynamic "rule_action_override" {
          for_each = local.waf_badinputs_body_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "aigw-${var.env}-known-bad-inputs"
    }
  }

  # 4. Core rule set (OWASP-style). Header / URI / query rules block; body rules COUNT (see top of file).
  rule {
    name     = "AWS-CommonRuleSet"
    priority = 40
    override_action {
      dynamic "none" {
        for_each = var.waf.count_only ? [] : [1]
        content {}
      }
      dynamic "count" {
        for_each = var.waf.count_only ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        dynamic "rule_action_override" {
          for_each = local.waf_common_body_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "aigw-${var.env}-common"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "aigw-${var.env}"
  }
}

# ---- Logging: CloudWatch Logs (name must start with aws-waf-logs-). Credentials are redacted. ----
resource "aws_cloudwatch_log_group" "waf" {
  count = local.waf_on ? 1 : 0

  name              = "aws-waf-logs-aigw-${var.env}"
  retention_in_days = var.waf.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "aigw" {
  count = local.waf_on ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.aigw[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # API keys arrive in either header (see k8s/ai-gateway/40-security-policy.yaml); ALB Cognito session cookie.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

output "waf_web_acl_arn" {
  description = "Rendered into the aigw Ingress as alb.ingress.kubernetes.io/wafv2-acl-arn by scripts/deploy.sh ingress"
  value       = local.waf_on ? aws_wafv2_web_acl.aigw[0].arn : null
}
