# BSG Final Project — LLM Data Engineering Pipeline (Acme Co Hub PyMEs)

**Curso:** Diseño de Infraestructura Escalable — BSG Institute
**Proyecto 12:** ETL + Chunking + Embeddings + Indexing Pipeline para LLMs
**Caso de uso real:** Plataforma de Conocimiento del **Marketplace B2B PyME de Acme Co**, primer motor de instrumentación de la tesis **Economic Graph de la PyME Mexicana** (Grupo Acme).

---

## 📚 Material de entrega — empezar aquí

El **[folder `Docs Finales/`](Docs%20Finales/)** contiene el material principal para revisión:

- **[01_Proyecto12_Origen_BSG.md](Docs%20Finales/01_Proyecto12_Origen_BSG.md)** — Spec original del Proyecto 12 (el "qué se pidió")
- **[Proyecto12_Entregable_Final.pdf](Docs%20Finales/Proyecto12_Entregable_Final.pdf)** — Entregable consolidado de 146 páginas (el "qué se entregó")
- **[README de Docs Finales](Docs%20Finales/README.md)** — Guía de lectura + links a presentaciones Gamma + disclosure de anonimización

### Presentaciones Gamma

- 📊 [Más a detalle](https://gamma.app/docs/Proyecto-12-LLM-Data-Engineering-Pipeline-6wow0z7dqdyr7f9)
- 📋 [Resumen ejecutivo](https://gamma.app/docs/Proyecto-12-LLM-Data-Engineering-Pipeline-auzjwr6wb2as59u)

### Sobre la anonimización

Por confidencialidad del cliente real, los nombres de marcas en este repo están anonimizados con un mapping consistente. Ver el bloque "Disclosure" en [Docs Finales/README.md](Docs%20Finales/README.md) para las equivalencias.

> En resumen: **Acme Co** = cliente principal (telco), **Grupo Acme** = conglomerado al que pertenece, **PyME Digital** = ICP fictio de la PyME representativa. Términos como **Carrier Billing** se mantienen porque son nomenclatura estándar de industria.

---

## Resumen ejecutivo

Pipeline cloud-nativo en **AWS** que ingesta 500+ documentos (PDF/DOCX/HTML) del Marketplace B2B PyME de Acme Co, los limpia, aplica **chunking semántico con Quality Gate** (incluida regla maestra para chunks financieros CNBV), genera **embeddings con Bedrock Titan V2** (1024 dim), los indexa en **Aurora PostgreSQL + `pgvector`** con índice HNSW, registra cada versión inmutable en **DynamoDB** para auditoría LFPDPPP/CNBV, y expone una **state machine de Step Functions** que orquesta el flujo end-to-end con observabilidad completa en **CloudWatch** (dashboard + 7 alarmas).

Cumple los 12 componentes de la rúbrica del Proyecto 12 (~92/100 pts directos cubiertos) y entrega la **plomería de datos del Año 1** de un activo estratégico de 7 años para Acme Co / Grupo Acme.

---

## Stack técnico

| Capa | Tecnología | Componente del repo |
|---|---|---|
| Cloud | AWS — `us-east-1` | `infra/` (Terraform) |
| Ingesta | S3 versionado + KMS + Intelligent Tiering | `infra/s3.tf` |
| ETL | AWS Glue 4.0 (Python 3 + Spark) — parser PDF/DOCX/HTML, limpieza, dedup headers/footers | `etl/glue_etl_job.py` |
| Chunking | AWS Lambda **container image arm64** — `RecursiveCharacterTextSplitter` + Quality Gate de 7 reglas con regla maestra financiera | `chunking/` |
| Embeddings | AWS Bedrock Titan Embed V2 (1024 dim, `normalize=true`) | `chunking/lambda_function.py` |
| Indexación | Aurora PostgreSQL 16 Serverless v2 + `pgvector` (HNSW `m=16, ef_construction=64`) | `indexer/sql/00_init_pgvector.sql` |
| Loader | ECS Fargate **container image arm64** — `psycopg2 execute_values` UPSERT batch | `indexer/` |
| Versionamiento | DynamoDB `index_versions` + `chunk_quality_audit` (GSI by-verdict) | `infra/dynamodb.tf` |
| Orquestación | Step Functions Standard con 9 estados + Map paralelo + Catch + Retry | `orchestration/state_machine.json.tpl` |
| Observabilidad | CloudWatch dashboard (13 widgets) + 7 alarmas críticas + SNS topics | `infra/cloudwatch.tf` |
| Notificaciones | SNS + email suscripción opcional | `infra/stepfunctions.tf` |
| IaC | Terraform 1.6+ con provider AWS ~> 5.50 | `infra/` |

---

## Estructura del repositorio

```
.
├── README.md                         (este archivo)
├── .gitignore                        (estricto: secretos, .terraform, OneDrive temp, etc.)
├── .env.example                      (plantilla de variables locales)
│
├── docs/                             (12 documentos de proyecto)
│   ├── 01_caso_de_uso.md             — Caso de Uso + KPIs (Acme Co Hub PyMEs)
│   ├── 02_seleccion_embeddings.md    — Comparativa + justificación Titan V2
│   ├── 03_semantic_chunking_pattern.md — Patrón de chunking + Quality Gate
│   ├── 04_arquitectura.md            — Arquitectura AWS + Mermaid + costos
│   ├── 08_indexacion_aurora_pgvector.md — Estrategia indexación + 10 best practices
│   ├── 09_versionamiento_observabilidad.md — Versiones + dashboard + alarmas
│   ├── 10_guia_usuario.md            — Guía PyMEs + asesores hub + Customer Success
│   ├── 11_guia_administrador.md      — Runbooks operativos completos
│   ├── 12_lecciones_aprendidas.md    — Trade-offs + limitaciones + mejoras
│   └── SECURITY.md                   — 3 riesgos identificados + mitigaciones
│
├── infra/                            (Terraform — ~1700 líneas)
│   ├── README.md                     — Instrucciones de despliegue
│   ├── versions.tf · variables.tf · main.tf · outputs.tf
│   ├── vpc.tf · security_groups.tf   — VPC + 4 SGs + 4 VPC endpoints
│   ├── s3.tf · secrets.tf            — 3 buckets + Aurora master secret
│   ├── aurora.tf                     — Aurora Serverless v2 + pgvector
│   ├── dynamodb.tf                   — index_versions + chunk_quality_audit
│   ├── iam.tf                        — 5 roles least-privilege
│   ├── glue.tf                       — Glue Job + scripts bucket
│   ├── lambda.tf                     — Lambda container image + ECR + S3 trigger
│   ├── ecs.tf                        — Cluster Fargate + Task Definition + ECR
│   ├── stepfunctions.tf              — State machine + SNS + EventBridge scheduler
│   ├── cloudwatch.tf                 — Dashboard 13 widgets + 7 alarmas
│   └── terraform.tfvars.example
│
├── etl/                              (Glue ETL Job — ~570 líneas)
│   ├── README.md
│   ├── glue_etl_job.py               — Spark Job: PDF/DOCX/HTML → Parquet
│   └── requirements.txt
│
├── chunking/                         (Lambda container image — ~490 líneas)
│   ├── README.md
│   ├── lambda_function.py            — RecursiveCharacterTextSplitter + Quality Gate
│   ├── Dockerfile                    — Multi-stage arm64 non-root sbx_user1051
│   ├── requirements.txt              — boto3 + langchain-text-splitters + tiktoken + pyarrow
│   └── .dockerignore
│
├── indexer/                          (ECS Fargate loader — ~300 líneas Python + DDL + queries)
│   ├── README.md
│   ├── loader.py                     — S3 Parquet → Aurora UPSERT batch
│   ├── Dockerfile                    — Multi-stage arm64 non-root indexer:uid1001
│   ├── requirements.txt              — boto3 + psycopg2-binary + pyarrow
│   ├── .dockerignore
│   └── sql/
│       ├── 00_init_pgvector.sql      — DDL completo: tabla + 9 índices + MV + trigger
│       └── 01_query_examples.sql     — 8 patrones de query (k-NN, hybrid, financial, tuning)
│
└── orchestration/                    (Step Functions ASL)
    ├── README.md
    └── state_machine.json.tpl        — Definición ASL con placeholders Terraform
```

---

## Componentes de la rúbrica del Proyecto 12

| # | Componente | Pts | Estado | Archivos clave |
|---|---|---|---|---|
| 1 | Caso de Uso | 10 | ✅ | `docs/01_caso_de_uso.md` |
| 2 | Selección Modelo + Infra | 10 | ✅ | `docs/02_seleccion_embeddings.md`, `infra/` |
| 3 | Patrón LLM (Semantic Chunking) | 10 | ✅ | `docs/03_semantic_chunking_pattern.md` |
| 4 | Docker/Contenerización | 8 | ✅ | `chunking/Dockerfile`, `indexer/Dockerfile` |
| 5 | Orquestación del Pipeline | 8 | ✅ | `orchestration/state_machine.json.tpl`, `infra/stepfunctions.tf` |
| 6 | Arquitectura del Pipeline | 10 | ✅ | `docs/04_arquitectura.md`, `infra/` completo |
| 7 | Diseño ETL + Chunking | 10 | ✅ | `etl/glue_etl_job.py`, `chunking/lambda_function.py` |
| 8 | Embeddings | 6 | ✅ | `chunking/lambda_function.py` (Bedrock Titan V2) |
| 9 | Indexación Cloud | 6 | ✅ | `indexer/sql/`, `indexer/loader.py` |
| 10 | Versionamiento | 7 | ✅ | `infra/dynamodb.tf`, `indexer/loader.py::register_version` |
| 11 | Observabilidad | 7 | ✅ | `infra/cloudwatch.tf` (dashboard + 7 alarmas) |
| 12 | Documentación Final | 8 | ✅ | `docs/10_guia_usuario.md`, `docs/11_guia_administrador.md`, `docs/12_lecciones_aprendidas.md` |
| **Total** | | **100** | **✅** | |

**Distribución por bloque:** Arquitectura/Diseño 45% · Implementación 40% · Documentación 15%.

---

## Quick start

### Prerrequisitos
- AWS CLI configurado (region `us-east-1`)
- Terraform 1.6+
- Docker Desktop con `buildx`
- Acceso habilitado a Bedrock Titan V2 (consola AWS → Bedrock → Model access)

### Despliegue inicial (paso a paso resumido)

```powershell
# 1. Infra foundation (sin compute en primer apply)
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars: deploy_lambda_chunking=false, deploy_indexer_task=false
$env:TF_DISABLE_PLUGIN_TLS = "1"   # ver SECURITY.md
terraform init && terraform apply

# 2. Inicializar pgvector en Aurora
# (psql desde dentro del VPC con credenciales del secret)
# Ver indexer/README.md para detalle

# 3. Build + push de imágenes Docker
# (chunking + indexer; ver chunking/README.md e indexer/README.md)

# 4. Subir script Glue ETL
aws s3 cp ../etl/glue_etl_job.py "s3://$(terraform output -raw glue_scripts_bucket)/etl/"

# 5. Apply final con compute habilitado
# Editar terraform.tfvars: deploy_*=true
terraform apply

# 6. Disparar primera ejecución del pipeline
aws stepfunctions start-execution \
    --state-machine-arn "$(terraform output -raw state_machine_arn)" \
    --name "manual-$(Get-Date -Format 'yyyyMMddTHHmm')"

# 7. Abrir dashboard
Start-Process (terraform output -raw cloudwatch_dashboard_url)
```

**Detalle completo:** ver `docs/11_guia_administrador.md` §3.

---

## KPIs comprometidos

| KPI | Meta Fase 1 (500 docs) | Meta Fase 2 (5,000 docs) |
|---|---|---|
| Tiempo de indexación completa | ≤ 60 min | ≤ 30 min |
| Latencia búsqueda vectorial (k=5) P95 | ≤ 800 ms | ≤ 400 ms |
| Tasa de errores de parsing | ≤ 3% | ≤ 1% |
| Precisión top-5 global | ≥ 80% | ≥ 90% |
| **Precisión top-5 subset financiero CNBV** | **≥ 95%** | **≥ 98%** |
| Costo mensual AWS | ≤ **USD 500** | ≤ **USD 1,500** |
| Disponibilidad del endpoint | ≥ 99.0% | ≥ 99.5% |

---

## Costo estimado de operación

| Componente | Costo idle | Costo en reindex completo |
|---|---|---|
| Aurora Serverless v2 (0.5–2 ACU) | ~USD 45/mes | +~USD 20/mes |
| VPC Interface Endpoints (Bedrock + Secrets) | USD 16/mes | — |
| Bedrock Titan V2 (~5M tokens) | — | ~USD 0.10 |
| Lambda + Glue + ECS + S3 + DynamoDB | < USD 5/mes | +~USD 7 |
| CloudWatch (Logs + Metrics + Dashboard) | ~USD 10/mes | +~USD 5 |
| **Total estimado** | **~USD 75-90/mes** | **~USD 130-180/mes** |

**Margen** vs techo de USD 500/mes: ~70%.

---

## Decisiones clave (resumen — detalle en `docs/12_lecciones_aprendidas.md`)

1. **Aurora `pgvector` sobre OpenSearch** — compliance LFPDPPP + hybrid retrieval + SQL estándar
2. **Bedrock Titan V2 (1024 dim) sobre OpenAI / BGE-M3** — datos no salen de AWS + costo predecible
3. **Lambda container image** — para deps pesadas (PyArrow + LangChain + tiktoken)
4. **ECS Fargate para indexer** — cargas batch con conexión a DB
5. **HNSW sobre IVFFlat** — mejor recall + latencia a < 1M vectores
6. **Quality Gate con regla maestra financiera** — chunks `criticality=financial` nunca se descartan (CNBV)
7. **Versionamiento por `version_id` propagado end-to-end** — auditoría LFPDPPP a 5 años
8. **Step Functions Standard sobre Express** — duración variable + reintentos exponenciales

---

## Estado actual rápido

| Hito | Estado |
|---|---|
| Diseño + IaC + Docs (12/12 componentes rúbrica) | ✅ Completo |
| Tests locales pytest | ✅ **93/93 PASSED** |
| Docker builds (chunking + indexer arm64) | ✅ Healthcheck OK |
| pgvector DDL local (Postgres contenedor) | ✅ HNSW + cosine search OK |
| Terraform validate + plan vs AWS real | ✅ 83 recursos planificados |
| **Deploy real a AWS end-to-end** | ✅ **Ruta C completada (`run-demo-20260601-015935` SUCCEEDED en 2 min 30s)** |
| Evidencia visual (PNGs + tablas + JSON exports) | ✅ `evidence/cloud/artifacts/` |
| 12 bugs reales del deploy documentados | ✅ `docs/12_lecciones_aprendidas.md §2bis` |
| KPIs en 4 capas (técnica + negocio + compliance + agente LLM) | ✅ `docs/13` + `docs/14` |

**📄 Punto de entrada de evidencia:** [`evidence/cloud/RUN_demo-20260601-015935.md`](evidence/cloud/RUN_demo-20260601-015935.md)

**📊 Estado vivo del proyecto:** [`docs/CHECKPOINT.md`](docs/CHECKPOINT.md)

**☁️ Infraestructura AWS:** conservada activa (~$3.06/día, $92/mes idle). Para destruir cuando se decida, ver `docs/11_guia_administrador.md §destroy`.

## Lecturas recomendadas según rol

| Rol | Empieza por |
|---|---|
| **Cualquier rol — empieza aquí** | [`docs/00_decisiones_clave.md`](docs/00_decisiones_clave.md) (síntesis ejecutiva 4 min: por qué AWS + por qué Titan V2) |
| **Sponsor / Comité Ejecutivo Acme Co** | `docs/00_decisiones_clave.md` + `docs/01_caso_de_uso.md` + `evidence/cloud/RUN_demo-20260601-015935.md` |
| **Profesor / Comité BSG** | Este README + `docs/00_decisiones_clave.md` + `docs/04_arquitectura.md` + `evidence/cloud/RUN_demo-20260601-015935.md` + `docs/12_lecciones_aprendidas.md` §2bis (12 bugs reales) |
| **Data Engineer / DBA** | `docs/04_arquitectura.md` → `docs/08_indexacion_aurora_pgvector.md` → `infra/` → `evidence/cloud/artifacts/aurora_raw.txt` |
| **DevOps / Cloud Engineer** | `docs/11_guia_administrador.md` → `infra/README.md` → `docs/SECURITY.md` → `docs/12_lecciones_aprendidas.md §2bis` |
| **Producto / Roadmap agente** | `docs/13_indicadores_y_justificacion.md` Capa 4 + `docs/14_kpis_agente_llm_referencia.md` |
| **Asesor del hub Acme Co** | `docs/10_guia_usuario.md` Sección B |
| **PyME "PyME Digital"** (futuro) | `docs/10_guia_usuario.md` Sección A |
| **Compliance / Legal** | `docs/01_caso_de_uso.md` §9 + `docs/09_versionamiento_observabilidad.md` §3.3 + `evidence/cloud/RUN_demo-20260601-015935.md` (sección Compliance) |

---

## Estado actual y siguiente fase

**Fase 1 (este repo):** Pipeline foundation completo. **Deploy real a AWS validado end-to-end** con 2 runs SUCCEEDED, 5 chunks indexados en Aurora con HNSW funcional, dataset_hash SHA-256 registrado en DDB, regla maestra CNBV verificada (100% chunks pass con marcador financiero detectado y promovido a `criticality=financial`).

**Fase 1.1 (próxima):**
1. Lambda Query + API Gateway con citación obligatoria
2. Emitir métricas custom CloudWatch desde el código (`ChunksGenerated`, `ChunksDiscarded`, `ChunksFinancialMarked`, `EstimatedCostUSD`)
3. Backend remoto de Terraform (S3 + DynamoDB lock)
4. CI/CD GitHub Actions para Docker build & push
5. Crear gold-set de 20 queries × 4 verticales para Recall@5

**Fase 2 (Año 2 de la tesis Economic Graph — capa Agente LLM):**
- LLM generativo (Bedrock Claude / Nova) conectado al índice Aurora
- Instrumentación de Capa 4 KPIs: Task Success, Faithfulness, Hallucination Rate, Tool Call Accuracy, CSAT (ver `docs/13` §Capa 4)
- Bedrock Guardrails + PII detection
- Expansión a 8 verticales + integración con Banco Acme + particionado Aurora por `version_id`

---

## Licencia y uso

Material académico del curso **BSG Institute — Diseño de Infraestructura Escalable**.

Anclado al caso de negocio confidencial de Acme Co / Grupo Acme (Marketplace B2B PyME). No distribuir sin autorización del autor y del profesor.

**Autor:** Alfredo Suárez · `arse.alf@gmail.com`
**Profesor:** Msc. Andrés Felipe Rojas Parra · CAIO · `andres.rojas@triskelss.com`
**Repositorio:** https://github.com/AlfredoSuarez/bsg-final-proyect-data-llm-test (privado)
