# ============================================================
# AWS Glue Job — ETL de documentos del Marketplace B2B PyME
# ============================================================

# Bucket dedicado para artifacts de Glue (scripts, temp, output de logs)
resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${local.name_prefix}-glue-scripts-${local.bucket_suffix}"

  tags = {
    Name    = "${local.name_prefix}-glue-scripts"
    Purpose = "Glue Job scripts + temp + spark UI logs"
  }
}

resource "aws_s3_bucket_versioning" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket                  = aws_s3_bucket.glue_scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Permitir al rol Glue leer su propio bucket de scripts y escribir temp
resource "aws_iam_role_policy" "glue_scripts_access" {
  name = "${local.name_prefix}-glue-scripts-access"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.glue_scripts.arn,
        "${aws_s3_bucket.glue_scripts.arn}/*"
      ]
    }]
  })
}

# ----------------------------------------------------------------
# CloudWatch Log Group dedicado para el Job (retencion 30 dias)
# ----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "glue_etl" {
  name              = "/aws-glue/jobs/${local.name_prefix}-etl"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-glue-etl-logs"
  }
}

# ----------------------------------------------------------------
# El Job propiamente — Spark 4.0 / Python 3
# ----------------------------------------------------------------
resource "aws_glue_job" "etl" {
  name              = "${local.name_prefix}-etl"
  description       = "ETL de documentos PDF/DOCX/HTML -> Parquet con metadata"
  role_arn          = aws_iam_role.glue_etl.arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 4
  timeout           = 60   # minutos

  command {
    name            = "glueetl"  # spark job; "pythonshell" para PythonShell
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/etl/glue_etl_job.py"
    python_version  = "3"
  }

  default_arguments = {
    # Bibliotecas adicionales — Glue las instala al inicio del job
    "--additional-python-modules"        = "PyPDF2==3.0.1,python-docx==1.1.2,beautifulsoup4==4.12.3"

    # Defaults que el Step Functions puede sobrescribir
    "--input_bucket"                     = aws_s3_bucket.raw_docs.bucket
    "--output_bucket"                    = aws_s3_bucket.clean_docs.bucket
    "--input_prefix"                     = "raw/"
    "--output_prefix"                    = "clean/"
    "--max_workers"                      = "50"

    # Defaults estandar de Glue
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.bucket}/spark-logs/"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.bucket}/temp/"
    "--job-bookmark-option"              = "job-bookmark-disable"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name      = "${local.name_prefix}-etl"
    Component = "etl-glue"
  }

  # El recurso depende del log group y de los buckets ya declarados
  depends_on = [
    aws_cloudwatch_log_group.glue_etl,
    aws_s3_bucket.glue_scripts,
    aws_iam_role_policy.glue_s3,
    aws_iam_role_policy.glue_scripts_access,
  ]
}

# ----------------------------------------------------------------
# Output util — nombre del Job y bucket de scripts
# ----------------------------------------------------------------
output "glue_etl_job_name" {
  description = "Nombre del Glue Job (referenciar desde Step Functions)"
  value       = aws_glue_job.etl.name
}

output "glue_scripts_bucket" {
  description = "Bucket donde subir el script Python del Glue Job"
  value       = aws_s3_bucket.glue_scripts.bucket
}
