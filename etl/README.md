# ETL — AWS Glue Job

Glue 4.0 Spark Job que ingesta documentos PDF / DOCX / HTML desde S3 `raw-docs`, los normaliza, y emite Parquet con metadata a S3 `clean-docs`. Es el primer componente compute del pipeline RAG documental del Marketplace B2B PyME de Acme Co.

## Contrato de entrada y salida

| Entrada | Formato | Ubicación |
|---|---|---|
| Documentos crudos | PDF / DOCX / HTML | `s3://<raw-bucket>/raw/**/*.{pdf,docx,html,htm}` |

| Salida | Formato | Ubicación |
|---|---|---|
| Parquet normalizado | Snappy, particionado por `doc_type` | `s3://<clean-bucket>/clean/doc_type=<x>/part-*.snappy.parquet` |

### Esquema de salida

| Columna | Tipo | Descripción |
|---|---|---|
| `document_id` | string | Hash estable derivado del key + content hash |
| `page_number` | int | Número de página lógica (1+) |
| `raw_text` | string | Texto limpio normalizado UTF-8 NFC |
| `source_filename` | string | Key original en S3 |
| `doc_type` | string | `contract` / `sla` / `policy_credit` / `dossier_icp` / `manual_tech` / `catalog` / `case_study` / `faq` / `process_op` / `unknown` |
| `vertical` | string | `moda_etica` / `skincare_d2c` / `joyeria_diseno` / `mascotas_premium` / `general` |
| `criticality` | string | `financial` / `legal` / `operational` / `informational` |
| `content_length` | int | Chars del texto limpio |
| `language` | string | Default `es-MX` |
| `version_hash` | string | SHA-256 del contenido crudo (idempotencia) |
| `extracted_at` | string | ISO timestamp UTC |

## Pipeline interno del Job

```
S3 raw-docs
    │
    ▼
list_documents()  ─── filtros por extensión soportada
    │
    ▼
RDD.parallelize(keys, numSlices=max_workers)
    │
    ▼
flatMap(process_document)  ─── por documento:
    │                          1. download S3
    │                          2. infer metadata (doc_type, vertical, criticality)
    │                          3. parse PDF/DOCX/HTML
    │                          4. dedup headers/footers
    │                          5. normalize text (NFC, whitespace, non-printable)
    │                          6. emit rows con schema explícito
    │                          on error → log + return [] (no detiene job)
    ▼
DataFrame.write
    .partitionBy("doc_type")
    .parquet("s3://clean/clean/")
```

## Heurísticas de inferencia

Las heurísticas viven en constantes al inicio de `glue_etl_job.py` para fácil ajuste:

- `DOC_TYPE_PATTERNS` — regex sobre el nombre del archivo. 9 categorías + `unknown`.
- `VERTICAL_PATTERNS` — regex sobre el nombre del archivo. 4 verticales + `general`.
- `CRITICALITY_BY_DOC_TYPE` — mapa fijo doc_type → criticality regulatoria.

Las inferencias se pueden refinar agregando lookahead sobre el contenido extraído (primeras 500 chars del PDF, por ejemplo) — está en backlog. La señal del filename suele ser suficiente para corpus internos curados.

## Limpieza implementada

1. **UTF-8 NFC** — `unicodedata.normalize("NFC", text)` resuelve acentos compuestos vs precompuestos.
2. **Caracteres no imprimibles** — regex `[^\x09\x0A\x20-\x7E -￿]` (preserva tabs, newlines, ASCII printable, y Unicode visible).
3. **Whitespace excesivo** — colapsa runs de espacios/tabs a 1 espacio; runs de newlines ≥ 3 a doble newline.
4. **Headers/footers repetidos** — detección por frecuencia: una línea que aparece en ≥ 60% de las páginas se considera boilerplate. Para documentos < 3 páginas, solo regex de patrones conocidos (numeración, "Confidencial", etc.).

## Manejo de errores

| Escenario | Comportamiento |
|---|---|
| Documento corrupto (PDF mal formado) | log ERROR + `return []` — job continúa con resto |
| Página individual con extract_text() fallido | log WARNING + página vacía |
| Extensión no soportada | log WARNING + skip |
| Bucket no existe / sin permisos | excepción de boto3 — job falla en el descubrimiento (intencional) |
| Encoding no UTF-8 en HTML | fallback a latin-1 con `errors="replace"` |

Métricas operativas se emiten a CloudWatch via `print` / `logger.info`:
- Total docs descubiertos
- Filas emitidas
- Distribución por `doc_type`
- Logs por documento con doc_id, pages_emitted, doc_type, vertical

## Despliegue

### Opción A — Via Terraform (recomendado)

El recurso `aws_glue_job` está declarado en `infra/glue.tf`. Subir el script a S3 y aplicar:

```powershell
# 1. Subir el script al bucket de Glue Scripts
$account = aws sts get-caller-identity --query Account --output text
aws s3 cp ../etl/glue_etl_job.py `
    "s3://bsg-acmeco-rag-dev-glue-scripts-$account/etl/glue_etl_job.py"

# 2. Aplicar Terraform
cd ../infra
$env:TF_DISABLE_PLUGIN_TLS = "1"  # ver SECURITY.md
terraform apply
```

### Opción B — Via consola AWS Glue (rápido para pruebas)

1. AWS Console → Glue → Jobs → Add Job
2. Type: **Spark**, Glue version: **Glue 4.0**, Language: **Python 3**
3. IAM Role: usar el output `iam_role_glue_arn` de Terraform
4. Script path: pegar `glue_etl_job.py`
5. Job parameters:
   - `--additional-python-modules`: `PyPDF2==3.0.1,python-docx==1.1.2,beautifulsoup4==4.12.3`
   - `--input_bucket`: nombre del raw-docs bucket
   - `--output_bucket`: nombre del clean-docs bucket
   - `--input_prefix`: `raw/`
   - `--output_prefix`: `clean/`
   - `--max_workers`: `50`
6. Worker type: **G.1X**, Number of workers: **4** (fase 1; escalable a 10 en fase 2)

## Invocación del Job

```powershell
# Vía CLI
aws glue start-job-run `
    --job-name bsg-acmeco-rag-dev-etl `
    --arguments '{
        "--input_bucket":  "bsg-acmeco-rag-dev-raw-docs-275541169383",
        "--output_bucket": "bsg-acmeco-rag-dev-clean-docs-275541169383",
        "--input_prefix":  "raw/",
        "--output_prefix": "clean/"
    }'

# Monitorear ejecución
aws glue get-job-runs --job-name bsg-acmeco-rag-dev-etl --max-results 1
```

Desde Step Functions (Prompt 9): estado `StartGlueJob` invoca este job de forma asíncrona y `WaitForGlueCompletion` polluea con backoff.

## Validación local (sin Spark)

Para probar las funciones de parsing y limpieza sin desplegar a Glue:

```python
# Crear venv e instalar requirements
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt boto3

# Test individual de funciones puras (sin Spark)
python -c "
from glue_etl_job import normalize_text, infer_doc_type, dedup_headers_footers
print(normalize_text('  hola   mundo\\n\\n\\n\\n  '))
print(infer_doc_type('contratos/carrier-billing-v2.pdf'))
"
```

## Limitaciones conocidas (backlog)

1. **DOCX paginación** — actualmente todo el DOCX se emite en `page_number=1`. Para paginación real se requiere render con LibreOffice o estimar por longitud — fuera de scope fase 1.
2. **PDFs con OCR pobre** — PyPDF2 falla en PDFs escaneados sin texto. Backlog: detectar `text == ""` en todas las páginas y enrutar a AWS Textract.
3. **Tablas en PDFs** — PyPDF2 extrae tablas como texto plano lineal. Migrar a PyMuPDF + `extract_tables()` mejora pero requiere binarios C.
4. **Detección de doc_type por contenido** — heurística solo sobre filename. Backlog: clasificador ligero (regex+keywords sobre primeras 1000 chars).
5. **Memoria del driver** — `rdd.flatMap(...).collect()` (via Spark DataFrame writer) puede consumir memoria del driver si emite >1M filas. Para fase 2 (5,000 docs) revisar particionado.

## Próximos pasos

Una vez validado este ETL contra un set de 50 documentos reales, el pipeline continúa con:

- **Prompt 7** — Lambda chunking + Bedrock Titan embeddings (lee de `clean/`, escribe a `embeddings/`)
- **Prompt 8** — DDL Aurora `pgvector` + loader ECS Fargate
- **Prompt 9** — Step Functions State Machine que orquesta Glue → Lambda → ECS
