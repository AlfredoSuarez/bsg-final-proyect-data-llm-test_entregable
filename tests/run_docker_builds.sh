#!/usr/bin/env bash
# Verifica que los dos Dockerfiles del pipeline buildean limpiamente.
# Genera output en evidence/docker_build_*.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$PROJECT_ROOT/evidence"
mkdir -p "$EVIDENCE_DIR"

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

FAILED=0

# ----------------------------------------------------------------
# Chunking Lambda image
# ----------------------------------------------------------------
echo "==> Building chunking/Dockerfile (arm64)"
CHUNK_LOG="$EVIDENCE_DIR/docker_build_chunking.txt"
{
    echo "=== docker build chunking/ — $(date -u +%FT%TZ) ==="
    echo ""
    cd "$PROJECT_ROOT/chunking"
    # --platform linux/arm64 requires buildx + emulation en x86_64
    # Si no hay buildx, usar build nativo (x86_64) solo para validacion sintactica
    if docker buildx version &>/dev/null; then
        docker buildx build --platform linux/arm64 -t bsg-rag-chunking-test:local --load . 2>&1
    else
        echo "(buildx no disponible — build nativo)"
        docker build -t bsg-rag-chunking-test:local . 2>&1
    fi
    echo "[exit code: $?]"
} | tee "$CHUNK_LOG"

if tail -5 "$CHUNK_LOG" | grep -qE "(naming to|writing image|exporting layers|successfully built)"; then
    echo -e "${GREEN}  ✓ chunking image OK${NC}"
else
    echo -e "${RED}  ✗ chunking build falló${NC}"
    FAILED=1
fi
echo ""

# ----------------------------------------------------------------
# Indexer ECS image
# ----------------------------------------------------------------
echo "==> Building indexer/Dockerfile (arm64)"
INDEX_LOG="$EVIDENCE_DIR/docker_build_indexer.txt"
{
    echo "=== docker build indexer/ — $(date -u +%FT%TZ) ==="
    echo ""
    cd "$PROJECT_ROOT/indexer"
    if docker buildx version &>/dev/null; then
        docker buildx build --platform linux/arm64 -t bsg-rag-indexer-test:local --load . 2>&1
    else
        echo "(buildx no disponible — build nativo)"
        docker build -t bsg-rag-indexer-test:local . 2>&1
    fi
    echo "[exit code: $?]"
} | tee "$INDEX_LOG"

if tail -5 "$INDEX_LOG" | grep -qE "(naming to|writing image|exporting layers|successfully built)"; then
    echo -e "${GREEN}  ✓ indexer image OK${NC}"
else
    echo -e "${RED}  ✗ indexer build falló${NC}"
    FAILED=1
fi

exit $FAILED
