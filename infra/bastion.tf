# ============================================================
# Bastion EC2 TEMPORAL para init pgvector en Aurora privada
# ============================================================
# Toda esta infraestructura existe SOLO si var.deploy_bastion = true.
# Cambiar a false y aplicar para destruirla completamente.
#
# Componentes:
#   - public subnet + Internet Gateway + route table
#   - EC2 t4g.nano (arm64, ~$0.0042/h) con Amazon Linux 2023
#   - IAM role con SSM Session Manager + lectura del secret Aurora
#   - Security Group permite egress; Aurora SG agrega ingress 5432
#
# Acceso: aws ssm start-session --target <instance-id>
# (no requiere SSH key, no expone puertos al internet)

variable "deploy_bastion" {
  description = "Bastion EC2 temporal para conectar a Aurora privada. false = sin bastion."
  type        = bool
  default     = false
}

# ----------------------------------------------------------------
# Networking publico (Internet Gateway + public subnet + route)
# ----------------------------------------------------------------
resource "aws_internet_gateway" "bastion" {
  count  = var.deploy_bastion ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-bastion-igw" }
}

resource "aws_subnet" "bastion_public" {
  count                   = var.deploy_bastion ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.10.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-bastion-public" }
}

resource "aws_route_table" "bastion_public" {
  count  = var.deploy_bastion ? 1 : 0
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bastion[0].id
  }

  tags = { Name = "${local.name_prefix}-bastion-public-rt" }
}

resource "aws_route_table_association" "bastion_public" {
  count          = var.deploy_bastion ? 1 : 0
  subnet_id      = aws_subnet.bastion_public[0].id
  route_table_id = aws_route_table.bastion_public[0].id
}

# ----------------------------------------------------------------
# Security Group del bastion + ingress en Aurora SG
# ----------------------------------------------------------------
resource "aws_security_group" "bastion" {
  count       = var.deploy_bastion ? 1 : 0
  name        = "${local.name_prefix}-bastion-sg"
  description = "Bastion temporal egress a Aurora y SSM endpoints"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress all - SSM, dnf, Aurora dentro VPC"
  }

  tags = { Name = "${local.name_prefix}-bastion-sg" }
}

resource "aws_security_group_rule" "aurora_ingress_from_bastion" {
  count                    = var.deploy_bastion ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.bastion[0].id
  description              = "PostgreSQL desde bastion temporal"
}

# ----------------------------------------------------------------
# IAM role con SSM Session Manager + read del secret Aurora
# ----------------------------------------------------------------
resource "aws_iam_role" "bastion" {
  count = var.deploy_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-bastion-role" }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.deploy_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_secrets_read" {
  count = var.deploy_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-secrets"
  role  = aws_iam_role.bastion[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.aurora_master.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.glue_scripts.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.deploy_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-profile"
  role  = aws_iam_role.bastion[0].name
}

# ----------------------------------------------------------------
# AMI: Amazon Linux 2023 arm64 (mas reciente)
# ----------------------------------------------------------------
data "aws_ami" "al2023_arm64" {
  count       = var.deploy_bastion ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ----------------------------------------------------------------
# Instance t4g.nano (arm64, cheapest Graviton available)
# user_data instala psql 15 (cliente compatible con Aurora PG 16)
# ----------------------------------------------------------------
resource "aws_instance" "bastion" {
  count                       = var.deploy_bastion ? 1 : 0
  ami                         = data.aws_ami.al2023_arm64[0].id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.bastion_public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = true

  user_data = <<-EOT
    #!/bin/bash
    set -e
    dnf install -y postgresql15 jq
    echo "READY" > /home/ec2-user/bastion-ready
  EOT

  tags = { Name = "${local.name_prefix}-bastion" }
}

# ----------------------------------------------------------------
# Outputs (solo cuando el bastion existe)
# ----------------------------------------------------------------
output "bastion_instance_id" {
  description = "Instance ID del bastion. Usar: aws ssm start-session --target <id>"
  value       = var.deploy_bastion ? aws_instance.bastion[0].id : null
}

output "bastion_public_ip" {
  description = "IP publica del bastion (solo informativo, no se usa para conexion)"
  value       = var.deploy_bastion ? aws_instance.bastion[0].public_ip : null
}
