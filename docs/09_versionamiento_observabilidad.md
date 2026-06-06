# Versionamiento y Observabilidad

**Documento:** 09 — Estrategia de versionamiento y observabilidad
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:** Equipo técnico Acme Co + Comité Ejecutivo de Innovación

---

## Resumen ejecutivo

El pipeline RAG documental del Marketplace B2B PyME está diseñado para ser **completamente versionado y observable** desde el día uno. Cada ejecución del pipeline produce una **versión inmutable del índice** registrada en DynamoDB, con hash determinístico del dataset de entrada, conteo de chunks por criticality, costo estimado y referencia al commit de código que la generó. Esta trazabilidad es no negociable para tres frentes simultáneos:

1. **Compliance regulatorio LFPDPPP / CNBV / CONDUSEF** — auditoría completa de qué chunk se descartó, por qué y cuándo (tabla `chunk_quality_audit`), más auditoría de qué versión del índice respondió a una consulta dada.
2. **Operación del hub** — el equipo de incubación de Acme Co puede ver en un dashboard único: ¿cuántas PyMEs respondió el sistema sin escalar?, ¿cuánto costó el último reindex?, ¿cuánto tardó?, ¿cuántos chunks financieros se marcaron para revisión humana?
3. **Iteración del activo de datos** — comparación A/B entre versiones del índice (`mv_version_stats`) habilita el camino hacia el LLM asistente de negocio del Año 2-3 de la tesis Economic Graph.

La observabilidad se materializa en **1 dashboard ejecutivo CloudWatch + 7 alarmas críticas** con notificación SNS al equipo de operaciones, todo definido en Terraform y reproducible. El versionamiento vive en **2 tablas DynamoDB on-demand** (`index_versions` + `chunk_quality_audit`) escritas desde el indexer ECS Fargate (Prompt 8) y la Lambda chunking (Prompt 7) respectivamente.

---

## 1. Versionamiento del índice

### 1.1 Tabla `index_versions` (DynamoDB)

Esquema definido en `infra/dynamodb.tf`:

| Atributo | Tipo | Notas |
|---|---|---|
| `version_id` (PK) | String | `run-<ExecutionName>` — propagado desde Step Functions |
| `created_at` | String (ISO timestamp) | También como **GSI** `by-created-at` para ordenamiento |
| `documents_count` | Number | Documentos únicos en esta versión |
| `chunks_count` | Number | Chunks totales upserted |
| `embeddings_count` | Number | Embeddings exitosos (= chunks_count si no hubo fallos) |
| `embedding_model` | String | `amazon.titan-embed-text-v2:0` |
| `cost_estimate_usd` | Number | Estimación Bedrock + Glue + Lambda + ECS de esta corrida |
| `dataset_hash` | String | SHA-256 de la lista ordenada de Parquet keys procesadas (drift detection) |
| `git_commit` | String | SHA del commit del repo que generó esta versión |
| `notes` | String | Resumen libre |

### 1.2 Tabla `chunk_quality_audit` (DynamoDB)

| Atributo | Tipo | Notas |
|---|---|---|
| `chunk_id` (PK) | String | sha1 idempotente del chunk |
| `version_id` (SK) | String | Permite drill-down por versión |
| `verdict` | String | `pass` / `warning` / `discard` |
| `reasons` | StringSet | Razones del Quality Gate (auditoría LFPDPPP) |
| `metrics_json` | String | `length_tokens`, `ttr`, `has_financial_marker`, etc. |
| `criticality` | String | `financial` / `legal` / `operational` / `informational` |
| `document_id` | String | |
| `timestamp` | String | ISO |
| **GSI `by-verdict`** | hash=`verdict`, range=`version_id` | Para reportes "¿qué chunks descartamos en la versión X?" |

### 1.3 Script Python de registro

Implementado como función `register_version()` en `indexer/loader.py` (ver Prompt 8). Se invoca al final del indexer tras `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats`:

```python
register_version({
    "documents_count":  len(documents),
    "chunks_count":     total_chunks_inserted,
    "embeddings_count": total_chunks_inserted,
    "cost_estimate_usd": compute_cost(total_chunks_inserted),
    "dataset_hash":      compute_dataset_hash(processed_keys),  # SHA-256
    "notes":             f"files_ok={len(processed)} files_failed={len(failed)}",
})
```

### 1.4 Comportamientos soportados (rúbrica)

| Escenario | Comportamiento |
|---|---|
| Se agregan nuevos documentos | Glue procesa todos los Parquets nuevos → Lambda chunkea → indexer UPSERT (nuevos chunk_ids = INSERT). Nueva versión con `documents_count` y `chunks_count` mayores. |
| Se re-procesan documentos existentes | Mismo `document_id` + contenido cambiado → nuevo `version_hash` desde el Glue ETL → diferentes `chunk_id`s para los chunks afectados. Los chunks viejos coexisten con los nuevos hasta cleanup explícito. Auditoría: comparar `mv_version_stats` entre versiones. |
| Se eliminan documentos | El Glue ETL no detecta deletes (lee S3, no compara). Cleanup explícito vía script ad-hoc: `DELETE FROM documents_embeddings WHERE document_id NOT IN (subquery actual)`. Backlog: agregar paso de reconciliación al pipeline. |

---

## 2. Observabilidad

### 2.1 Dashboard CloudWatch

Definido en `infra/cloudwatch.tf` con 5 filas de widgets:

| Fila | Widgets | Propósito |
|---|---|---|
| 1 — Pipeline Overview | Runs Succeeded/Failed · Execution Time P50/P95/Max · Estimated Cost USD | Vista ejecutiva: ¿el pipeline corre? ¿cuánto cuesta? |
| 2 — ETL (Glue) | Completed/Failed tasks · Duration Avg/Max | Salud del extractor de documentos |
| 3 — Chunking Lambda | Invocations/Errors/Throttles · Duration P50/P95/P99 · Chunks Generated/Discarded/Financial-marked | Calidad del chunking + Quality Gate visible |
| 4 — Bedrock | Invocations/Throttles/ClientErrors · Latency P50/P95 | Estado del proveedor crítico de embeddings |
| 5 — Indexer ECS + Aurora | CPU/Memory ECS · ACU + Connections Aurora | Backend de datos saludable |

**URL directa:** `terraform output cloudwatch_dashboard_url`

### 2.2 Alarmas (7 críticas)

| # | Alarma | Umbral | Implicación |
|---|---|---|---|
| 1 | `sfn-executions-failed` | > 0 en 1h | Pipeline falló — revisar logs Step Functions |
| 2 | `glue-failed-tasks` | > 5 en 5min | ETL con problemas — documentos corruptos o cuota |
| 3 | `lambda-chunking-errors` | > 10 en 5min | Chunking/embeddings con errores recurrentes |
| 4 | `bedrock-throttles` | > 50 en 5min | Bedrock saturado — solicitar quota o reducir paralelismo |
| 5 | `aurora-cpu` | > 80% por 10min | Aurora bajo presión — revisar queries o subir `max_capacity` |
| 6 | `aurora-capacity-near-max` | > 90% de `max_capacity` | Aurora a punto de hit cap — riesgo de saturación |
| 7 | `billing-80pct` | > USD 400/mes | 80% del techo de USD 500 — revisar consumo |

Todas las alarmas → SNS topic `pipeline_failure` → opcional email (`var.notification_email` en `infra/stepfunctions.tf`).

### 2.3 Métricas custom (`RAGPipeline` namespace)

Emitidas por el código del pipeline:

| Métrica | Emitida por | Para qué |
|---|---|---|
| `PipelineRunsSucceeded` | Step Functions `PublishCustomMetric` state | Conteo de runs OK |
| `PipelineRunsFailed` | Step Functions `PublishFailureMetric` | Conteo de runs KO |
| `ChunksGenerated` | Lambda chunking (backlog: agregar `put_metric_data` call) | Volumen de chunks producidos |
| `ChunksDiscarded` | Lambda chunking | Tasa de rechazo del Quality Gate |
| `ChunksFinancialMarked` | Lambda chunking | Subset crítico CNBV — monitoreo regulatorio |
| `EstimatedCostUSD` | Indexer (backlog: ya se calcula en `register_version`, falta emitir) | Costo por run |

> **Estado actual:** el Step Functions emite `PipelineRunsSucceeded`/`PipelineRunsFailed`. Las métricas de chunks y costo están en logs estructurados pero **no se emiten todavía como CloudWatch metric**. Esto es backlog inmediato — un `put_metric_data()` al final de la Lambda chunking y del indexer las hace visibles en el dashboard. El dashboard ya tiene los widgets preparados y aparecerán automáticamente cuando empiece a haber datos.

### 2.4 Logs estructurados

Cada componente emite logs JSON a su Log Group dedicado:

| Componente | Log Group | Retención |
|---|---|---|
| Glue ETL | `/aws-glue/jobs/${prefix}-etl` | 30 días |
| Lambda chunking | `/aws/lambda/${prefix}-chunking` | 30 días |
| ECS indexer | `/ecs/${prefix}-indexer` | 30 días |
| Step Functions | `/aws/vendedlogs/states/${prefix}-pipeline` | 30 días |
| Aurora PostgreSQL | logs export `postgresql` | 30 días |

Cada log line incluye `pipeline_run_id` (= `version_id`) que permite correlación end-to-end con CloudWatch Logs Insights:

```
fields @timestamp, message
| filter @log =~ /lambda.*chunking/ or @log =~ /ecs.*indexer/
| filter pipeline_run_id = "run-2026-05-24-001"
| sort @timestamp
```

---

## 3. Cómo estas métricas ayudan al equipo de incubación de Acme Co

El equipo del hub incubación + el Comité Ejecutivo necesitan **respuestas operacionales y estratégicas** del dashboard, no datos crudos. Mapping explícito:

### 3.1 Salud operacional diaria

| Pregunta del equipo | Métrica que la responde |
|---|---|
| "¿El sistema RAG respondió bien hoy?" | `Lambda Duration P95` < 800ms + `Errors` = 0 + `Throttles` = 0 |
| "¿Cuánto tardó la última reindexación?" | `States.ExecutionTime` Max en el widget 1 |
| "¿Tenemos chunks pendientes de revisión humana del subset financiero?" | `ChunksFinancialMarked` (warning queue) — KPI directo |
| "¿Aurora está aguantando el tráfico?" | `Aurora ACU` + `DatabaseConnections` |
| "¿Recibimos algún throttle de Bedrock?" | `Bedrock InvocationThrottles` — si > 0 sostenido, pedir cuota |

### 3.2 Decisiones estratégicas del Comité

| Decisión a tomar | Métrica clave |
|---|---|
| **¿Subir el techo de costo a USD 1,500 (Fase 2)?** | Tendencia mensual de `EstimatedCharges` + crecimiento del corpus + `ChunksGenerated` |
| **¿Activar Modelo B (build dedicado) del Business Case?** | `PipelineRunsSucceeded` / `PipelineRunsFailed` ratio + utilization Aurora + cost growth |
| **¿Migrar a IVFFlat o particionar Aurora?** | `Aurora capacity near max` + tamaño tabla (`mv_version_stats.total_chunks`) |
| **¿Promover al LLM asistente de Año 2-3?** | Precisión humana sobre top-5 (medida externa) + estabilidad de `PipelineRunsSucceeded` 90 días seguidos |

### 3.3 Auditoría regulatoria (LFPDPPP / CNBV)

| Requisito regulatorio | Cómo se satisface |
|---|---|
| "¿Por qué este chunk no apareció en la respuesta a un cliente?" | Query a `chunk_quality_audit` por `chunk_id` → verdict + reasons + metrics + timestamp |
| "¿Qué versión del índice respondió a la consulta del 15 de marzo?" | Logs CloudWatch + `version_id` en cada respuesta del endpoint + `index_versions` |
| "Demuestre que nunca descartó un chunk con marcador financiero" | `SELECT * FROM chunk_quality_audit WHERE verdict='discard' AND criticality='financial'` (debe ser vacío por la regla maestra) |
| "Trace de cualquier respuesta hasta el documento fuente" | `metadata_json.source_filename` + `metadata_json.section_hint` en cada chunk recuperado |

### 3.4 Comparación con KPIs del Business Case del Marketplace

Los KPIs del Business Case Año 1 (de `docs/01_caso_de_uso.md`) se monitorean parcialmente desde aquí:

| KPI del Caso de Uso | Métrica del Dashboard |
|---|---|
| Tiempo de indexación completa ≤ 60min | `States.ExecutionTime` Max |
| Latencia búsqueda P95 ≤ 800ms | (futuro) `RAGPipeline/QueryLatency` desde la Lambda Query |
| Costo mensual ≤ USD 500 | `EstimatedCharges` |
| Disponibilidad endpoint ≥ 99.0% | (futuro) API Gateway + Lambda Query metrics |

Los KPIs de calidad de respuesta (precisión top-5 ≥ 80%, etc.) requieren **evaluación humana externa** y se documentan en un proceso separado (ver Prompt 10).

---

## 4. Operación

### 4.1 Crear nueva versión del índice (full reindex)

```powershell
# 1. Asegurarse de que clean-docs/raw/ tiene los documentos a indexar
aws s3 ls s3://bsg-acmeco-rag-dev-raw-docs-<account>/raw/ --no-verify-ssl

# 2. Disparar la state machine
$smArn = terraform -chdir=infra output -raw state_machine_arn
$execArn = aws stepfunctions start-execution `
    --state-machine-arn $smArn `
    --name "v$(Get-Date -Format 'yyyyMMddTHHmm')" `
    --no-verify-ssl `
    --query executionArn --output text

# 3. Monitorear progreso
aws stepfunctions describe-execution --execution-arn $execArn --no-verify-ssl
```

### 4.2 Rollback a versión anterior

El rollback no implica re-popular Aurora — los datos de versiones anteriores siguen ahí. Es un cambio de **versión activa** en la lógica de consulta (la Lambda Query filtra por `version_id` específico):

```powershell
# 1. Listar versiones
aws dynamodb scan `
    --table-name bsg-acmeco-rag-dev-index-versions `
    --no-verify-ssl `
    --query 'Items[*].[version_id.S, created_at.S, chunks_count.N]' `
    --output table

# 2. Actualizar el env var ACTIVE_VERSION_ID en la Lambda Query
# (Fase 1.1 — la Lambda Query aún no está implementada; el rollback
#  manual hasta entonces es a través de filtros en consultas SQL)
```

### 4.3 Cleanup de versiones viejas

```sql
-- En Aurora — eliminar chunks de versión vieja
BEGIN;
    DELETE FROM documents_embeddings
    WHERE version_id IN ('run-2026-01-...', 'run-2026-02-...');
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats;
COMMIT;
```

```powershell
# En DynamoDB — el item de version_id queda como histórico
# (no se borra automáticamente — TTL deshabilitado por compliance 5 años)
```

---

## 5. Backlog operacional

| Item | Prioridad | Notas |
|---|---|---|
| Emitir métricas custom desde Lambda chunking (`ChunksGenerated`, etc.) | Alta | Trivial — `put_metric_data` al final del handler |
| Emitir `EstimatedCostUSD` desde indexer | Alta | Ya se calcula, falta emitir |
| Detección de deletes en el ETL (paso de reconciliación) | Media | Cleanup post-indexer compara `documents_embeddings` vs S3 actual |
| Lambda Query con filtro por `version_id` activo | Alta | Fase 1.1 — habilita rollback granular |
| KMS Customer Managed Keys | Media | Fase 2 (cuando crezca el corpus financiero) |
| Backend remoto Terraform (S3 + DDB lock) | Alta | Pre-requisito de cualquier deploy multi-developer |
| AWS Config + drift detection | Media | Para detectar cambios manuales fuera de Terraform |
| AWS Cost Anomaly Detection con email | Alta | Refuerza la alarma de billing |

---

**Documentos relacionados:**
- `01_caso_de_uso.md` — KPIs operacionales y de costo
- `04_arquitectura.md` — Arquitectura end-to-end (versionamiento + observabilidad en el diagrama)
- `08_indexacion_aurora_pgvector.md` — DDL y `mv_version_stats`
- `orchestration/state_machine.json.tpl` — ASL del pipeline
- `orchestration/README.md` — Operación de la state machine
- `infra/stepfunctions.tf` — IaC Step Functions + SNS
- `infra/cloudwatch.tf` — Dashboard + 7 alarmas
- `infra/dynamodb.tf` — Esquemas DDB
