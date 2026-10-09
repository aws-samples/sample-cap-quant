# Aurora PostgreSQL cluster for the LiteLLM accounting ledger at 500-user scale.
# Why Aurora instead of a single RDS instance (docs/scaling-500-users.md §5): every request writes a SpendLog row and
# batch-updates the spend rows of key/user/team; Aurora adds reader offloading, second-level failover, and storage autoscaling.
# The langfuse database is deliberately NOT here; it gets its own RDS instance (modules/rds) so trace metadata cannot
# contend with the ledger.

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-aurora-"
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

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version

  database_name   = var.db_name
  master_username = var.master_username
  # Master password managed in Secrets Manager, never lands in tfstate (same model as modules/rds)
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  storage_encrypted       = true
  backup_retention_period = var.backup_retention_period
  preferred_backup_window = "03:00-04:00"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  # Parameter changes are applied in the maintenance window; Aurora PostgreSQL 15+ enforces rds.force_ssl=1 by default,
  # which is why PgBouncer connects upstream with SERVER_TLS_SSLMODE=require.
  apply_immediately = false
}

# Instance 0 is the writer; the rest are readers with failover priority in index order
resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${var.name}-${count.index}"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version

  promotion_tier               = count.index
  performance_insights_enabled = true
  auto_minor_version_upgrade   = true
  publicly_accessible          = false
}
