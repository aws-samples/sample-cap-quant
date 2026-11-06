# Ops dashboard (services/dashboard): ECR repository + IAM role (Pod Identity) that may read/write the API-key
# secret in Secrets Manager. The Deployment itself is k8s/dashboard/, applied by scripts/deploy.sh dashboard.

resource "aws_ecr_repository" "dashboard" {
  name                 = "aigw-${var.env}/dashboard"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_secretsmanager_secret" "api_keys" {
  name = "aigw/${var.env}/api-keys"
}

data "aws_iam_policy_document" "dashboard" {
  statement {
    sid       = "ApiKeysReadWrite"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [data.aws_secretsmanager_secret.api_keys.arn]
  }
}

resource "aws_iam_role" "dashboard" {
  name               = "aigw-${var.env}-dashboard"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "dashboard" {
  name   = "api-keys"
  role   = aws_iam_role.dashboard.name
  policy = data.aws_iam_policy_document.dashboard.json
}

resource "aws_eks_pod_identity_association" "dashboard" {
  cluster_name    = local.infra.cluster_name
  namespace       = "dashboard"
  service_account = "dashboard"
  role_arn        = aws_iam_role.dashboard.arn
}

output "dashboard_ecr_repository_url" {
  value = aws_ecr_repository.dashboard.repository_url
}
