# ============================================================
# 3 buckets del pipeline — raw, clean, embeddings
# ============================================================

locals {
  # Sufijo único para evitar colisiones globales de nombres de bucket
  bucket_suffix = data.aws_caller_identity.current.account_id
}

# ----------------------------------------------------------------
# raw-docs — entrada del pipeline (PDF, DOCX, HTML)
# ----------------------------------------------------------------
resource "aws_s3_bucket" "raw_docs" {
  bucket = "${local.name_prefix}-raw-docs-${local.bucket_suffix}"

  tags = {
    Name    = "${local.name_prefix}-raw-docs"
    Purpose = "Documentos crudos PDF/DOCX/HTML"
  }
}

resource "aws_s3_bucket_versioning" "raw_docs" {
  bucket = aws_s3_bucket.raw_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_docs" {
  bucket = aws_s3_bucket.raw_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw_docs" {
  bucket                  = aws_s3_bucket.raw_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_docs" {
  bucket = aws_s3_bucket.raw_docs.id

  rule {
    id     = "intelligent-tiering-after-90d"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# ----------------------------------------------------------------
# clean-docs — Parquet normalizado por Glue
# ----------------------------------------------------------------
resource "aws_s3_bucket" "clean_docs" {
  bucket = "${local.name_prefix}-clean-docs-${local.bucket_suffix}"

  tags = {
    Name    = "${local.name_prefix}-clean-docs"
    Purpose = "Parquet limpio salida de Glue ETL"
  }
}

resource "aws_s3_bucket_versioning" "clean_docs" {
  bucket = aws_s3_bucket.clean_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clean_docs" {
  bucket = aws_s3_bucket.clean_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "clean_docs" {
  bucket                  = aws_s3_bucket.clean_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------
# embeddings — Parquet con vectores 1024 dim
# ----------------------------------------------------------------
resource "aws_s3_bucket" "embeddings" {
  bucket = "${local.name_prefix}-embeddings-${local.bucket_suffix}"

  tags = {
    Name    = "${local.name_prefix}-embeddings"
    Purpose = "Parquet con embeddings Titan V2 1024 dim"
  }
}

resource "aws_s3_bucket_versioning" "embeddings" {
  bucket = aws_s3_bucket.embeddings.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "embeddings" {
  bucket = aws_s3_bucket.embeddings.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "embeddings" {
  bucket                  = aws_s3_bucket.embeddings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
