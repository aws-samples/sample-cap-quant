# TPP 应用的 IRSA roles。命名空间/ServiceAccount 约定(apps 层 Helm values 必须与此一致):
#   litellm/litellm、langfuse/langfuse、external-secrets/external-secrets

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

# ---- LiteLLM:调用 Bedrock(渠道之一,凭据即此 role,无静态密钥)----
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
        # Bedrock Mantle(OpenAI 模型的 OpenAI 兼容端点,LiteLLM 路由 bedrock_mantle/)
        # 是独立服务前缀,不在 bedrock:* 之内;资源为 Mantle project(默认 project/default)
        Effect   = "Allow"
        Action   = ["bedrock-mantle:CreateInference"]
        Resource = ["arn:aws:bedrock-mantle:*:${var.account_id}:project/*"]
      }
    ]
  })
}

# ---- Langfuse:事件桶读写 ----
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

# ---- AWS Load Balancer Controller(策略庞大,用社区模块自带的托管策略)----
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

# ---- External Secrets Operator:只读 tpp/ 前缀下的 secrets ----
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
        # RDS 托管主密码(rds! 前缀),用于拼 DATABASE_URL
        "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:rds!*"
      ]
    }]
  })
}
