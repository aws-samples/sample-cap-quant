output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader endpoint; null for single-node groups"
  value       = var.num_nodes > 1 ? aws_elasticache_replication_group.this.reader_endpoint_address : null
}

output "port" {
  value = 6379
}

output "security_group_id" {
  value = aws_security_group.redis.id
}
