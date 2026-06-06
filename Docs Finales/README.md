# Docs Finales — Material de entrega del Proyecto 12

Este folder contiene el **material final a revisar** del Proyecto 12 — LLM Data Engineering Pipeline. Es el punto de entrada para evaluadores, sponsors y cualquier persona que necesite entender el proyecto sin navegar el repo completo.

---

## Contenido

| Archivo | Descripción | Para qué sirve |
|---|---|---|
| **[01_Proyecto12_Origen_BSG.md](01_Proyecto12_Origen_BSG.md)** | Especificación original del Proyecto 12 publicada por BSG Institute (Msc. Andrés Felipe Rojas Parra) | Documento de partida — define los 12 componentes obligatorios y la rúbrica académica |
| **[Proyecto12_Entregable_Final.pdf](Proyecto12_Entregable_Final.pdf)** | Entregable consolidado de 146 páginas con todos los documentos del proyecto | Respuesta técnica al spec del profesor; revisar este para evaluación detallada |
| **[README_Proyecto.md](README_Proyecto.md)** | Copia del README general del repo | Contexto rápido del proyecto y guía de navegación del código |

---

## Presentaciones (Gamma)

Las dos presentaciones complementarias del proyecto, generadas con Gamma AI:

### 📊 Más a detalle (versión completa)

https://gamma.app/docs/Proyecto-12-LLM-Data-Engineering-Pipeline-6wow0z7dqdyr7f9

Profundiza en:
- Caso de uso del Marketplace B2B PyME
- Justificación de stack (AWS + Bedrock + Aurora pgvector)
- Quality Gate con regla maestra financiera
- Resultados del deploy real a AWS

### 📋 Resumen ejecutivo

https://gamma.app/docs/Proyecto-12-LLM-Data-Engineering-Pipeline-auzjwr6wb2as59u

Versión condensada para sponsor / comité ejecutivo.

---

## Disclosure de anonimización

Por confidencialidad del cliente real, los nombres de marcas en este entregable están anonimizados. Las equivalencias reales solo se comparten verbalmente y NO aparecen en el material entregado:

| Nombre en el entregable | Tipo |
|---|---|
| **Acme Co** | Cliente principal (telco) |
| **Grupo Acme** | Conglomerado empresarial al que pertenece |
| **Banco Acme** | Subsidiaria bancaria del Grupo |
| **Retail Acme** | Subsidiaria de retail del Grupo |
| **PyME Digital** | ICP (Ideal Customer Profile) — perfil de la PyME representativa |
| **Aliado Telco** | Programa de aliados comerciales del cliente |

Términos NO anonimizados (son genéricos de industria, no marcas registradas):
- **Carrier Billing** — instrumento financiero estándar del sector telco
- Tecnologías AWS, herramientas open source, librerías Python

---

## Orden de lectura sugerido

| Si tienes... | Lee en este orden |
|---|---|
| **5 minutos** | Resumen ejecutivo (Gamma) → `01_Proyecto12_Origen_BSG.md` |
| **15 minutos** | Lo anterior + sección "Decisiones clave" del PDF (páginas 14-22) |
| **1 hora** | PDF completo de 146 páginas |
| **Quieres profundizar técnicamente** | PDF completo + repo (especialmente `infra/`, `etl/`, `chunking/`, `evidence/cloud/`) |

---

## Estado del entregable

- ✅ 12/12 componentes de la rúbrica del Proyecto 12 cumplidos
- ✅ Tests locales: 93/93 pytest verde
- ✅ Docker builds arm64 (chunking + indexer) con healthcheck OK
- ✅ Terraform validate + plan contra AWS real: 83 recursos planificados sin errores
- ✅ **Deploy end-to-end SUCCEEDED en AWS** (run `demo-20260601-015935`, 2 min 30s)
- ✅ 5 chunks indexados en Aurora con embeddings Titan V2 (1024 dim)
- ✅ Regla maestra CNBV verificada: 100% chunks pass con marcador financiero detectado
- ✅ KPIs en 4 capas (técnica + negocio + compliance + roadmap agente LLM)
- ✅ 12 bugs reales del deploy documentados como lecciones aprendidas
