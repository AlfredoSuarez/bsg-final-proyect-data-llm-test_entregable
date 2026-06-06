# ============================================================
# IAM Roles — least privilege por componente
# ============================================================

locals {
  bedrock_titan_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
}

# ----------------------------------------------------------------
# Glue ETL Role
# ----------------------------------------------------------------
resource "aws_iam_role" "glue_etl" {
  name = "${local.name_prefix}-glue-etl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-glue-etl-role" }
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_etl.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "${local.name_prefix}-glue-s3-access"
  role = aws_iam_role.glue_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.raw_docs.arn,
          "${aws_s3_bucket.raw_docs.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.clean_docs.arn,
          "${aws_s3_bucket.clean_docs.arn}/*"
        ]
      }
    ]
  })
}

# ----------------------------------------------------------------
# Lambda Chunking Role
# ----------------------------------------------------------------
resource "aws_iam_role" "lambda_chunking" {
  name = "${local.name_prefix}-lambda-chunking-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-lambda-chunking-role" }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_chunking.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_chunking.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_chunking_inline" {
  name = "${local.name_prefix}-lambda-chunking-policy"
  role = aws_iam_role.lambda_chunking.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3CleanRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.clean_docs.arn,
          "${aws_s3_bucket.clean_docs.arn}/*"
        ]
      },
      {
        Sid    = "S3EmbeddingsWrite"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.embeddings.arn,
          "${aws_s3_bucket.embeddings.arn}/*"
        ]
      },
      {
        Sid    = "BedrockInvokeTitan"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [local.bedrock_titan_arn]
      },
      {
        Sid    = "DynamoDBAuditWrite"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
        Resource = [aws_dynamodb_table.chunk_quality_audit.arn]
      }
    ]
  })
}

# ----------------------------------------------------------------
# ECS Indexer Role (Task Role + Execution Role)
# ----------------------------------------------------------------
resource "aws_iam_role" "ecs_indexer_task" {
  name = "${local.name_prefix}-ecs-indexer-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-ecs-indexer-task-role" }
}

resource "aws_iam_role_policy" "ecs_indexer_inline" {
  name = "${local.name_prefix}-ecs-indexer-policy"
  role = aws_iam_role.ecs_indexer_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3EmbeddingsRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.embeddings.arn,
          "${aws_s3_bucket.embeddings.arn}/*"
        ]
      },
      {
        Sid    = "AuroraSecretRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.aurora_master.arn]
      },
      {
        Sid    = "DynamoDBVersionWrite"
        Effect = "Allow"
        Action = ["dynamodb:PutItem"]
        Resource = [aws_dynamodb_table.index_versions.arn]
      }
    ]
  })
}

# Execution role estándar para Fargate (pull de imagen ECR, logs)
resource "aws_iam_role" "ecs_indexer_execution" {
  name = "${local.name_prefix}-ecs-indexer-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-ecs-indexer-execution-role" }
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_indexer_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ----------------------------------------------------------------
# Step Functions Role — orquesta Glue, Lambda, ECS, DynamoDB
# ----------------------------------------------------------------
resource "aws_iam_role" "stepfunctions" {
  name = "${local.name_prefix}-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-stepfunctions-role" }
}

resource "aws_iam_role_policy" "stepfunctions_inline" {
  name = "${local.name_prefix}-stepfunctions-policy"
  role = aws_iam_role.stepfunctions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueStartJob"
        Effect = "Allow"
        Action = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:job/${local.name_prefix}-*"
      },
      {
        Sid    = "LambdaInvoke"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.name_prefix}-*"
      },
      {
        Sid    = "ECSRunTask"
        Effect = "Allow"
        Action = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-*"
      },
      {
        Sid    = "PassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_indexer_task.arn,
          aws_iam_role.ecs_indexer_execution.arn
        ]
      },
      {
        Sid    = "DynamoDBVersions"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = [aws_dynamodb_table.index_versions.arn]
      },
      {
        Sid    = "EventsForECS"
        Effect = "Allow"
        Action = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "*"
      }
    ]
  })
}
