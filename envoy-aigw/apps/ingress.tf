# Public entry: one ALB (IngressGroup "aigw") serving
#   <hostname>              -> Envoy data plane (API)              k8s/ingress/alb-ingress.yaml.tmpl
#   grafana.<hostname>      -> Grafana (its own login)              k8s/ingress/monitoring-ingress.yaml.tmpl
#   prometheus.<hostname>   -> Prometheus, behind ALB Cognito auth  k8s/ingress/monitoring-ingress.yaml.tmpl
# ACM certificate (apex + wildcard, DNS-validated in Route 53) + Route 53 aliases + Cognito user pool.

locals {
  ingress_on = var.ingress.enabled && var.ingress.hostname != "" && var.ingress.hosted_zone_id != ""
  alias_on   = local.ingress_on && var.ingress.alb_ready
  hosts = local.ingress_on ? {
    api        = var.ingress.hostname
    grafana    = "grafana.${var.ingress.hostname}"
    prometheus = "prometheus.${var.ingress.hostname}"
    dashboard  = "dashboard.${var.ingress.hostname}"
  } : {}
}

# ---- Certificate ----
resource "aws_acm_certificate" "aigw" {
  count = local.ingress_on ? 1 : 0

  domain_name               = var.ingress.hostname
  subject_alternative_names = ["*.${var.ingress.hostname}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Keyed by domain name (known at plan time). apex and wildcard resolve to the same validation CNAME, so the
# two instances write the same record; allow_overwrite makes that harmless.
resource "aws_route53_record" "acm_validation" {
  for_each = local.ingress_on ? {
    for dvo in aws_acm_certificate.aigw[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.ingress.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "aigw" {
  count = local.ingress_on ? 1 : 0

  certificate_arn         = aws_acm_certificate.aigw[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# ---- Cognito: login in front of Prometheus (ALB authenticate-cognito action) ----
resource "aws_cognito_user_pool" "ops" {
  count = local.ingress_on ? 1 : 0

  name                     = "aigw-${var.env}-ops"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"

  admin_create_user_config {
    allow_admin_create_user_only = true # no self sign-up
  }
  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_domain" "ops" {
  count = local.ingress_on ? 1 : 0

  domain       = "aigw-${var.env}-ops-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.ops[0].id
}

resource "aws_cognito_user_pool_client" "alb" {
  count = local.ingress_on ? 1 : 0

  name            = "alb-prometheus"
  user_pool_id    = aws_cognito_user_pool.ops[0].id
  generate_secret = true # ALB requires a confidential client

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls = [
    "https://${local.hosts.prometheus}/oauth2/idpresponse",
    "https://${local.hosts.dashboard}/oauth2/idpresponse",
  ]
  logout_urls = ["https://${local.hosts.prometheus}/", "https://${local.hosts.dashboard}/"]
}

# First operator login. Temporary password lands in Secrets Manager; Cognito forces a change at first login.
resource "random_password" "ops_admin" {
  count   = local.ingress_on ? 1 : 0
  length  = 16
  special = false
}

resource "aws_cognito_user" "ops_admin" {
  count = local.ingress_on ? 1 : 0

  user_pool_id       = aws_cognito_user_pool.ops[0].id
  username           = var.ops_admin_email
  temporary_password = random_password.ops_admin[0].result
  attributes = {
    email          = var.ops_admin_email
    email_verified = true
  }
  message_action = "SUPPRESS" # no invite e-mail; password is read from Secrets Manager
}

resource "aws_secretsmanager_secret" "ops_admin" {
  count = local.ingress_on ? 1 : 0
  name  = "aigw/${var.env}/cognito-ops-admin"
}

resource "aws_secretsmanager_secret_version" "ops_admin" {
  count     = local.ingress_on ? 1 : 0
  secret_id = aws_secretsmanager_secret.ops_admin[0].id
  secret_string = jsonencode({
    username           = var.ops_admin_email
    temporary_password = random_password.ops_admin[0].result
    login_url          = "https://${local.hosts.prometheus}/"
  })
}

data "aws_caller_identity" "current" {}

# ---- Route 53 aliases -> the ALB created by the controller for IngressGroup "aigw" ----
data "aws_lb" "aigw" {
  count = local.alias_on ? 1 : 0

  tags = {
    "ingress.k8s.aws/stack" = "aigw"
  }
}

resource "aws_route53_record" "aigw" {
  for_each = local.alias_on ? local.hosts : {}

  zone_id = var.ingress.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = data.aws_lb.aigw[0].dns_name
    zone_id                = data.aws_lb.aigw[0].zone_id
    evaluate_target_health = true
  }
}

output "acm_certificate_arn" {
  value = local.ingress_on ? aws_acm_certificate_validation.aigw[0].certificate_arn : null
}

output "gateway_hostname" {
  value = local.ingress_on ? var.ingress.hostname : null
}

output "cognito" {
  value = local.ingress_on ? {
    user_pool_arn  = aws_cognito_user_pool.ops[0].arn
    client_id      = aws_cognito_user_pool_client.alb[0].id
    domain         = aws_cognito_user_pool_domain.ops[0].domain
    admin_secret   = aws_secretsmanager_secret.ops_admin[0].name
    prometheus_url = "https://${local.hosts.prometheus}/"
    grafana_url    = "https://${local.hosts.grafana}/"
    dashboard_url  = "https://${local.hosts.dashboard}/"
  } : null
}
