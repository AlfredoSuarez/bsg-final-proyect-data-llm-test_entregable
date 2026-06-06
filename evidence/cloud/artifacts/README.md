# Artefactos visuales — run-demo-20260601-015935

Generados programáticamente desde AWS CLI outputs (no son screenshots de Console).

**Reemplazan los screenshots manuales** que normalmente se tomarían de la consola web — ofrecen los mismos datos con la ventaja de ser reproducibles y editables.

---

## Inventario

| Archivo | Descripción | Reemplaza screenshot de |
|---|---|---|
| [sfn_diagram.png](sfn_diagram.png) | Diagrama del flujo Step Functions con estados visitados marcados en verde | **AWS Console → Step Functions → execution Graph view** |
| [cw_metrics.png](cw_metrics.png) | 3 charts CloudWatch: latencia p95 Lambda, Invocations/Errors, Pipeline runs custom | **AWS Console → CloudWatch → Dashboard** `bsg-acmeco-rag-dev-pipeline` |
| [tables.md](tables.md) | Tablas markdown con DDB items (versions + audit) y SFN history detallado | **AWS Console → DynamoDB → Explore items** |
| [aurora_raw.txt](aurora_raw.txt) | Output crudo de Aurora: EXPLAIN ANALYZE, sample rows, definición de 11 índices | **AWS Console → RDS → Query Editor** |
| [ddb_index_versions.json](ddb_index_versions.json) | JSON export completo de la tabla de versiones | (raw para auditoría) |
| [ddb_qaudit.json](ddb_qaudit.json) | JSON export del Quality Gate audit filtrado por version_id | (raw para auditoría) |
| [sfn_definition.json](sfn_definition.json) | JSON definition de la state machine | (raw para auditoría) |
| [sfn_history.json](sfn_history.json) | 63 events del execution history | (raw para auditoría) |

Scripts reproducibles:
- `gen_diagram_matplotlib.py` — genera `sfn_diagram.png`
- `gen_charts.py` — genera `cw_metrics.png` consultando CloudWatch
- `gen_tables.py` — genera `tables.md`

---

## Hallazgos clave visibles en los artefactos

### 1. Step Functions: 7 estados visitados, 0 errores

```
START → InitializeRun → StartGlueETL → ListCleanParquetFiles
      → ChunkAllParquetsInParallel (Map)
            → InvokeChunkingLambda x4 (concurrencia controlada)
      → RunIndexerTask (ECS Fargate)
      → PublishCustomMetric (RAGPipeline/PipelineRunsSucceeded=1)
      → NotifySuccess (SNS) → END
```

Tiempos por state:
- **StartGlueETL**: 2 min 06 s (Glue cold start incluido)
- **InvokeChunkingLambda**: <1 s por invocación (con tiktoken cache warm)
- **RunIndexerTask**: 50 s (pull imagen ECR + run loader)
- **Total**: 2 min 30 s end-to-end

### 2. CloudWatch metrics — el dashboard funciona

- **`RAGPipeline/PipelineRunsSucceeded`**: 3 datapoints (3 runs OK)
- **`AWS/Lambda/Duration`**: p95 latency capturada en 5 buckets de 1 min
- **`AWS/Lambda/Errors`**: 0 errores en el 5to run (vs invocaciones >0 → success rate 100%)

### 3. DynamoDB audit con regla maestra trazable

8 items para `version_id = run-demo-20260601-015935`:
- 5 `pass` con `criticality=financial` y reason `financial_marker_detected` ← **regla maestra activa**
- 3 `discard` con reason `too_short` y `has_financial=False` ← descartados correctamente
- Cada item con SHA-256 chunk_id + metrics_json + timestamp ISO 8601

### 4. Aurora con HNSW funcional pero seq-scan en datasets pequeños

```sql
EXPLAIN ANALYZE WITH q AS (SELECT embedding FROM documents_embeddings LIMIT 1)
SELECT chunk_id FROM documents_embeddings
ORDER BY embedding <=> (SELECT embedding FROM q) LIMIT 5;
```

**Resultado:** `Seq Scan` (no HNSW), Sort Method `quicksort 25kB`, Execution Time 1.97 ms

**Explicación:** Postgres planner decide Seq Scan para 5 rows porque el cost del índice (8.36..49.48) supera el cost del seq+sort (0..11.12). **Esto es correcto** — HNSW se justifica cuando el corpus crece (>10K chunks).

11 índices creados en `documents_embeddings`:
- 2 unique (PK, chunk_id)
- 1 HNSW vector(1024) con `m=16, ef_construction=64`
- 5 btree (doc_type, vertical, criticality, version_id, document_id)
- 1 partial btree (criticality, version_id) WHERE criticality='financial' ← **regla maestra a nivel SQL**
- 1 GIN (metadata_json jsonb_path_ops)
- 1 GIN (to_tsvector 'spanish' chunk_text) ← **full-text search en español**

### 5. Distribución por doc_type (post-fix bug #11)

| doc_type | chunks indexados |
|---|---|
| contract | 3 |
| dossier_icp | 1 |
| faq | 1 |
| manual_tech | 0 (todos descartados por Quality Gate, FAQ HTML cortas) |

---

## Cómo regenerar estos artefactos

Requisitos: `python 3.13`, `matplotlib`, `aws cli v2`, bastion `i-07d1d81e371cc0363` accesible via SSM.

```bash
cd evidence/cloud/artifacts
export AWS_PROFILE=bsg-deployer

# Re-captura desde AWS
aws dynamodb scan --table-name bsg-acmeco-rag-dev-index-versions \
    --output json > ddb_index_versions.json

aws dynamodb scan --table-name bsg-acmeco-rag-dev-chunk-quality-audit \
    --filter-expression "version_id = :v" \
    --expression-attribute-values '{":v":{"S":"<RUN_ID>"}}' \
    --output json > ddb_qaudit.json

aws stepfunctions describe-state-machine \
    --state-machine-arn arn:aws:states:us-east-1:275541169383:stateMachine:bsg-acmeco-rag-dev-pipeline \
    --query "definition" --output text > sfn_definition.json

aws stepfunctions get-execution-history \
    --execution-arn arn:aws:states:us-east-1:275541169383:execution:bsg-acmeco-rag-dev-pipeline:<RUN_ID> \
    --output json > sfn_history.json

# Re-genera artefactos
python gen_diagram_matplotlib.py     # sfn_diagram.png
python gen_charts.py                 # cw_metrics.png
python gen_tables.py                 # tables.md
```

---

## Decisión metodológica

Los screenshots de console son **una foto en el tiempo** que se desactualiza inmediatamente. Estos artefactos son **idempotentes y reproducibles** — sirven mejor como evidencia académica y como artefacto vivo del proyecto.

Si necesitas screenshots para el entregable visual (slide deck, presentación), se pueden capturar manualmente desde la console mientras los recursos siguen arriba — ver `RUN_demo-20260601-014747.md` para URLs directas.
