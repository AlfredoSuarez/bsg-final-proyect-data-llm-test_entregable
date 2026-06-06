# ============================================================
# Lambda Chunking + Embeddings (container image)
# ============================================================
# Strategy:
#   1. Terraform crea el repositorio ECR vacio.
#   2. Usuario hace docker build + push (ver chunking/README.md).
#   3. Terraform crea la Lambda apuntando a la imagen.
#
# Si es el PRIMER apply (sin imagen aun), descomentar var.skip_lambda_chunking
# para evitar fallar el apply. Luego de hacer push, comentar y re-aplicar.

# ----------------------------------------------------------------
# ECR repository — almacena la imagen del container Lambda
# ----------------------------------------------------------------
resource "aws_ecr_repository" "chunking" {
  name                 = "${local.name_prefix}-chunking"
  image_tag_mutability = "MUTABLE" # permite re-pushear "latest"

  image_scanning_configuration {
    scan_on_push = true # Amazon Inspector escanea CVEs en cada push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = "${local.name_prefix}-chunking"
    Purpose = "Lambda chunking container image"
  }
}

# Lifecycle policy — mantener solo las ultimas 10 imagenes
resource "aws_ecr_lifecycle_policy" "chunking" {
  repository = aws_ecr_repository.chunking.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las 10 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ----------------------------------------------------------------
# CloudWatch Log Group dedicado
# ----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda_chunking" {
  name              = "/aws/lambda/${local.name_prefix}-chunking"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-chunking-logs"
  }
}

# ----------------------------------------------------------------
# Variable opcional para saltar la Lambda en el primer apply
# (cuando aun no hay imagen en ECR)
# ----------------------------------------------------------------
variable "deploy_lambda_chunking" {
  description = "Si false, Terraform omite la creacion de la Lambda (usar en primer apply antes de push de imagen)."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------
# Lambda Function (container image)
# ----------------------------------------------------------------
resource "aws_lambda_function" "chunking" {
  count = var.deploy_lambda_chunking ? 1 : 0

  function_name = "${local.name_prefix}-chunking"
  description   = "Semantic chunking + Bedrock Titan embeddings"
  role          = aws_iam_role.lambda_chunking.arn

  # Container image deployment
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.chunking.repository_url}:latest"
  architectures = ["arm64"]

  # Recursos compute
  memory_size = 2048
  timeout     = 900
  ephemeral_storage {
    size = 1024
  }

  # VPC config — Lambda dentro del VPC para acceder a Bedrock por endpoint privado
  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  # Reserved concurrency — limita el throughput hacia Bedrock para no
  # exceder cuotas. Ajustable segun reindexaciones simultaneas.
  reserved_concurrent_executions = 5

  environment {
    variables = {
      BEDROCK_MODEL_ID        = "amazon.titan-embed-text-v2:0"
      BEDROCK_REGION          = var.aws_region
      EMBEDDING_DIMENSIONS    = "1024"
      EMBEDDINGS_BUCKET       = aws_s3_bucket.embeddings.bucket
      EMBEDDINGS_PREFIX       = "embeddings/"
      INPUT_PREFIX_STRIP      = "clean/"
      DDB_AUDIT_TABLE         = aws_dynamodb_table.chunk_quality_audit.name
      CHUNK_SIZE_MAX          = "1500"
      CHUNK_SIZE_MIN          = "500"
      CHUNK_OVERLAP           = "200"
      MAX_PARALLEL_EMBEDDINGS = "10"
      VERSION_ID              = "default" # Step Functions sobrescribe por run
      LOG_LEVEL               = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = {
    Name      = "${local.name_prefix}-chunking"
    Component = "chunking-lambda"
  }

  # No fallar si el image tag latest no existe aun (primer apply)
  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [
    aws_iam_role_policy.lambda_chunking_inline,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_cloudwatch_log_group.lambda_chunking,
    aws_vpc_endpoint.bedrock_runtime,
  ]
}

# ----------------------------------------------------------------
# Permiso para que S3 invoque a la Lambda
# ----------------------------------------------------------------
resource "aws_lambda_permission" "chunking_s3" {
  count = var.deploy_lambda_chunking ? 1 : 0

  statement_id  = "AllowExecutionFromCleanDocsBucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chunking[0].function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.clean_docs.arn
}

# ----------------------------------------------------------------
# Bucket notification — trigger Lambda al subir Parquet a /clean/
# ----------------------------------------------------------------
resource "aws_s3_bucket_notification" "clean_docs" {
  count = var.deploy_lambda_chunking ? 1 : 0

  bucket = aws_s3_bucket.clean_docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.chunking[0].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "clean/"
    filter_suffix       = ".parquet"
  }

  depends_on = [aws_lambda_permission.chunking_s3]
}

# ----------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------
output "ecr_chunking_repository_url" {
  description = "URI del repositorio ECR para la imagen Lambda chunking"
  value       = aws_ecr_repository.chunking.repository_url
}

output "lambda_chunking_function_name" {
  description = "Nombre de la Lambda chunking (nulo si deploy_lambda_chunking=false)"
  value       = var.deploy_lambda_chunking ? aws_lambda_function.chunking[0].function_name : null
}

output "lambda_chunking_arn" {
  description = "ARN de la Lambda chunking"
  value       = var.deploy_lambda_chunking ? aws_lambda_function.chunking[0].arn : null
}
