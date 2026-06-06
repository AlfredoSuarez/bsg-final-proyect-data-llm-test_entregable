# Guía de Usuario — Sistema de Conocimiento del Marketplace B2B PyME

**Documento:** 10 — Guía de Usuario
**Proyecto:** Plataforma de Conocimiento del Hub PyMEs y Marketplace B2B de Acme Co
**Versión:** 1.0
**Fecha:** 2026-05-24
**Audiencia:**
- **Sección A** — PyMEs incubadas (perfil "PyME Digital")
- **Sección B** — Asesores comerciales del hub de incubación de Acme Co
- **Sección C** — Customer Success y Agency Ops

---

## Para qué sirve el sistema

El **Sistema de Conocimiento del Marketplace** es la fuente única, citada y trazable de información sobre todos los servicios, paquetes, contratos, casos de éxito y procesos operativos del hub de Acme Co. Responde en segundos a preguntas que antes requerían buscar entre documentos dispersos o consultar a varias personas del equipo.

**Cada respuesta del sistema incluye una cita verificable** al documento fuente — número de versión, nombre del archivo, sección y página. Esto es crítico cuando la pregunta es sobre **información financiera** (Carrier Billing, 24% APR, comisión de apertura, scoring) porque la regulación CNBV exige que el cliente conozca la fuente exacta de la respuesta.

> **Estado actual (Fase 1):** la interfaz pública para PyMEs está en construcción. Mientras tanto, los **asesores del hub** consultan el sistema vía SQL interno y entregan respuestas + citas a las PyMEs. La Sección A describe cómo serán las consultas cuando la interfaz esté disponible (Fase 1.1).

---

# SECCIÓN A — Para PyMEs ("PyME Digital")

## A.1 ¿Qué puedes preguntar?

El sistema conoce el catálogo completo del Marketplace, incluyendo:

| Categoría | Ejemplos de información disponible |
|---|---|
| **Paquetes de marketing** | Precios, alcance, agencias asociadas, casos de éxito del paquete "Arranque Social", "Pre-campaña Hot Sale", "Lanzamiento de Producto", etc. |
| **Financiamiento Carrier Billing** | Cláusulas contractuales, tasa 24% APR, comisión de apertura 3%, plazos, criterios de scoring |
| **Auditoría de agencias** | Criterios que Acme Co aplica para curar agencias, cómo se evalúa una nueva |
| **Casos de éxito por vertical** | Resultados reales de PyMEs en Moda Ética, Skincare D2C, Joyería de Diseño, Mascotas Premium |
| **Procesos operativos** | Onboarding, escalamiento de tickets, resolución de conflictos con agencias |
| **SLAs** | Tiempos de respuesta del soporte, garantías del servicio |

## A.2 Cómo hacer una buena consulta

### Lo que funciona bien

✅ **Sé específica.**

> *"¿Cuál es la comisión de apertura del Carrier Billing para PyMEs en el segmento Micro?"*

El sistema encuentra exactamente la cláusula correspondiente en el contrato vigente.

✅ **Usa el vocabulario del marketplace.**

> *"¿Qué incluye el paquete Arranque Social para Moda Ética?"*

Mencionar el paquete y la vertical activa filtros automáticos que reducen el ruido.

✅ **Pide la fuente cuando necesites verificación.**

> *"Muéstrame la cláusula exacta sobre cargos por mora con su número de versión."*

Útil cuando vas a tomar una decisión financiera.

### Lo que NO funciona bien (todavía)

❌ **Preguntas sobre tu PyME específica.**

> *"¿Cuánto puedo financiar mi negocio?"*

El sistema no conoce tu facturación específica. Esa pregunta se la responde un asesor con tu información.

❌ **Preguntas conversacionales sin sustantivos.**

> *"¿Y eso cómo funciona?"*

El sistema no mantiene contexto entre preguntas en Fase 1. Cada consulta es independiente.

❌ **Preguntas sobre datos en tiempo real.**

> *"¿Cuántas PyMEs activas tiene el marketplace ahora?"*

El sistema tiene la documentación, no las métricas operativas en tiempo real.

## A.3 Cómo interpretar los resultados

Cuando consultas al sistema (vía tu asesor en Fase 1, o vía la interfaz directa en Fase 1.1), recibes una respuesta con esta estructura:

```
┌─────────────────────────────────────────────────────────────────┐
│ RESPUESTA                                                       │
│                                                                 │
│ La comisión de apertura del Carrier Billing es del 3% sobre     │
│ el principal financiado. Esta comisión se aplica una sola vez   │
│ al momento de la activación del paquete.                        │
│                                                                 │
├─ FUENTES (3) ───────────────────────────────────────────────────┤
│ 1. Contrato Carrier Billing v2.3 · sección 3.1 Apertura         │
│    Relevancia: 96% · Versión índice: run-2026-05-24             │
│                                                                 │
│ 2. Catálogo de Paquetes Marketing v1.4 · "Términos              │
│    financieros" · Relevancia: 87%                               │
│                                                                 │
│ 3. FAQ Carrier Billing v1.0 · "¿Cuánto es la apertura?"         │
│    Relevancia: 84%                                              │
└─────────────────────────────────────────────────────────────────┘
```

**Tres cosas que mirar siempre:**

1. **Relevancia ≥ 80%** — la respuesta probablemente sea correcta. < 70% sugiere que la pregunta no está bien cubierta en el corpus o necesita reformularse.
2. **Fuente con número de versión** — siempre cita el documento exacto. Si tomas una decisión financiera, verifica que la versión del contrato sea la vigente.
3. **Múltiples fuentes coincidentes** — si 3 fuentes dicen lo mismo, la confianza es alta. Si solo 1 fuente lo dice y las otras 2 son tangenciales, valida con un asesor humano.

## A.4 Ejemplos por vertical

### Moda Ética / Slow Fashion

```
Q: "¿Hay casos de éxito de marcas de moda ética que usaron el paquete
    Pre-campaña Hot Sale?"

R: Sí, dos casos documentados:
   • Marca "Origen Local" (CDMX) — incrementó ventas 3.2x en Hot Sale
     2024 con paquete Pre-campaña + financiamiento 6 meses.
   • Marca "Hilo Mexicano" (Guadalajara) — ROAS 4.8x con presupuesto
     financiado de $25,000 MXN.

   Fuentes: Caso Origen Local v1.0 (95%) · Caso Hilo Mexicano v1.2 (91%)
```

### Skincare D2C

```
Q: "¿Qué agencias auditadas tienen experiencia en lanzamiento de
    productos de skincare?"

R: 4 agencias auditadas con experiencia en skincare:
   • Agencia Pixel (CDMX) — 12 campañas D2C en últimos 12 meses
   • Estudio Glow (Monterrey) — especialista en video TikTok skincare
   • Brand House (Guadalajara) — full-funnel beauty
   • Atelier Digital (Querétaro) — performance + content

   Todas con auditoría vigente al cierre del Q1 2026.

   Fuentes: Catálogo Agencias v2.1 (98%) · Dossier ICP Skincare v1.0 (88%)
```

### Joyería de Diseño

```
Q: "¿Qué precio tienen los paquetes para joyería de diseño en
    Mérida?"

R: Los paquetes disponibles para joyería en Mérida son:
   • Arranque Social: $12,000 MXN (incluye 2 semanas de pauta + 5 reels)
   • Lanzamiento de Colección: $18,000 MXN
   • Pre-campaña Hot Sale: $25,000 MXN

   Todos financiables a 3, 6 o 12 meses vía Carrier Billing
   (24% APR).

   Fuentes: Catálogo Paquetes v1.4 (96%) · Pricing Regional v2.0 (90%)
```

### Mascotas Premium

```
Q: "¿Cómo se evalúa el ROI esperado de una campaña para una PyME
    de productos premium para mascotas?"

R: La evaluación considera 3 dimensiones:
   1. Histórico del segmento — pet parents millennials en CDMX,
      GDL y MTY muestran LTV promedio $4,800/cliente.
   2. Ticket promedio del producto — productos premium pet ($800-2500)
      tienen 7.25% conversion en Instagram (referencia AMVO).
   3. Reach orgánico vs pagado — la mezcla recomendada es 60/40.

   Fuentes: Dossier ICP Mascotas Premium v1.0 (94%) · Guía ROI
   Marketing Digital PyME v1.2 (89%)
```

## A.5 Limitaciones que debes conocer

| Limitación | Implicación |
|---|---|
| **El sistema responde con info del corpus, no con tu data.** | Pregúntale al sistema sobre el marketplace, no sobre tu PyME en particular. |
| **Idioma:** español (México). | Preguntas en inglés u otros idiomas pueden devolver resultados de menor calidad. |
| **Actualización:** el índice se reconstruye mensualmente. | Cambios muy recientes pueden no estar reflejados aún. La fecha de la versión está en cada cita. |
| **Sin contexto entre preguntas.** | Cada consulta es independiente. Reformula incluyendo los sustantivos necesarios. |
| **Sin generación creativa.** | El sistema *recupera* información existente; no inventa contenido. Si pides "escribe un copy de Instagram", devolverá ejemplos del corpus pero no generará algo nuevo. |

## A.6 Qué hacer cuando algo no funciona

| Síntoma | Acción |
|---|---|
| El sistema devuelve "sin resultados con relevancia suficiente" | Reformula con sustantivos clave; o consulta a tu asesor del hub |
| La respuesta cita una versión del documento que parece vieja | El índice se reconstruye mensualmente; reporta a Customer Success que verifique |
| La respuesta no parece coincidir con tu experiencia real | Comparte con Customer Success — esto alimenta el feedback loop para mejorar el sistema |
| Necesitas hablar con un humano | Tu asesor del hub está disponible vía WhatsApp Business 9am-6pm |

---

# SECCIÓN B — Para asesores comerciales del hub

## B.1 Acceso al sistema (Fase 1)

En Fase 1 los asesores consultan el índice **directamente vía SQL** (DBeaver, pgAdmin, o herramienta corporativa). Las credenciales están en AWS Secrets Manager — pide al equipo técnico de Acme Co que te dé acceso al secret `bsg-acmeco-rag-dev-aurora-master`.

### Conexión con DBeaver

1. Solicita las credenciales vía ticket interno (responsable: Cloud Team).
2. New Database Connection → PostgreSQL.
3. Host: el endpoint del secret. Port: 5432. Database: `ragvectors`.
4. **SSL Mode: require** (no negociable).
5. Conecta vía VPN corporativa o Bastion host (Aurora no es accesible desde internet).

## B.2 Las 5 consultas más útiles

### B.2.1 Búsqueda básica por similitud semántica

Como asesor, primero generas el embedding de la consulta (vía endpoint interno de embeddings, o pidiendo al equipo técnico) y luego lo usas en SQL:

```sql
-- Asume que el embedding de la consulta está en una variable :query_embedding
SELECT
    chunk_id,
    document_id,
    LEFT(chunk_text, 300)               AS preview,
    metadata_json->>'section_hint'      AS section,
    metadata_json->>'source_filename'   AS source,
    doc_type,
    vertical,
    1 - (embedding <=> :query_embedding) AS relevancia
FROM documents_embeddings
WHERE version_id = (
    SELECT version_id FROM mv_version_stats
    ORDER BY last_updated_at DESC LIMIT 1
)
ORDER BY embedding <=> :query_embedding
LIMIT 5;
```

### B.2.2 Filtrar por vertical y tipo de documento

```sql
-- "Mostrar casos de éxito de Moda Ética"
SELECT chunk_id, LEFT(chunk_text, 400) AS preview,
       metadata_json->>'source_filename' AS source
FROM documents_embeddings
WHERE vertical = 'moda_etica'
  AND doc_type = 'case_study'
ORDER BY created_at DESC
LIMIT 10;
```

### B.2.3 Subset financiero (consultas regulatorias)

```sql
-- Siempre incluir version_id en la respuesta al cliente
SELECT
    chunk_id,
    chunk_text,
    metadata_json,
    version_id,
    created_at,
    1 - (embedding <=> :query_embedding) AS relevancia
FROM documents_embeddings
WHERE criticality = 'financial'
ORDER BY embedding <=> :query_embedding
LIMIT 5;

-- IMPORTANTE: cuando entregues esta respuesta a la PyME, incluye:
--   1. El chunk_text completo (no parafrasees)
--   2. El source_filename + section_hint (cita verificable)
--   3. El version_id (trazabilidad CNBV)
```

### B.2.4 Hybrid search — vector + keyword

Útil cuando hay terminología exacta (nombres de paquete específicos):

```sql
WITH semantic AS (
    SELECT chunk_id, 1 - (embedding <=> :query_embedding) AS sem_score
    FROM documents_embeddings
    ORDER BY embedding <=> :query_embedding LIMIT 50
),
lexical AS (
    SELECT chunk_id, ts_rank(to_tsvector('spanish', chunk_text), q) AS lex_score
    FROM documents_embeddings,
         plainto_tsquery('spanish', :query_text) q
    WHERE to_tsvector('spanish', chunk_text) @@ q
    LIMIT 50
)
SELECT e.chunk_id, LEFT(e.chunk_text, 300) AS preview,
       COALESCE(s.sem_score, 0) * 0.7 + COALESCE(l.lex_score, 0) * 0.3 AS hybrid_score
FROM documents_embeddings e
LEFT JOIN semantic s USING (chunk_id)
LEFT JOIN lexical  l USING (chunk_id)
WHERE s.chunk_id IS NOT NULL OR l.chunk_id IS NOT NULL
ORDER BY hybrid_score DESC LIMIT 10;
```

### B.2.5 Distribución del corpus por vertical

Útil para entender qué tan cubierta está una vertical antes de prometer info al cliente:

```sql
SELECT vertical, doc_type, COUNT(*) AS chunks
FROM documents_embeddings
GROUP BY vertical, doc_type
ORDER BY vertical, chunks DESC;
```

## B.3 Buenas prácticas al responder a una PyME

| Práctica | Por qué |
|---|---|
| **Cita siempre la fuente exacta.** | Construye confianza y permite a la PyME verificar. |
| **Para info financiera, copia el chunk_text literal — no parafrasees.** | Riesgo CNBV: paráfrasis puede cambiar el sentido. |
| **Si la relevancia top-1 está bajo 70%, no respondas con certeza.** | Sugiere reformulación o escala a Customer Success. |
| **Documenta cada consulta atendida en el CRM con `version_id`.** | Trazabilidad regulatoria a 5 años. |
| **Si encuentras info desactualizada, reporta a Cloud Team.** | Alimenta el ciclo de mejora del índice. |

---

# SECCIÓN C — Para Customer Success y Agency Ops

## C.1 Consultas operativas

### Auditoría de Quality Gate — ¿qué chunks se descartaron?

```sql
-- Solo accesible vía DynamoDB scan (no es SQL Aurora)
aws dynamodb scan `
    --table-name bsg-acmeco-rag-dev-chunk-quality-audit `
    --filter-expression "verdict = :v" `
    --expression-attribute-values '{":v":{"S":"discard"}}' `
    --query 'Items[*].[document_id.S, reasons.SS, criticality.S]' `
    --output table `
    --no-verify-ssl
```

Si un documento que esperabas ver está descartado, comprueba `reasons` — puede ser que sea boilerplate, demasiado corto o sin metadata. Coordina con Cloud Team para retroalimentar el Quality Gate.

### Verificar que un chunk financiero esté presente

```sql
-- "¿Está indexada la cláusula 4.2 del contrato Carrier Billing v2.3?"
SELECT chunk_id, LEFT(chunk_text, 500), metadata_json
FROM documents_embeddings
WHERE criticality = 'financial'
  AND metadata_json->>'source_filename' LIKE '%carrier_billing_v2.3%'
  AND metadata_json->>'section_hint' ILIKE '%4.2%';
```

### Ver historial de versiones del índice

```powershell
aws dynamodb scan `
    --table-name bsg-acmeco-rag-dev-index-versions `
    --query 'Items[*].[version_id.S, created_at.S, documents_count.N, chunks_count.N, cost_estimate_usd.N]' `
    --output table `
    --no-verify-ssl
```

## C.2 Escalamientos

| Escenario | Escalar a |
|---|---|
| Sistema retorna respuesta incorrecta sobre info financiera | **URGENTE** → Cloud Team + Compliance |
| Documento nuevo a indexar (catálogo actualizado) | Cloud Team — corren reindex mensual |
| Auditoría regulatoria solicita trazabilidad | Cloud Team — proveen logs Step Functions + DDB |
| PyME reporta problemas recurrentes de búsqueda | Customer Success lead + Cloud Team |

---

## Referencias

- `01_caso_de_uso.md` — Caso de negocio completo
- `02_seleccion_embeddings.md` — Tecnología subyacente (Bedrock Titan V2)
- `03_semantic_chunking_pattern.md` — Cómo funciona el Quality Gate
- `11_guia_administrador.md` — Operación técnica del sistema
- `12_lecciones_aprendidas.md` — Trade-offs y mejoras futuras

**Contacto operativo:** ver `11_guia_administrador.md` §1 para escalamientos técnicos.
