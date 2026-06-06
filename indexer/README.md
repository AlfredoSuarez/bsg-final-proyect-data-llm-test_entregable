# Indexer — Aurora pgvector loader (ECS Fargate)

Container Python que **lee Parquet con embeddings desde S3** `embeddings/`, **UPSERTea en Aurora PostgreSQL** con `pgvector`, y **registra una nueva versión del índice** en DynamoDB. Corre como **task ECS Fargate** disparada por Step Functions tras la Lambda chunking del Prompt 7.

Cumple el componente **#4 Docker** de la rúbrica (multi-stage, non-root, slim, healthcheck) y el componente **#9 Indexación cloud** (Aurora `pgvector` con índice HNSW, hybrid retrieval, vista materializada).

## Archivos

```
indexer/
├── Dockerfile              # multi-stage, arm64, non-root user (uid 1001)
├── .dockerignore
├── requirements.txt        # boto3, psycopg2-binary, pyarrow
├── loader.py               # script principal (~300 líneas)
├── sql/
│   ├── 00_init_pgvector.sql       # DDL: tabla + índices + mv_version_stats
│   └── 01_query_examples.sql      # 8 ejemplos: k-NN, hybrid, financial, tuning
└── README.md
```

## Esquema de la tabla `documents_embeddings`

| Columna | Tipo | Notas |
|---|---|---|
| `id` | BIGSERIAL PK | autogenerado |
| `chunk_id` | VARCHAR(64) UNIQUE | sha1 idempotente del chunker |
| `document_id` | VARCHAR(64) | |
| `page_number` | INTEGER | |
| `chunk_index` | INTEGER | |
| `chunk_text` | TEXT | para hybrid retrieval + reembed |
| `metadata_json` | JSONB | con índice GIN |
| `embedding` | **VECTOR(1024)** | Titan V2 normalizado |
| `token_count` | INTEGER | |
| `doc_type` | VARCHAR(32) | CHECK enum |
| `vertical` | VARCHAR(32) | |
| `criticality` | VARCHAR(32) | CHECK enum (financial/legal/op/info) |
| `source_filename` | TEXT | |
| `version_id` | VARCHAR(64) | |
| `created_at` | TIMESTAMPTZ | |
| `updated_at` | TIMESTAMPTZ | trigger automático |

### Índices

| Nombre | Tipo | Para |
|---|---|---|
| `idx_documents_embeddings_hnsw` | **HNSW** (m=16, ef_construction=64) cosine_ops | ANN k-NN |
| `idx_documents_embeddings_doc_type` | B-tree | filtros |
| `idx_documents_embeddings_vertical` | B-tree | filtros |
| `idx_documents_embeddings_criticality` | B-tree | filtros |
| `idx_documents_embeddings_version_id` | B-tree | rollback / drift |
| `idx_documents_embeddings_document_id` | B-tree | document drill-down |
| `idx_documents_embeddings_crit_version` | B-tree partial WHERE financial | subset crítico |
| `idx_documents_embeddings_metadata_gin` | GIN jsonb_path_ops | filtros ad-hoc |
| `idx_documents_embeddings_chunk_text_fts` | GIN to_tsvector('spanish') | hybrid retrieval |

> **¿Por qué `vector(1024)` y no `vector(1536)`?** El prompt original del proyecto menciona 1536 (dim Titan V1). Adoptamos Titan V2 que usa 1024 dim por defecto (decisión documentada en `docs/02_seleccion_embeddings.md` §2.5). Beneficios: 3× menos almacenamiento que 1536 + búsqueda ANN más rápida + costo más bajo.

## Inicialización del schema

Tras `terraform apply` del cluster Aurora, ejecutar UNA vez:

```powershell
# Obtener credenciales del secret
$secretArn = terraform -chdir=infra output -raw aurora_secret_arn
$secretJson = aws secretsmanager get-secret-value `
    --secret-id $secretArn --query SecretString --output text --no-verify-ssl
$secret = $secretJson | ConvertFrom-Json

# Aplicar DDL (requiere psql instalado: choco install postgresql)
$env:PGPASSWORD = $secret.password
psql -h $secret.host -U $secret.username -d $secret.dbname `
     -f sql/00_init_pgvector.sql

# Verificar
psql -h $secret.host -U $secret.username -d $secret.dbname -c "
    SELECT extname, extversion FROM pg_extension WHERE extname='vector';
    SELECT count(*) FROM documents_embeddings;
"
```

Alternativa sin psql instalado: usar **AWS RDS Query Editor** desde la consola (requiere `enable_http_endpoint` que no activamos por costo).

## Build + push de la imagen

```powershell
# Variables
$account = aws sts get-caller-identity --query Account --output text --no-verify-ssl
$region = "us-east-1"
$repo = "bsg-acmeco-rag-dev-indexer"
$tag = "v1.0.0"
$ecrUri = "$account.dkr.ecr.$region.amazonaws.com/$repo"

# 1. Login ECR
aws ecr get-login-password --region $region --no-verify-ssl |
    docker login --username AWS --password-stdin "$account.dkr.ecr.$region.amazonaws.com"

# 2. Build (arm64)
cd indexer
docker build --platform linux/arm64 -t "${repo}:${tag}" .

# 3. Tag + push
docker tag "${repo}:${tag}" "${ecrUri}:${tag}"
docker tag "${repo}:${tag}" "${ecrUri}:latest"
docker push "${ecrUri}:${tag}"
docker push "${ecrUri}:latest"
```

## Ejecución manual (debug)

```powershell
# Necesitas estar en VPC para alcanzar Aurora (Bastion o port-forward).
# Alternativa: lanzar el container desde una EC2 dentro del VPC.

docker run --rm `
    -e AWS_REGION=us-east-1 `
    -e EMBEDDINGS_BUCKET=bsg-acmeco-rag-dev-embeddings-275541169383 `
    -e AURORA_SECRET_ARN="arn:aws:secretsmanager:..." `
    -e DDB_VERSIONS_TABLE=bsg-acmeco-rag-dev-index-versions `
    -e VERSION_ID=manual-test-001 `
    -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
    -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
    bsg-acmeco-rag-dev-indexer:latest
```

## Ejecución vía ECS RunTask

```powershell
$accountId = aws sts get-caller-identity --query Account --output text --no-verify-ssl
$cluster = "bsg-acmeco-rag-dev-cluster"
$taskDef = "bsg-acmeco-rag-dev-indexer"
$subnet1 = terraform -chdir=infra output -json private_subnet_ids | ConvertFrom-Json | Select-Object -First 1
$ecsSg = terraform -chdir=infra output -raw security_group_ecs_id

aws ecs run-task `
    --cluster $cluster `
    --task-definition $taskDef `
    --launch-type FARGATE `
    --network-configuration "awsvpcConfiguration={subnets=[$subnet1],securityGroups=[$ecsSg],assignPublicIp=DISABLED}" `
    --overrides '{
        "containerOverrides": [{
            "name": "indexer",
            "environment": [
                {"name": "VERSION_ID", "value": "manual-2026-05-24"}
            ]
        }]
    }' `
    --no-verify-ssl
```

En el flujo normal, **Step Functions** invoca el `RunTask` automáticamente al completar la Lambda chunking (Prompt 9).

## Variables de entorno

| Variable | Default | Requerido |
|---|---|---|
| `AWS_REGION` | `us-east-1` | |
| `EMBEDDINGS_BUCKET` | — | ✅ |
| `EMBEDDINGS_PREFIX` | `embeddings/` | |
| `AURORA_SECRET_ARN` | — | ✅ |
| `DDB_VERSIONS_TABLE` | — | ✅ |
| `EMBEDDING_MODEL` | `amazon.titan-embed-text-v2:0` | |
| `BATCH_SIZE` | `500` | |
| `VERSION_ID` | autogen `run-<UTC>` | inyectar desde Step Functions |
| `GIT_COMMIT` | `unknown` | inyectar desde CI/CD |
| `LOG_LEVEL` | `INFO` | |

## Pipeline interno

```
list_parquet_files(s3 prefix)
    ↓
for each .parquet:
    ├─ download_file → /tmp
    ├─ pyarrow.read_table → rows[]
    ├─ for batch of BATCH_SIZE:
    │     ├─ build values[] with format_vector_literal(emb)
    │     ├─ INSERT ... ON CONFLICT (chunk_id) DO UPDATE
    │     └─ conn.commit()
    └─ on error: conn.rollback() + log + continue siguiente archivo
    ↓
REFRESH MATERIALIZED VIEW mv_version_stats
    ↓
PutItem index_versions → DynamoDB
    ↓
exit code 0 (todos ok) | 1 (algunos failed) | 2 (Aurora connection failed)
```

## Manejo de errores

| Escenario | Comportamiento |
|---|---|
| Aurora no responde | exit code 2, sin parcial |
| Un Parquet corrupto | rollback de su tx + log + skip + continúa siguientes |
| Un row con `embedding` nulo | warning + skip ese row, continúa el batch |
| `mv_version_stats` refresh falla | warning + continúa hacia register_version |
| `register_version` falla | excepción no capturada → exit no-cero, datos en Aurora OK |

## Mejores prácticas pgvector aplicadas

1. **HNSW > IVFFlat** a este volumen — mejor recall, sin tuning de `nlist`/`nprobe`.
2. **`vector_cosine_ops`** porque Titan V2 normaliza → equivale a inner product.
3. **`m=16, ef_construction=64`** — sweet spot para 1k-100k vectores.
4. **`SET LOCAL hnsw.ef_search = 100`** por sesión para queries críticas (subset financiero).
5. **GIN sobre `metadata_json`** con `jsonb_path_ops` (más rápido que default para `@>`).
6. **B-tree compuesto parcial** `(criticality, version_id) WHERE criticality='financial'` — el subset financiero queda más caliente que el resto.
7. **UPSERT en batch via `execute_values`** — 10x más rápido que executemany.
8. **`template` con casts explícitos `::vector` y `::jsonb`** — psycopg2 no infiere bien estos tipos.
9. **`sslmode=require`** — Aurora requiere SSL; siempre.
10. **Vista materializada** `mv_version_stats` — dashboards no hacen full scan.

## Optimizaciones backlog

| Item | Cuándo | Notas |
|---|---|---|
| Particionar `documents_embeddings` por `version_id` | > 100K filas | drop de versión vieja = drop de partition |
| `IVFFlat` en lugar de HNSW | > 1M filas | memoria, no latencia |
| KMS Customer Managed Keys | Fase 2 | regulación CNBV si crece la cartera |
| Bastion EC2 o SSM Session Manager | hoy | acceso a Aurora desde laptop sin VPN |
| Aurora I/O-Optimized | si la factura crece | $0/IO pero +30% on storage |

## Próximo paso

**Prompt 9** — Step Functions State Machine que orquesta:
```
Glue ETL (Prompt 6) → Lambda chunking (Prompt 7) → ECS RunTask indexer (este)
                                                  → DDB PutItem index_versions
```
y emite métricas custom a CloudWatch para el dashboard del Prompt 9.
