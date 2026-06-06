# Selección de Modelo de Embeddings e Infraestructura — Acme Co Hub PyMEs

**Documento:** 02 — Selección de modelo de embeddings
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:** Comité técnico de Acme Co + Comité Ejecutivo de Innovación

---

## Resumen ejecutivo

El motor de embeddings es la pieza que traduce texto en español del corpus del **Marketplace B2B PyME de Acme Co** — catálogos de agencias auditadas, contratos de Carrier Billing, políticas de scoring crediticio al 24% APR, dossiers ICP, casos de éxito por vertical y SLAs — en representaciones vectoriales para búsqueda semántica. La elección impacta directamente cinco frentes: **calidad de respuesta, costo recurrente, latencia, control regulatorio (LFPDPPP / INAI / CNBV / CONDUSEF) y complejidad operativa**.

Se evaluaron tres alternativas representativas del mercado: una **managed nativa de AWS** (Titan Text Embeddings V2 vía Bedrock), una **líder externa** (OpenAI `text-embedding-3-large`) y una **open-source self-hosted** (BGE-M3 de BAAI). La recomendación firme es **AWS Titan Text Embeddings V2 sobre Bedrock**, por su combinación de costo bajo, calidad multilingüe sólida, integración nativa con el resto del stack AWS, y — críticamente para Acme Co como parte de Grupo Acme — **garantías de compliance regulatorio mexicano y residencia de datos** que permiten manejar información contractual y financiera sensible de PyMEs sin trasladar datos fuera del perímetro de la cuenta AWS de la empresa.

---

## 1. Tabla comparativa

| Dimensión | **AWS Titan Embeddings V2** (Bedrock) | **OpenAI `text-embedding-3-large`** | **BGE-M3** (open-source, self-hosted) |
|---|---|---|---|
| **Modelo / versión** | `amazon.titan-embed-text-v2:0` | `text-embedding-3-large` | `BAAI/bge-m3` |
| **Dimensiones del vector** | 1024 (default), configurable a 512 o 256 | 3072 (reducible vía Matryoshka) | 1024 |
| **Tokens máximos por input** | 8,192 | 8,191 | 8,192 |
| **Soporte para español** | ✅ Bueno — entrenado en 100+ idiomas, sólido en castellano técnico y legal | ✅ Excelente — líder en benchmarks multilingües (MIRACL, MTEB) | ✅ Muy bueno — destacado en MTEB multilingüe |
| **Costo por 1M tokens (input)** | **USD 0.02** | USD 0.13 | USD ~0.03–0.15 (depende utilización GPU) |
| **Latencia típica (P50, batch=1)** | 50–150 ms | 200–500 ms (depende región/red) | 30–100 ms (GPU local) |
| **Throughput práctico** | Hasta 2,000 req/min con cuotas estándar (ampliable) | Tiers según plan; rate limits estrictos | Limitado por GPU dedicada |
| **Integración con AWS** | **Nativa** — IAM, VPC endpoints, CloudWatch, KMS, PrivateLink | Externa — requiere Secrets Manager + egress HTTPS + monitoreo aparte | Hosting propio en ECS/EC2/EKS + ops |
| **Control de datos / compliance** | Datos **no se usan** para entrenamiento. Permanecen en AWS. SOC 1/2/3, ISO 27001/17/18, HIPAA-eligible, PCI-DSS, GDPR-eligible | Datos enviados a OpenAI (zero data retention disponible en tier Enterprise) | **Control total** — los datos no salen del perímetro |
| **Operación / ops overhead** | Bajo — managed, sin servidores | Bajo — managed, pero externo a AWS | **Alto** — modelo, GPU, parches, escalado, observabilidad propias |
| **Predictibilidad de costo** | Alta — pago por token, sin mínimos | Alta — pago por token, sin mínimos | Baja — costo dominado por utilización de GPU (idle = caro) |
| **Lock-in** | Medio — específico AWS, pero el vector es estándar | Medio — específico OpenAI | Bajo — modelo portable, pesos en HuggingFace |
| **Tiempo a producción** | Horas (habilitar acceso al modelo + IAM) | Días (cuenta enterprise + compliance review) | Semanas (infra GPU + tuning + ops) |

> **Nota sobre costos:** los valores corresponden a precios públicos vigentes al momento de elaboración del documento (mayo 2026). Verificar siempre en la página oficial de pricing antes del compromiso presupuestario, ya que los precios de Bedrock y OpenAI han mostrado tendencia a la baja y a la introducción de tiers nuevos.

---

## 2. Justificación de la elección: AWS Titan Embeddings V2 + Bedrock

### 2.1 Encaja con el perfil del corpus del Marketplace B2B PyME

El corpus combina **cuatro registros lingüísticos** que conviven en el mismo índice: (a) terminología contractual legal en español de México (cláusulas Carrier Billing, SLAs, scoring 24% APR), (b) lenguaje técnico de telecomunicaciones de los manuales de AcmeCo Negocios y Aliado Telco, (c) lenguaje comercial-aspiracional de los dossiers ICP "PyME Digital" y casos de éxito por vertical (Moda Ética, Skincare D2C, Joyería de Diseño, Mascotas premium), y (d) material formativo / FAQs orientado a PyMEs digital-first. Titan V2 está entrenado sobre un corpus multilingüe amplio que cubre adecuadamente los cuatro registros. Para un caso de uso donde la métrica objetivo es "el top-5 contiene la respuesta correcta" — y, en el subset financiero crítico, top-5 ≥ 95% — Titan V2 entrega calidad equivalente a alternativas más costosas dentro del margen de error de la evaluación humana sobre 100 consultas mensuales segmentadas por las 4 verticales operativas.

### 2.2 La economía es decisiva a escala del hub

A los volúmenes proyectados (5M tokens en fase 1, 50M tokens en fase 2 considerando reindexaciones mensuales) el costo total de embeddings con Titan V2 se mantiene en el orden de **decenas de centavos a un par de dólares por ciclo de reindexación**. OpenAI multiplica ese costo por ~6.5x y BGE-M3 self-hosted, contra-intuitivamente, **sale más caro a este volumen** porque una GPU debe estar reservada incluso cuando no procesa (idle cost). El costo marginal de Titan no es decisivo en términos absolutos — todas las alternativas son baratas — pero **la predictibilidad** del modelo pay-per-token elimina sorpresas presupuestarias frente al comité.

### 2.3 Compliance regulatorio mexicano y residencia de datos sin trabajo adicional

El corpus del hub contiene **tres clases de información regulada** que vuelven el compliance no negociable:

1. **Datos personales de PyMEs y de sus titulares** (LFPDPPP — Ley Federal de Protección de Datos Personales en Posesión de los Particulares, supervisada por el INAI). Aplica a contratos Carrier Billing, dossiers ICP que perfilan a "PyME Digital" y a su negocio, y casos de éxito que mencionan PyMEs identificables.
2. **Información sobre productos financieros** (scoring crediticio, tasa 24% APR, comisión de apertura 3%, cláusulas de Carrier Billing). Al escalar la cartera, esto cae bajo supervisión de **CNBV / CONDUSEF**, y las respuestas a usuarios deben ser trazables al documento contractual exacto vigente al momento de la consulta.
3. **Información confidencial de terceros del ecosistema Grupo Acme** (potencial integración futura con Banco Acme para scoring federado y warehouse lending), lo que añade un perímetro de control intra-grupo.

Con Bedrock, los textos enviados a embeddings **no se usan para entrenar modelos**, permanecen dentro del perímetro de la cuenta AWS de Acme Co, viajan exclusivamente por VPC Endpoints sin tránsito por internet pública, y cada invocación queda registrada automáticamente en CloudTrail. Esto habilita de forma directa el **Consent Ledger granular** y el **Comité de Privacidad** que la visión Economic Graph requiere desde el Año 1 (decisiones #5 y #2 de las 8 decisiones de primer trimestre del Dossier Ejecutivo).

OpenAI ofrece una postura comparable únicamente en su tier Enterprise, que añade revisión legal, contrato adicional, compromisos mínimos y dependencia de un proveedor externo a Grupo Acme — fricción innecesaria y exposición regulatoria adicional para un proyecto que comienza con 500 documentos sensibles. BGE-M3 self-hosted da control total pero traslada toda la responsabilidad de compliance, parcheo de modelo y monitoreo de seguridad al equipo de Acme Co, sin beneficio diferencial en el caso de uso.

### 2.4 Integración nativa con el resto del pipeline reduce TCO

El pipeline ya está diseñado sobre S3, Glue, Lambda, Aurora `pgvector`, DynamoDB, Step Functions y CloudWatch. Cada uno de estos servicios se autentica contra Bedrock mediante un **único IAM role** con la acción `bedrock:InvokeModel`, sin secretos compartidos, sin egress de red hacia internet, sin servicios de monitoreo paralelos. Para OpenAI habría que mantener llaves en Secrets Manager con rotación, abrir egress controlado vía NAT Gateway, e instrumentar métricas y costos por fuera. Para BGE-M3 habría que sumar ECS/EKS con GPU, gestión de imagen del modelo, autoscaling y un stack de observabilidad propio. La integración nativa **reduce horas de operación recurrentes** que son el costo oculto real del pipeline.

### 2.5 Trade-off explícito que se asume

La elección **no es óptima en tres puntos** y conviene declararlo:

1. **Calidad de embedding** en benchmarks puros (MTEB): OpenAI `text-embedding-3-large` y BGE-M3 muestran ventaja marginal en algunas subtasks de retrieval multilingüe. Se acepta porque la diferencia desaparece en evaluación humana orientada al caso de uso real del hub.
2. **Dimensiones del vector**: 1024 vs. 3072 de OpenAI implica menor capacidad teórica de representación. Se acepta porque reduce 3x el almacenamiento en `pgvector` y acelera la búsqueda ANN.
3. **Lock-in a AWS**: Titan no es portable a otros clouds sin reindexar. Se acepta porque el resto del stack ya está en AWS y la migración hipotética representa un riesgo bajo a 18 meses.

---

## 3. Proyección de costos por fase

| Concepto | Fase 1 (500 docs) | Fase 2 (5,000 docs) |
|---|---|---|
| Tokens estimados por indexación completa (avg. 10K tok/doc) | 5,000,000 | 50,000,000 |
| Reindexaciones por mes | 1 | 2 |
| Tokens mensuales de indexación | 5M | 100M |
| **Costo mensual de embeddings — Titan V2** | **USD 0.10** | **USD 2.00** |
| (Comparativa — OpenAI `3-large`) | USD 0.65 | USD 13.00 |
| (Comparativa — BGE-M3 self-hosted, g5.xlarge) | ~USD 100 idle | ~USD 500 idle |
| Tokens por consulta (query embedding) | ~50 | ~50 |
| Consultas mensuales | 1,500 | 25,000 |
| Tokens mensuales de queries | 75,000 | 1,250,000 |
| **Costo mensual de queries — Titan V2** | **USD 0.0015** | **USD 0.025** |
| **TOTAL embeddings/mes — Titan V2** | **≈ USD 0.10** | **≈ USD 2.03** |

> El componente de embeddings representa **menos del 1%** del presupuesto total mensual proyectado (USD 500 fase 1 / USD 1,500 fase 2). Aurora `pgvector` y Glue son los dominantes del costo.

---

## 4. Implicaciones para el resto del pipeline

Esta decisión fija parámetros que aterrizan en componentes posteriores del proyecto:

| Decisión | Valor | Componente afectado |
|---|---|---|
| Modelo invocado | `amazon.titan-embed-text-v2:0` | Lambda de chunking (Prompt 7) |
| Región Bedrock | `us-east-1` | IAM, VPC endpoints, latencia |
| **Dimensión del vector** | **1024** | Aurora DDL: `vector(1024)` (no `vector(1536)`) — corregir en Prompt 8 |
| Tokens máximos por chunk | ≤ 8,192 (margen real 1,500) | Estrategia de chunking dinámico |
| IAM action requerida | `bedrock:InvokeModel` | IAM role Lambda + ECS Fargate loader |
| Strategy de batching | Hasta 50 textos por invocación (límite Bedrock) | Optimización en Lambda |
| Manejo de errores | Reintentos con backoff exponencial + jitter ante `ThrottlingException` | Lambda con `botocore.config.Config(retries=...)` |
| Cuota inicial | 2,000 req/min (revisable vía Service Quotas) | Diseño de paralelización |

> **Ajuste pendiente:** el Prompt 8 del archivo `PROMPTS_ClaudeCode_Proyecto12_AcmeCo.md` menciona `embedding vector(1536)` (dimensión de Titan V1). Al usar **V2 con 1024 dimensiones** debemos actualizar el DDL de Aurora a `vector(1024)` y el índice ANN correspondiente. Este cambio se documenta y aplica en el Prompt 8.

---

## 5. Habilitación de acceso al modelo en Bedrock

Bedrock requiere **habilitar explícitamente el acceso a cada modelo** desde la consola antes de invocarlo (paso fácil de olvidar y bloqueante). Pasos para Acme Co:

1. AWS Console → Bedrock → `Model access` (región `us-east-1`)
2. Solicitar acceso a **Amazon → Titan Text Embeddings V2**
3. Confirmar el caso de uso (no requiere aprobación manual para modelos de Amazon)
4. Validar con CLI: `aws bedrock list-foundation-models --region us-east-1 --by-provider amazon`
5. Validar invocación mínima de prueba contra `amazon.titan-embed-text-v2:0`

---

## 6. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Cuota de Bedrock insuficiente en pico de reindexación | Media | Medio | Solicitar aumento de quota anticipado; throttle en Lambda con SQS buffer |
| Calidad de embedding insuficiente para español técnico-legal | Baja | Alto | Evaluación piloto con 50 docs reales antes de comprometer fase 1 |
| Cambio de pricing de Bedrock | Baja | Bajo | Costo absoluto es marginal — incluso 5x sigue dentro del techo presupuestario |
| Drift de calidad por evolución del corpus | Media | Medio | Re-evaluación trimestral con RAGAS; benchmark interno de 100 consultas etiquetadas |
| Bloqueo regional (Bedrock no disponible en alguna región objetivo) | Baja | Medio | `us-east-1` y `us-west-2` son las regiones más completas; descartar otras para Bedrock |

---

## 7. Recomendación final

**Adoptar AWS Titan Text Embeddings V2 (`amazon.titan-embed-text-v2:0`) en `us-east-1` con vectores de 1024 dimensiones** como motor único de embeddings del pipeline en fase 1 y fase 2 del Marketplace B2B PyME de Acme Co. La decisión apuntala simultáneamente la operación del Año 1 del Business Case (1,000 PyMEs activas, $21.9M GMV) y la foundation técnica del LLM asistente de negocio que la tesis Economic Graph contempla para el Año 2-3.

Revisión obligatoria al cierre de fase 1 contra los KPIs del documento `01_caso_de_uso.md`, con dos criterios explícitos de re-evaluación:

- **Calidad general:** si la precisión top-5 cae por debajo del 80% en evaluación humana.
- **Calidad crítica (subset financiero):** si la precisión top-5 en consultas sobre Carrier Billing, 24% APR y scoring crediticio cae por debajo del 95% — umbral no negociable por el riesgo CNBV/CONDUSEF.

---

**Documentos relacionados:**
- `01_caso_de_uso.md` — KPIs y volumetría que justifican el cálculo de costos
- `03_semantic_chunking_pattern.md` — Estrategia de chunking que respeta el límite de 8,192 tokens
- `04_arquitectura.md` — Integración de Bedrock con Lambda, IAM y VPC
- `08_indexacion_aurora_pgvector.md` — DDL ajustado a `vector(1024)`
