# ============================================================
# Aurora PostgreSQL Serverless v2 + pgvector
# ============================================================

resource "aws_db_subnet_group" "aurora" {
  name        = "${local.name_prefix}-aurora-subnets"
  description = "Subnets privadas del VPC para Aurora"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-aurora-subnets"
  }
}

# Parameter group del cluster — pre-carga la extensión vector para que
# CREATE EXTENSION vector funcione sin permisos extra.
resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${local.name_prefix}-aurora-cluster-pg"
  family      = "aurora-postgresql16"
  description = "Cluster parameter group con pgvector pre-cargado"

  # NOTA: pgvector NO requiere estar en shared_preload_libraries.
  # Aurora PostgreSQL 16 lo rechaza explicitamente. La extension se
  # carga a nivel sesion con CREATE EXTENSION vector (lo hace el DDL
  # init en indexer/sql/00_init_pgvector.sql).
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  tags = {
    Name = "${local.name_prefix}-aurora-cluster-pg"
  }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${local.name_prefix}-aurora"

  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.aurora_engine_version

  database_name      = var.aurora_database_name
  master_username    = var.aurora_master_username
  master_password    = random_password.aurora_master.result

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  storage_encrypted   = true
  deletion_protection = var.enable_deletion_protection
  skip_final_snapshot = !var.enable_deletion_protection
  final_snapshot_identifier = var.enable_deletion_protection ? "${local.name_prefix}-aurora-final" : null

  backup_retention_period      = 7
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  tags = {
    Name = "${local.name_prefix}-aurora"
  }

  lifecycle {
    ignore_changes = [
      master_password, # rotación via Secrets Manager
    ]
  }
}

# Una instancia en modo Serverless v2 — escala 0.5–2 ACU
resource "aws_rds_cluster_instance" "aurora" {
  identifier         = "${local.name_prefix}-aurora-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  performance_insights_enabled = true
  performance_insights_retention_period = 7

  tags = {
    Name = "${local.name_prefix}-aurora-instance-1"
  }
}

# NOTA: tras `terraform apply` ejecutar UNA vez para activar pgvector:
#
#   psql -h <aurora-endpoint> -U rag_admin -d ragvectors -c "CREATE EXTENSION IF NOT EXISTS vector;"
#
# Luego el DDL de documents_embeddings (ver docs/08_indexacion_aurora_pgvector.md)
# se aplicará desde el indexer ECS o desde un init job manual.
