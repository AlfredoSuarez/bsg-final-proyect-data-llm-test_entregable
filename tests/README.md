# Tests Locales — Polish y Evidencia (Opción 1)

Suite de tests pytest + verificaciones Docker/SQL **sin desplegar a AWS**. Cumple dos objetivos:

1. **Polish del código**: cazar bugs antes de gastar dinero en AWS deploys.
2. **Evidencia académica**: outputs guardados en `evidence/` para el entregable.

## Cobertura

| Test | Qué valida | Crítico para rúbrica |
|---|---|---|
| `tests/test_etl_parser.py` | Parser PDF/DOCX/HTML, normalización, dedup headers/footers, inferencia doc_type/vertical/criticality, hashes idempotentes | #7 ETL+Chunking |
| `tests/test_chunking.py` | **Regla maestra Quality Gate (chunks financieros NO discard)**, TTR, marcadores CNBV, chunk_id idempotente, splitter, section_hint | #3 Patrón LLM + #7 Chunking |
| `tests/test_indexer.py` | `format_vector_literal` pgvector, `compute_dataset_hash` determinístico | #9 Indexación + #10 Versionamiento |
| `tests/run_docker_builds.sh` | Ambos Dockerfiles buildean limpiamente (arm64 + nativo fallback) | #4 Docker |
| `tests/run_sql_ddl_test.sh` | DDL aplica sobre Postgres+pgvector, índices se crean, INSERT/SELECT vectorial funciona | #9 Indexación pgvector |

## Setup en WSL

```bash
cd "/mnt/c/Users/Rog/OneDrive/BCG Institute/Arquitectura Escalable/Proyecto_Final"

# 1. Crear venv (recomendado)
python3 -m venv .venv
source .venv/bin/activate

# 2. Instalar dependencias de tests
pip install -r tests/requirements.txt

# 3. (Opcional) Verificar Docker disponible para tests #4 y #9
docker version
```

## Correr todo el suite

```bash
# Desde la raíz del repo
bash tests/run_all.sh
```

Esto genera `evidence/` con:
- `pytest_output.txt` — output completo de los unit tests
- `docker_build_chunking.txt` — output de `docker build` chunking
- `docker_build_indexer.txt` — output de `docker build` indexer
- `sql_ddl_apply.txt` — output de aplicar el DDL pgvector

## Correr componentes individualmente

```bash
# Solo pytest (más rápido — ~10 s)
python3 -m pytest tests/ -v

# Solo un archivo
python3 -m pytest tests/test_chunking.py -v

# Solo un test (debug)
python3 -m pytest tests/test_chunking.py::TestQualityGateReglaMaestra -v

# Solo Docker builds
bash tests/run_docker_builds.sh

# Solo SQL DDL
bash tests/run_sql_ddl_test.sh
```

## Tests críticos para no romper jamás

**`TestQualityGateReglaMaestra`** en `test_chunking.py`. Estos tests son la verificación de la regla maestra CNBV/CONDUSEF — un chunk con marcador financiero NUNCA debe descartarse.

Si alguno de estos tests rompe, **no commitear** y resolver el bug en código:

```bash
python3 -m pytest tests/test_chunking.py::TestQualityGateReglaMaestra -v --tb=long
```

## Cómo se mockean los AWS deps

`conftest.py` aplica:

1. **Mocks de `awsglue`, `pyspark`, `psycopg2`** — no están instalados en WSL.
2. **Env vars con defaults** — el código de Lambda y indexer requiere env vars at import time.
3. **boto3 clients** — NO se mockean. `boto3.client('bedrock-runtime', ...)` no hace network calls en construcción. Solo se invocan métodos en tests que requieren AWS (que no están en esta suite).

## Documentos sintéticos generados

`tests/fixtures/generate_docs.py` crea 5 documentos representativos:

| Archivo | Cubre |
|---|---|
| `sample_contract_carrier_billing.pdf` | Multi-page con headers/footers + cláusulas financieras + 24% APR + comisión apertura 3% |
| `sample_manual_negocios.pdf` | Multi-page técnico con listas y secciones |
| `sample_dossier_ana_digital.docx` | DOCX comercial vertical Moda Ética |
| `sample_faq_carrier_billing.html` | HTML con `<script>` + `<style>` para test de cleanup |
| `sample_corrupt.pdf` | Bytes truncados para test de error handling |

Generación idempotente: si ya existen no se regeneran. Para forzar regeneración: `rm -rf tests/fixtures/samples/`.

## Troubleshooting

| Síntoma | Causa | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'awsglue'` | conftest no se cargó | Correr desde raíz del repo, no desde `tests/` |
| `KeyError: 'EMBEDDINGS_BUCKET'` | env vars no seteadas | conftest debería setearlas; verificar que `pytest tests/` los detecta |
| `docker: command not found` | Docker no instalado en WSL | Habilitar WSL integration en Docker Desktop |
| `docker buildx: command not found` | buildx no disponible | El script cae a `docker build` nativo (x86_64 — solo verifica sintaxis) |
| `pgvector/pgvector:pg16: pull access denied` | Imagen no existe | Verificar con `docker pull pgvector/pgvector:pg16` |
| Tests pasan pero `evidence/` vacío | No corriste `bash tests/run_all.sh` | El script `run_all.sh` es el que captura outputs a `evidence/` |

## Siguiente paso tras todos los tests OK

→ Avanzar a **Opción 2** (mini-demo en AWS): ver `docs/11_guia_administrador.md` §3-4.
