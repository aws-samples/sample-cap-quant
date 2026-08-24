output "litellm_role_arn" {
  value = aws_iam_role.litellm.arn
}

output "langfuse_role_arn" {
  value = aws_iam_role.langfuse.arn
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "alb_controller_role_arn" {
  value = module.lb_controller_irsa.iam_role_arn
}
