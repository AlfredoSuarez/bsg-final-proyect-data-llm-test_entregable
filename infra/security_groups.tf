# ============================================================
# Security Groups — modelo least-privilege por componente
# ============================================================

# Aurora — sólo acepta 5432 desde Lambda, ECS y Query
resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora-sg"
  description = "Aurora PostgreSQL ingress 5432 desde Lambda, ECS y Query"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-aurora-sg"
  }
}

resource "aws_security_group_rule" "aurora_ingress_from_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.lambda.id
  description              = "PostgreSQL desde Lambda chunking/query"
}

resource "aws_security_group_rule" "aurora_ingress_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "PostgreSQL desde ECS indexer Fargate"
}

# Lambda — egress permitido a HTTPS (Bedrock, S3, KMS via endpoints)
resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "Lambda functions egress a Bedrock, S3 y Aurora"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS a servicios AWS via VPC endpoints"
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "PostgreSQL a Aurora dentro del VPC"
  }

  tags = {
    Name = "${local.name_prefix}-lambda-sg"
  }
}

# ECS Fargate — egress a HTTPS y Aurora
resource "aws_security_group" "ecs" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS Fargate indexer egress a S3, Secrets Manager y Aurora"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS a servicios AWS via VPC endpoints"
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "PostgreSQL a Aurora dentro del VPC"
  }

  tags = {
    Name = "${local.name_prefix}-ecs-sg"
  }
}

# VPC Endpoints — acepta HTTPS desde dentro del VPC
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "VPC Interface Endpoints ingress 443 desde VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS desde recursos del VPC"
  }

  tags = {
    Name = "${local.name_prefix}-vpce-sg"
  }
}
