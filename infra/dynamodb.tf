# ============================================================
# DynamoDB — versionado del índice y auditoría de Quality Gate
# ============================================================

# Tabla de versiones del índice — una fila por reindexación
resource "aws_dynamodb_table" "index_versions" {
  name         = "${local.name_prefix}-index-versions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "version_id"

  attribute {
    name = "version_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "by-created-at"
    hash_key        = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name    = "${local.name_prefix}-index-versions"
    Purpose = "Versionado del indice RAG"
  }
}

# Tabla de auditoría del Quality Gate — una fila por decisión sobre un chunk
# Útil para compliance LFPDPPP (por qué se descartó/marcó un chunk)
resource "aws_dynamodb_table" "chunk_quality_audit" {
  name         = "${local.name_prefix}-chunk-quality-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chunk_id"
  range_key    = "version_id"

  attribute {
    name = "chunk_id"
    type = "S"
  }

  attribute {
    name = "version_id"
    type = "S"
  }

  attribute {
    name = "verdict"
    type = "S"
  }

  global_secondary_index {
    name            = "by-verdict"
    hash_key        = "verdict"
    range_key       = "version_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name    = "${local.name_prefix}-chunk-quality-audit"
    Purpose = "Auditoria Quality Gate por chunk - compliance LFPDPPP-CNBV"
  }
}
