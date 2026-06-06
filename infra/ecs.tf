# ============================================================
# ECS Fargate Cluster + Indexer Task Definition
# ============================================================
# El indexer corre como una task Fargate disparada por Step Functions
# tras la Lambda chunking termine de embebir. Carga embeddings desde
# S3 a Aurora pgvector via UPSERT batch.

# ----------------------------------------------------------------
# ECR repository — almacena la imagen del indexer
# ----------------------------------------------------------------
resource "aws_ecr_repository" "indexer" {
  name                 = "${local.name_prefix}-indexer"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = "${local.name_prefix}-indexer"
    Purpose = "ECS Fargate indexer container image"
  }
}

resource "aws_ecr_lifecycle_policy" "indexer" {
  repository = aws_ecr_repository.indexer.name

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
# ECS Cluster — Fargate-only, sin EC2
# ----------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${local.name_prefix}-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ----------------------------------------------------------------
# CloudWatch Log Group para el indexer
# ----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ecs_indexer" {
  name              = "/ecs/${local.name_prefix}-indexer"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-indexer-logs"
  }
}

# ----------------------------------------------------------------
# Toggle: permitir primer apply sin imagen en ECR
# ----------------------------------------------------------------
variable "deploy_indexer_task" {
  description = "Si false, omite el task definition del indexer (usar en primer apply antes de push de imagen)."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------
# Task Definition — Fargate arm64, 1 vCPU + 2 GB
# ----------------------------------------------------------------
resource "aws_ecs_task_definition" "indexer" {
  count = var.deploy_indexer_task ? 1 : 0

  family                   = "${local.name_prefix}-indexer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024" # 1 vCPU
  memory                   = "2048" # 2 GB
  execution_role_arn       = aws_iam_role.ecs_indexer_execution.arn
  task_role_arn            = aws_iam_role.ecs_indexer_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "indexer"
      image     = "${aws_ecr_repository.indexer.repository_url}:latest"
      essential = true

      environment = [
        { name = "AWS_REGION",         value = var.aws_region },
        { name = "EMBEDDINGS_BUCKET",  value = aws_s3_bucket.embeddings.bucket },
        { name = "EMBEDDINGS_PREFIX",  value = "embeddings/" },
        { name = "AURORA_SECRET_ARN",  value = aws_secretsmanager_secret.aurora_master.arn },
        { name = "DDB_VERSIONS_TABLE", value = aws_dynamodb_table.index_versions.name },
        { name = "EMBEDDING_MODEL",    value = "amazon.titan-embed-text-v2:0" },
        { name = "BATCH_SIZE",         value = "500" },
        { name = "LOG_LEVEL",          value = "INFO" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_indexer.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "indexer"
        }
      }

      # No exponemos puertos — proceso batch, no servidor.
      portMappings = []

      # readonly root filesystem (excepto /tmp via ephemeral storage)
      readonlyRootFilesystem = false
    }
  ])

  ephemeral_storage {
    size_in_gib = 21 # 20 GB es el minimo cobrado; 21 da margen para /tmp
  }

  tags = {
    Name      = "${local.name_prefix}-indexer-task"
    Component = "indexer-fargate"
  }

  lifecycle {
    ignore_changes = [
      # Permitir que CI/CD actualice la imagen sin pelearse con Terraform
      container_definitions,
    ]
  }

  depends_on = [
    aws_iam_role_policy.ecs_indexer_inline,
    aws_iam_role_policy_attachment.ecs_execution_managed,
    aws_cloudwatch_log_group.ecs_indexer,
  ]
}

# ----------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------
output "ecr_indexer_repository_url" {
  description = "URI del repositorio ECR para la imagen del indexer"
  value       = aws_ecr_repository.indexer.repository_url
}

output "ecs_cluster_name" {
  description = "Nombre del cluster ECS donde corre el indexer"
  value       = aws_ecs_cluster.this.name
}

output "ecs_indexer_task_definition_arn" {
  description = "ARN de la task definition del indexer"
  value       = var.deploy_indexer_task ? aws_ecs_task_definition.indexer[0].arn : null
}

output "ecs_indexer_task_definition_family" {
  description = "Family name del task definition (para RunTask via Step Functions)"
  value       = var.deploy_indexer_task ? aws_ecs_task_definition.indexer[0].family : null
}
