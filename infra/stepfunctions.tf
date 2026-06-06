# ============================================================
# Step Functions State Machine — RAG Pipeline Orchestrator
# ============================================================
# Coordina el pipeline end-to-end:
#   Glue ETL -> Lambda chunking (Map paralelo) -> ECS RunTask indexer
#   -> CloudWatch custom metric -> SNS notify.

# ----------------------------------------------------------------
# SNS Topics — exito y fallo del pipeline
# ----------------------------------------------------------------
resource "aws_sns_topic" "pipeline_success" {
  name = "${local.name_prefix}-pipeline-success"

  tags = {
    Name = "${local.name_prefix}-pipeline-success"
  }
}

resource "aws_sns_topic" "pipeline_failure" {
  name = "${local.name_prefix}-pipeline-failure"

  tags = {
    Name = "${local.name_prefix}-pipeline-failure"
  }
}

# Email opcional para suscripcion a alertas de fallo
variable "notification_email" {
  description = "Email para suscribirse al topic de fallos del pipeline. Vacio = no suscripcion."
  type        = string
  default     = ""

  validation {
    condition = (
      var.notification_email == "" ||
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    )
    error_message = "notification_email debe ser un email valido o cadena vacia."
  }
}

resource "aws_sns_topic_subscription" "failure_email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.pipeline_failure.arn
  protocol  = "email"
  endpoint  = var.notification_email
  # AWS envia email de confirmacion — el usuario debe aceptar.
}

# ----------------------------------------------------------------
# Permisos adicionales para Step Functions:
#   - SNS Publish a los topics
#   - CloudWatch PutMetricData
#   - S3 ListObjectsV2 sobre clean-docs bucket
# ----------------------------------------------------------------
resource "aws_iam_role_policy" "stepfunctions_extras" {
  name = "${local.name_prefix}-stepfunctions-extras"
  role = aws_iam_role.stepfunctions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          aws_sns_topic.pipeline_success.arn,
          aws_sns_topic.pipeline_failure.arn,
        ]
      },
      {
        Sid    = "CloudWatchPutMetric"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "RAGPipeline"
          }
        }
      },
      {
        Sid    = "S3ListClean"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.clean_docs.arn]
      },
      {
        Sid    = "CloudWatchLogsDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
    ]
  })
}

# ----------------------------------------------------------------
# CloudWatch Log Group para Step Functions
# ----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "stepfunctions" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-pipeline"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-stepfunctions-logs"
  }
}

# ----------------------------------------------------------------
# State Machine — renderizada desde el template
# ----------------------------------------------------------------
resource "aws_sfn_state_machine" "pipeline" {
  count = var.deploy_lambda_chunking && var.deploy_indexer_task ? 1 : 0

  name     = "${local.name_prefix}-pipeline"
  role_arn = aws_iam_role.stepfunctions.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/../orchestration/state_machine.json.tpl", {
    glue_job_name                 = aws_glue_job.etl.name
    raw_bucket                    = aws_s3_bucket.raw_docs.bucket
    clean_bucket                  = aws_s3_bucket.clean_docs.bucket
    lambda_chunking_function_name = aws_lambda_function.chunking[0].function_name
    ecs_cluster_arn               = aws_ecs_cluster.this.arn
    ecs_task_definition_arn       = aws_ecs_task_definition.indexer[0].arn
    ecs_security_group_id         = aws_security_group.ecs.id
    private_subnets_json          = jsonencode(aws_subnet.private[*].id)
    sns_success_topic_arn         = aws_sns_topic.pipeline_success.arn
    sns_failure_topic_arn         = aws_sns_topic.pipeline_failure.arn
    environment                   = var.environment
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.stepfunctions.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-pipeline"
  }

  depends_on = [
    aws_iam_role_policy.stepfunctions_inline,
    aws_iam_role_policy.stepfunctions_extras,
    aws_cloudwatch_log_group.stepfunctions,
  ]
}

# ----------------------------------------------------------------
# EventBridge schedule — opcional, reindexacion mensual automatica
# ----------------------------------------------------------------
variable "enable_scheduled_reindex" {
  description = "Si true, programa una reindexacion completa el primer dia del mes a las 02:00 UTC."
  type        = bool
  default     = false
}

resource "aws_scheduler_schedule" "monthly_reindex" {
  count = var.enable_scheduled_reindex && var.deploy_lambda_chunking && var.deploy_indexer_task ? 1 : 0

  name        = "${local.name_prefix}-monthly-reindex"
  group_name  = "default"
  description = "Reindexacion mensual del pipeline RAG"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 2 1 * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_sfn_state_machine.pipeline[0].arn
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      source = "eventbridge-scheduler"
    })
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.enable_scheduled_reindex ? 1 : 0

  name = "${local.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-scheduler-role" }
}

resource "aws_iam_role_policy" "scheduler_invoke_sfn" {
  count = var.enable_scheduled_reindex && var.deploy_lambda_chunking && var.deploy_indexer_task ? 1 : 0

  name = "${local.name_prefix}-scheduler-invoke-sfn"
  role = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = [aws_sfn_state_machine.pipeline[0].arn]
    }]
  })
}

# ----------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------
output "state_machine_arn" {
  description = "ARN de la state machine del pipeline RAG"
  value       = var.deploy_lambda_chunking && var.deploy_indexer_task ? aws_sfn_state_machine.pipeline[0].arn : null
}

output "sns_pipeline_success_topic_arn" {
  description = "Topic SNS de exito (suscribir email para notificaciones)"
  value       = aws_sns_topic.pipeline_success.arn
}

output "sns_pipeline_failure_topic_arn" {
  description = "Topic SNS de fallo (suscribir email para alertas)"
  value       = aws_sns_topic.pipeline_failure.arn
}
