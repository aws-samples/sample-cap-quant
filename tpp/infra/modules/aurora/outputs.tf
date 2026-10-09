output "address" {
  description = "Writer endpoint; used for DATABASE_URL (same output name as modules/rds so the apps layer is interchangeable)"
  value       = aws_rds_cluster.this.endpoint
}

output "reader_address" {
  description = "Reader endpoint (load-balanced across readers); reserved for reporting/ETL, LiteLLM itself only writes to the writer"
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  value = aws_rds_cluster.this.port
}

output "db_name" {
  value = aws_rds_cluster.this.database_name
}

output "username" {
  value = aws_rds_cluster.this.master_username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the Aurora managed master password; the apps layer uses it to construct DATABASE_URL"
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.this.id
}
