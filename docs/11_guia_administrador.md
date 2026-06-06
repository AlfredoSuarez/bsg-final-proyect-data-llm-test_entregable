# Guía de Administrador — Operación del Pipeline RAG

**Documento:** 11 — Guía de Administrador
**Proyecto:** Plataforma de Conocimiento del Hub PyMEs y Marketplace B2B de Acme Co
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:** Equipo técnico Acme Co — Cloud Engineering, Data Engineering, DevOps, Security

---

## 1. Información de contacto

| Rol | Responsabilidad | Contacto |
|---|---|---|
| **Owner del proyecto** | Decisiones de arquitectura, sponsor BSG | Alfredo Suárez · `arse.alf@gmail.com` |
| **Cuenta AWS** | `275541169383` (region `us-east-1`) | (acceso vía SSO Acme Co, ver SECURITY.md) |
| **Repositorio Git** | https://github.com/AlfredoSuarez/bsg-final-proyect-data-llm-test (privado) | |
| **Escalamiento Bedrock** | Cuotas, acceso a modelos | AWS Bedrock Console → Limits → Request quota increase |
| **Escalamiento Compliance** | LFPDPPP / CNBV / CONDUSEF | Acme Co Legal + DPO |

## 2. Arquitectura en una página

```
S3 raw-docs ─→ Glue ETL ─→ S3 clean-docs ─→ Lambda chunking ─→ Bedrock Titan V2
                                                    │
                                                    ▼
                                               S3 embeddings ─→ ECS Fargate indexer ─→ Aurora pgvector
                                                                                      │
                                                                                      ▼
                                                                                 DynamoDB
                                                                              (versions + audit)

Orquestación: Step Functions  ·  Observabilidad: CloudWatch (dashboard + 7 alarms)
```

Para detalles completos ver `docs/04_arquitectura.md`.

## 3. Despliegue desde cero

### 3.1 Prerrequisitos

| Item | Verificar |
|---|---|
| Cuenta AWS activa, region `us-east-1` | `aws sts get-caller-identity` |
| IAM user (no root — ver `docs/SECURITY.md` Riesgo #1) | El ARN debe terminar en `:user/...`, no `:root` |
| AWS CLI configurado con `AWS_CA_BUNDLE` | `aws configure get ca_bundle` o usar `--no-verify-ssl` en redes con SSL inspection |
| Terraform 1.6+ instalado | `terraform version` |
| Docker Desktop con `buildx` para arm64 | `docker buildx ls` |
| Acceso habilitado a Bedrock Titan V2 | AWS Console → Bedrock → Model access → Amazon → Titan Text Embeddings V2 |
| Clone del repo | `git clone https://github.com/AlfredoSuarez/bsg-final-proyect-data-llm-test` |

### 3.2 Apply de la infra foundation

```powershell
cd <repo>/infra

# Copiar plantilla de variables y ajustar
Copy-Item terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars: project_name, environment, notification_email (opcional)

# Primer apply: SIN Lambda ni Indexer (aún no hay imágenes en ECR)
# Editar terraform.tfvars temporalmente:
#   deploy_lambda_chunking = false
#   deploy_indexer_task    = false

$env:TF_DISABLE_PLUGIN_TLS = "1"   # ver SECURITY.md §2
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Aurora tarda **10-15 min** en crearse. Vas a ver `Still creating...` repetido — es normal.

### 3.3 Inicializar pgvector en Aurora

Tras el primer `terraform apply`, conecta vía Bastion o desde una EC2 dentro del VPC:

```powershell
# Obtener credenciales
$secretArn = terraform output -raw aurora_secret_arn
$secretJson = aws secretsmanager get-secret-value `
    --secret-id $secretArn --query SecretString --output text --no-verify-ssl
$secret = $secretJson | ConvertFrom-Json

# Aplicar DDL (requiere psql instalado dentro del VPC)
$env:PGPASSWORD = $secret.password
psql -h $secret.host -U $secret.username -d $secret.dbname `
     -f ../indexer/sql/00_init_pgvector.sql

# Verificar
psql -h $secret.host -U $secret.username -d $secret.dbname -c "
    SELECT extname, extversion FROM pg_extension WHERE extname='vector';
    \d documents_embeddings
"
```

### 3.4 Build + push de imágenes Docker

```powershell
$account = aws sts get-caller-identity --query Account --output text --no-verify-ssl
$region = "us-east-1"

# Login ECR
aws ecr get-login-password --region $region --no-verify-ssl |
    docker login --username AWS --password-stdin "$account.dkr.ecr.$region.amazonaws.com"

# --- Chunking Lambda image ---
cd ../chunking
docker buildx build --platform linux/arm64 -t "bsg-acmeco-rag-dev-chunking:v1.0.0" --load .
docker tag bsg-acmeco-rag-dev-chunking:v1.0.0 "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-chunking:v1.0.0"
docker tag bsg-acmeco-rag-dev-chunking:v1.0.0 "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-chunking:latest"
docker push "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-chunking:v1.0.0"
docker push "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-chunking:latest"

# --- Indexer ECS image ---
cd ../indexer
docker buildx build --platform linux/arm64 -t "bsg-acmeco-rag-dev-indexer:v1.0.0" --load .
docker tag bsg-acmeco-rag-dev-indexer:v1.0.0 "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-indexer:v1.0.0"
docker tag bsg-acmeco-rag-dev-indexer:v1.0.0 "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-indexer:latest"
docker push "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-indexer:v1.0.0"
docker push "$account.dkr.ecr.$region.amazonaws.com/bsg-acmeco-rag-dev-indexer:latest"
```

### 3.5 Subir el script de Glue

```powershell
cd ../infra
$glueScriptsBucket = terraform output -raw glue_scripts_bucket
aws s3 cp ../etl/glue_etl_job.py "s3://$glueScriptsBucket/etl/glue_etl_job.py" --no-verify-ssl
```

### 3.6 Apply final con compute habilitado

```powershell
# Editar terraform.tfvars:
#   deploy_lambda_chunking = true
#   deploy_indexer_task    = true

terraform plan -out=tfplan
terraform apply tfplan
```

### 3.7 Verificar el despliegue

```powershell
# Resources principales
terraform output

# Step Functions visible
aws stepfunctions list-state-machines --no-verify-ssl --query 'stateMachines[*].name'

# Lambda
aws lambda list-functions --no-verify-ssl --query 'Functions[?contains(FunctionName, `bsg-acmeco`)].FunctionName'

# ECS cluster
aws ecs list-clusters --no-verify-ssl --query 'clusterArns[*]'

# Dashboard URL
terraform output cloudwatch_dashboard_url
```

---

## 4. Runbook — Ejecutar reindexación completa

### 4.1 Cuándo se ejecuta

- **Manual**: tras agregar/cambiar documentos al raw bucket de forma masiva.
- **Programado mensual**: si `enable_scheduled_reindex = true` — el día 1 a las 02:00 UTC.

### 4.2 Procedimiento

```powershell
# 1. Verificar documentos en raw
$rawBucket = terraform -chdir=infra output -raw s3_raw_docs_bucket
aws s3 ls "s3://$rawBucket/raw/" --recursive --no-verify-ssl | Measure-Object

# 2. Disparar el pipeline
$smArn = terraform -chdir=infra output -raw state_machine_arn
$execName = "manual-$(Get-Date -Format 'yyyyMMddTHHmmssZ')"

$execArn = aws stepfunctions start-execution `
    --state-machine-arn $smArn `
    --name $execName `
    --input '{"trigger":"manual"}' `
    --no-verify-ssl `
    --query executionArn --output text

Write-Host "Execution started: $execArn"

# 3. Monitorear (puede tardar 30-60 min)
do {
    Start-Sleep -Seconds 30
    $status = aws stepfunctions describe-execution `
        --execution-arn $execArn `
        --no-verify-ssl `
        --query status --output text
    Write-Host "Status: $status"
} while ($status -eq "RUNNING")

Write-Host "Final status: $status"

# 4. Si SUCCEEDED, ver la nueva versión en DDB
aws dynamodb scan `
    --table-name bsg-acmeco-rag-dev-index-versions `
    --no-verify-ssl `
    --query 'Items[?contains(version_id.S, `'$execName'`)]'

# 5. Si FAILED, ver historia detallada
aws stepfunctions get-execution-history `
    --execution-arn $execArn `
    --no-verify-ssl `
    --max-items 50 |
    ConvertFrom-Json |
    Select-Object -ExpandProperty events |
    Where-Object { $_.type -like "*Failed*" -or $_.type -like "*Error*" }
```

### 4.3 Tiempos esperados

| Etapa | Fase 1 (500 docs) | Fase 2 (5,000 docs) |
|---|---|---|
| Glue ETL | ~8-15 min | ~25-40 min |
| Lambda chunking (paralelo) | ~5-10 min | ~15-25 min |
| ECS indexer | ~5-10 min | ~15-25 min |
| **Total end-to-end** | **~20-35 min** | **~60-90 min** |

Si tarda más, revisar dashboard CloudWatch — probable Bedrock throttling o Aurora bajo carga.

---

## 5. Runbook — Reindexar un documento específico

Cuando solo cambias un documento (no reindex completo):

### Opción A — Subir y dejar que el S3 trigger haga su trabajo

```powershell
# Si solo cambias el documento crudo y quieres que pase por el ETL completo
aws s3 cp documento_actualizado.pdf "s3://$rawBucket/raw/contratos/" --no-verify-ssl

# Esperar que la próxima reindexación programada lo capture, o disparar manual:
# Ver §4.2 arriba.
```

### Opción B — Procesar un Parquet específico de /clean/

Si el documento ya pasó por Glue ETL y solo necesitas re-chunkearlo:

```powershell
# Identificar el Parquet específico
$cleanBucket = terraform -chdir=infra output -raw s3_clean_docs_bucket
aws s3 ls "s3://$cleanBucket/clean/" --recursive --no-verify-ssl | Select-String "doc_type=contract"

# Invocar Lambda manualmente con S3 event sintético
$key = "clean/doc_type=contract/part-0001.snappy.parquet"
$payload = @{
    Records = @(
        @{
            s3 = @{
                bucket = @{ name = $cleanBucket }
                object = @{ key = $key }
            }
        }
    )
    version_id = "manual-rechunk-$(Get-Date -Format 'yyyyMMddTHHmm')"
} | ConvertTo-Json -Depth 5 -Compress

aws lambda invoke `
    --function-name bsg-acmeco-rag-dev-chunking `
    --payload $payload `
    --no-verify-ssl `
    output.json
Get-Content output.json
```

### Opción C — Cargar embeddings ya emitidos al índice

Si los embeddings ya están en `/embeddings/` y solo necesitas re-cargarlos:

```powershell
$ecsCluster = terraform -chdir=infra output -raw ecs_cluster_name
$subnets = terraform -chdir=infra output -json private_subnet_ids | ConvertFrom-Json
$ecsSg = terraform -chdir=infra output -raw security_group_ecs_id

aws ecs run-task `
    --cluster $ecsCluster `
    --task-definition bsg-acmeco-rag-dev-indexer `
    --launch-type FARGATE `
    --network-configuration "awsvpcConfiguration={subnets=[$($subnets[0]),$($subnets[1])],securityGroups=[$ecsSg],assignPublicIp=DISABLED}" `
    --overrides '{
        "containerOverrides": [{
            "name": "indexer",
            "environment": [
                {"name": "VERSION_ID", "value": "manual-reload-2026-05-24"}
            ]
        }]
    }' `
    --no-verify-ssl
```

---

## 6. Monitoreo día a día

### 6.1 Dashboard ejecutivo

URL: `terraform output cloudwatch_dashboard_url`

Revisar diariamente (5 minutos):

1. **Row 1 — Pipeline Overview**: ¿hubo runs Failed en las últimas 24h?
2. **Row 3 — Chunking Lambda**: errors > 0? Duration P95 < 10 min?
3. **Row 4 — Bedrock**: ¿hay throttles?
4. **Row 5 — Aurora**: ACU + connections estables?

### 6.2 Alarmas activas

```powershell
# Listar alarmas en estado ALARM
aws cloudwatch describe-alarms `
    --state-value ALARM `
    --no-verify-ssl `
    --query 'MetricAlarms[*].[AlarmName, StateReason]' `
    --output table
```

### 6.3 Logs estructurados con correlación

```powershell
# Buscar errores de una ejecución específica
aws logs start-query `
    --log-group-names "/aws/lambda/bsg-acmeco-rag-dev-chunking" `
                      "/ecs/bsg-acmeco-rag-dev-indexer" `
                      "/aws-glue/jobs/bsg-acmeco-rag-dev-etl" `
    --start-time (Get-Date -Date "2026-05-24" -AsUTC).ToUnixTimeSeconds() `
    --end-time (Get-Date -AsUTC).ToUnixTimeSeconds() `
    --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc' `
    --no-verify-ssl
```

### 6.4 Costo del último mes

```powershell
aws ce get-cost-and-usage `
    --time-period "Start=2026-04-24,End=2026-05-24" `
    --granularity MONTHLY `
    --metrics UnblendedCost `
    --group-by Type=DIMENSION,Key=SERVICE `
    --no-verify-ssl
```

Comparar contra el techo USD 500/mes (Fase 1). Si llega a 80% (USD 400), la alarma `billing-80pct` ya disparó.

---

## 7. Runbook — Rollback de versión

### 7.1 Cuando hacerlo

- Una versión nueva del índice tiene problemas de calidad detectados post-deploy.
- El comité de Compliance pide volver a un estado conocido.
- A/B testing: comparar versión A vs B sobre un subset de consultas.

### 7.2 Procedimiento

**El rollback NO borra datos** — todas las versiones coexisten en Aurora. Solo cambia qué versión usa la lógica de consulta.

```powershell
# 1. Listar versiones disponibles
aws dynamodb scan `
    --table-name bsg-acmeco-rag-dev-index-versions `
    --no-verify-ssl `
    --query 'Items[*].[version_id.S, created_at.S, documents_count.N, chunks_count.N]' `
    --output table

# 2. Identificar la versión a la que vas a hacer rollback
$targetVersion = "run-manual-20260424T093015Z"

# 3. Verificar el stado de esa versión (chunks indexados)
aws rds-data execute-statement `
    --resource-arn (terraform -chdir=infra output -raw aurora_cluster_endpoint) `
    --secret-arn (terraform -chdir=infra output -raw aurora_secret_arn) `
    --database ragvectors `
    --sql "SELECT COUNT(*) FROM documents_embeddings WHERE version_id = '$targetVersion'" `
    --no-verify-ssl
```

> Nota: en Fase 1 la activación de la versión la hace la **Lambda Query** que aún no está implementada (Fase 1.1). Mientras tanto, el rollback se hace **filtrando manualmente** en cada consulta SQL: `WHERE version_id = '$targetVersion'`.

### 7.3 Cleanup de versiones obsoletas

```sql
-- Tras validar que una versión vieja ya no se necesita
BEGIN;
    DELETE FROM documents_embeddings
    WHERE version_id IN ('run-2026-01-...', 'run-2026-02-...');
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats;
COMMIT;
```

El item en DynamoDB queda como histórico — **no eliminar** por requerimiento de retención 5 años (compliance LFPDPPP).

---

## 8. Runbook — Subir nueva versión de imagen Docker

```powershell
# 1. Build + push (ver §3.4)
# Por ejemplo, nueva versión del chunking:
$account = aws sts get-caller-identity --query Account --output text --no-verify-ssl
$ecrUri = "$account.dkr.ecr.us-east-1.amazonaws.com/bsg-acmeco-rag-dev-chunking"

cd chunking
docker buildx build --platform linux/arm64 -t "$ecrUri:v1.1.0" --load .
docker push "$ecrUri:v1.1.0"
docker tag "$ecrUri:v1.1.0" "$ecrUri:latest"
docker push "$ecrUri:latest"

# 2. Forzar a Lambda a recoger la nueva imagen (no es automático en este setup)
aws lambda update-function-code `
    --function-name bsg-acmeco-rag-dev-chunking `
    --image-uri "$ecrUri:latest" `
    --no-verify-ssl

# 3. Probar con una invocación sintética
aws lambda invoke `
    --function-name bsg-acmeco-rag-dev-chunking `
    --payload '{"test": true}' `
    --no-verify-ssl test-out.json
Get-Content test-out.json
```

Para el indexer ECS:

```powershell
# 1. Build + push (igual que arriba)
# 2. Crear nueva revisión del task definition (Terraform lo hace en el próximo apply)
# 3. O forzar nuevo deployment del task definition existente:
aws ecs update-service `
    --cluster bsg-acmeco-rag-dev-cluster `
    --service indexer-service `
    --force-new-deployment `
    --no-verify-ssl

# Nota: el indexer no corre como service permanente, sino como task on-demand
# La nueva imagen se recoge en el siguiente RunTask automáticamente.
```

---

## 9. Troubleshooting común

| Síntoma | Diagnóstico | Solución |
|---|---|---|
| Step Functions FAILED en `StartGlueETL` | Glue Job con error en logs | Revisar CloudWatch `/aws-glue/jobs/...`. Si es `ConcurrentRunsExceeded`, esperar; otra ejecución ya está corriendo. |
| Lambda chunking `Timeout` | Función excede 900s | Revisar tamaño del Parquet; si > 50K chunks por archivo, particionar el upstream (más outputs de Glue, menos chunks por archivo) |
| Bedrock `ThrottlingException` recurrente | Cuota de cuenta insuficiente | Pedir aumento en Service Quotas → Bedrock → `OnDemandInvokeModelRequests per second` |
| ECS task `STOPPED` con exit code 1 | Algún Parquet falló durante indexer | Revisar CloudWatch `/ecs/...` por documento específico; el indexer continúa con los siguientes — no relanzar todo |
| ECS task `STOPPED` con exit code 2 | Aurora connection failed | Verificar Aurora ACU activo, security group, VPC endpoints |
| Aurora `connection limit exceeded` | Demasiadas conexiones concurrentes | Aurora Serverless v2 escala con ACU; subir `max_capacity` temporalmente |
| Dashboard widget "Estimated Cost" vacío | Métrica custom no se emite | Backlog: implementar `put_metric_data` en código (ver `09_versionamiento_observabilidad.md` backlog) |
| Terraform `Plugin did not respond` | SSL inspection en red corporativa | `$env:TF_DISABLE_PLUGIN_TLS = "1"` — ver `SECURITY.md` Riesgo #2 |
| `terraform.tfstate` desaparece | OneDrive borró el archivo | Mover el repo fuera de OneDrive — ver `SECURITY.md` Riesgo #3 |

---

## 10. Mantenimiento programado

### 10.1 Mensual

- Revisar dashboard CloudWatch — tendencias mensuales
- Validar costo vs presupuesto (`aws ce get-cost-and-usage`)
- Auditar `chunk_quality_audit` — buscar incrementos anómalos en `discard`
- Validar Bedrock Titan V2 sigue siendo el mejor modelo (sin reemplazos relevantes)

### 10.2 Trimestral

- Evaluar precisión top-5 humana sobre 100 consultas (en Fase 1.1 con la Lambda Query)
- Re-tunear umbrales del Quality Gate si la tasa de `warning` financial sube > 15%
- Revisar HNSW vs IVFFlat según tamaño del corpus
- Rotar secret Aurora (manual o vía Secrets Manager rotation)
- `VACUUM ANALYZE documents_embeddings`

### 10.3 Anual

- Re-evaluar la decisión Aurora pgvector vs alternativas
- Audit security completa (IAM, KMS, VPC, secrets)
- Renovar acceso a Bedrock model (puede pedirse re-aprobación)
- Backup test recovery — restaurar Aurora desde snapshot a una instancia paralela

---

## 11. Apagado y destrucción

```powershell
# 1. Validar que no hay datos críticos sin backup
# 2. Vaciar buckets S3 (Terraform no destruye buckets con objetos)
aws s3 rm "s3://$rawBucket"        --recursive --no-verify-ssl
aws s3 rm "s3://$cleanBucket"      --recursive --no-verify-ssl
aws s3 rm "s3://$embeddingsBucket" --recursive --no-verify-ssl
aws s3 rm "s3://$glueScriptsBucket" --recursive --no-verify-ssl

# 3. Destruir
cd infra
$env:TF_DISABLE_PLUGIN_TLS = "1"
terraform destroy
```

Aurora tarda 5-10 min en destruirse. Confirmar en consola que **todos** los recursos se eliminaron (a veces VPC endpoints quedan colgando).

---

## Referencias

- `04_arquitectura.md` — Arquitectura completa
- `09_versionamiento_observabilidad.md` — Métricas y alarmas en detalle
- `SECURITY.md` — Riesgos identificados y mitigaciones
- `infra/README.md` — Detalle Terraform
- `etl/README.md` — Glue ETL
- `chunking/README.md` — Lambda chunking
- `indexer/README.md` — ECS Fargate indexer
- `orchestration/README.md` — Step Functions
