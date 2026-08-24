resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.name}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# LiteLLM 多副本的 budget/cooldown 同步 + Scorer EWMA 状态 + Langfuse 队列
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "TPP shared Redis"

  engine             = "redis"
  engine_version     = var.engine_version
  node_type          = var.node_type
  num_cache_clusters = var.num_nodes

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = var.num_nodes > 1
  at_rest_encryption_enabled = true
  # dev 关闭 TLS 简化客户端配置;prod 开启并给 LiteLLM/Langfuse 配 REDIS_SSL
  transit_encryption_enabled = var.transit_encryption
}
