# Lecciones Aprendidas

**Documento:** 12 — Lecciones Aprendidas
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:** Comité Ejecutivo de Innovación Acme Co · Comité Académico BSG · Equipo del proyecto

---

## 0. Marco para leer este documento

Este proyecto entregó un **pipeline cloud-nativo de ingeniería de datos para LLMs** en AWS, anclado al Marketplace B2B PyME de Acme Co y a la tesis Economic Graph de Grupo Acme. Las lecciones que siguen están organizadas en tres bloques: **(1) trade-offs de diseño** que se tomaron deliberadamente y siguen siendo correctos, **(2) limitaciones actuales** que conocemos y que no son bloqueantes para la fase 1 pero deben resolverse antes de productivizar, y **(3) próximas mejoras posibles** ordenadas por impacto sobre la tesis Economic Graph.

Cada lección describe **qué se hizo, por qué, cuál fue el costo y qué se aprende**. El objetivo es que cualquier equipo que tome este pipeline en la siguiente fase entienda no solo las decisiones, sino también las razones — y pueda actualizarlas cuando el contexto cambie.

---

## 1. Trade-offs de diseño

### 1.1 Aurora `pgvector` sobre OpenSearch / BigQuery / AlloyDB

**Decisión.** Aurora PostgreSQL 16 Serverless v2 con extensión `pgvector` como base vectorial única.

**Razón.** Mantener todos los datos sensibles dentro del perímetro AWS de Acme Co (LFPDPPP) y reusar SQL estándar para queries híbridas (vector + BM25 + filtros JSONB). El costo de idle (~USD 45-90/mes) es marginal vs. el techo declarado de USD 500/mes.

**Costo asumido.**

- **Sin escalado horizontal nativo.** Aurora Serverless v2 escala verticalmente; a > 1M vectores conviene partitioning o migración a un motor especializado.
- **Latencia ~5% mayor** que OpenSearch para k-NN puro en benchmarks públicos.
- **Lock-in** moderado: la migración hipotética a otro motor requiere reindexar (no es portable el vector con su índice HNSW).

**Lección.** En proyectos donde el corpus tiene rica metadata estructurada y los filtros híbridos son críticos (como subset financiero `criticality='financial'`), `pgvector` gana sobre vector stores especializados. La diferencia de latencia es invisible para el usuario final cuando el end-to-end es dominado por la generación LLM (futura Fase 2). Lo que sí es visible es la facilidad de operar con `psql` y SQL ANSI vs. un DSL propietario.

### 1.2 Bedrock Titan V2 (1024 dim) sobre OpenAI 3-large o BGE-M3

**Decisión.** Titan Embed Text V2 con vectores de 1024 dimensiones.

**Razón.** Integración nativa con AWS (VPC endpoints, IAM, Secrets, CloudTrail), compliance LFPDPPP/CNBV por construcción (datos no salen de AWS, no se usan para entrenar) y costo por 1M tokens 5× menor que V1.

**Costo asumido.**

- **Calidad de embedding** marginalmente inferior a `text-embedding-3-large` en benchmarks MTEB multilingüe (diferencia < margen de error en evaluación humana).
- **Lock-in AWS** — un cambio de cloud requiere reindexar.
- **Dimensiones más pequeñas** (1024 vs 3072 de OpenAI) — menor capacidad teórica de representación, compensada por mayor velocidad de búsqueda y menos almacenamiento.

**Lección.** Para casos de uso de retrieval (k-NN con métrica "el top-5 contiene la respuesta correcta"), la diferencia entre embeddings de calidad equivalente desaparece en evaluación humana orientada al caso real. Lo que sí no es indistinto es **compliance**, **predictibilidad de costo** y **complejidad operativa** — y en esos tres ejes Bedrock gana decisivamente.

### 1.3 RecursiveCharacterTextSplitter + Quality Gate sobre chunker estructural custom

**Decisión.** Usar `langchain.text_splitters.RecursiveCharacterTextSplitter` (chunking por separadores hierárquicos) con length_function en tokens (tiktoken cl100k_base) más un Quality Gate de 7 reglas con **regla maestra para chunks financieros**.

**Razón.** El prompt original del Proyecto 12 (Prompt 7 del archivo de prompts) lo especifica. RecursiveCharacterTextSplitter está bien probado y es ampliamente documentado. La regla maestra del Quality Gate compensa la pérdida de estructura aplicando un filtro de criticality regulatoria que no descarta chunks financieros aunque tengan flags duras.

**Costo asumido.**

- **No preserva la estructura semántica completa** del documento (jerarquía H1/H2/H3, cláusulas atómicas como en `docs/03_semantic_chunking_pattern.md`). La `section_hint` que devuelve cada chunk es la primera línea, no la ruta jerárquica completa.
- **Citación regulatoria menos rica.** El CNBV/CONDUSEF idealmente exige citación a nivel "Contrato Carrier Billing > 4.2 Cargos por mora". La cita actual es "primera línea del chunk + filename". Funciona, pero no es la implementación ideal.

**Lección.** El chunker estructural definido en `docs/03_semantic_chunking_pattern.md` es estrictamente superior para el caso de uso, pero su implementación requiere un parser específico por tipo de documento (PDF con extracción de outline, DOCX con `xml.etree`, HTML con árbol semántico). Para Fase 1 se eligió la opción simple + Quality Gate; para Fase 2 vale la pena invertir en el chunker estructural — especialmente porque el subset financiero del corpus crecerá con la cartera de Carrier Billing.

### 1.4 Container image Lambda en lugar de zip + layer

**Decisión.** El Lambda de chunking se empaqueta como **container image** (Dockerfile multi-stage arm64) publicado a ECR, en lugar del enfoque tradicional zip + Lambda Layer.

**Razón.** PyArrow + LangChain + tiktoken + boto3 exceden el límite de 250 MB del Lambda zip (con o sin layer). El container image permite hasta 10 GB. Además, el mismo Dockerfile y herramientas se reusan para el indexer ECS Fargate — un patrón consistente.

**Costo asumido.**

- **Cold start** del container Lambda es ~2-3× más alto que zip (10-15 s vs 3-5 s). Mitigable con Provisioned Concurrency en Fase 1.1 si la latencia interactiva importa.
- **Image build pipeline** más complejo que zip (requiere Docker buildx y push a ECR). En Fase 1 esto se hace manualmente; CI/CD lo automatiza en Fase 1.1.
- **Tamaño de imagen** ~700 MB — cuesta storage en ECR (~USD 0.10/GB-mes, negligible).

**Lección.** Para Lambdas con dependencias ML/data engineering pesadas, container image es el patrón correcto y debe ser el default. El cold start adicional rara vez importa para pipelines batch (que es nuestro caso). Para endpoints interactivos (Lambda Query en Fase 1.1), considerar Provisioned Concurrency.

### 1.5 ECS Fargate sobre Lambda para el indexer

**Decisión.** El loader que UPSERTea embeddings a Aurora corre como **task ECS Fargate**, no como Lambda.

**Razón.** Cargas batch de larga duración (potencialmente > 5 min), gestión limpia de conexiones a Aurora (psycopg2 con SSL), control de RAM (2 GB cómodos, vs Lambda donde hay que justificar cada MB), y — clave — **satisface el componente #4 Docker de la rúbrica con multi-stage build y usuario no-root**.

**Costo asumido.**

- **Mayor complejidad de despliegue** que Lambda (cluster ECS + task definition + RunTask vs. simple function invoke).
- **No invocable por S3 event directo** — el indexer requiere ser disparado por Step Functions o por CLI.

**Lección.** Lambda no es siempre la opción correcta. Para cargas batch con conexiones a DB y duración variable, Fargate gana en simplicidad operativa a costa de complejidad de IaC. La regla práctica: si la carga puede durar más de 10 min en P95 o requiere > 3 GB RAM sostenida, Fargate.

### 1.6 HNSW sobre IVFFlat

**Decisión.** Índice HNSW (`m=16, ef_construction=64, vector_cosine_ops`) para ANN.

**Razón.** A volúmenes < 1M vectores (que cubre Fase 1 y 2 hasta 40K vectores), HNSW ofrece mejor recall y latencia que IVFFlat, sin requerir tuning de `nlist`/`nprobe`.

**Costo asumido.**

- **Mayor consumo de memoria** en Aurora — el índice HNSW vive en RAM cuando se consulta intensivamente.
- **Construcción más lenta** que IVFFlat (3-5× más tiempo) — relevante solo en reconstrucción masiva del índice.

**Lección.** A escala fase 1 / fase 2 del proyecto, HNSW es el default correcto. Re-evaluar IVFFlat si el corpus supera 100K vectores y el costo Aurora se vuelve significativo.

### 1.7 Verticales y doc_types como CHECK constraints en SQL

**Decisión.** El DDL de `documents_embeddings` valida `doc_type` y `criticality` con `CHECK` constraints (whitelist explícita de valores).

**Razón.** Defensa en profundidad. Aun si el código de chunking emite un valor inesperado, Aurora lo rechaza al INSERT — falla rápido y trazable.

**Costo asumido.**

- **Schema rígido.** Agregar un nuevo `doc_type` (ej. `marketing_collateral`) requiere migración SQL (`ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT ...`).
- **Acoplamiento** entre código (heurísticas de inferencia en `etl/glue_etl_job.py`) y SQL (CHECK list en `indexer/sql/00_init_pgvector.sql`).

**Lección.** Para corpus con cardinalidad conocida y baja (10 doc_types, 4 verticales, 4 criticalities), el CHECK constraint es la opción correcta — el costo de migración es bajo y el beneficio en consistencia es alto. Para corpus con cardinalidad creciente o impredecible, mejor migrar a una tabla de lookup separada con FK.

---

## 2. Limitaciones actuales (conocidas, no bloqueantes para Fase 1)

### 2.1 DOCX paginación simplificada

El Glue ETL emite todo el contenido de un DOCX como `page_number=1`. DOCX no tiene concepto nativo de página hasta render. **Impacto:** la cita devuelta dice "página 1" para cualquier DOCX, lo cual es honesto pero menos preciso que PDF. **Solución:** estimar páginas por longitud o renderizar con LibreOffice headless (~5x más tiempo de ETL).

### 2.2 OCR de PDFs escaneados no se procesa

PyPDF2 falla silenciosamente en PDFs sin texto extraíble (escaneados con OCR pobre). El documento se procesa con `raw_text=""` y todas sus filas se descartan en chunking. **Solución:** detectar `text == ""` en todas las páginas y enrutar a AWS Textract. Ya está documentado en `etl/README.md`.

### 2.3 Heurística doc_type por filename

La inferencia de `doc_type` y `vertical` en el Glue ETL usa regex sobre el nombre del archivo. Funciona ~85% en corpus interno curado, pero falla con archivos cuyo nombre es genérico (`scan_001.pdf`, `documento.pdf`). **Solución:** complementar con clasificación sobre las primeras 1000 chars del contenido extraído (un clasificador simple con keywords + regex, no requiere LLM).

### 2.4 `section_hint` heurística, no `section_path` estructural

Cada chunk lleva `section_hint = primera línea del chunk`. Para citación regulatoria CNBV idealmente queremos `section_path = "Contrato Carrier Billing > 4. Default Management > 4.2 Cargos por mora"`. **Solución:** chunker estructural custom (ver §1.3 arriba).

### 2.5 Batch real en Bedrock no implementado

La Lambda chunking invoca Bedrock con `invoke_model` (un texto por llamada), paralelizado con `ThreadPoolExecutor`. Bedrock tiene un endpoint `bedrock-runtime` que **no soporta batch sincrónico**. Existe `bedrock` (no `bedrock-runtime`) con batch async vía S3, pero es overkill para nuestro volumen. **No es bloqueante** — el paralelismo actual (10 threads) procesa 4,000 chunks en ~60 s, cómodo dentro del timeout Lambda.

### 2.6 Lambda Query (endpoint de consulta) no implementada

El pipeline produce un índice consultable, pero el endpoint API Gateway + Lambda Query que devuelve respuestas con citación verificable a las PyMEs **no está construido aún**. En Fase 1 las consultas las hacen asesores del hub vía SQL directo. **Solución:** implementar Lambda Query en Fase 1.1 — diseño documentado en `docs/04_arquitectura.md` §2.9.

### 2.7 Sin autenticación granular en Fase 1

API Gateway no está expuesto a usuarios externos. En Fase 1.1 cuando se exponga, requerirá Cognito + API Keys + rate limiting per-PyME. **Solución:** ya documentado en backlog de `04_arquitectura.md` y `09_versionamiento_observabilidad.md`.

### 2.8 Métricas custom CloudWatch no se emiten desde el código

Los Lambdas y el indexer emiten logs detallados pero **no llaman `cloudwatch.put_metric_data()`** para emitir `ChunksGenerated`, `ChunksDiscarded`, etc. El dashboard ya tiene los widgets preparados pero aparecerán vacíos hasta que el código emita las métricas. **Solución:** trivial — agregar `cw.put_metric_data(...)` al final de cada handler. En backlog inmediato.

### 2.9 Detección de deletes en el ETL

El Glue ETL **no detecta documentos eliminados** del bucket raw. Solo procesa lo que está. Eso significa que un documento removido del corpus permanece en el índice hasta cleanup manual. **Solución:** paso de reconciliación post-indexer que compara documentos en `documents_embeddings` vs documentos en S3 y borra los huérfanos.

### 2.10 SSL inspection + cuenta root + OneDrive (entorno local del autor)

Documentado en `docs/SECURITY.md` con 3 riesgos clasificados (crítico, medio, bajo). Aplicable solo al entorno local del desarrollo académico — **no impacta el sistema en producción** porque el deploy real se hace desde IAM users con MFA en redes sin SSL inspection en máquinas fuera de OneDrive. Documentado completamente con mitigaciones.

---

## 2bis. Bugs encontrados durante el deploy real a AWS (Ruta C)

> Esta sección documenta los **12 bugs reales** descubiertos durante el deploy end-to-end a AWS el 2026-05-31 / 2026-06-01. Cada uno tomó iteración del Terraform o de las imágenes Docker, y el conjunto representa el **aprendizaje más concreto y reproducible** del proyecto. Evidencia completa en `evidence/cloud/RUN_demo-20260601-015935.md` y artefactos en `evidence/cloud/artifacts/`.

### Categoría A — IaC contra AWS API real

| # | Síntoma | Causa raíz | Fix |
|---|---|---|---|
| 1 | `Character sets beyond ASCII are not supported` en `aws_security_group.description` | Em-dashes y acentos en strings que viajan al API EC2 | Limpiar todos los strings que van a AWS (SG descriptions, DDB Tag Values, alarm_descriptions) a ASCII estricto. Los comentarios `#` Terraform pueden mantener acentos. |
| 2 | `Invalid parameter value: vector` en `aws_rds_cluster_parameter_group.parameter.shared_preload_libraries` | Aurora PostgreSQL 16 NO permite `vector` en `shared_preload_libraries`. La doc del proyecto lo asumió por convención de community Postgres. | Quitar `vector`. pgvector se carga con `CREATE EXTENSION vector` desde sesión, no a nivel cluster. |
| 3 | `Tag Value provided is invalid` en `aws_dynamodb_table.tags` | DDB tag values permiten solo `letters digits spaces + - = . _ : / @` — paréntesis y acentos prohibidos | Reemplazar `(`, `)`, acentos en cada Tag Value que va a DDB. |
| 4 | `SCHEMA_VALIDATION_FAILED: The value for the field 'Message.$' must be a valid JSONPath` | Step Functions JSONPath no soporta bracket notation con caracteres especiales: `$.foo['--bar']` | Simplificar paths para evitar `--` y `[]`. Si se requiere el valor, capturarlo en estado previo. |
| 5 | `AccessDeniedException: state machine IAM Role not authorized to access the Log Destination` | `aws_sfn_state_machine.logging_configuration` requiere permisos extra (`logs:CreateLogDelivery`, etc.) que no están en la policy default | Agregar inline policy con: `logs:{CreateLogDelivery, GetLogDelivery, UpdateLogDelivery, DeleteLogDelivery, ListLogDeliveries, PutResourcePolicy, DescribeResourcePolicies, DescribeLogGroups}` + X-Ray `{PutTraceSegments, PutTelemetryRecords, GetSamplingRules, GetSamplingTargets}` |

### Categoría B — Container Image + Lambda + ECS

| # | Síntoma | Causa raíz | Fix |
|---|---|---|---|
| 6 | `Source image ... does not exist` al crear Lambda | Lambda image-based requiere imagen pushed ANTES de `aws_lambda_function` create | Two-pass apply: var `deploy_lambda_chunking=false` para foundation → docker push → cambiar a `true` y reaplicar |
| 7 | `image manifest, config or layer media type ... is not supported` (Lambda) | Buildx adjunta provenance/SBOM attestations al manifest por default; Lambda no las soporta | `docker buildx build --provenance=false --sbom=false ...` |
| 8 | `Lambda.TooManyRequestsException - Rate Exceeded` (429) | Burst limit de cuenta nueva en us-east-1; Map state lanza 4 Lambdas VPC-attached de cold start simultáneo | `aws lambda put-function-concurrency --reserved-concurrent-executions 5` (garantiza capacity fuera del pool compartido) |
| 9 | `ResourceInitializationError: cannot pull from ECR (i/o timeout 44.213.79.104:443)` en ECS Fargate | Task corre en private subnet sin egress a internet ni VPC endpoint para ECR | Agregar 3 VPC endpoints: `ecr.api`, `ecr.dkr`, `logs` |

### Categoría C — Código de la Lambda

| # | Síntoma | Causa raíz | Fix |
|---|---|---|---|
| 10 | Pipeline `SUCCEEDED` pero `0 chunks generados`. Logs: `ConnectTimeoutError: openaipublic.blob.core.windows.net` | tiktoken descarga el tokenizer `cl100k_base.tiktoken` desde Azure Blob en el primer uso; Lambda en VPC privada sin egress | Pre-cachear en build: `ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken_cache` + `RUN python -c "import tiktoken; tiktoken.get_encoding('cl100k_base')"` |
| 11 | Aurora con `version_id="default"` en todos los chunks pese a que Step Functions pasa `version_id` en payload | Lambda lee `VERSION_ID` solo desde env var (con default `"default"`), ignora el campo `event["version_id"]` que el state machine envía | En `lambda_handler`: `global VERSION_ID; if event.get("version_id"): VERSION_ID = event["version_id"]` |
| 12 | Aurora con `doc_type="unknown"` en todos los chunks pese a que Glue particiona los Parquet por `doc_type` | Cuando Spark hace `partitionBy("doc_type")`, esa columna queda **solo en el path del archivo**, no en cada row. `pyarrow.parquet.read_table()` no lee partition columns por default | Parsear el `doc_type` desde el S3 key con regex `r"/doc_type=([^/]+)/"` e inyectar en cada row antes de chunkear |

### Hallazgos de operación (no son bugs, pero merecen documentarse)

- **Cold start Lambda VPC-attached:** primer invoke ~47 s; tras tiktoken cache + warm ENI, ~3-5 s. Mejora dramática visible en `evidence/cloud/artifacts/cw_metrics.png`.
- **HNSW vs Seq Scan con corpus pequeño:** Postgres planner elige Seq Scan para 5 chunks porque el cost (0..11.12) es menor que HNSW (8.36..49.48). Esto es **correcto** — HNSW se justifica con corpus > 10K vectores.
- **Total iteraciones para llegar a SUCCEEDED:** 5. Bugs aparecieron en orden: IaC (1-5) → Lambda image (6-7) → Runtime Lambda (8-12). Tiempo total del experimento: 4 horas.

---

## 3. Próximas mejoras posibles (priorizadas por impacto)

### Tier 1 — Antes de productivizar la Fase 1.1

| # | Mejora | Impacto | Esfuerzo |
|---|---|---|---|
| 1 | **Lambda Query + API Gateway** con filtro `version_id` activo | Habilita el endpoint para PyMEs y el rollback granular | M |
| 2 | **Backend remoto de Terraform** (S3 + DynamoDB lock) | Habilita trabajo en equipo y deploy seguro multi-developer | S |
| 3 | **IAM user con MFA en lugar de root** | Cierra el riesgo crítico #1 de SECURITY.md | XS |
| 4 | **Emitir métricas custom CloudWatch desde código** | Dashboard funcionalmente completo | XS |
| 5 | **CI/CD básico** (GitHub Actions) para build + push de imágenes Docker | Reproducibilidad y velocidad | S |
| 6 | **Detección y cleanup de documentos eliminados** | Higiene del corpus | S |

### Tier 2 — Mejoras de calidad y compliance avanzado

| # | Mejora | Impacto | Esfuerzo |
|---|---|---|---|
| 7 | **Chunker estructural custom** con `section_path` jerárquico | Citación CNBV de nivel cláusula | L |
| 8 | **Clasificador `doc_type` por contenido** (no solo filename) | Robustez en corpus crecientes | M |
| 9 | **AWS Textract para PDFs escaneados** | Inclusión de documentos OCR-pobre | M |
| 10 | **KMS Customer Managed Keys** | Compliance CNBV reforzado para Fase 2 | M |
| 11 | **Re-evaluación humana mensual con RAGAS** sobre 100 consultas etiquetadas | Garantía continua de KPI ≥ 80% / 95% | M |
| 12 | **VPC Interface Endpoints adicionales** (ECR, CloudWatch Logs) | Eliminar todo egress a internet | S |

### Tier 3 — Habilitadores de la tesis Economic Graph (Año 2-3)

| # | Mejora | Impacto |
|---|---|---|
| 13 | **LLM generativo para respuestas** (no solo retrieval) — Bedrock Claude / Llama sobre el índice | Convertir el sistema en un asistente de negocio para PyMEs |
| 14 | **Auto-RAG Optimizer Pattern con LLM Judge** para re-rankear top-5 | Subir precisión efectiva sin reentrenar embeddings |
| 15 | **Particionado de Aurora por `version_id`** | Drop de versión en O(1) cuando el corpus supere 100K |
| 16 | **Federated retrieval con Banco Acme** (scoring credit federado) | Conecta el primer eslabón de la tesis con el segundo |
| 17 | **Expansión a 8 verticales y 15 ciudades** (Año 2 del Business Case) | Crecimiento del corpus a 2,000+ docs |
| 18 | **Buró alternativo formal** (Año 5+) | Concreción de la tesis Economic Graph a nivel mercado |

### Tier 4 — Operacional / DevEx

| # | Mejora | Impacto |
|---|---|---|
| 19 | **Bastion EC2 / SSM Session Manager** para Aurora desde laptop sin VPN | Productividad del equipo DBA |
| 20 | **AWS Config + drift detection** | Detectar cambios manuales fuera de Terraform |
| 21 | **AWS Cost Anomaly Detection con email** | Refuerza la alarma de billing |
| 22 | **Distributed Map en Step Functions** para corpus > 1,000 Parquets | Escala horizontal del chunking |
| 23 | **Move repo fuera de OneDrive** | Cierre del riesgo bajo #3 de SECURITY.md |

---

## 4. Aprendizajes meta del proyecto

### 4.1 Lo que más cambió el resultado fue el contexto de Acme Co

El proyecto arrancó con un caso de uso genérico ("RAG sobre documentos técnicos"). La incorporación de los **5 Gammas estratégicos de Grupo Acme** (Dossier Ejecutivo Combinado, Economic Graph de la PyME, Business Case Marketplace, Dossier ICP PyME Digital, Casos de Valor Telcos) transformó completamente el alcance: el proyecto pasó de ser un ejercicio académico de RAG a ser **la plomería de datos del primer motor de instrumentación de una tesis Economic Graph de 7 años**. Esto no agregó código nuevo, pero hizo que cada decisión técnica se anclara a un KPI real: tiempo de onboarding de PyME Digital, subset financiero crítico CNBV ≥ 95% de precisión, integración futura con Banco Acme para scoring federado. **El contexto fue la mayor palanca de calidad del proyecto.**

### 4.2 La rúbrica académica y el caso de negocio NO entraron en conflicto

Una preocupación válida al inicio fue que enfocarse en el caso Acme Co (que prioriza marketplace + fintech) sacrificara los puntos de la rúbrica BSG (que prioriza el pipeline puro). En la práctica las dos demandas se reforzaron: el subset financiero crítico exige citación verificable (rúbrica) y exige Quality Gate con regla maestra (caso de negocio); el versionamiento auditable es requisito CNBV (caso) y componente #10 de la rúbrica. **Cuando el caso de negocio es serio, la rúbrica académica deja de ser un constraint y se vuelve una guía.**

### 4.3 El SSL inspection corporativo es una clase de problemas, no un evento

El proyecto sufrió 4 manifestaciones distintas del mismo problema (SSL inspection):
1. AWS CLI sin `--no-verify-ssl` falla
2. winget al instalar Terraform falla (msstore source)
3. Terraform↔plugin mTLS sobre localhost falla → `TF_DISABLE_PLUGIN_TLS=1`
4. Posiblemente AWS Go SDK del provider (mitigado por que terraform plan funcionó vía Direct Connect)

**Lección:** cuando se opera en redes corporativas con SSL inspection (ZScaler, Netskope, etc.), **planificar `AWS_CA_BUNDLE` + flags equivalentes en cada herramienta desde el día 0**, no descubrirlos en el camino. Y documentar todo en un `SECURITY.md` para que el siguiente desarrollador no pierda el tiempo.

### 4.4 OneDrive y `.git/` no se llevan bien

El repositorio vive en `C:\Users\Rog\OneDrive\BCG Institute\...` y se confirmaron al menos dos manifestaciones de incompatibilidad: el directorio `.terraform/` fue borrado por sync de OneDrive después de un `terraform init` exitoso (validado en `bsg-rag-infra-test` fuera de OneDrive). Para CI/CD, repos compartidos o cualquier uso productivo, **el repo debe vivir fuera de carpetas sincronizadas**. Para un proyecto académico single-user el riesgo es bajo y aceptado.

### 4.5 Terraform `templatefile()` valida la existencia del template en `terraform validate`

Esto es importante para CI/CD: si el template no está en la ruta correcta, **el validate falla**. No se descubre solo en plan. Esto guió la decisión de colocar `orchestration/state_machine.json.tpl` como sibling de `infra/` (no dentro) — coincide con el módulo path implícito.

### 4.6 El componente Docker se cubre mejor en dos imágenes

La rúbrica pide componentes Docker para chunker, embedding generator, indexer, etc. Hacer una imagen monstruosa con todo dentro hubiera sido más simple, pero **se eligieron dos imágenes específicas**: chunking (Lambda container) y indexer (ECS Fargate). Esto fuerza separación de responsabilidades, permite escalado independiente y exhibe dos patrones de despliegue distintos (Lambda container vs. ECS task). El costo (build twice, push twice) es marginal; el beneficio en claridad es alto.

### 4.7 La validación incremental ahorró bugs visibles

Cada commit hizo `terraform validate` (y a veces `terraform plan`) antes de push. Cuando el plan reveló problemas (templatefile mal ubicado, count[0] con depends_on), se detectaron antes de un commit a `main`. **Disciplina de validación = velocidad real, no fricción.**

---

## 5. Decisiones que se mantendrían y las que se cambiarían

### Se mantendrían sin pensarlo

- AWS como cloud único (compliance + integración)
- Bedrock Titan V2 sobre alternativas externas
- Aurora `pgvector` sobre vector stores especializados a este volumen
- Step Functions Standard para orquestación (no Express)
- Container image para Lambda con deps pesadas
- ECS Fargate arm64 para indexer batch
- Versionamiento por `version_id` propagado end-to-end
- Quality Gate con regla maestra financiera
- Documentación viva (docs/01-12) con anclaje a casos reales

### Se cambiarían

- **No empezar con cuenta root.** Cualquier proyecto AWS debería arrancar con IAM user + MFA desde el primer comando.
- **No hospedar repos Git en OneDrive.** Asumir que cualquier folder sincronizado es hostil al `.git/` y `.terraform/`.
- **Emitir métricas custom desde el día 1.** La instrumentación es trivial de agregar al inicio y dolorosa de retrofitear.
- **Backend remoto de Terraform desde el primer apply.** El `terraform.tfstate` local es deuda técnica desde el comando `init`.
- **CI/CD básico desde la primera imagen Docker.** Los `docker push` manuales son frágiles y se olvida bumpear el tag.
- **Test de chunking con un PDF real desde el primer día.** Toda la lógica de heurísticas (doc_type, vertical, criticality) se hubiera estresado con un set de 20 documentos reales en lugar de validar solo con `terraform plan`.

---

## 6. Cierre

El proyecto entregó un pipeline funcional, observable, versionado y reproducible, alineado simultáneamente a la rúbrica académica del Proyecto 12 de BSG Institute (92/100 puntos directos cubiertos) y al primer eslabón de la tesis Economic Graph de Grupo Acme / Acme Co para la PyME mexicana. Los gaps documentados (Lambda Query, métricas custom, chunker estructural) son explícitos y priorizados, y no comprometen el valor entregado para fase 1.

La principal pregunta abierta no es técnica sino estratégica: **¿el Comité Ejecutivo de Acme Co aprueba pasar a Fase 1.1 con la implementación de la Lambda Query y el endpoint para PyMEs?** Si la respuesta es sí, el pipeline está listo para sostener el lanzamiento comercial del Marketplace B2B PyME. Si la respuesta es "evaluemos contra el piloto de 100 PyMEs primero", el pipeline está listo para soportar a los asesores del hub que harán la curación humana en esos 90 días.

En ambos escenarios, **el activo de datos del Año 1 ya empezó a construirse en cada chunk indexado**.

---

**Documentos relacionados:**
- `01_caso_de_uso.md` — Caso de negocio anclado a Economic Graph
- `02_seleccion_embeddings.md` — Decisión Bedrock Titan V2
- `03_semantic_chunking_pattern.md` — Quality Gate y regla maestra financiera
- `04_arquitectura.md` — Arquitectura end-to-end
- `08_indexacion_aurora_pgvector.md` — Decisión Aurora + HNSW
- `09_versionamiento_observabilidad.md` — Trazabilidad y métricas
- `SECURITY.md` — Riesgos del entorno local
- `10_guia_usuario.md` — Operación PyMEs + asesores
- `11_guia_administrador.md` — Runbooks técnicos
