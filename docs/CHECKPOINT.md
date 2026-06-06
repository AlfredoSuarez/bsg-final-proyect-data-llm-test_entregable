# Checkpoint del Proyecto — Estado al 2026-05-27

**Último commit:** `180761e docs(checkpoint): estado del proyecto para sobrevivir compactacion`
**Branch:** `main` (working tree clean, sincronizado con `origin/main`)
**Repo:** https://github.com/AlfredoSuarez/bsg-final-proyect-data-llm-test (privado)

> Este checkpoint reemplaza al de 2026-05-24. El anterior queda en el histórico de git.

---

## TL;DR — dónde estamos

| Item | Estado |
|---|---|
| **Diseño + IaC + Docs** | ✅ Completo (12/12 componentes rúbrica, ~92/100 pts cubiertos) |
| **Terraform validate + plan contra AWS real** | ✅ 60+ recursos planificados sin errores |
| **Tests locales pytest** | 🟡 **91/93 PASSED** — 2 fallas con causa raíz ya identificada (mismo bug) |
| **Docker builds local** | 🔴 Falló por permisos: `permission denied ... docker.sock` |
| **SQL DDL test (Postgres + pgvector)** | 🔴 No corrió (archivo de evidencia vacío) |
| **Deploy real en AWS (Opción 2 mini-demo)** | ⏳ Pendiente decisión + ejecución |
| **Evidencia académica** | 🟡 Parcial — pytest_output.txt completo; docker y sql vacíos/fallidos |

---

## 🔥 Pendientes inmediatos (en orden de prioridad)

### 1. Arreglar las 2 fallas pytest — mismo bug, fix de ~3 líneas

**Diagnóstico (confirmado en [evidence/pytest_output.txt](../evidence/pytest_output.txt)):**

```
FAILED tests/test_etl_parser.py::TestInferDocType::test_inferencia_doc_type
  [contracts/sla_servicios.pdf-sla]
  AssertionError: assert 'contract' == 'sla'

FAILED tests/test_etl_parser.py::TestInferDocType::test_inferencia_doc_type
  [faqs/preguntas_carrier_billing.html-faq]
  AssertionError: assert 'contract' == 'faq'
```

**Causa raíz** — en [etl/glue_etl_job.py:85-86](../etl/glue_etl_job.py#L85-L86):

```python
DOC_TYPE_PATTERNS = [
    (re.compile(r"\b(contrato|contratos|contract|contracts|carrier\s*billing)\b", re.I), "contract"),
    (re.compile(r"\bsla\b", re.I), "sla"),
    ...
]
```

El patrón `contract` matchea **antes** que el resto (orden de evaluación en `infer_doc_type` retorna el primer hit) y es **promiscuo**:
- `"contracts/sla_servicios.pdf"` → matchea `contracts` → retorna `contract` (debería ser `sla`)
- `"faqs/preguntas_carrier_billing.html"` → matchea `carrier billing` → retorna `contract` (debería ser `faq`)

**Fix recomendado:**

```python
# Opción A: reordenar para que patrones más específicos vayan primero
DOC_TYPE_PATTERNS = [
    (re.compile(r"\bsla\b", re.I), "sla"),
    (re.compile(r"\b(faq|faqs|preguntas|objeciones)\b", re.I), "faq"),
    # ... resto de patrones específicos antes de contract
    (re.compile(r"\b(contrato|contratos|contract|contracts|carrier\s*billing)\b", re.I), "contract"),
    ...
]

# Opción B (preferida): partir el patrón promiscuo
# carrier billing NO siempre es contract — puede ser FAQ, manual, etc.
# Mejor que cuente como señal financiera, no como tipo de doc.
(re.compile(r"\b(contrato|contratos|contract|contracts)\b", re.I), "contract"),
```

Una vez aplicado, correr en WSL:
```bash
source .venv/bin/activate
python3 -m pytest tests/test_etl_parser.py::TestInferDocType -v
# debe quedar 93/93
```

### 2. Resolver permisos Docker en WSL

```
ERROR: permission denied while trying to connect to the docker API at
unix:///var/run/docker.sock
```

**Fix estándar (sin reinstalar):**
```bash
sudo usermod -aG docker $USER
newgrp docker          # aplica el cambio en la sesión actual
docker ps              # debe listar sin sudo
bash tests/run_docker_builds.sh
```

Si persiste, opciones: `sudo bash tests/run_docker_builds.sh` (rápido, no ideal) o usar **Docker Desktop con WSL2 integration** desde Windows.

### 3. Correr SQL DDL test (archivo vacío)

```bash
bash tests/run_sql_ddl_test.sh 2>&1 | tee evidence/sql_ddl_apply.txt
```

Requiere `postgres + pgvector` local (el script levanta un contenedor) → depende del paso 2 (Docker funcionando).

### 4. Decisión: incluir `evidence/*.txt` en git como entregable

Actualmente `evidence/` está en `.gitignore`. Para entrega académica conviene committear los outputs como prueba de ejecución:
```bash
# Editar .gitignore: cambiar "evidence/*" por "evidence/*.tmp"
# Luego:
git add evidence/pytest_output.txt evidence/docker_build_*.txt evidence/sql_ddl_apply.txt
git commit -m "docs(evidence): outputs de pruebas locales para entrega academica"
```

---

## Pendientes opcionales (Opción 2 — mini-demo AWS real)

Costo total estimado: **USD 3-5 por 24h**. Solo si se quiere capturar screenshots reales del dashboard CloudWatch / Step Functions / DynamoDB / queries Aurora.

Pre-requisito **bloqueante**: crear IAM user con MFA (mitiga riesgo #1 de SECURITY.md — actualmente se usa root). Ver `docs/11_guia_administrador.md §2`.

Flujo abreviado:
```bash
cd infra && terraform init && terraform apply -target=module.foundation
psql -h <aurora-endpoint> -U rag_admin -d ragvectors -f ../indexer/sql/00_init_pgvector.sql
# build + push imágenes a ECR (ver docs/11_guia_administrador.md §3.4)
aws s3 cp ../etl/glue_etl_job.py "s3://$(terraform output -raw glue_scripts_bucket)/etl/"
terraform apply   # compute habilitado
aws stepfunctions start-execution \
    --state-machine-arn "$(terraform output -raw state_machine_arn)" \
    --name "demo-$(date +%Y%m%d%H%M)"
# capturar screenshots
terraform destroy
```

---

## Contexto del proyecto (sin cambios desde checkpoint anterior)

- **Curso:** Diseño de Infraestructura Escalable — BSG Institute · Msc. Andrés Felipe Rojas Parra
- **Estudiante:** Alfredo Suárez · `arse.alf@gmail.com`
- **Caso de uso real:** Plataforma de Conocimiento del **Marketplace B2B PyME de Acme Co**, primer eslabón de la tesis **Economic Graph de la PyME Mexicana** de Grupo Acme.
- **Audiencia ICP:** "PyME Digital" — mujer millennial 30-45, PyME digital-first, facturación $1M–$20M MXN, en 4 verticales (Moda Ética / Skincare D2C / Joyería de Diseño / Mascotas Premium) y 5 ciudades (GDL, CDMX, MTY, QRO, MID).
- **Audiencia entregable:** dual — BSG académico + Acme Co / Grupo Acme estratégico.

---

## Stack técnico (no negociables — ya validados)

| Capa | Tecnología |
|---|---|
| Cloud | AWS `us-east-1`, cuenta `275541169383` |
| Embeddings | Bedrock Titan V2 (**1024 dim**, no 1536) |
| Indexación | Aurora PostgreSQL 16 Serverless v2 + `pgvector` |
| Índice ANN | HNSW (`m=16, ef_construction=64, cosine_ops`) |
| ETL | AWS Glue 4.0 Spark + Python |
| Chunking | AWS Lambda container arm64 + LangChain + tiktoken |
| Quality Gate | 7 reglas + **regla maestra financiera** (chunks con marcadores CNBV nunca discard, solo warning) |
| Indexer | ECS Fargate container arm64 + `psycopg2 execute_values` |
| Versionamiento | DynamoDB `index_versions` + `chunk_quality_audit`; `version_id = run-<ExecutionName>` propagado end-to-end |
| Orquestación | Step Functions Standard (9 estados + Map paralelo) |
| Observabilidad | CloudWatch dashboard 13 widgets + 7 alarmas críticas + SNS |
| IaC | Terraform 1.6+ (provider AWS ~> 5.50) |

---

## Historia de commits (últimos 13)

```
180761e docs(checkpoint): estado del proyecto para sobrevivir compactacion   ← HEAD
2df5cfc fix: 3 bugs encontrados por pytest + 1 test mal escrito
874a252 test: Opcion 1 — tests locales pytest + scripts Docker/SQL para WSL
5a1d0fc docs: Prompt 10 — Guia Usuario + Guia Administrador + Lecciones + README
3772ba8 feat(orchestration+observability): Prompt 9 — Step Functions + CloudWatch
9df0e00 feat(indexer): Prompt 8 — pgvector DDL + ECS Fargate loader
9ee2031 feat(chunking): Prompt 7 — Lambda chunking + Bedrock Titan embeddings
6f8f776 feat(etl): Prompt 6 — Glue 4.0 ETL Job + IaC
caeedad docs(security): documentar hallazgos del setup AWS local
2ab59f6 feat(arquitectura+iac): Prompt 5 — arquitectura AWS y Terraform foundation
b8b7937 docs(03): Semantic Chunking Pattern con Quality Gate financiero
d0522e5 docs: caso de uso y selección de embeddings (Prompts 2 y 3)
f1857c7 chore: estructura inicial del proyecto
```

---

## Setup actual del entorno WSL del usuario

| Item | Estado |
|---|---|
| Sistema | Ubuntu 24.04 en WSL2 sobre Windows 11 |
| Python | 3.12.3 |
| venv | `.venv/` activo en raíz del repo |
| Terraform | 1.15.4 en Windows (revisar si necesita instalarse en WSL para Opción 2) |
| AWS CLI | v2.34.14 en Windows, accesible desde WSL vía `/mnt/c/` |
| Docker | ⚠️ Instalado pero usuario sin permisos en `docker.sock` |
| git | Configurado con PAT desde `.env.tools_api` línea 15 (`Github=...`) |
| Credenciales | `~/.git-credentials` con `chmod 600` |

---

## Issues conocidos del entorno local (no resueltos)

| # | Issue | Severidad | Mitigación |
|---|---|---|---|
| 1 | Cuenta AWS root en uso (`arn:aws:iam::275541169383:root`) | 🚨 Crítico | Crear IAM user con MFA antes de `terraform apply`. Ver `docs/SECURITY.md` |
| 2 | SSL inspection corporativo bloquea TLS | ⚠️ Medio | `--no-verify-ssl` en AWS CLI; `TF_DISABLE_PLUGIN_TLS=1` en Terraform |
| 3 | Repo en OneDrive — borra `.terraform/` y `.git` puede corromperse | ⚠️ Bajo | `.terraform/` en `/tmp/`; mover repo eventualmente |
| 4 | `.env.tools_api` con tokens production en OneDrive (incl. **Stripe LIVE `sk_live_*`**) | 🚨 Crítico | **Rotar Stripe HOY**. Mover archivo a `~/.secrets/` fuera de OneDrive |
| 5 | Usuario WSL sin acceso a `docker.sock` | ⚠️ Medio | `sudo usermod -aG docker $USER && newgrp docker` |

---

## Comandos clave para continuar

```bash
# Activar entorno en WSL
cd "/mnt/c/Users/Rog/OneDrive/BCG Institute/Arquitectura Escalable/Proyecto_Final"
source .venv/bin/activate

# Verificar último commit y status
git log --oneline -3
git status

# Re-correr pytest con tracebacks cortos
python3 -m pytest tests/ --tb=short 2>&1 | tee evidence/pytest_output.txt

# Solo el subset de inferencia
python3 -m pytest tests/test_etl_parser.py::TestInferDocType -v

# Docker (después de usermod -aG docker)
docker ps
bash tests/run_docker_builds.sh 2>&1 | tee evidence/docker_build_$(date +%Y%m%d).txt

# SQL DDL test
bash tests/run_sql_ddl_test.sh 2>&1 | tee evidence/sql_ddl_apply.txt
```

---

## Cómo retomar después de compactar

Si se pierde contexto:

1. **Leer este archivo primero:** `docs/CHECKPOINT.md`
2. **Verificar último commit:** `git log --oneline -3`
3. **Leer memoria persistente:** `~/.claude/projects/c--Users-Rog-.../memory/MEMORY.md` y `project_proyecto12_pipeline.md`
4. **Decidir próximo paso (en orden):**
   - Arreglar los 2 tests de `infer_doc_type` (§1 — bug de orden de patrones, fix de 3 líneas)
   - Resolver permisos Docker (§2 — `usermod -aG docker`)
   - Correr Docker builds + SQL DDL (§2-3)
   - Decidir si avanzar a Opción 2 (deploy real, USD 3-5)
5. **Mantener commits descriptivos** con co-author tag (ver formato en commits anteriores)

---

## Decisiones de producto/diseño tomadas (no negociables)

1. **Aurora `pgvector` con `vector(1024)`** — no migrar a OpenSearch, no usar 1536 dim de Titan V1
2. **Bedrock Titan V2 sobre OpenAI / BGE-M3** — compliance y residencia AWS
3. **Container image para Lambda chunking** — necesario por tamaño de deps (>250 MB)
4. **ECS Fargate arm64 para indexer** — cargas batch + cubre componente #4 Docker
5. **Step Functions Standard** (no Express) — duración variable >5 min
6. **Quality Gate regla maestra**: `criticality=financial` NUNCA descarta, solo warning
7. **Versionamiento end-to-end por `version_id = run-<ExecutionName>`** propagado Step Functions
8. **HNSW sobre IVFFlat** a este volumen (< 1M vectores)
9. **VPC sin egress a internet** + interface endpoints para Bedrock y Secrets Manager
10. **Docker multi-stage non-root** en ambas imágenes (chunking + indexer)

---

## Documentos relacionados (referencia rápida)

| Documento | Propósito |
|---|---|
| [README.md](../README.md) | Overview ejecutivo + quick start |
| [docs/01_caso_de_uso.md](01_caso_de_uso.md) | Caso de negocio Acme Co + KPIs |
| [docs/04_arquitectura.md](04_arquitectura.md) | Diagrama Mermaid + costos detallados |
| [docs/11_guia_administrador.md](11_guia_administrador.md) | Runbooks operativos completos |
| [docs/12_lecciones_aprendidas.md](12_lecciones_aprendidas.md) | Trade-offs + limitaciones + mejoras |
| [docs/SECURITY.md](SECURITY.md) | Riesgos del setup local + mitigaciones |
| [tests/README.md](../tests/README.md) | Cómo correr tests en WSL |
| [infra/README.md](../infra/README.md) | Cómo desplegar Terraform |

---

**Próxima acción esperada del usuario:**

1. Aplicar el fix de §1 a `etl/glue_etl_job.py` (reordenar `DOC_TYPE_PATTERNS` o partir el patrón `contract`).
2. Correr `python3 -m pytest tests/test_etl_parser.py::TestInferDocType -v` para verificar 93/93.
3. `sudo usermod -aG docker $USER && newgrp docker` y luego correr los scripts de Docker / SQL.
4. Decidir si se commitea `evidence/*.txt` para entrega académica.
