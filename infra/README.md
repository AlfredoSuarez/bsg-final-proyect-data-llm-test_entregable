# Infrastructure as Code — Terraform

Foundation de AWS del pipeline RAG documental del Marketplace B2B PyME de Acme Co.

Este directorio contiene los recursos AWS **foundation** (storage, DB, secrets, IAM, networking) sobre los que el compute (Glue Job, Lambda chunking, ECS Indexer, Step Functions) se montará en Prompts posteriores (6/7/8/9).

## Qué se crea con `terraform apply`

| Recurso | Detalle | Costo aproximado/mes |
|---|---|---|
| 1 VPC dedicada | CIDR `10.42.0.0/16`, 2 subnets privadas en 2 AZ | $0 |
| 2 VPC Gateway Endpoints | S3, DynamoDB | $0 |
| 2 VPC Interface Endpoints | Bedrock Runtime, Secrets Manager | ~$16 |
| 3 buckets S3 | `raw-docs`, `clean-docs`, `embeddings` con versioning + KMS | ~$2 |
| 1 cluster Aurora PostgreSQL 16 Serverless v2 | 0.5–2 ACU, `pgvector` pre-cargado, 7 días backup | ~$45–170 |
| 1 secret en Secrets Manager | credenciales Aurora autogeneradas | ~$0.40 |
| 2 tablas DynamoDB on-demand | `index-versions`, `chunk-quality-audit` | ~$1 |
| 5 IAM Roles | Glue, Lambda, ECS task, ECS execution, Step Functions | $0 |
| 4 Security Groups | Aurora, Lambda, ECS, VPC Endpoints | $0 |
| **Total foundation idle** | | **~$65–190/mes** |

## Prerrequisitos

| Item | Cómo verificar |
|---|---|
| Terraform ≥ 1.6.0 | `terraform version` |
| AWS CLI configurado | `aws sts get-caller-identity` |
| Cuenta AWS con permisos | Admin o equivalente para esta sandbox |
| Acceso a Bedrock Titan V2 habilitado | `aws bedrock list-foundation-models --region us-east-1 --by-provider amazon \| Select-String "titan-embed-text-v2"` |

> **Habilitar Bedrock Titan V2:** AWS Console → Bedrock → Model access → Request access → Amazon → Titan Text Embeddings V2 → Submit (auto-aprobación para modelos de Amazon).

## Despliegue paso a paso (PowerShell)

```powershell
# 1. Entrar al directorio
cd "C:\Users\Rog\OneDrive\BCG Institute\Arquitectura Escalable\Proyecto_Final\infra"

# 2. Copiar plantilla de variables y ajustar
Copy-Item terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con tus valores

# 3. Verificar identidad y región
aws sts get-caller-identity
aws configure get region   # debe ser us-east-1

# 4. Inicializar Terraform (descarga providers)
terraform init

# 5. Validar sintaxis
terraform validate

# 6. Generar plan (NO crea recursos todavía)
terraform plan -out=tfplan

# 7. Aplicar (CREA RECURSOS — Aurora tarda 10-15 min)
terraform apply tfplan

# 8. Ver outputs útiles
terraform output
```

## Activar `pgvector` post-deploy

Tras `terraform apply` exitoso, ejecutar UNA vez para activar la extensión:

```powershell
# Obtener credenciales del secret
$secretArn = terraform output -raw aurora_secret_arn
$secretJson = aws secretsmanager get-secret-value --secret-id $secretArn --query SecretString --output text
$secret = $secretJson | ConvertFrom-Json

# Conectar y crear extensión
# Requiere psql instalado (Postgres client) — alternativa: usar DBeaver, pgAdmin, etc.
$env:PGPASSWORD = $secret.password
psql -h $secret.host -U $secret.username -d $secret.dbname -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql -h $secret.host -U $secret.username -d $secret.dbname -c "SELECT extversion FROM pg_extension WHERE extname='vector';"
```

El DDL completo de la tabla `documents_embeddings` se aplica desde el Indexer (Prompt 8) o manualmente con el script `scripts/init_schema.sql`.

## Destruir todo (cuidado en prod)

```powershell
# Si `enable_deletion_protection = true`, primero desactivar en tfvars
terraform destroy
```

Aurora tarda 5–10 min en destruirse. Los buckets S3 con objetos requieren vaciado manual antes (Terraform no borra buckets no vacíos por defecto).

## Estructura de archivos

```
infra/
├── versions.tf           # Versiones de Terraform y providers
├── variables.tf          # Variables de entrada
├── main.tf               # Provider config + locals + tags comunes
├── vpc.tf                # VPC, subnets, route tables, endpoints
├── security_groups.tf    # SGs para Aurora, Lambda, ECS, VPC endpoints
├── s3.tf                 # 3 buckets con versioning + KMS + lifecycle
├── secrets.tf            # Random password + Secrets Manager
├── aurora.tf             # Aurora Serverless v2 + pgvector
├── dynamodb.tf           # 2 tablas (versions + quality audit)
├── iam.tf                # Roles least-privilege por componente
├── outputs.tf            # Outputs útiles
├── terraform.tfvars.example  # Plantilla
└── README.md             # Este archivo
```

## Qué NO está incluido todavía

| Componente | Cuándo llega |
|---|---|
| Glue Job (recurso `aws_glue_job`) | Prompt 6 — cuando el código Python del ETL exista |
| Lambda functions (recurso `aws_lambda_function`) | Prompt 7 — cuando el código del chunker exista |
| ECS Task Definition + Cluster | Prompt 8 — cuando la imagen Docker exista |
| Step Functions State Machine | Prompt 9 — orquestación end-to-end |
| API Gateway + Query Lambda | Fase 1.1 |
| VPC Interface Endpoints adicionales | Cuando se desplieguen ECR, CloudWatch Logs, etc. |
| KMS Customer Managed Keys | Fase 2 (cuando corpus financiero crezca) |
| Backend remoto S3 + DynamoDB lock | Fase 1.1 |

## Validaciones de seguridad

Antes de `terraform apply` o `terraform plan` verificar:

- `terraform.tfvars` no está en el repo (`git check-ignore terraform.tfvars`)
- `*.tfstate` no está en el repo (`git check-ignore terraform.tfstate`)
- `aurora_master` secret no se imprime en outputs (verificado: `sensitive = true` implícito por Secrets Manager)
- Buckets S3 con `public_access_block` (verificado en `s3.tf`)
- Aurora en subnets privadas (sin `publicly_accessible`)

## Troubleshooting

**Error `Plugin did not respond` / `x509: certificate signed by unknown authority` en localhost:**

Síntoma típico en máquinas con SSL inspection corporativo (ZScaler, Netskope, etc.). El producto de inspección intercepta el handshake mTLS entre Terraform y los provider plugins en `127.0.0.1`. **Workaround:**

```powershell
$env:TF_DISABLE_PLUGIN_TLS = "1"
terraform plan
```

Esto deshabilita mTLS entre Terraform y plugins (sólo localhost — riesgo bajo en single-user dev). Ver `docs/SECURITY.md` para detalles del entorno.

**Error `Cannot find Bedrock model`:**
- Verificar `aws bedrock list-foundation-models --region us-east-1`
- Habilitar acceso al modelo en Bedrock console

**Error `Subnet group requires subnets in at least 2 AZs`:**
- Verificar que `data.aws_availability_zones.available` retorna ≥ 2 AZs en `us-east-1`

**Aurora tarda mucho:**
- Normal — 10 a 15 min para create, 5 a 10 min para destroy

**`pgvector` no aparece:**
- Verificar `engine_version` (16.6+ requerido)
- Verificar `shared_preload_libraries` en parameter group incluye `vector`
- Reboot del cluster si recién cambió el parameter group

**OneDrive borra `.terraform/`:**
- Síntoma confirmado: ejecutar `terraform init` dentro del workspace OneDrive puede crear y luego perder el directorio `.terraform/`. Workaround: ejecutar terraform desde un directorio temporal fuera de OneDrive (ej. `$env:LOCALAPPDATA\Temp\<proyecto>-tf\`) copiando los `.tf` antes de cada operación. Ver Riesgo #3 en `docs/SECURITY.md`.

## Referencias

- [Aurora pgvector documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.VectorDB.html)
- [AWS Bedrock IAM permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/security-iam.html)
- [Aurora Serverless v2 capacity](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.setting-capacity.html)
