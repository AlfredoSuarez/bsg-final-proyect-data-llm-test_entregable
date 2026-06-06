# ============================================================
# CloudWatch Dashboard + Alarms — Observabilidad del pipeline
# ============================================================

# ----------------------------------------------------------------
# Dashboard ejecutivo
# ----------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "rag_pipeline" {
  dashboard_name = "${local.name_prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      # ============== ROW 1: Pipeline Overview ==============
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# RAG Pipeline — Acme Co Marketplace B2B PyME\n**Ambiente:** ${var.environment} · **Region:** ${var.aws_region} · Refresca cada 5 min · [Step Functions Console](https://${var.aws_region}.console.aws.amazon.com/states/home)"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "Pipeline runs (Step Functions)"
          region = var.aws_region
          view   = "timeSeries"
          stacked = false
          metrics = [
            ["RAGPipeline", "PipelineRunsSucceeded", "Environment", var.environment, { label = "Succeeded", color = "#2ca02c" }],
            ["RAGPipeline", "PipelineRunsFailed",    "Environment", var.environment, { label = "Failed",    color = "#d62728" }],
          ]
          period = 300
          stat   = "Sum"
        }
      },

      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Step Functions execution time"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name_prefix}-pipeline", { label = "P50", stat = "p50" }],
            ["AWS/States", "ExecutionTime", "StateMachineArn", "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name_prefix}-pipeline", { label = "P95", stat = "p95" }],
            ["AWS/States", "ExecutionTime", "StateMachineArn", "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name_prefix}-pipeline", { label = "Max", stat = "Maximum" }],
          ]
          period = 300
          yAxis = {
            left = { label = "ms", min = 0 }
          }
        }
      },

      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Estimated cost per run (USD)"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["RAGPipeline", "EstimatedCostUSD", "Environment", var.environment],
          ]
          period = 3600
          stat   = "Average"
          annotations = {
            horizontal = [
              { label = "Techo USD 500/mes", value = 500, color = "#d62728" },
            ]
          }
        }
      },

      # ============== ROW 2: ETL (Glue) ==============
      {
        type   = "text"
        x      = 0
        y      = 8
        width  = 24
        height = 1
        properties = {
          markdown = "## ETL — AWS Glue"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 5
        properties = {
          title   = "Glue Job runs"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          metrics = [
            ["AWS/Glue", "glue.driver.aggregate.numCompletedTasks", "JobName", "${local.name_prefix}-etl", { label = "Completed tasks" }],
            ["AWS/Glue", "glue.driver.aggregate.numFailedTasks",    "JobName", "${local.name_prefix}-etl", { label = "Failed tasks", color = "#d62728" }],
          ]
          period = 300
          stat   = "Sum"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 5
        properties = {
          title   = "Glue Job duration"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Glue", "glue.driver.aggregate.elapsedTime", "JobName", "${local.name_prefix}-etl", { stat = "Average", label = "Avg" }],
            ["AWS/Glue", "glue.driver.aggregate.elapsedTime", "JobName", "${local.name_prefix}-etl", { stat = "Maximum", label = "Max" }],
          ]
          period = 300
          yAxis = {
            left = { label = "ms", min = 0 }
          }
        }
      },

      # ============== ROW 3: Lambda Chunking ==============
      {
        type   = "text"
        x      = 0
        y      = 14
        width  = 24
        height = 1
        properties = {
          markdown = "## Chunking + Embeddings — AWS Lambda"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 8
        height = 5
        properties = {
          title   = "Lambda invocations / errors"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations",     "FunctionName", "${local.name_prefix}-chunking"],
            ["AWS/Lambda", "Errors",          "FunctionName", "${local.name_prefix}-chunking", { color = "#d62728" }],
            ["AWS/Lambda", "Throttles",       "FunctionName", "${local.name_prefix}-chunking", { color = "#ff7f0e" }],
          ]
          period = 60
          stat   = "Sum"
        }
      },

      {
        type   = "metric"
        x      = 8
        y      = 15
        width  = 8
        height = 5
        properties = {
          title   = "Lambda duration (ms)"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-chunking", { stat = "p50", label = "P50" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-chunking", { stat = "p95", label = "P95" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${local.name_prefix}-chunking", { stat = "p99", label = "P99" }],
          ]
          period = 60
          annotations = {
            horizontal = [
              { label = "Timeout", value = 900000, color = "#d62728" }
            ]
          }
        }
      },

      {
        type   = "metric"
        x      = 16
        y      = 15
        width  = 8
        height = 5
        properties = {
          title   = "Chunks Quality Gate distribution"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          metrics = [
            ["RAGPipeline", "ChunksGenerated",       "Environment", var.environment, { label = "Generated" }],
            ["RAGPipeline", "ChunksDiscarded",       "Environment", var.environment, { label = "Discarded",       color = "#d62728" }],
            ["RAGPipeline", "ChunksFinancialMarked", "Environment", var.environment, { label = "Financial marker" }],
          ]
          period = 300
          stat   = "Sum"
        }
      },

      # ============== ROW 4: Bedrock ==============
      {
        type   = "text"
        x      = 0
        y      = 20
        width  = 24
        height = 1
        properties = {
          markdown = "## Embeddings — AWS Bedrock Titan V2"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 21
        width  = 12
        height = 5
        properties = {
          title   = "Bedrock invocations / throttles"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Bedrock", "Invocations",            "ModelId", "amazon.titan-embed-text-v2:0"],
            ["AWS/Bedrock", "InvocationThrottles",    "ModelId", "amazon.titan-embed-text-v2:0", { color = "#ff7f0e" }],
            ["AWS/Bedrock", "InvocationClientErrors", "ModelId", "amazon.titan-embed-text-v2:0", { color = "#d62728" }],
          ]
          period = 60
          stat   = "Sum"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 21
        width  = 12
        height = 5
        properties = {
          title   = "Bedrock latency (ms)"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/Bedrock", "InvocationLatency", "ModelId", "amazon.titan-embed-text-v2:0", { stat = "p50", label = "P50" }],
            ["AWS/Bedrock", "InvocationLatency", "ModelId", "amazon.titan-embed-text-v2:0", { stat = "p95", label = "P95" }],
          ]
          period = 60
        }
      },

      # ============== ROW 5: ECS Indexer + Aurora ==============
      {
        type   = "text"
        x      = 0
        y      = 26
        width  = 24
        height = 1
        properties = {
          markdown = "## Indexer ECS Fargate · Aurora pgvector"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 27
        width  = 12
        height = 5
        properties = {
          title   = "ECS task CPU / Memory"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization",    "ClusterName", "${local.name_prefix}-cluster"],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", "${local.name_prefix}-cluster"],
          ]
          period = 60
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 27
        width  = 12
        height = 5
        properties = {
          title   = "Aurora ACU + connections"
          region  = var.aws_region
          view    = "timeSeries"
          metrics = [
            ["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", "${local.name_prefix}-aurora", { label = "ACU" }],
            ["AWS/RDS", "DatabaseConnections",       "DBClusterIdentifier", "${local.name_prefix}-aurora", { yAxis = "right", label = "Connections" }],
          ]
          period = 60
        }
      },
    ]
  })
}

# ============================================================
# Alarms — 7 alarmas criticas con accion SNS al topic de fallos
# ============================================================
locals {
  # Treat as alarm action on all critical alarms
  alarm_actions = [aws_sns_topic.pipeline_failure.arn]
  ok_actions    = [aws_sns_topic.pipeline_success.arn]
}

# 1. Step Functions: ExecutionsFailed > 0 en 1 hora
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  count = var.deploy_lambda_chunking && var.deploy_indexer_task ? 1 : 0

  alarm_name          = "${local.name_prefix}-sfn-executions-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 3600
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline[0].arn
  }

  alarm_description = "Step Functions del pipeline RAG fallo al menos 1 vez en 1 hora"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-sfn-failures" }
}

# 2. Glue Job failed tasks
resource "aws_cloudwatch_metric_alarm" "glue_failed_tasks" {
  alarm_name          = "${local.name_prefix}-glue-failed-tasks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "AWS/Glue"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = aws_glue_job.etl.name
  }

  alarm_description = "Glue ETL job tiene > 5 tareas fallidas en 5 min"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-glue-failed" }
}

# 3. Lambda errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.deploy_lambda_chunking ? 1 : 0

  alarm_name          = "${local.name_prefix}-lambda-chunking-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.chunking[0].function_name
  }

  alarm_description = "Lambda chunking > 10 errores en 5 min"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-lambda-errors" }
}

# 4. Bedrock throttling
resource "aws_cloudwatch_metric_alarm" "bedrock_throttles" {
  alarm_name          = "${local.name_prefix}-bedrock-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "InvocationThrottles"
  namespace           = "AWS/Bedrock"
  period              = 300
  statistic           = "Sum"
  threshold           = 50
  treat_missing_data  = "notBreaching"

  dimensions = {
    ModelId = "amazon.titan-embed-text-v2:0"
  }

  alarm_description = "Bedrock Titan V2 esta throttling - considerar reservar concurrency o reducir paralelismo"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-bedrock-throttles" }
}

# 5. Aurora CPU
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  alarm_name          = "${local.name_prefix}-aurora-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  }

  alarm_description = "Aurora CPU > 80% por 10 min - considerar elevar max_capacity"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-aurora-cpu" }
}

# 6. Aurora ACU cerca del max — riesgo de saturacion
resource "aws_cloudwatch_metric_alarm" "aurora_capacity" {
  alarm_name          = "${local.name_prefix}-aurora-capacity-near-max"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ServerlessDatabaseCapacity"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.aurora_max_capacity * 0.9
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  }

  alarm_description = "Aurora ServerlessDatabaseCapacity > 90% del max_capacity configurado"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-aurora-capacity" }
}

# 7. Costo mensual estimado de la cuenta > 80% del techo
resource "aws_cloudwatch_metric_alarm" "billing_threshold" {
  # Billing metrics solo viven en us-east-1; respetamos eso si aws_region cambia
  count = var.aws_region == "us-east-1" ? 1 : 0

  alarm_name          = "${local.name_prefix}-billing-80pct"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600  # 6 horas (billing metrics se actualizan cada 6h)
  statistic           = "Maximum"
  threshold           = 400    # 80% del techo USD 500/mes (Fase 1)
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_description = "Costo mensual estimado > USD 400 (80% del techo Fase 1)"
  alarm_actions     = local.alarm_actions

  tags = { Name = "${local.name_prefix}-billing-80pct" }
}

# ----------------------------------------------------------------
# Output con URL del dashboard
# ----------------------------------------------------------------
output "cloudwatch_dashboard_url" {
  description = "URL directa al dashboard ejecutivo del pipeline"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.rag_pipeline.dashboard_name}"
}
