# ============================================================
# Outputs — referencias útiles tras terraform apply
# ============================================================

output "vpc_id" {
  description = "ID del VPC del pipeline"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas (para Lambda VPC config, ECS task)"
  value       = aws_subnet.private[*].id
}

output "s3_raw_docs_bucket" {
  description = "Bucket de documentos crudos (entrada del pipeline)"
  value       = aws_s3_bucket.raw_docs.bucket
}

output "s3_clean_docs_bucket" {
  description = "Bucket de Parquet limpio (salida de Glue)"
  value       = aws_s3_bucket.clean_docs.bucket
}

output "s3_embeddings_bucket" {
  description = "Bucket de Parquet con embeddings"
  value       = aws_s3_bucket.embeddings.bucket
}

output "aurora_cluster_endpoint" {
  description = "Endpoint principal de Aurora (write)"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Endpoint de lectura de Aurora"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_database_name" {
  description = "Nombre de la base de datos"
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_secret_arn" {
  description = "ARN del secret con credenciales Aurora — leer con aws secretsmanager get-secret-value"
  value       = aws_secretsmanager_secret.aurora_master.arn
  sensitive   = false
}

output "dynamodb_index_versions_table" {
  description = "Tabla DDB de versiones del índice"
  value       = aws_dynamodb_table.index_versions.name
}

output "dynamodb_chunk_quality_audit_table" {
  description = "Tabla DDB de auditoría Quality Gate"
  value       = aws_dynamodb_table.chunk_quality_audit.name
}

output "iam_role_glue_arn" {
  description = "ARN del rol Glue ETL"
  value       = aws_iam_role.glue_etl.arn
}

output "iam_role_lambda_chunking_arn" {
  description = "ARN del rol Lambda chunking"
  value       = aws_iam_role.lambda_chunking.arn
}

output "iam_role_ecs_indexer_task_arn" {
  description = "ARN del task role ECS indexer"
  value       = aws_iam_role.ecs_indexer_task.arn
}

output "iam_role_ecs_indexer_execution_arn" {
  description = "ARN del execution role ECS indexer"
  value       = aws_iam_role.ecs_indexer_execution.arn
}

output "iam_role_stepfunctions_arn" {
  description = "ARN del rol Step Functions"
  value       = aws_iam_role.stepfunctions.arn
}

output "security_group_lambda_id" {
  description = "SG para asignar a Lambda functions en VPC"
  value       = aws_security_group.lambda.id
}

output "security_group_ecs_id" {
  description = "SG para asignar a ECS tasks"
  value       = aws_security_group.ecs.id
}

output "bedrock_titan_model_arn" {
  description = "ARN del modelo Bedrock Titan V2 (referencia para IAM y código)"
  value       = local.bedrock_titan_arn
}

output "account_id" {
  description = "ID de la cuenta AWS donde se despliega"
  value       = data.aws_caller_identity.current.account_id
  sensitive   = false
}
