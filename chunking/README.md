# Lambda Chunking + Embeddings — RAG Pipeline Acme Co

AWS Lambda containerizada que ejecuta el **Semantic Chunking Pattern** descrito en `docs/03_semantic_chunking_pattern.md`, invoca **AWS Bedrock Titan Embeddings V2** (1024 dim) y emite Parquet con embeddings a S3 `embeddings/`. Disparada por S3 ObjectCreated en `clean-docs/clean/*.parquet`.

## Contrato I/O

| Entrada | Origen |
|---|---|
| Parquet `clean/doc_type=<x>/part-*.snappy.parquet` | Output del Glue ETL Job (`etl/glue_etl_job.py`) |
| Columnas requeridas en input | `document_id`, `page_number`, `raw_text`, `doc_type`, `vertical`, `criticality`, `source_filename` |

| Salida | Destino |
|---|---|
| Parquet `embeddings/doc_type=<x>/part-*_embeddings.parquet` | S3 `embeddings-bucket` |
| Tabla DynamoDB `chunk_quality_audit` | Una fila por chunk con verdict del Quality Gate |

### Esquema del Parquet de embeddings (output)

| Columna | Tipo | Descripción |
|---|---|---|
| `document_id` | string | Heredado del input |
| `chunk_id` | string | sha1(doc:page:idx:content_hash) — idempotente |
| `chunk_index` | int | Posición del chunk dentro del documento |
| `page_number` | int | Página origen |
| `metadata_json` | string | JSON con section_hint, doc_type, vertical, criticality, verdict, reasons, token_count, source_filename, version_id |
| `embedding` | list&lt;float&gt;[1024] | Vector Titan V2 normalizado |
| `chunk_text` | string | Texto del chunk (para re-embedding si cambia el modelo) |
| `token_count` | int | Tokens cl100k_base |
| `doc_type` | string | |
| `vertical` | string | |
| `criticality` | string | financial / legal / operational / informational |
| `version_id` | string | ID de la corrida del pipeline (Step Functions) |
| `embedded_at` | string | ISO timestamp |

## Pipeline interno

```
S3 Event (ObjectCreated /clean/*.parquet)
    │
    ▼
download_file → /tmp/input.parquet
    │
    ▼
pyarrow.parquet.read_table → list[row]
    │
    ▼
process_row(row) por cada fila:
    │  1. RecursiveCharacterTextSplitter (LangChain)
    │     · length_function = tiktoken.cl100k_base
    │     · separators = ["\n\n", "\n", ". ", "; ", ", ", " ", ""]
    │     · chunk_size = 1500 tokens, overlap = 200
    │  2. compute_chunk_id (idempotente)
    │  3. quality_gate(text, criticality) → (verdict, reasons, metrics)
    │     · 4 reglas + regla maestra:
    │       chunks con marcador financiero NUNCA discard
    │
    ▼
embed_batch_parallel (ThreadPoolExecutor, max=10):
    │  Bedrock invoke_model por chunk
    │  · adaptive retry (5 intentos exponenciales)
    │  · timeout 30s read, 10s connect
    │  · pool de 50 conexiones HTTPS
    │
    ▼
audit_chunk → DynamoDB chunk_quality_audit (1 row por chunk, todos)
    │
    ▼
write_output_parquet → S3 embeddings/doc_type=.../X_embeddings.parquet
```

## Quality Gate

7 reglas implementadas (alineadas con `docs/03_semantic_chunking_pattern.md` §5):

| # | Validación | Acción |
|---|---|---|
| 1 | `length_tokens < 100` | `discard` (no financiero) / `warning` (financiero) |
| 2 | `TTR < 0.30` | igual |
| 3 | Primera línea matchea boilerplate | igual |
| 4 | Marcador financiero detectado (regex CNBV/CONDUSEF) | Activa **regla maestra** |
| 5 | (futuro) Idioma no es-MX | warning |
| 6 | (futuro) OCR confidence baja | warning |
| 7 | Metadata incompleta | discard |

**Regla maestra:** si `criticality=financial` (declarado o detectado), el chunk **nunca se descarta** — sólo se marca como `warning` y se enruta a SQS de revisión humana.

Patrón regex de marcadores financieros (en `lambda_function.py`):
```python
\b(APR|tasa anual|tasa de interés|CAT|carrier billing|comisión de apertura|
   scoring|cláusula|cargos por mora|penalización|24%|3%)\b
```

## Variables de entorno requeridas

| Variable | Default | Notas |
|---|---|---|
| `BEDROCK_MODEL_ID` | `amazon.titan-embed-text-v2:0` | |
| `BEDROCK_REGION` | `us-east-1` | |
| `EMBEDDING_DIMENSIONS` | `1024` | Debe coincidir con `vector(1024)` de Aurora |
| `EMBEDDINGS_BUCKET` | — | **requerido** |
| `EMBEDDINGS_PREFIX` | `embeddings/` | |
| `INPUT_PREFIX_STRIP` | `clean/` | Prefix a quitar del input key para derivar output |
| `DDB_AUDIT_TABLE` | — | **requerido** — tabla `chunk_quality_audit` |
| `CHUNK_SIZE_MAX` | `1500` | Tokens |
| `CHUNK_SIZE_MIN` | `500` | Tokens (referencia, no impuesto) |
| `CHUNK_OVERLAP` | `200` | Tokens |
| `MAX_PARALLEL_EMBEDDINGS` | `10` | Threads concurrentes |
| `VERSION_ID` | `default` | Step Functions inyecta por run |
| `LOG_LEVEL` | `INFO` | DEBUG para troubleshooting |

## Configuración Lambda recomendada

| Parámetro | Valor |
|---|---|
| Runtime | Container image (no zip) |
| Architecture | `arm64` (20% más barato que x86_64) |
| Memory | `2048 MB` |
| Timeout | `900 s` (15 min) |
| Ephemeral storage | `1024 MB` (`/tmp` para Parquet) |
| Reserved concurrency | `5` inicial, escalable a `20` |
| VPC config | Subnets privadas + `lambda-sg` (acceso a Bedrock vía VPC endpoint) |

## Build y push de la imagen

```powershell
# Variables
$account = aws sts get-caller-identity --query Account --output text --no-verify-ssl
$region = "us-east-1"
$repo = "bsg-acmeco-rag-dev-chunking"
$tag = "v1.0.0"
$ecrUri = "$account.dkr.ecr.$region.amazonaws.com/$repo"

# 1. Login a ECR
aws ecr get-login-password --region $region --no-verify-ssl |
  docker login --username AWS --password-stdin "$account.dkr.ecr.$region.amazonaws.com"

# 2. Build (desde chunking/)
cd chunking
docker build --platform linux/arm64 -t "${repo}:${tag}" .

# 3. Tag y push
docker tag "${repo}:${tag}" "${ecrUri}:${tag}"
docker tag "${repo}:${tag}" "${ecrUri}:latest"
docker push "${ecrUri}:${tag}"
docker push "${ecrUri}:latest"

# 4. Actualizar Lambda con la nueva imagen (si ya está desplegada)
aws lambda update-function-code `
    --function-name bsg-acmeco-rag-dev-chunking `
    --image-uri "${ecrUri}:${tag}" `
    --no-verify-ssl
```

## Despliegue (Terraform)

El recurso `aws_lambda_function` está en `infra/lambda.tf` y referencia la imagen por `image_uri`. La imagen debe existir en ECR antes del `terraform apply`. Si es la primera vez:

1. `terraform apply` crea el repositorio ECR (sin la Lambda — depende de la imagen).
2. Build + push de la imagen al repositorio creado.
3. `terraform apply` de nuevo — esta vez la Lambda se crea con la imagen referenciada.

Alternativa: aplicar primero sólo el repositorio ECR con `terraform apply -target=aws_ecr_repository.chunking`, hacer push, y luego `terraform apply` completo.

## Manejo de errores

| Escenario | Comportamiento |
|---|---|
| S3 event sin Records | `{"statusCode": 400}` |
| Archivo no Parquet | log INFO + skip |
| Download S3 falla | log ERROR + skip ese record, continúa siguientes |
| Read Parquet falla | log ERROR + skip |
| Chunking de una fila falla | log ERROR + skip fila, continúa otras |
| Embedding de un chunk falla | log ERROR + chunk no se emite a Parquet, queda en audit como `verdict` original sin embedding |
| Bedrock throttling | SDK reintenta 5 veces con backoff exponencial adaptativo |
| Write Parquet falla | log ERROR + return parcial |
| DDB audit falla | log ERROR + continúa (no detiene pipeline) |

## Costo aproximado por invocación (500 docs → ~4000 chunks)

| Componente | Cantidad | Costo |
|---|---|---|
| Lambda runtime (arm64, 2048MB) | 1 invoc × 60s | ~$0.001 |
| Bedrock Titan V2 | 4000 chunks × ~750 tok | $0.06 |
| DynamoDB writes (audit) | 4000 escrituras | ~$0.005 |
| S3 PUT (output Parquet) | 1–10 archivos | ~$0.0001 |
| **Total por reindexación completa** | | **~$0.07** |

## Limitaciones conocidas

1. **section_hint heurística** — primera línea del chunk, no `section_path` estructural. Para citación regulatoria estricta CNBV, una v2 leerá `section_path` del input Parquet (a emitir por Glue ETL).
2. **Tokenizer cl100k_base** — aproxima Titan V2 con error < 5%. La exactitud importa sólo para el corte de chunk_size, no para la calidad del embedding (Titan tokeniza por su cuenta).
3. **No batch en Bedrock** — `invoke_model` es per-text. Usamos paralelismo (ThreadPool=10) pero NO batch real. Bedrock V2 no expone batch sincrónico vigente en `bedrock-runtime`. Para batch async ver `bedrock` (no `bedrock-runtime`) — overkill a este volumen.
4. **Lambda memoria 2GB** — suficiente para Parquets de hasta ~50K chunks por invocación. Para volúmenes mayores migrar a ECS Fargate (mismo container image, diferente trigger).

## Validación local (sin desplegar a Lambda)

```powershell
# Crear venv
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Test de chunking solo (sin Bedrock real)
python -c "
import os
os.environ['EMBEDDINGS_BUCKET'] = 'test'
os.environ['DDB_AUDIT_TABLE'] = 'test'
from lambda_function import process_row, quality_gate

row = {
    'document_id': 'doc1', 'page_number': 1,
    'raw_text': 'Cláusula 4.2 Cargos por mora. El cliente acepta APR del 24% con comisión de apertura del 3%. ' * 50,
    'doc_type': 'contract', 'vertical': 'general',
    'criticality': 'financial', 'source_filename': 'test.pdf'
}
chunks = process_row(row)
print(f'Chunks: {len(chunks)}')
for c in chunks[:2]:
    print(f'  verdict={c[\"verdict\"]} tokens={c[\"token_count\"]} reasons={c[\"reasons\"]}')
"
```

## Próximos pasos

- **Prompt 8** — DDL Aurora `pgvector` + loader ECS Fargate que consume estos Parquets
- **Prompt 9** — Step Functions State Machine que orquesta Glue → Lambda → ECS y registra version_id en DynamoDB `index_versions`
