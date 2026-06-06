# ============================================================
# Aurora master password — generado, guardado en Secrets Manager
# ============================================================

resource "random_password" "aurora_master" {
  length      = 32
  special     = true
  min_special = 4
  # Caracteres especiales evitados por RDS: /, ", @, espacios
  override_special = "!#$%&()*+,-.:;<=>?[]^_{|}~"
}

resource "aws_secretsmanager_secret" "aurora_master" {
  name        = "${local.name_prefix}-aurora-master"
  description = "Credenciales master del cluster Aurora PostgreSQL para RAG pipeline"

  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-aurora-master"
  }
}

resource "aws_secretsmanager_secret_version" "aurora_master" {
  secret_id = aws_secretsmanager_secret.aurora_master.id
  secret_string = jsonencode({
    username = var.aurora_master_username
    password = random_password.aurora_master.result
    engine   = "postgres"
    host     = aws_rds_cluster.aurora.endpoint
    port     = aws_rds_cluster.aurora.port
    dbname   = var.aurora_database_name
  })
}
