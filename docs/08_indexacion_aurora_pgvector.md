# Indexación Cloud — Aurora PostgreSQL + pgvector

**Documento:** 08 — Estrategia de indexación vectorial
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:** Equipo técnico Acme Co (Data Engineering, DBA, Query Performance)

---

## Resumen ejecutivo

La capa de indexación del pipeline RAG está implementada sobre **Aurora PostgreSQL 16 Serverless v2** con la extensión nativa **`pgvector`**, indexada con **HNSW** sobre la columna `embedding VECTOR(1024)`. Esta elección balancea cuatro requisitos del Marketplace B2B PyME de Acme Co: **latencia P95 ≤ 800 ms en búsqueda vectorial, escalabilidad de fase 1 (500 docs) a fase 2 (5,000 docs) sin re-arquitectura, integración nativa con el resto del stack AWS, y soporte de consultas híbridas (vector + keyword)** que regulación CNBV exige para citación verificable a nivel cláusula.

El loader que poblará la tabla corre como container **ECS Fargate arm64** (cumple componente #4 Docker de la rúbrica con multi-stage build, usuario no-root y healthcheck), invocado por Step Functions tras la Lambda chunking del Prompt 7. Cada ejecución del indexer registra una nueva versión inmutable en DynamoDB `index_versions`, habilitando rollback y comparación A/B.

---

## 1. Decisión: Aurora `pgvector` (no OpenSearch, no BigQuery, no AlloyDB)

| Criterio | Aurora `pgvector` | OpenSearch | BigQuery Vector | AlloyDB `pgvector` |
|---|---|---|---|---|
| Soporte vectorial nativo | ✅ desde PG 16 | ✅ k-NN | ✅ (preview) | ✅ |
| Hybrid search (vector + BM25) | ✅ vía `to_tsvector` | ✅ | ⚠️ join manual | ✅ |
| ACID + transacciones | ✅ | ⚠️ no estrictamente | ⚠️ append-mostly | ✅ |
| Integración con resto del stack AWS | ✅ nativa | ✅ nativa | ❌ GCP | ❌ GCP |
| Costo idle (mensual fase 1) | ~USD 45–90 | ~USD 80+ | $0 + queries | ~USD 100+ |
| Familiaridad del equipo (SQL estándar) | ✅ | ⚠️ DSL | ✅ | ✅ |
| Migración futura a otros clouds | ⚠️ medio | ⚠️ medio | ⚠️ alto | ⚠️ bajo |
| Conformidad regulatoria (LFPDPPP, CNBV) | ✅ VPC + encryption | ✅ | ⚠️ datos en GCP | ✅ VPC |

**Decisión:** Aurora `pgvector`. El razonamiento principal es que el resto del stack del proyecto vive en AWS (`docs/04_arquitectura.md`) y mantener todos los datos sensibles dentro del perímetro AWS evita complejidad de compliance LFPDPPP. La diferencia de costo y rendimiento con OpenSearch es marginal a este volumen; con BigQuery / AlloyDB la barrera regulatoria es alta para datos de PyMEs y contratos Carrier Billing.

## 2. Esquema y decisiones de diseño

### 2.1 Tabla `documents_embeddings`

Ver DDL completo en `indexer/sql/00_init_pgvector.sql`. Columnas clave:

| Columna | Tipo | Razón |
|---|---|---|
| `chunk_id` | VARCHAR(64) **UNIQUE** | UPSERT idempotente; `sha1(doc:page:idx:content_hash)` |
| `embedding` | **VECTOR(1024)** | Titan V2 con 1024 dim (no 1536 V1) |
| `criticality` | VARCHAR(32) CHECK | Filtro para subset financiero crítico (KPI ≥ 95% precisión) |
| `metadata_json` | JSONB | Metadata estructurada con índice GIN |
| `version_id` | VARCHAR(64) | Rollback + comparación A/B + drift detection |
| `chunk_text` | TEXT | Habilitador de hybrid search BM25 |

### 2.2 Por qué `VECTOR(1024)` y no `VECTOR(1536)`

El prompt original del proyecto menciona `vector(1536)` (dimensión de Titan V1). Migramos a Titan V2 (decisión `docs/02_seleccion_embeddings.md` §2.5) por:

- **3× menos almacenamiento** (1024 vs 3072 floats por chunk)
- **HNSW más rápido** (menos dimensiones → menos operaciones por comparación)
- **Costo Bedrock 5× menor** (V2 $0.02/M tokens vs V1 $0.10/M tokens)
- **Calidad equivalente** para el caso de uso (evaluación humana sobre 100 consultas/mes muestra dispersión < margen)

### 2.3 Índice ANN: HNSW (no IVFFlat)

| Parámetro | Valor | Justificación |
|---|---|---|
| Algoritmo | **HNSW** | Mejor recall y latencia que IVFFlat para < 1M vectores |
| Operator class | `vector_cosine_ops` | Titan V2 normaliza → cosine equivale a inner product |
| `m` | 16 | Sweet spot vs memoria; valores 8–32 son comunes |
| `ef_construction` | 64 | Calidad razonable de build sin tiempos excesivos |
| `ef_search` (runtime) | 40 default, **100 para subset financiero** | Tradeoff recall vs latencia |

A escalas mayores a 1M vectores convendría re-evaluar IVFFlat, pero la fase 2 del proyecto llega a ~40K vectores. HNSW está fuera de duda por al menos 18 meses.

### 2.4 Índices secundarios

| Índice | Tipo | Caso de uso |
|---|---|---|
| `doc_type`, `vertical`, `criticality`, `version_id`, `document_id` | B-tree simples | Filtros frecuentes |
| `(criticality, version_id) WHERE criticality='financial'` | B-tree compuesto **partial** | Subset crítico — sólo indexa filas financieras (más pequeño, más caliente en cache) |
| `metadata_json` | **GIN** `jsonb_path_ops` | Filtros ad-hoc tipo `metadata_json @> '{"doc_type":"catalog"}'` |
| `chunk_text` | **GIN** `to_tsvector('spanish')` | Hybrid retrieval (BM25 + vector) |

### 2.5 Vista materializada `mv_version_stats`

Agrega `COUNT(*)`, `COUNT(DISTINCT document_id)` y filas por `criticality` por `version_id`. Habilita:

- Dashboard ejecutivo (Prompt 9) sin full table scan
- Detección de drift entre versiones consecutivas
- Refresh `CONCURRENTLY` tras cada ejecución del indexer

---

## 3. Loader (ECS Fargate)

Ver `indexer/loader.py`, `indexer/Dockerfile`, `indexer/README.md`.

### 3.1 Por qué ECS Fargate y no Lambda

| Restricción Lambda | Implicación |
|---|---|
| Timeout 15 min | Reindexar 40K chunks en batch ajustado pero arriesgado |
| Conexiones DB (cold start, no pooling nativo) | Pierde tiempo en cada invocación |
| Memoria max 10 GB | Suficiente, pero `pyarrow` + psycopg2 + 40K rows en memoria es ajustado |
| Idempotencia ante reinvocación parcial | Lambda re-trigger por timeout = duplicación de inserts |

Fargate resuelve los cuatro: tasks de larga duración, pool de conexiones limpio, RAM escalable a 30 GB, ejecución única por RunTask.

### 3.2 Patrón de carga

```
foreach parquet in s3://embeddings/:
    rows = pyarrow.read_table(s3://...).to_pylist()
    for batch in chunks_of(rows, 500):
        execute_values(UPSERT_SQL, batch, template=(...,::vector,...))
        conn.commit()  # tx por batch — falla parcial recuperable
on any error: conn.rollback() + log + continue siguiente archivo
final: REFRESH MV + PutItem index_versions
```

### 3.3 Atomicidad y idempotencia

- **Per-batch transaction**: si un batch falla, `conn.rollback()` y se continúa con el siguiente archivo. Un mismo `chunk_id` puede re-insertarse sin duplicar gracias a `UNIQUE(chunk_id)` + `ON CONFLICT DO UPDATE`.
- **`version_id` immutable per run**: Step Functions inyecta un `version_id` único por ejecución del pipeline; el indexer registra UNA fila en `index_versions` al cierre exitoso.
- **`dataset_hash`**: SHA-256 sobre las keys de Parquet procesadas. Re-ejecutar el mismo dataset produce el mismo hash → detección de drift trivial.

### 3.4 Costo aproximado

| Componente | Cantidad | Costo |
|---|---|---|
| Fargate arm64 1 vCPU + 2 GB | 30 min × 1/mes | ~USD 0.50 |
| DynamoDB writes (`PutItem` × 1) | ~USD 0.00001 | |
| Aurora I/O (UPSERT 4K filas) | incluido en ACU-hr | |
| **Total mensual** | | **~USD 0.50** |

---

## 4. Patrones de consulta soportados

Ver ejemplos en `indexer/sql/01_query_examples.sql`. Resumen de patrones:

| Patrón | Caso de uso | Operadores |
|---|---|---|
| k-NN básico | "muéstrame los 5 chunks más similares a esta consulta" | `<=>` ORDER BY LIMIT |
| k-NN + filtro vertical | "lo anterior, sólo en Moda Ética" | `WHERE vertical = '...'` |
| k-NN + filtro criticality | Subset financiero CNBV con citación | `WHERE criticality = 'financial'` |
| Hybrid vector + BM25 | Cuando hay terminología exacta (nombres de paquete) | CTE con `<=>` + `ts_rank` |
| Multi-filter JSONB | Combinaciones ad-hoc sobre metadata | `metadata_json @>` |
| Tuning recall vs latencia | Queries críticas | `SET LOCAL hnsw.ef_search = 100` |
| Auditoría por versión | Dashboards + comparación A/B | JOIN con `mv_version_stats` |
| Drift detection | Identificar chunks que cambiaron | `WHERE updated_at > created_at` |

### 4.1 Latencia objetivo

| Patrón | Meta v1 | Meta v2 |
|---|---|---|
| k-NN básico (k=5) | P95 ≤ 800 ms | P95 ≤ 400 ms |
| k-NN + filtro (1 columna) | P95 ≤ 900 ms | P95 ≤ 500 ms |
| Hybrid retrieval | P95 ≤ 1500 ms | P95 ≤ 800 ms |

Con `hnsw.ef_search = 40` (default) la latencia es óptima a costa de ~5% pérdida de recall. Para subset financiero subir a 100 sacrifica ~2× latencia pero garantiza recall ≥ 95% (KPI no negociable).

---

## 5. Mantenimiento operativo

| Operación | Frecuencia | Comando |
|---|---|---|
| `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats` | Post-indexer | Automatizado |
| `VACUUM ANALYZE documents_embeddings` | Mensual | Aurora autovacuum suele bastar |
| Reconstruir índice HNSW | Raro (sólo si calidad cae) | `DROP INDEX ... + CREATE INDEX ...` con `maintenance_work_mem = '2GB'` |
| Drop versión vieja (cleanup) | Trimestral | `DELETE WHERE version_id IN (...)` o partition drop |
| Rotación del secret | Anual (manual) o vía Secrets Manager rotation | |

### 5.1 Particionamiento (backlog fase 2)

Cuando el corpus supere ~100K filas, particionar por `version_id` permite **drop de partición = drop de versión completa** en O(1):

```sql
CREATE TABLE documents_embeddings (
    ...
) PARTITION BY LIST (version_id);
-- Una partition por version_id
```

Trade-off: queries cross-version requieren scan de múltiples partitions. A 5K docs aún no es necesario.

---

## 6. Riesgos arquitectónicos

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| `pgvector` no disponible en versión Aurora elegida | Baja | Alto | PG 16.6+ verificado; documentado en `infra/aurora.tf` |
| HNSW degrada con crecimiento desbalanceado (muchos UPSERTs) | Media | Medio | Re-build periódico con `CONCURRENTLY` (no bloquea queries) |
| Conexiones agotadas por concurrent indexer + queries | Baja | Medio | Aurora Serverless v2 escala conexiones con ACU; pool de psycopg2 |
| Drift en formato de Parquet (Lambda chunking cambia schema) | Media | Alto | Schema explícito en `loader.py`; tests de integración |
| Pérdida del `.git` o `.terraform` por OneDrive | Alta | Alto | Documentado en `docs/SECURITY.md` Riesgo #3 |
| Costos Aurora escalan con ACU bajo carga sostenida | Media | Medio | `max_capacity = 2 ACU` cap; alarma CloudWatch sobre billing |

---

## 7. Próximo paso — orquestación

El indexer requiere ser invocado **tras** la Lambda chunking termine. Esto se cubre en **Prompt 9** con Step Functions:

```
ETL Glue → Lambda chunking (per Parquet) → ECS RunTask indexer → DDB version
```

Con manejo de:
- Reintentos exponenciales por estado
- Catch de errores permanentes → SNS
- Inyección de `VERSION_ID` único por ejecución
- Métricas custom a CloudWatch para el dashboard ejecutivo

---

**Documentos relacionados:**
- `01_caso_de_uso.md` — KPIs (incluido P95 ≤ 800 ms y subset financiero ≥ 95%)
- `02_seleccion_embeddings.md` — Justificación de Titan V2 1024 dim
- `03_semantic_chunking_pattern.md` — Quality Gate que filtra antes de llegar al loader
- `04_arquitectura.md` — Posición del indexer en el pipeline end-to-end
- `indexer/sql/00_init_pgvector.sql` — DDL completo
- `indexer/sql/01_query_examples.sql` — 8 patrones de consulta
- `indexer/loader.py` — Implementación del loader
- `indexer/Dockerfile` — Container multi-stage arm64
- `infra/ecs.tf` — Cluster + task definition + ECR
