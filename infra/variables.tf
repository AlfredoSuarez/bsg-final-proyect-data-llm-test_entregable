variable "project_name" {
  description = "Prefijo de nombramiento para todos los recursos"
  type        = string
  default     = "bsg-acmeco-rag"
}

variable "environment" {
  description = "Entorno (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging o prod."
  }
}

variable "aws_region" {
  description = "Región AWS donde se despliega el pipeline"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR del VPC dedicada del pipeline"
  type        = string
  default     = "10.42.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDRs de las 2 subnets privadas (1 por AZ)"
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "aurora_engine_version" {
  description = "Versión PostgreSQL — debe ser 16.x para soporte nativo de pgvector"
  type        = string
  default     = "16.6"
}

variable "aurora_min_capacity" {
  description = "ACUs mínimas Aurora Serverless v2 (0.5 = idle costo ~$43/mes)"
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity" {
  description = "ACUs máximas Aurora Serverless v2 (Fase 1 = 2.0)"
  type        = number
  default     = 2.0
}

variable "aurora_database_name" {
  description = "Nombre de la base de datos Aurora"
  type        = string
  default     = "ragvectors"
}

variable "aurora_master_username" {
  description = "Usuario master de Aurora (la contraseña se genera y guarda en Secrets Manager)"
  type        = string
  default     = "rag_admin"
}

variable "enable_deletion_protection" {
  description = "Protección contra terraform destroy del cluster Aurora (activar en prod)"
  type        = bool
  default     = false
}

variable "enable_bedrock_endpoint" {
  description = "Crear VPC Interface Endpoint para Bedrock Runtime (~$8/mes). Requerido para Lambda en VPC."
  type        = bool
  default     = true
}

variable "enable_secrets_manager_endpoint" {
  description = "Crear VPC Interface Endpoint para Secrets Manager (~$8/mes). Requerido para ECS Fargate."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags adicionales que se mezclan con los tags comunes del proyecto"
  type        = map(string)
  default     = {}
}
