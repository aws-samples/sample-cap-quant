# IRSA roles for TPP applications. Namespace/ServiceAccount conventions (apps-layer Helm values must match these):
#   litellm/litellm, langfuse/langfuse, external-secrets/external-secrets

locals {
  irsa_subjects = {
    litellm          = "system:serviceaccount:litellm:litellm"
    langfuse         = "system:serviceaccount:langfuse:langfuse"
    external_secrets = "system:serviceaccount:external-secrets:external-secrets"
  }
}

data "aws_iam_policy_document" "assume" {
  for_each = local.irsa_subjects

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---- LiteLLM: invokes Bedrock (one of the channels; this role is the credential, no static keys) ----
resource "aws_iam_role" "litellm" {
  name               = "${var.name_prefix}-litellm"
  assume_role_policy = data.aws_iam_policy_document.assume["litellm"].json
}

resource "aws_iam_role_policy" "litellm_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.litellm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${var.account_id}:inference-profile/*"
        ]
      },
      {
        # Bedrock Mantle (OpenAI-compatible endpoint for OpenAI models, LiteLLM route bedrock_mantle/)
        # is a separate service prefix not covered by bedrock:*; the resource is a Mantle project (default project/default)
        Effect   = "Allow"
        Action   = ["bedrock-mantle:CreateInference"]
        Resource = ["arn:aws:bedrock-mantle:*:${var.account_id}:project/*"]
      }
    ]
  })
}

# ---- Langfuse: event bucket read/write ----
resource "aws_iam_role" "langfuse" {
  name               = "${var.name_prefix}-langfuse"
  assume_role_policy = data.aws_iam_policy_document.assume["langfuse"].json
}

resource "aws_iam_role_policy" "langfuse_s3" {
  name = "langfuse-s3"
  role = aws_iam_role.langfuse.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.langfuse_bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${var.langfuse_bucket_arn}/*"]
      }
    ]
  })
}

# ---- AWS Load Balancer Controller (the policy is large; use the managed policy bundled with the community module) ----
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.name_prefix}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# ---- External Secrets Operator: read-only access to secrets under the tpp/ prefix ----
resource "aws_iam_role" "external_secrets" {
  name               = "${var.name_prefix}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.assume["external_secrets"].json
}

resource "aws_iam_role_policy" "external_secrets_sm" {
  name = "secretsmanager-read"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:tpp/*",
        # RDS managed master password (rds! prefix), used to construct DATABASE_URL
        "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:rds!*"
      ]
    }]
  })
}
