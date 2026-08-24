resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name}-rds-"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
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

# LiteLLM 记账账本(keys/budget/spend)——平台最关键的持久化数据。
# langfuse 库不在此创建(RDS 无法直接建第二个库),由 M4 的 bootstrap Job 执行 CREATE DATABASE。
resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = "litellm"
  username = "tpp"
  # 主密码托管进 Secrets Manager,不落 tfstate
  manage_master_user_password = true

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = var.multi_az

  backup_retention_period      = 7
  performance_insights_enabled = true
  auto_minor_version_upgrade   = true

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot
}
