# IAM Role for Ray pods
resource "aws_iam_role" "ray_pod_role" {
  name = "${local.name}-ray-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:default:ray-service-account"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# IAM Policy for S3 and ECR access
resource "aws_iam_policy" "ray_pod_policy" {
  name = "${local.name}-ray-pod-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "ray_pod_policy_attachment" {
  role       = aws_iam_role.ray_pod_role.name
  policy_arn = aws_iam_policy.ray_pod_policy.arn
}

# Kubernetes Service Account
resource "kubernetes_service_account" "ray_service_account" {
  metadata {
    name      = "ray-service-account"
    namespace = "default"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ray_pod_role.arn
    }
  }
  
  depends_on = [module.eks]
}
