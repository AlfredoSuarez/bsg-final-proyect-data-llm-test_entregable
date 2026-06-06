# Caso de Uso de Negocio — Plataforma de Conocimiento del Hub PyMEs y Marketplace B2B de Acme Co

**Documento:** 01 — Caso de Uso y KPIs
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 2.0
**Fecha:** 2026-05-24
**Audiencia:** Comité Estratégico Acme Co / Grupo Acme — Innovación, Producto, Riesgo y Compliance

---

## Resumen ejecutivo

Acme Co está ejecutando una transición estratégica de **operador de telecomunicaciones premium** a **capa de observabilidad, crédito y activación comercial de la PyME mexicana** — el "Economic Graph de la PyME" — apalancada en los activos del ecosistema Grupo Acme (FTTH nacional, Carrier Billing, Addressable TV Ads, Banco Acme, Retail Acme, TV Azteca, Totalshop).

El primer motor de instrumentación de esa tesis es el **Marketplace B2B PyME + Fintech Embebida** que arranca operación en 2026 con la meta Año 1 de **1,000 PyMEs activas, $21.9M MXN de GMV y $10M MXN de revenue**. Este marketplace opera con un corpus documental que crece rápido y se vuelve crítico para el funcionamiento del hub: catálogos de agencias auditadas, paquetes de servicio verticalizados, contratos de Carrier Billing, políticas de scoring crediticio (24% APR), SLAs, dossiers ICP, casos de éxito y manuales operativos.

Este proyecto propone construir un **pipeline cloud-nativo en AWS** que ingesta, normaliza, segmenta semánticamente y vectoriza todo ese corpus, e indexa el resultado en Aurora PostgreSQL con `pgvector`. Sobre ese índice se habilita una **interfaz de búsqueda vectorial con citación verificable** que actúa como capa de conocimiento del hub para PyMEs, asesores comerciales, equipo de riesgo, agency ops y customer success — y que sienta la plomería de datos para los productos LLM y data products que la tesis Economic Graph contempla para los Años 2–3 y posteriores.

La inversión es marginal en costo cloud (≤ USD 500/mes fase 1) y se justifica por tres palancas: **descarga operativa del hub para atender más PyMEs por asesor**, **trazabilidad y compliance LFPDPPP/CNBV** sobre cada respuesta entregada, y **construcción del primer eslabón del activo de datos** del Economic Graph.

---

## 1. Contexto estratégico

### 1.1 Posición actual de Acme Co

| Métrica | Valor (cierre 2025) | Fuente |
|---|---|---|
| Suscriptores activos | 5.44 M (incluye ~67k PyMEs) | IR AcmeCo |
| Cobertura FTTH | 100% — única red 100% fibra masiva en México | Ookla, nPerf |
| Ingresos totales | Ps. 45,550 M MXN | BMV |
| EBITDA | Ps. 20,608 M · margen 45% | BMV |
| Pertenencia | Subsidiaria de Corporación RBS (97.7%) · **Grupo Acme** | Estructura corporativa |

### 1.2 La tesis Economic Graph

Acme Co deja de ser un telco premium y se convierte en la **capa de observabilidad, crédito y activación comercial de la PyME mexicana**. El marketplace y la fintech embebida no son el producto: son la **instrumentación**. El producto real es el **grafo de datos** monetizable como marketplace, fintech y data products.

Cinco motores del sistema, dos nuevos y tres ya operativos:

1. **Marketplace B2B de Marketing** (nuevo, MVP en producción) — intención de crecimiento + ROI de campañas
2. **Fintech embebida PyME** (nuevo) — Carrier Billing 8% fee + crédito 24% APR
3. **Totalshop** (operativo) — demanda consumidor + comportamiento de compra
4. **AcmeCo Negocios + Aliado Telco** (operativo) — baseline operativo de PyMEs
5. **Addressable TV Ads** (operativo) — outcome publicitario, único en México

### 1.3 Meta Año 1 del Marketplace B2B PyME (Business Case)

| Línea | Conservador | **Base** | Optimista |
|---|---|---|---|
| PyMEs activas al cierre | 500 | **1,000** | 1,500 |
| GMV anual | $10.9M MXN | **$21.9M MXN** | $32.8M MXN |
| Revenue total | $5.0M MXN | **$10.0M MXN** | $15.0M MXN |
| EBITDA (Modelo A apalancado) | $0 | **$2.1M MXN (21%)** | $5.3M MXN |
| LTV / CAC | 20× | **28×** | 35× |
| Cartera crediticia vigente | $2.9M MXN | **$5.8M MXN** | $8.7M MXN |

### 1.4 El rol específico de este proyecto en la tesis

Este proyecto entrega el **primer eslabón de plomería de datos** que la tesis Economic Graph requiere: un pipeline reproducible, versionado y auditable que indexa todo el conocimiento operativo del hub para hacerlo consultable con citación verificable. Sin este eslabón:

- El hub no puede escalar de 100 a 1,000 PyMEs sin crecimiento lineal de personal.
- Las respuestas a PyME Digital (ICP) sobre Carrier Billing y 24% APR no son trazables → riesgo CNBV/CONDUSEF.
- No se puede construir el LLM asistente de negocio (Año 2–3) sobre un corpus que no está normalizado, segmentado e indexado.

---

## 2. Problema de negocio actual

El hub PyMEs opera ya con tres tensiones medibles que el sistema RAG resuelve:

### 2.1 Asfixia operativa al escalar el funnel

El piloto del marketplace fija como objetivo de 90 días **100 PyMEs registradas, 60 con campaña cerrada, 40% con financiamiento activo**. Cada PyME genera consultas en múltiples puntos del funnel: comparación de paquetes ("Arranque Social", "Pre-campaña Hot Sale"), términos de Carrier Billing, criterios de auditoría de agencias, dossiers ICP de su vertical, casos de éxito comparables. Responder esto manualmente con un equipo lean (Modelo A apalancado) **es el cuello de botella estructural** para alcanzar la meta de 1,000 PyMEs activas.

### 2.2 Riesgo regulatorio sobre información financiera

El marketplace ofrece financiamiento al **24% APR** vía Carrier Billing — tasa 3× menor que tarjeta corporativa promedio (33–42%) pero sujeta a regulación CNBV/CONDUSEF al escalar la cartera. Las respuestas comerciales sobre el costo del crédito, las cláusulas y los criterios de scoring **deben ser trazables, consistentes y citadas** al documento contractual exacto vigente al momento de la consulta. Una respuesta inconsistente entre dos asesores sobre la misma cláusula es un riesgo material.

### 2.3 Dependencia de conocimiento tácito en perfiles clave

El piloto opera con un equipo de ~11.5 FTEs (Modelo B) o equivalente apalancado (Modelo A). La operación sobre 4 verticales × 5 ciudades × N paquetes × N agencias auditadas genera un grafo de conocimiento que reside parcialmente en cabezas de pocos asesores senior. Cuando esos perfiles no están disponibles, las respuestas a PyMEs se ralentizan o se vuelven inconsistentes. **Para escalar a Año 3 (1,000–3,000 PyMEs activas) ese cuello hay que codificarlo.**

---

## 3. Sistema propuesto: Pipeline RAG documental del hub

Pipeline cloud-nativo en AWS que ingesta el corpus completo del hub, normaliza y segmenta semánticamente cada documento, genera embeddings con **AWS Bedrock Titan**, indexa los vectores en **Aurora PostgreSQL con `pgvector`**, versiona cada índice en DynamoDB y expone una interfaz de búsqueda vectorial con citación verificable.

**Capas funcionales:**

| Capa | Descripción | Componente AWS |
|---|---|---|
| Ingesta | Carga automática de PDFs/DOCX/HTML desde fuentes oficiales del hub | S3 (raw) |
| ETL | Extracción de texto, limpieza, normalización UTF-8, deduplicación de headers/footers | AWS Glue |
| Chunking semántico | Segmentación adaptativa por estructura del documento (500–1500 tokens, overlap 200), con metadata enriquecida | AWS Lambda |
| Embeddings | Vectorización con Bedrock Titan Embeddings V2 (1024 dim) | Bedrock |
| Indexación | Almacenamiento en `pgvector` con índice HNSW para búsqueda ANN | Aurora PostgreSQL |
| Versionamiento | Registro de cada versión del índice con hash, volumen, modelo y costo | DynamoDB |
| Orquestación | Pipeline reintetable y tolerante a fallos | Step Functions |
| Observabilidad | Logs, métricas, costos, dashboard | CloudWatch |
| Loader containerizado | Carga a Aurora desde Parquet (cubre componente Docker de la rúbrica) | ECS Fargate |

**Habilidad clave entregada al hub:** una respuesta a cualquier consulta sobre el marketplace incluye **siempre** la cita exacta al documento fuente y su versión vigente. Esa propiedad es el cimiento del compliance LFPDPPP/CNBV y del LLM asistente de negocio que se construye encima en Año 2–3.

---

## 4. Stakeholders

| Stakeholder | Rol en el proyecto | Beneficio principal |
|---|---|---|
| **PyMEs "PyME Digital"** (ICP) | Usuarios finales del sistema de consulta | Autoservicio para entender catálogo de paquetes, financiamiento, criterios de auditoría — disponible 24/7 |
| **Asesores comerciales del hub** | Operadores del funnel del piloto | Respuestas consistentes y citadas; capacidad de atender 3× más PyMEs por asesor |
| **Equipo Risk / Credit** | Scoring del 24% APR y monitoreo de cartera | Acceso ágil a políticas de scoring vigentes y precedentes documentados |
| **Agency Ops** | Auditoría y curación de agencias del marketplace | Trazabilidad de criterios de auditoría y de casos resueltos |
| **Customer Success** | Atención post-venta a PyMEs activas | Resolución de tickets nivel 1 sin escalar — meta ≥ 40% Año 1, ≥ 70% Año 3 |
| **Comité Estratégico Acme Co / Grupo Acme** | Sponsor de la tesis Economic Graph | Plomería de datos del primer motor; foundation para LLM-PyME y data products |
| **Banco Acme** | Warehouse lender / co-lender del crédito PyME | Información consistente sobre PyMEs financiadas; integración futura con scoring federado |
| **Compliance — LFPDPPP / INAI / CNBV / CONDUSEF** | Validación regulatoria | Citación verificable y auditoría completa de cada respuesta sobre productos financieros |
| **Equipo técnico Acme Co (CDO + Data Eng)** | Co-propietarios del pipeline | Plataforma versionada, observable, reproducible — fundación del data lake del Año 2 |

---

## 5. Alcance documental — el corpus real del hub Año 1

| Tipo de documento | Volumen estimado | Característica relevante |
|---|---|---|
| Catálogo de agencias auditadas + descripciones de paquetes ("Arranque Social", "Pre-campaña Hot Sale", etc.) | ~80 docs | PDFs y HTML, actualización frecuente (catálogo vivo) |
| Contratos Carrier Billing + términos de financiamiento (24% APR, apertura 3%) | ~50 docs | DOCX/PDF, cláusulas críticas, riesgo CNBV/CONDUSEF |
| Dossiers ICP (PyME Digital + perfiles secundarios: Carlos Restaurantero, Laura Wellness, Sofía Consultora, Retail Físico) | ~40 docs | PDFs estructurados, foundation para targeting comercial |
| Manuales técnicos de AcmeCo Negocios + Aliado Telco | ~80 docs | PDFs técnicos, contenido estable |
| Casos de éxito por vertical (Moda Ética, Skincare D2C, Joyería, Mascotas) + ejemplos de startups incubadas (BeautyDesk, Mesero IA, Divya Brow Bar, etc.) | ~60 docs | PDFs comerciales, alto valor para asesoría |
| Políticas de scoring crediticio + criterios de aprobación | ~30 docs | PDFs internos, alta sensibilidad (LFPDPPP) |
| SLAs + términos de servicio del marketplace | ~40 docs | DOCX/PDF, cláusulas legales, requieren trazabilidad exacta |
| Procesos operativos del marketplace (onboarding agencia, auditoría, resolución de conflictos, default management) | ~50 docs | PDFs internos, soporte a Agency Ops y Customer Success |
| Material formativo / FAQs para PyMEs (objeciones, disparadores de compra, copy hooks) | ~70 docs | HTML/PDF, alta frecuencia de consulta y de actualización |
| **Total fase 1** | **~500 docs** | |

---

## 6. Volumetría y crecimiento alineados con la tesis

| Métrica | Año 1 (lanzamiento Marketplace) | Año 3 (consolidación) | Año 7 (Economic Graph maduro) |
|---|---|---|---|
| Documentos indexados | 500 | 2,000 | 5,000+ |
| Chunks estimados (avg. 8/doc) | ~4,000 | ~16,000 | ~40,000+ |
| Embeddings generados | ~4,000 | ~16,000 | ~40,000+ |
| Verticales operativas | 4 (Moda, Belleza, Joyería, Mascotas) | 8 (+ Restaurantes, Wellness, Consultoría, Retail Físico) | 20+ (multi-tenant por industria) |
| Ciudades cubiertas | 5 (GDL, CDMX, MTY, QRO, MID) | 15+ | Nacional + 2 países LatAm |
| PyMEs activas en el hub | 1,000 | 3,000 | 50,000+ |
| Consultas mensuales | 1,500 | 8,000 | 100,000+ |
| Usuarios concurrentes pico | 10 | 50 | 500+ |
| Reindexaciones por mes | 1 | 2 | 4 |

> El diseño contempla crecimiento de 10× sin re-arquitectura, gracias a `pgvector` (escalable vertical y por particiones), separación de capas serverless (Glue + Lambda) y al loader containerizado en ECS Fargate.

---

## 7. KPIs y metas de éxito

### 7.1 KPIs técnicos del pipeline

| KPI | Meta v1 (lanzamiento) | Meta v2 (optimizada) | Cómo se mide |
|---|---|---|---|
| Tiempo de indexación completa (500 docs) | ≤ **60 min** | ≤ **30 min** | Step Functions execution duration |
| Latencia búsqueda vectorial (k=5) | P95 ≤ **800 ms** | P95 ≤ **400 ms** | CloudWatch custom metric en endpoint |
| Tasa de errores de parsing | ≤ **3%** | ≤ **1%** | Docs fallidos / total ingestados |
| Cobertura de metadatos (vertical + tipo + versión) | ≥ **90%** | ≥ **98%** | Auditoría sobre `documents_embeddings` |
| Disponibilidad del endpoint | ≥ **99.0%** | ≥ **99.5%** | CloudWatch uptime |

### 7.2 KPIs de calidad de respuesta

| KPI | Meta v1 | Meta v2 | Cómo se mide |
|---|---|---|---|
| Precisión top-5 (la respuesta correcta está en los 5 chunks recuperados) | ≥ **80%** | ≥ **90%** | Evaluación humana sobre 100 consultas/mes |
| **Precisión top-5 en consultas financieras (Carrier Billing, 24% APR, scoring)** | ≥ **95%** | ≥ **98%** | Subset crítico para compliance — evaluación humana mensual |
| CSAT del sistema de consulta | ≥ **4.0 / 5** | ≥ **4.5 / 5** | Encuesta post-consulta opcional |
| Tasa de respuestas con cita verificable | **100%** | **100%** | Diseño del sistema garantiza citación obligatoria |
| Cobertura por vertical (precisión equivalente en las 4 verticales) | ≤ **10 pp** dispersión | ≤ **5 pp** dispersión | Evaluación segmentada por vertical |

### 7.3 KPIs de negocio (anclados al Business Case del Marketplace Año 1)

| KPI | Meta 6 meses | Meta 12 meses (cierre Año 1) | Conexión con tesis |
|---|---|---|---|
| PyMEs atendidas por asesor (productividad) | +30% | **+80%** | Habilita meta 1,000 PyMEs activas con equipo lean |
| Tiempo de onboarding promedio de PyME Digital | −25% | **−50%** | Disparador clave del piloto de 100 PyMEs en 90 días |
| Consultas resueltas sin escalar a humano | ≥ 40% | **≥ 60%** | Descarga operativa del equipo de Customer Success |
| Densidad de señal por PyME / mes (eventos capturados) | ≥ 6 | **≥ 8** | Meta directa del Business Case Año 1 |
| NPS del hub PyMEs | +10 pts vs baseline | **+20 pts vs baseline** | Alineado con NPS objetivo ≥ 50 del piloto |
| Cobertura de las 4 verticales con señal activa | 4/4 | **4/4** | Requisito de la tesis Año 1 |

### 7.4 KPIs de costo

| KPI | Meta fase 1 (500 docs) | Meta fase 2 (5,000 docs) |
|---|---|---|
| **Costo mensual AWS total** | ≤ **USD 500/mes** | ≤ **USD 1,500/mes** |
| Costo por 1,000 embeddings generados | ≤ USD 0.20 | ≤ USD 0.15 |
| Costo por consulta vectorial | ≤ USD 0.001 | ≤ USD 0.0005 |
| Costo por documento indexado (end-to-end) | ≤ USD 0.05 | ≤ USD 0.02 |

> **Notas sobre el costo objetivo:** USD 500/mes en fase 1 contempla Aurora PostgreSQL Serverless v2 con escalado a cero en horarios valle, Bedrock Titan Embeddings bajo demanda, Glue 1×/mes para reindexación completa, ECS Fargate del loader bajo demanda, y volumetría de consultas de 1,500/mes. Monitoreo en tiempo real vía AWS Cost Anomaly Detection. Como referencia: el componente de embeddings representa menos del 1% del costo total — el dominante es Aurora.

---

## 8. Criterios de aceptación de la fase 1

El proyecto se considera **exitoso en su fase 1** si al cierre cumple simultáneamente:

1. ≥ 95% de los 500 documentos están correctamente ingestados, segmentados e indexados, con representación de las **4 verticales operativas** (Moda Ética, Skincare D2C, Joyería de Diseño, Mascotas premium).
2. El pipeline completo se ejecuta de extremo a extremo de forma automática, reintentable y observable.
3. El endpoint de búsqueda vectorial responde dentro del SLA P95 ≤ 800 ms y el endpoint exhibe ≥ 99.0% de disponibilidad.
4. La precisión top-5 supera el 80% global y el **95% en el subset crítico de consultas financieras** (Carrier Billing, 24% APR, scoring).
5. Existe versionamiento auditable de al menos 3 versiones del índice, con demo de los flujos *add*, *reprocess* y *delete*.
6. Cada respuesta del endpoint incluye **cita verificable obligatoria** al documento fuente y a su versión vigente.
7. El costo mensual real está dentro del techo de USD 500/mes comprometido.
8. Las Guías de Usuario (PyMEs y asesores) y de Administrador (equipo técnico Acme Co) están publicadas y validadas por los stakeholders.

---

## 9. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| **LFPDPPP / INAI** — tratamiento de datos personales de PyMEs en consultas y dossiers ICP | Alta | Alto | Aurora en VPC privada · IAM mínimo · auditoría de consultas · alineación con Comité de Privacidad del Año 1 (8 decisiones del Dossier Ejecutivo) |
| **CNBV / CONDUSEF** — info sobre productos financieros (24% APR, scoring) consultable sin trazabilidad | Alta | Alto | Citación verificable obligatoria · versionamiento por hash · subset crítico con KPI de precisión ≥ 95% |
| Calidad heterogénea de PDFs origen (catálogos en HTML, contratos en DOCX, scans con OCR pobre) | Alta | Medio | Quality gate en chunking · reporte de documentos rechazados · re-evaluación trimestral |
| Drift de catálogo del marketplace (cambia mensualmente) | Alta | Medio | Reindexación programada mensual · versionamiento por hash del dataset · cache de embeddings reusables |
| Cuotas de Bedrock insuficientes en pico de reindexación | Media | Medio | Solicitud anticipada de aumento de quota · throttle en Lambda con SQS buffer |
| Calidad de embedding insuficiente para español técnico-legal-financiero | Baja | Alto | Evaluación piloto con 50 docs reales antes de comprometer fase 1 · re-evaluación contra RAGAS trimestral |
| Adopción lenta por parte de PyME Digital (UX del endpoint) | Media | Alto | Integración con flujos existentes del hub · onboarding guiado · A/B testing de respuestas |

---

## 10. Conexión con la hoja de ruta del Economic Graph

| Año | Hito del proyecto RAG | Hito de la tesis Economic Graph |
|---|---|---|
| **Año 1** | Pipeline operativo · 500 docs · 4 verticales · citación verificable | 1,000 PyMEs activas · $21.9M GMV · plomería de datos en construcción |
| **Año 2** | Expansión a 2,000 docs · 8 verticales · LLM asistente de negocio sobre el índice | Modelo de crédito v2 con señal transaccional · primeros data products externos |
| **Año 3** | Multi-tenant por industria · re-indexación bisemanal · evaluación RAGAS continua | PyME Pulse · Campaign Benchmark API · Alt Credit Scoring API · Data como ≥ 10% de ingresos |
| **Año 5+** | Federated retrieval con Banco Acme · 20+ verticales | Buró alternativo formal · expansión LatAm · Data como ≥ 20% de ingresos |

---

## 11. Recomendación al Comité

Aprobar el inicio de la **fase 1 del Pipeline RAG documental del hub** como entregable de plomería de datos del primer motor de la tesis Economic Graph. La inversión cloud (≤ USD 500/mes) es marginal frente al techo presupuestario del Business Case Año 1 (~$8M MXN incrementales del Modelo A) y entrega tres outputs no-negociables para la operación del marketplace:

1. **Capacidad operativa** para alcanzar la meta de 1,000 PyMEs activas con el equipo lean del Modelo A.
2. **Cumplimiento regulatorio** sobre productos financieros vía citación verificable obligatoria.
3. **Foundation técnica reutilizable** para los productos LLM y data products del Año 2 y posteriores.

Se recomienda revisión de avances en cada checkpoint del Business Case Año 1 (cierre de cohorte de 100 PyMEs, mes 4, mes 7 y cierre de Año 1), con criterio de re-evaluación si la precisión top-5 cae por debajo del 80% global o del 95% en el subset financiero crítico.

---

**Documentos relacionados:**
- `02_seleccion_embeddings.md` — Comparativa de modelos y justificación de Bedrock Titan
- `03_semantic_chunking_pattern.md` — Diseño del patrón de chunking semántico
- `04_arquitectura.md` — Arquitectura AWS completa e IaC
- `08_indexacion_aurora_pgvector.md` — DDL de `pgvector` con `vector(1024)`
- `10_guia_usuario.md` — Guía de Usuario para PyMEs PyME Digital y asesores del hub
- `11_guia_administrador.md` — Guía de Administrador para equipo técnico Acme Co

**Fuentes externas (Gamma Acme Co — confidencial Grupo Acme):**
- *Acme Co · Dossier Ejecutivo Combinado* (Abril 2026)
- *Acme Co como Economic Graph de la PyME Mexicana* (Visión Estratégica 7 años)
- *Business Case Año 1 — Marketplace B2B PyME*
- *Dossier ICP · Perfil Ideal de Cliente PyME de Primera Ola*
- *Casos de Creación de Valor: Telcos e Inversores que Apostaron por Startups*
