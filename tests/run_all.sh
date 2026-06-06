#!/usr/bin/env bash
# ============================================================
# Runner unificado de tests locales — Opción 1 del plan de evidencia
# ============================================================
# Genera evidence/ con outputs de:
#   - pytest del código Python (parser ETL, chunker, indexer)
#   - docker build de las 2 imágenes (chunking + indexer)
#   - psql apply del DDL pgvector sobre Postgres local en Docker
#
# Uso: desde la raíz del repo en WSL:
#   bash tests/run_all.sh
#
# Salida: evidence/ + exit code 0 si todo OK, no-cero si algo falló.

set -euo pipefail

# Colores
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$PROJECT_ROOT/evidence"

mkdir -p "$EVIDENCE_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}RAG Pipeline — Local Evidence Generator${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Project root : $PROJECT_ROOT"
echo -e "Evidence dir : $EVIDENCE_DIR"
echo -e "Timestamp    : $TIMESTAMP"
echo ""

FAILED=0

# ============================================================
# 1. Verificar Python venv
# ============================================================
echo -e "${YELLOW}[1/4] Verificando entorno Python...${NC}"

if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    echo -e "${YELLOW}  WARNING: no estás dentro de un venv.${NC}"
    echo -e "${YELLOW}  Recomendado: python3 -m venv .venv && source .venv/bin/activate${NC}"
    echo -e "${YELLOW}  Continuando con Python del sistema...${NC}"
fi

if ! python3 -c "import pytest" 2>/dev/null; then
    echo -e "${RED}  pytest no instalado. Instala con:${NC}"
    echo -e "${RED}    pip install -r tests/requirements.txt${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ Python + pytest disponibles${NC}"
echo ""

# ============================================================
# 2. Pytest
# ============================================================
echo -e "${YELLOW}[2/4] Corriendo pytest (parser ETL + chunking + indexer)...${NC}"
PYTEST_OUTPUT="$EVIDENCE_DIR/pytest_output.txt"
{
    echo "=== pytest output — $TIMESTAMP ==="
    echo ""
    cd "$PROJECT_ROOT"
    python3 -m pytest tests/ -v 2>&1 || echo "[exit code: $?]"
} | tee "$PYTEST_OUTPUT"

if grep -q "passed" "$PYTEST_OUTPUT" && ! grep -q "failed" "$PYTEST_OUTPUT"; then
    echo -e "${GREEN}  ✓ Pytest OK — output en $PYTEST_OUTPUT${NC}"
else
    echo -e "${RED}  ✗ Pytest tiene fallos — revisa $PYTEST_OUTPUT${NC}"
    FAILED=1
fi
echo ""

# ============================================================
# 3. Docker builds
# ============================================================
echo -e "${YELLOW}[3/4] Build de imágenes Docker...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}  Docker no disponible — skip (no es bloqueante)${NC}"
else
    bash "$SCRIPT_DIR/run_docker_builds.sh" || {
        echo -e "${RED}  ✗ Docker build falló${NC}"
        FAILED=1
    }
fi
echo ""

# ============================================================
# 4. SQL DDL apply (Postgres + pgvector en Docker)
# ============================================================
echo -e "${YELLOW}[4/4] Verificando DDL pgvector contra Postgres local...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}  Docker no disponible — skip${NC}"
else
    bash "$SCRIPT_DIR/run_sql_ddl_test.sh" || {
        echo -e "${RED}  ✗ SQL DDL test falló${NC}"
        FAILED=1
    }
fi
echo ""

# ============================================================
# Resumen
# ============================================================
echo -e "${BLUE}========================================${NC}"
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ TODOS LOS CHECKS PASARON${NC}"
    echo -e "${GREEN}  Evidencia generada en: $EVIDENCE_DIR${NC}"
else
    echo -e "${RED}✗ ALGUNOS CHECKS FALLARON${NC}"
    echo -e "${RED}  Revisar logs en: $EVIDENCE_DIR${NC}"
fi
echo -e "${BLUE}========================================${NC}"

ls -lh "$EVIDENCE_DIR/" 2>/dev/null || true

exit $FAILED
