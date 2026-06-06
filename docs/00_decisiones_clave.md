# Decisiones clave del proyecto — síntesis ejecutiva

**Documento:** 00 — Síntesis de justificaciones de AWS y modelo de embeddings
**Audiencia:** Profesor / Comité BSG · Sponsor Acme Co · Lectores que necesitan el "executive answer" antes de leer la especificación completa
**Tiempo de lectura:** 4 minutos

Este documento responde dos preguntas que el evaluador suele hacer primero:

1. **¿Por qué AWS y no Azure, GCP o on-prem?**
2. **¿Por qué Bedrock Titan V2 y no OpenAI text-embedding-3-large o BGE-M3 self-hosted?**

Si necesitas la justificación extensa, ver los documentos referenciados al final de cada sección.

---

## 1. ¿Por qué AWS?

### 1.1 Tres principios rectores derivados del caso de uso

| # | Principio | Implicación técnica |
|---|---|---|
| 1 | **Cero datos fuera del perímetro AWS de Acme Co** | Bedrock vía VPC endpoint privado · Aurora en subnets privadas · S3 y DynamoDB via gateway endpoints · sin tránsito por internet pública |
| 2 | **Compliance LFPDPPP/CNBV/CONDUSEF/INAI estructural, no opcional** | Residencia de datos en región AWS · CloudTrail nativo · datos NO se usan para entrenar modelos · certificaciones SOC1/2/3, ISO 27001/17/18, HIPAA-eligible |
| 3 | **Ecosistema Grupo Acme ya en AWS** | Banco Acme, AcmeCo, Retail Acme ya operan workloads críticos en AWS · integración futura con scoring federado de Banco Acme es nativa, no inter-cloud |

### 1.2 Dos razones operativas concretas

- **Bedrock managed** elimina la necesidad de mantener GPU dedicada (vs BGE-M3 self-hosted en ECS/EKS, que paga GPU idle incluso cuando no procesa).
- **IaC madura con Terraform AWS provider ~> 5.50** (>2,000 recursos cubiertos) permite un IaC completo y reproducible — algo más complejo de lograr con multi-cloud o on-prem.

### 1.3 Lo que NO se eligió y por qué

- **Azure / GCP**: el resto del stack de Grupo Acme vive en AWS; migrar añadiría 1 cloud nuevo a operar sin beneficio funcional.
- **On-prem**: contradice el principio de elasticidad y el time-to-production que el caso de uso exige (Año 1 del Business Case Marketplace B2B PyME tiene meta de 1,000 PyMEs activas).
- **Híbrido (Azure ML + AWS RDS, por ejemplo)**: multiplica los puntos de fallo de compliance y la superficie de auditoría.

> **Detalle completo:** `docs/04_arquitectura.md` §1 (principios rectores) y `docs/02_seleccion_embeddings.md` §2.3 (compliance regulatorio mexicano).

---

## 2. ¿Por qué Bedrock Titan Text Embeddings V2?

### 2.1 Tabla comparativa (las 3 alternativas evaluadas)

| Dimensión | **Titan V2** (elegido) | OpenAI text-embedding-3-large | BGE-M3 self-hosted |
|---|---|---|---|
| **Dimensiones** | 1024 (configurable 512/256) | 3072 | 1024 |
| **Costo / 1M tokens** | **USD 0.02** | USD 0.13 (6.5× más caro) | USD 0.03–0.15 (GPU idle = caro) |
| **Latencia p50** | 50–150 ms | 200–500 ms | 30–100 ms |
| **Datos para entrenamiento del proveedor** | NO se usan | Solo en tier Enterprise | N/A (control total) |
| **Residencia de datos** | Dentro de AWS Acme Co | Sale a OpenAI | Dentro del perímetro |
| **Compliance LFPDPPP/CNBV** | Nativo, sin trabajo extra | Requiere tier Enterprise + revisión legal | Control pero ops propias |
| **Integración AWS** | IAM + VPC + KMS + CloudTrail nativo | Externa: requiere Secrets + NAT + monitoreo aparte | ECS/EKS con GPU + observabilidad propia |
| **Time-to-production** | Horas | Días | Semanas |
| **Lock-in** | Medio (AWS) | Medio (OpenAI) | Bajo |

### 2.2 Cinco razones que decidieron Titan V2

1. **Encaja con el corpus del Marketplace B2B PyME.** Combina cuatro registros lingüísticos: contractual legal (cláusulas Carrier Billing, SLAs), técnico telecom (manuales AcmeCo Negocios), comercial-aspiracional (dossiers ICP "PyME Digital") y formativo / FAQ. Titan V2 está entrenado multilingüe y maneja sólidamente castellano técnico y legal.

2. **Economía decisiva a escala.** Volúmenes proyectados: 5M tokens fase 1, 50M tokens fase 2. Costo Titan V2: decenas de centavos por ciclo de reindexación. OpenAI multiplicaría por 6.5×. BGE-M3 self-hosted paradójicamente sale más caro por GPU idle a este volumen.

3. **Compliance regulatorio mexicano sin trabajo adicional.** El corpus contiene tres clases de información regulada: (a) datos personales LFPDPPP (PII PyMEs + dossiers ICP), (b) información sobre productos financieros sujeta a CNBV/CONDUSEF (scoring 24% APR, comisión apertura 3%, cláusulas Carrier Billing), y (c) info confidencial intra-Grupo Acme (integración futura Banco Acme). Bedrock cubre los tres por construcción.

4. **Integración nativa reduce TCO.** Un solo IAM role con `bedrock:InvokeModel`, sin secrets compartidos, sin egress a internet, sin servicios de monitoreo paralelos. OpenAI requeriría Secrets Manager con rotación + NAT Gateway + instrumentación adicional. BGE-M3 requeriría stack ECS/EKS con GPU + autoscaling + observabilidad propia.

5. **Trade-offs explícitos asumidos** (declarados, no ocultos):
   - Calidad MTEB marginalmente inferior a OpenAI 3-large — desaparece en evaluación humana sobre 100 consultas mensuales del caso real.
   - 1024 dim vs 3072 — compensa con 3× menos almacenamiento en Aurora y búsqueda HNSW más rápida.
   - Lock-in AWS — aceptable porque el resto del stack ya está en AWS; la migración hipotética representa riesgo bajo a 18 meses.

> **Detalle completo:** `docs/02_seleccion_embeddings.md` §1 (tabla comparativa expandida), §2 (las 5 razones detalladas), §3 (proyección de costos por fase) y `docs/12_lecciones_aprendidas.md` §1.2 (trade-offs explícitos del retrospect).

---

## 3. La solicitud original del proyecto

El prompt del **Proyecto 12 BSG** especifica un pipeline cloud-nativo de ETL + Chunking + Embeddings + Indexación para 500+ documentos PDF/DOCX/HTML, con orquestación, observabilidad y versionamiento, validado contra una rúbrica de 12 componentes (100 pts).

**La solicitud no impuso AWS ni Titan V2** — fueron decisiones de diseño tomadas con criterio profesional. La elección se ancla al **caso de uso real Acme Co / Grupo Acme** (no académico abstracto), lo que eleva los criterios de selección desde "qué embedding gana en benchmarks MTEB" hacia:

- ¿Qué embedding cumple compliance regulatorio mexicano sin esfuerzo extra?
- ¿Qué cloud permite mantener residencia de datos dentro del perímetro Grupo Acme?
- ¿Qué stack es predecible en costo a 18-24 meses y no añade carga operativa al equipo de Acme Co?

Las tres preguntas convergen a **AWS + Bedrock Titan V2**.

---

## 4. Validación en el deploy real

El 2026-06-01 se ejecutó el pipeline end-to-end en AWS (`run-demo-20260601-015935`, 2 min 30 s). Las promesas de diseño quedaron sustanciadas con datos reales:

| Promesa de diseño | Validación medida |
|---|---|
| Titan V2 entrega vectores de 1024 dim | `embedding vector(1024)` en Aurora con 5 chunks reales |
| Datos no salen del perímetro AWS | Bedrock invocado vía VPC endpoint privado (sin egress internet, confirmado en CloudTrail) |
| Costo predecible pay-per-token | Registrado en DynamoDB: `cost_estimate_usd=0.0001` para 5 chunks (~830 tokens) |
| Auditoría LFPDPPP/CNBV completa | 8/8 chunks decisionados en `chunk_quality_audit` con timestamp + reason + metrics_json + dataset_hash SHA-256 |
| Integración nativa IAM (sin secrets) | Lambda invoca Bedrock con IAM policy `bedrock:InvokeModel`, sin secrets compartidos |
| HNSW funcional sobre 1024-dim vectores | Cosine search retorna similarities 1.0 → 0.71 → 0.58 → 0.54 → 0.22 (decreciente coherente) |

> **Evidencia completa:** `evidence/cloud/RUN_demo-20260601-015935.md` (archivo principal) y artefactos visuales en `evidence/cloud/artifacts/` (sfn_diagram.png + cw_metrics.png + tablas DDB).

---

## 5. Referencias cruzadas

| Pregunta | Documento principal | Sección |
|---|---|---|
| "¿Cuáles eran las alternativas evaluadas?" | `docs/02_seleccion_embeddings.md` | §1 tabla comparativa |
| "¿Cómo se calculó el costo a escala?" | `docs/02_seleccion_embeddings.md` | §3 proyección por fase |
| "¿Qué arquitectura serverless se diseñó?" | `docs/04_arquitectura.md` | §2 (componentes) y diagrama Mermaid |
| "¿Qué riesgos quedan abiertos?" | `docs/12_lecciones_aprendidas.md` | §1.1, §1.2 (trade-offs Aurora pgvector + Bedrock Titan V2) y §2bis (12 bugs reales del deploy) |
| "¿Cómo se mide si el pipeline funcionó?" | `docs/13_indicadores_y_justificacion.md` | 4 capas de KPIs + Capa 4 (agente LLM, roadmap fase 2) |
| "¿Funcionó en AWS real?" | `evidence/cloud/RUN_demo-20260601-015935.md` | TL;DR + cobertura por indicador |
