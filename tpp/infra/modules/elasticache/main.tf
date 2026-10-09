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

# dev: one shared instance for LiteLLM router state + Scorer EWMA state + Langfuse ingestion queue.
# prod: instantiated twice (router / queue), each HA with TLS + AUTH -- see infra/envs/prod/main.tf.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = var.description

  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_clusters   = var.num_nodes
  parameter_group_name = var.parameter_group_name

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = var.num_nodes > 1
  multi_az_enabled           = var.multi_az_enabled && var.num_nodes > 1
  at_rest_encryption_enabled = true
  # dev disables TLS to simplify client config; prod enables TLS + AUTH and sets REDIS_SSL / REDIS_PASSWORD on the clients
  transit_encryption_enabled = var.transit_encryption
  auth_token                 = var.auth_token
}
