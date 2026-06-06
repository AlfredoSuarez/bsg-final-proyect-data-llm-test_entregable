#!/usr/bin/env bash
# Levanta Postgres 16 + pgvector en Docker, aplica el DDL del indexer
# y verifica tablas + índices + vista materializada.
# Genera output en evidence/sql_ddl_apply.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$PROJECT_ROOT/evidence"
mkdir -p "$EVIDENCE_DIR"

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

CONTAINER="bsg-rag-pg-test"
SQL_LOG="$EVIDENCE_DIR/sql_ddl_apply.txt"
DDL_FILE="$PROJECT_ROOT/indexer/sql/00_init_pgvector.sql"

# Cleanup container si existe
docker rm -f "$CONTAINER" &>/dev/null || true

echo "==> Levantando pgvector/pgvector:pg16 en Docker..."
{
    echo "=== SQL DDL apply test — $(date -u +%FT%TZ) ==="
    echo ""

    # Imagen oficial de pgvector con Postgres 16 — incluye la extension preinstalada
    docker run -d --name "$CONTAINER" \
        -e POSTGRES_PASSWORD=testpass \
        -e POSTGRES_DB=ragvectors \
        -p 15432:5432 \
        pgvector/pgvector:pg16

    # Esperar a que Postgres esté listo (max 30 seg)
    echo "Esperando a que Postgres esté listo..."
    for i in {1..30}; do
        if docker exec "$CONTAINER" pg_isready -U postgres &>/dev/null; then
            echo "  ✓ Postgres listo tras ${i}s"
            break
        fi
        sleep 1
    done

    echo ""
    echo "==> Aplicando DDL: $DDL_FILE"
    docker cp "$DDL_FILE" "$CONTAINER:/tmp/init.sql"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -f /tmp/init.sql 2>&1

    echo ""
    echo "==> Verificación: tablas y extension"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "\dt" 2>&1
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "\d documents_embeddings" 2>&1
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector'" 2>&1

    echo ""
    echo "==> Verificación: índices"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "\di documents_embeddings*" 2>&1

    echo ""
    echo "==> Verificación: vista materializada"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "\dm mv_version_stats" 2>&1

    echo ""
    echo "==> Insert + select sintético"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "
        INSERT INTO documents_embeddings (
            chunk_id, document_id, page_number, chunk_index,
            chunk_text, metadata_json, embedding,
            token_count, doc_type, vertical, criticality,
            source_filename, version_id
        ) VALUES (
            'test-chunk-001', 'test-doc-001', 1, 0,
            'Test chunk text para verificar insert',
            '{\"section_hint\":\"test\"}'::jsonb,
            ('[' || array_to_string(array_fill(0.5::float, ARRAY[1024]), ',') || ']')::vector,
            10, 'contract', 'general', 'financial',
            'test.pdf', 'test-version-001'
        );
        SELECT chunk_id, doc_type, criticality FROM documents_embeddings;
        " 2>&1

    echo ""
    echo "==> Test de búsqueda vectorial"
    docker exec -e PGPASSWORD=testpass "$CONTAINER" \
        psql -U postgres -d ragvectors -c "
        SELECT chunk_id, 1 - (embedding <=> ('[' || array_to_string(array_fill(0.5::float, ARRAY[1024]), ',') || ']')::vector) AS similarity
        FROM documents_embeddings
        ORDER BY embedding <=> ('[' || array_to_string(array_fill(0.5::float, ARRAY[1024]), ',') || ']')::vector
        LIMIT 1;
        " 2>&1
} | tee "$SQL_LOG"

# Verificación de éxito
SUCCESS=0
if grep -qE "(CREATE TABLE|CREATE EXTENSION|INSERT 0 1)" "$SQL_LOG"; then
    SUCCESS=1
fi

# Cleanup
docker rm -f "$CONTAINER" &>/dev/null || true

if [[ $SUCCESS -eq 1 ]]; then
    echo -e "${GREEN}  ✓ DDL aplicado correctamente${NC}"
    exit 0
else
    echo -e "${RED}  ✗ DDL falló — revisar $SQL_LOG${NC}"
    exit 1
fi
