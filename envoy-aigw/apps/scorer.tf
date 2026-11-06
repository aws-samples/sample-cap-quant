# Scorer (services/scorer): only an ECR repository is needed on the AWS side; it talks to Prometheus, Redis and the
# Kubernetes API in-cluster and holds no AWS credentials.
resource "aws_ecr_repository" "scorer" {
  name                 = "aigw-${var.env}/scorer"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "scorer_ecr_repository_url" {
  value = aws_ecr_repository.scorer.repository_url
}
