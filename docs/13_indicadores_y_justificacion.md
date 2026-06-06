# 13 — Indicadores del Pipeline y su Justificación

> **Audiencia dual:**
> - Académico (BSG): demuestra rigor metodológico — qué se mide, por qué, cómo.
> - Estratégico (Acme Co / Grupo Acme): liga indicadores técnicos a las metas del Año 1 del Marketplace B2B PyME (1,000 PyMEs, GMV $21.9M MXN, 4 verticales).

Este documento establece el **registro oficial de indicadores** del pipeline RAG: cada métrica trae fórmula, umbral, método de captura ejecutable y justificación de por qué se eligió esa y no otra.

---

## Marco de medición — 4 capas

El pipeline se mide en 4 capas independientes pero correlacionadas:

| Capa | Pregunta que responde | Audiencia primaria | Scope este entregable |
|---|---|---|---|
| **1. Técnica** | ¿El pipeline corre, qué tan rápido, qué tan limpio? | Equipo de datos, ingeniería | ✅ Instrumentado |
| **2. Negocio** | ¿Sirve para el Marketplace B2B PyME? ¿Justifica su costo? | Acme Co (Patricia López), Banco Acme | ✅ Instrumentado parcial |
| **3. Compliance** | ¿Cumple LFPDPPP / CNBV / CONDUSEF / INAI? | Legal, riesgo, auditoría | ✅ Instrumentado |
| **4. Agente LLM (futuro)** | ¿El agente que CONSUME este índice responde bien? | Producto, UX, riesgo regulatorio | 🔮 Roadmap fase 2 — referencia [docs/14_kpis_agente_llm_referencia.md](14_kpis_agente_llm_referencia.md) |

Cada indicador se reporta en **CloudWatch dashboard** + log JSON estructurado + (cuando aplica) tabla DynamoDB para auditoría.

> **Sobre la Capa 4:** este entregable es el **primer eslabón data engineering** del agente RAG. Cuando se sume la capa de inferencia/agente (Año 2 del Business Case Acme Co), los KPIs de la Capa 4 se vuelven instrumentables. Documentarlos aquí establece el contrato de medición end-to-end del producto final.

---

## Capa 1 — Indicadores técnicos del pipeline

### 1.1 Throughput de ingesta

| Atributo | Valor |
|---|---|
| **Fórmula** | `docs_procesados / duración_job_min` |
| **Umbral objetivo** | ≥ 30 docs/min (sostenido) |
| **Umbral crítico** | < 10 docs/min — dispara alarma |
| **Captura** | CloudWatch metric `AWS/Glue/glue.driver.aggregate.recordsRead` |
| **Comando CLI** | Ver §Captura ejecutable abajo |
| **Justificación** | El onboarding inicial del Marketplace contempla ~500 docs (contratos, catálogos, dossiers ICP, FAQs). A 30 docs/min cierra en <20 min; permite reindexaciones nocturnas sin saturar Bedrock. Por debajo de 10, el SLA de "índice fresco diario" no se cumple. |

### 1.2 Latencia p95 del chunking

| Atributo | Valor |
|---|---|
| **Fórmula** | `percentile_95(Lambda.Duration)` |
| **Umbral objetivo** | < 8 s |
| **Umbral crítico** | > 15 s (alarma `lambda-chunking-duration` ya configurada) |
| **Captura** | CloudWatch metric `AWS/Lambda/Duration` con `Statistic=p95`, dim `FunctionName=bsg-acmeco-rag-dev-chunking` |
| **Justificación** | Bedrock Titan V2 tiene SLA ~2 s por embedding batch; con 5 retries + overhead la cola sube. > 15 s indica throttling Bedrock o explosión en cantidad de chunks por doc (PDF mal parseado). |

### 1.3 Distribución del Quality Gate (% pass / warning / discard)

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(verdict=X) / count(*) * 100` agrupado por `version_id` |
| **Umbral pass** | ≥ 75% (corpus limpio) |
| **Umbral discard** | < 15% (más alto indica splitter mal calibrado o docs basura) |
| **Captura** | Query DynamoDB `chunk_quality_audit` con GSI `by-verdict` |
| **Justificación** | Es el único indicador que separa "el pipeline corrió" de "el pipeline produjo material útil para RAG". Sin esto, podríamos celebrar 500 docs ingestados que generan respuestas de baja calidad. |

### 1.4 % de chunks promovidos por **regla maestra financiera**

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(has_financial_marker=true AND verdict IN (pass, warning)) / count(*)` |
| **Umbral** | **Tracking** (no umbral fijo) — se reporta tendencia |
| **Captura** | DynamoDB `chunk_quality_audit` con filter `has_financial_marker = true` |
| **Justificación** | **Indicador regulatorio.** La regla maestra CNBV/CONDUSEF dice que chunks con marcadores financieros (APR, CAT, Carrier Billing, cláusula, comisión) **nunca se descartan**. Este indicador prueba que la regla está activa en producción y permite auditoría retrospectiva: "muéstreme los 1,247 chunks financieros del run X y por qué quedaron". |

### 1.5 Costo de embeddings (USD por 1,000 docs)

| Atributo | Valor |
|---|---|
| **Fórmula** | `bedrock_invocations × avg_tokens × $0.00002 / 1000` (Titan V2 pricing) |
| **Umbral objetivo** | < USD 0.50 por 1,000 docs |
| **Captura** | CloudWatch `AWS/Bedrock/InvocationsCount` + log JSON Lambda con `input_tokens` |
| **Justificación** | Defiende la decisión de Titan V2 sobre OpenAI (~10x más caro) y BGE-M3 (gratis pero requiere GPU 24/7, TCO superior a este volumen). |

### 1.6 Recall@5 sobre gold-set

| Atributo | Valor |
|---|---|
| **Fórmula** | `Σ (top5_contiene_doc_relevante) / N` sobre 20 queries manuales gold-set |
| **Umbral objetivo** | ≥ 0.80 |
| **Captura** | Script offline `tests/eval_recall.py` (a crear) contra Aurora |
| **Justificación** | **Único proxy directo de "el RAG funciona".** Throughput y latencia pueden estar verdes con un índice inútil. Sin un gold-set, no hay forma de saber si las decisiones de chunking/embeddings son correctas. 20 queries cubren las 4 verticales × 5 categorías de intención (FAQ, contrato, política, catálogo, caso éxito). |

---

## Capa 2 — Indicadores de negocio (Acme Co)

### 2.1 Cobertura del corpus por vertical

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(DISTINCT document_id) GROUP BY vertical` |
| **Umbral** | ≥ 5 docs por vertical y por doc_type crítico (contract, policy_credit, faq) |
| **Captura** | SQL contra Aurora `rag_chunks` |
| **Justificación** | El Marketplace cubre 4 verticales (Moda Ética / Skincare D2C / Joyería Diseño / Mascotas Premium). Si una vertical tiene < 5 docs en una categoría crítica, las asesoras no pueden dar respuesta confiable a PyME Digital de esa vertical → riesgo de churn temprano. |

### 2.2 Frescura del índice

| Atributo | Valor |
|---|---|
| **Fórmula** | `now() - MAX(indexed_at)` |
| **Umbral objetivo** | < 24 h (re-indexación diaria nocturna) |
| **Umbral crítico** | > 7 días — dispara alerta |
| **Captura** | SQL `SELECT now() - MAX(indexed_at) FROM rag_chunks WHERE active = true` |
| **Justificación** | Política Carrier Billing y comisiones cambian con frecuencia. Una asesora que cita un APR vencido genera disputa CONDUSEF. > 7 días sin reindex sugiere un bug en Step Functions schedule. |

### 2.3 Costo por consulta de asesor

| Atributo | Valor |
|---|---|
| **Fórmula** | `(costo_indexacion_mes + costo_query_mes) / num_consultas_mes` |
| **Umbral objetivo** | < USD 0.05 por consulta |
| **Captura** | AWS Cost Explorer + CloudWatch `RAGPipeline/QueryCount` (futuro) |
| **Justificación** | Sustenta el **Business Case Año 1** del Marketplace. Asesora humana = ~MXN 80 por consulta resuelta. RAG a < USD 0.05 (MXN 0.85) = ROI 94×. |

### 2.4 Tiempo ahorrado por consulta (proxy: contexto retornado)

| Atributo | Valor |
|---|---|
| **Fórmula** | `tokens_contexto_top5 × tasa_lectura_humana_min` |
| **Umbral** | Tracking — se reporta tendencia |
| **Captura** | Log query con `total_context_tokens` |
| **Justificación** | Argumento ante Acme Co: cada consulta resuelta sin escalar ahorra ~12 min de búsqueda manual en SharePoint legacy. Indicador para el dossier de Patricia López. |

---

## Capa 3 — Indicadores de compliance

### 3.1 % de chunks financieros con trazabilidad de auditoría

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(criticality=financial AND chunk_id IN chunk_quality_audit) / count(criticality=financial)` |
| **Umbral** | **100%** (hard) |
| **Captura** | Cross-table SQL Aurora + scan DynamoDB |
| **Justificación** | **Requisito CNBV/CONDUSEF.** Todo chunk derivado de un contrato o política de crédito debe tener su veredicto del Quality Gate auditable. < 100% = riesgo regulatorio material. |

### 3.2 Tiempo de rollback a `version_id` anterior

| Atributo | Valor |
|---|---|
| **Fórmula** | `(t_query_alterada - t_rollback_iniciado)` |
| **Umbral objetivo** | < 5 min |
| **Captura** | Medible solo en simulación de DR — query con `active_version_id` flip en DynamoDB |
| **Justificación** | Plan de continuidad. Si una reindex introduce contenido erróneo (ej. contrato draft mezclado con producción), el rollback debe ser inmediato. > 5 min implica RTO no aceptable. |

### 3.3 100% chunks con `version_id` y `dataset_hash`

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(*) WHERE version_id IS NULL OR dataset_hash IS NULL` |
| **Umbral** | **0** (hard) |
| **Captura** | SQL `SELECT count(*) FROM rag_chunks WHERE version_id IS NULL OR dataset_hash IS NULL` |
| **Justificación** | **LFPDPPP Art. 19 — trazabilidad.** Cada vector debe trazarse a su run de origen y al snapshot del corpus que lo generó. Sin esto, no hay forma de responder a una solicitud INAI de "muéstreme qué datos derivaron en esta respuesta". |

### 3.4 Eventos no autorizados en Aurora (CloudTrail)

| Atributo | Valor |
|---|---|
| **Fórmula** | `count(eventName IN [Delete*, Drop*, Truncate*] AND errorCode IS NULL)` |
| **Umbral** | **0** (hard) — alarma inmediata |
| **Captura** | CloudTrail Lake query |
| **Justificación** | **INAI — integridad del repositorio.** El índice es un activo regulado. Cualquier delete no programado debe disparar investigación dentro de 1h. |

---

## Capa 4 — Indicadores del Agente LLM (roadmap fase 2)

> **Estado:** los KPIs de esta capa **no están instrumentados** en este entregable. Aplican cuando se sume la capa de inferencia/agente que consume el índice Aurora producido por las capas 1-3. Establecen el contrato de medición del producto final.

Fuente: catálogo estándar de la industria — ver [docs/14_kpis_agente_llm_referencia.md](14_kpis_agente_llm_referencia.md) para definiciones completas, fórmulas y citas.

### 4.1 Task Success Rate (TSR)

| Atributo | Valor |
|---|---|
| **Fórmula** | `TSR = tareas resueltas correctamente / tareas totales` |
| **Umbral objetivo** | ≥ 0.85 (línea base producción) |
| **Umbral crítico** | < 0.70 |
| **Captura** | Lambda Query (futuro) + tabla `agent_tasks` con outcome etiquetado |
| **Justificación** | **Única métrica que mide outcome de negocio.** El resto puede estar verde con TSR bajo. Para PyME Digital, tarea = "consulta sobre Carrier Billing/contrato/proceso resuelta sin escalar". |

### 4.2 Faithfulness / Grounding

| Atributo | Valor |
|---|---|
| **Fórmula** | `Faithfulness = respuestas fieles al contexto / respuestas totales` |
| **Umbral objetivo** | ≥ 0.95 |
| **Captura** | LLM-as-a-judge sobre triplet (query, chunks_retrieved, answer) |
| **Justificación** | **RAG sin grounding es inútil.** Mide si el LLM cita SOLO el contexto recuperado del índice Aurora, no su conocimiento pre-entrenado. Es la métrica que justifica el costo de la indexación. |

### 4.3 Hallucination Rate

| Atributo | Valor |
|---|---|
| **Fórmula** | `HR = respuestas con contenido inventado o no soportado / respuestas totales` |
| **Umbral objetivo** | ≤ 0.02 |
| **Umbral crítico** | > 0.05 → bloqueo de release |
| **Captura** | LLM-as-a-judge + auditoría manual sobre muestra |
| **Justificación** | **Riesgo regulatorio CNBV/CONDUSEF.** Si el agente inventa APR, comisiones o cláusulas, hay riesgo material. Complemento crítico de Faithfulness. |

### 4.4 Retrieval Precision@k (complemento del 1.6 Recall@5 de Capa 1)

| Atributo | Valor |
|---|---|
| **Fórmula** | `Precision@k = documentos relevantes en top-k / k` |
| **Umbral objetivo** | ≥ 0.60 |
| **Captura** | Script offline con gold-set + relevance labels manuales |
| **Justificación** | Capa 1.6 mide Recall (¿está el relevante en top-k?) pero no Precision (¿qué fracción del top-k es ruido?). Precision baja inunda el LLM con contexto irrelevante y eleva el HR. |

### 4.5 Tool Call Accuracy

| Atributo | Valor |
|---|---|
| **Fórmula** | `TCA = llamadas correctas de tool / llamadas totales de tool` |
| **Umbral objetivo** | ≥ 0.90 |
| **Captura** | Logs estructurados del agente con `tool_name`, `params`, `success` |
| **Justificación** | Si el agente invocará APIs de Acme Co (validación Carrier Billing, scoring crediticio, alta PyME), la precisión de la invocación es crítica — parámetros mal formados rompen el flujo. |

### 4.6 Schema Validity Rate

| Atributo | Valor |
|---|---|
| **Fórmula** | `SVR = salidas válidas contra schema / salidas totales` |
| **Umbral objetivo** | ≥ 0.99 |
| **Captura** | Validación JSON Schema en pipeline downstream |
| **Justificación** | Outputs estructurados (cards, formularios, tickets) requieren JSON estricto. Una respuesta inválida rompe el frontend de PyME Digital. |

### 4.7 End-to-End Latency p95 (agente completo)

| Atributo | Valor |
|---|---|
| **Fórmula** | `p95 del tiempo total: query → retrieve → generate → response` |
| **Umbral objetivo** | < 3 s |
| **Umbral crítico** | > 6 s |
| **Captura** | Lambda Query con instrumentation OpenTelemetry / X-Ray |
| **Justificación** | Diferente del 1.2 que mide solo Lambda chunking (offline). Este mide la experiencia real del usuario en línea. |

### 4.8 Cost per Successful Task (CPST)

| Atributo | Valor |
|---|---|
| **Fórmula** | `CPST = (costo Bedrock retrieve + Bedrock generate + tools) / tareas exitosas` |
| **Umbral objetivo** | < USD 0.05 por consulta resuelta |
| **Captura** | Cost Explorer + tabla `agent_tasks` |
| **Justificación** | Diferente del 2.3. Este mide TODA la pila del agente (incluyendo el LLM generativo, que puede ser 20× más caro que el embedding). Sostiene el Business Case. |

### 4.9 Policy Violation Rate

| Atributo | Valor |
|---|---|
| **Fórmula** | `PVR = respuestas con violación de política / respuestas totales` |
| **Umbral objetivo** | ≤ 0.01 |
| **Umbral crítico** | > 0.03 → revisión de guardrails |
| **Captura** | Guardrails layer (Bedrock Guardrails o Lakera Guard) con audit log |
| **Justificación** | Compliance — uso aceptable + reglas Acme Co. Ejemplos: hablar de competidores, dar consejo financiero personalizado sin disclaimer, etc. |

### 4.10 PII Leakage Incidents

| Atributo | Valor |
|---|---|
| **Fórmula** | `PII Incidents = número de respuestas con datos personales expuestos en el periodo` |
| **Umbral objetivo** | **0** (hard) |
| **Captura** | PII detection layer + auditoría mensual |
| **Justificación** | **LFPDPPP Art. 14, 19, 60.** Riesgo regulatorio material. Si el agente filtra RFC/CURP/datos de cuentas, hay sanción. Complementa el 3.4 (eventos CloudTrail) con foco en el contenido de las respuestas. |

### 4.11 CSAT (Customer Satisfaction)

| Atributo | Valor |
|---|---|
| **Fórmula** | `CSAT = suma de calificaciones de satisfacción / número de respuestas de encuesta` |
| **Umbral objetivo** | ≥ 4.2 / 5 |
| **Captura** | Encuesta post-interacción en UI del Marketplace |
| **Justificación** | Único proxy directo de "el usuario está satisfecho". Las métricas técnicas pueden estar verdes con CSAT bajo (respuestas técnicamente correctas pero mal entonadas para PyME Digital). |

### 4.12 User Feedback Rate

| Atributo | Valor |
|---|---|
| **Fórmula** | `Feedback Rate = interacciones con feedback explícito / interacciones totales` |
| **Umbral objetivo** | ≥ 0.10 |
| **Captura** | Botones thumbs up/down + comentarios opcionales en UI |
| **Justificación** | Cobertura del loop de mejora continua. Sin feedback explícito, el fine-tuning futuro del agente queda ciego. |

---

## Captura ejecutable — comandos listos para correr

> Reemplaza `$VERSION_ID` con el run específico (ej. `run-demo-2026053012`) y `$ENV` con el environment (`dev` por default).

### Setup

```bash
export AWS_REGION=us-east-1
export ENV=dev
export NAME_PREFIX=bsg-acmeco-rag-$ENV
export VERSION_ID=run-XXXXXXXXXXXXX
```

### 1.1 Throughput Glue

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Glue \
  --metric-name glue.driver.aggregate.recordsRead \
  --dimensions Name=JobName,Value=$NAME_PREFIX-etl \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum
```

### 1.2 Latencia p95 chunking

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=$NAME_PREFIX-chunking \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --extended-statistics p95
```

### 1.3 Distribución Quality Gate

```bash
for V in pass warning discard; do
  COUNT=$(aws dynamodb query \
    --table-name $NAME_PREFIX-chunk-quality-audit \
    --index-name by-verdict \
    --key-condition-expression "verdict = :v AND version_id = :ver" \
    --expression-attribute-values "{\":v\":{\"S\":\"$V\"},\":ver\":{\"S\":\"$VERSION_ID\"}}" \
    --select COUNT --query Count --output text)
  echo "$V: $COUNT"
done
```

### 1.4 % chunks financieros

```bash
aws dynamodb scan \
  --table-name $NAME_PREFIX-chunk-quality-audit \
  --filter-expression "version_id = :ver AND has_financial_marker = :true" \
  --expression-attribute-values '{":ver":{"S":"'"$VERSION_ID"'"},":true":{"BOOL":true}}' \
  --select COUNT --query Count
```

### 2.1 Cobertura por vertical (Aurora)

```sql
SELECT vertical, doc_type, COUNT(DISTINCT document_id) AS n_docs
FROM rag_chunks
WHERE version_id = :version_id
GROUP BY vertical, doc_type
ORDER BY vertical, doc_type;
```

### 2.2 Frescura del índice

```sql
SELECT
  now() - MAX(indexed_at) AS lag,
  COUNT(*) AS active_chunks
FROM rag_chunks
WHERE active = true;
```

### 3.1 Auditoría chunks financieros (cross-store)

```sql
-- 1. Lista chunks financieros activos en Aurora
SELECT chunk_id FROM rag_chunks
WHERE criticality = 'financial' AND version_id = :version_id;
```
```bash
# 2. Para cada chunk_id, verificar existencia en DynamoDB
# (script: tests/audit_financial_coverage.sh — a crear)
```

### 3.3 Integridad de versionamiento

```sql
SELECT COUNT(*) AS huerfanos
FROM rag_chunks
WHERE version_id IS NULL OR dataset_hash IS NULL;
-- Debe ser 0
```

---

## Estado de implementación (al 2026-06-01, post-deploy AWS real)

| Indicador | Captura lista | Emisión activa | Dashboard widget |
|---|---|---|---|
| 1.1 Throughput | ✅ via AWS/Glue | ✅ automática | ✅ widget #4 |
| 1.2 Latencia p95 | ✅ via AWS/Lambda — **medido real: 3-5 s warm, 47 s cold start** | ✅ automática | ✅ widget #5 |
| 1.3 Quality Gate | ✅ DynamoDB query — **medido real: 5 pass / 0 warn / 3 discard** | 🟡 logged, falta `put_metric_data` | ✅ widget #11 |
| 1.4 % financial | ✅ DynamoDB scan — **medido real: 100% pass tienen marker** | 🟡 logged, falta `put_metric_data` | ✅ widget #11 |
| 1.5 Costo embeddings | 🟡 logged en `index_versions.cost_estimate_usd` — **medido real: 0.0001 USD/run** | 🔴 falta emisión CW | ✅ widget #2 |
| 1.6 Recall@5 | 🔴 falta script + gold-set | 🔴 N/A | 🔴 falta widget |
| 2.1 Cobertura por doc_type | ✅ SQL Aurora — **medido: contract=3, dossier_icp=1, faq=1** | N/A (snapshot) | 🟡 falta vista BI |
| 2.2 Frescura | ✅ SQL | N/A | 🟡 falta widget |
| 2.3 Costo/consulta | 🟡 Cost Explorer | 🔴 falta `QueryCount` | 🔴 |
| 2.4 Tiempo ahorrado | 🔴 falta lambda query | 🔴 | 🔴 |
| 3.1 % financiero auditado | ✅ cross-store — **medido: 100% (5/5)** | N/A | 🔴 falta widget |
| 3.2 Tiempo rollback | 🟡 medible en DR drill | N/A | N/A |
| 3.3 Integridad version_id | ✅ SQL — **medido: 0 huérfanos** | N/A | 🟡 falta alarma |
| 3.4 Eventos CloudTrail | 🟡 CloudTrail query | N/A | 🟡 falta alarma |
| **4.1 Task Success Rate** | 🔮 fase 2 — requiere agente | 🔮 | 🔮 |
| **4.2 Faithfulness** | 🔮 fase 2 — LLM-as-judge | 🔮 | 🔮 |
| **4.3 Hallucination Rate** | 🔮 fase 2 — LLM-as-judge | 🔮 | 🔮 |
| **4.4 Retrieval Precision@k** | 🔮 fase 2 — gold-set + relevance | 🔮 | 🔮 |
| **4.5 Tool Call Accuracy** | 🔮 fase 2 — agente con tools | 🔮 | 🔮 |
| **4.6 Schema Validity** | 🔮 fase 2 — validación JSON | 🔮 | 🔮 |
| **4.7 E2E Latency p95 agente** | 🔮 fase 2 — Lambda Query | 🔮 | 🔮 |
| **4.8 Cost per Successful Task** | 🔮 fase 2 — Cost Explorer + tasks | 🔮 | 🔮 |
| **4.9 Policy Violation Rate** | 🔮 fase 2 — Bedrock Guardrails | 🔮 | 🔮 |
| **4.10 PII Leakage Incidents** | 🔮 fase 2 — PII detection layer | 🔮 | 🔮 |
| **4.11 CSAT** | 🔮 fase 2 — encuesta UI | 🔮 | 🔮 |
| **4.12 User Feedback Rate** | 🔮 fase 2 — thumbs up/down UI | 🔮 | 🔮 |

**Resumen:**
- **Capas 1-3 (14 indicadores):** 8/14 ya capturan hoy con datos REALES del run end-to-end del 2026-06-01. 4 requieren `put_metric_data` (backlog trivial). 2 requieren trabajo no trivial (gold-set Recall@5 + Lambda Query).
- **Capa 4 (12 indicadores):** 0/12 instrumentados — todos requieren la capa de agente LLM (fase 2 del producto). Documentados aquí para que el contrato de medición end-to-end quede establecido.

---

## Decisiones de diseño justificadas

**¿Por qué Recall@5 y no Recall@10 o MRR?**
Top-5 es el contexto típico que se pasa a un LLM generativo downstream. MRR penaliza posición exacta, pero a este caso de uso (asesora consulta documentos) basta con que la respuesta correcta esté en los 5 primeros.

**¿Por qué medir % chunks financieros y no % docs financieros?**
Un solo contrato genera 20-50 chunks. La unidad regulatoria es el **chunk** (es lo que termina en el contexto del LLM). Medir docs subreporta.

**¿Por qué umbral 75% de `pass` y no 90%?**
El corpus real del Marketplace incluye FAQs cortos, catálogos de imágenes con poco texto, snippets de pricing. Un 75% pass + 15% warning + 10% discard refleja realidad operativa.

**¿Por qué costo por consulta y no costo total mensual?**
Costo total es función de adopción (variable de mercado). Costo por consulta es invariante técnico y compara directamente con la alternativa (asesora humana MXN 80/consulta).

**¿Por qué CloudWatch + DynamoDB y no solo CloudWatch?**
CloudWatch resuelve agregación en tiempo real. DynamoDB resuelve **auditoría individual de cada chunk** — requisito CNBV: "muéstreme el chunk_id ABC123 y el por qué de su veredicto". Métricas agregadas no responden esa pregunta.

---

## Próximos trabajos (backlog priorizado)

| Item | Esfuerzo | Impacto |
|---|---|---|
| Agregar `cw.put_metric_data(...)` al final de `chunking/lambda_function.py` para emitir `ChunksGenerated`, `ChunksDiscarded`, `ChunksFinancialMarked` | 30 min | Alto — desbloquea 3 widgets |
| Crear `tests/eval_recall.py` con gold-set de 20 queries × 4 verticales | 4 h | Alto — único proxy de calidad RAG |
| Crear `tests/audit_financial_coverage.sh` (cross-store Aurora ↔ DynamoDB) | 1 h | Medio — cierra indicador 3.1 |
| Implementar Lambda Query con métrica `QueryLatency` y `TotalContextTokens` | 6 h | Alto — desbloquea capa 2 completa |
| Cost Explorer query agendada para indicador 2.3 | 2 h | Medio |

---

## Documentos relacionados

| Doc | Relevancia |
|---|---|
| [09_versionamiento_observabilidad.md](09_versionamiento_observabilidad.md) | Diseño original de métricas y alarmas |
| [12_lecciones_aprendidas.md](12_lecciones_aprendidas.md) | Backlog de `put_metric_data` faltante |
| [11_guia_administrador.md](11_guia_administrador.md) | Cómo navegar el dashboard CloudWatch |
| [03_semantic_chunking_pattern.md](03_semantic_chunking_pattern.md) | Definición del Quality Gate y la regla maestra |
| [CHECKPOINT.md](CHECKPOINT.md) | Estado actual del proyecto |
