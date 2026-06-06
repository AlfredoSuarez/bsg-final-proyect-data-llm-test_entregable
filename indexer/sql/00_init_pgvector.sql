-- ============================================================
-- DDL — Inicializacion del schema RAG en Aurora PostgreSQL 16
-- ============================================================
-- Aplicar UNA vez tras `terraform apply` del cluster Aurora.
-- Idempotente: usa IF NOT EXISTS en todos los objetos.
--
-- IMPORTANTE: el prompt original del proyecto menciona vector(1536)
-- (dim Titan V1). Usamos vector(1024) porque la decision tecnica es
-- Titan V2 (ver docs/02_seleccion_embeddings.md seccion 2.5). Cambio
-- documentado y trazable.
-- ============================================================

-- ---- 1. Extensiones ----
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---- 2. Tabla principal: documents_embeddings ----
CREATE TABLE IF NOT EXISTS documents_embeddings (
    id              BIGSERIAL    PRIMARY KEY,
    chunk_id        VARCHAR(64)  NOT NULL UNIQUE,
    document_id     VARCHAR(64)  NOT NULL,
    page_number     INTEGER,
    chunk_index     INTEGER,
    chunk_text      TEXT         NOT NULL,
    metadata_json   JSONB        NOT NULL,
    embedding       VECTOR(1024) NOT NULL,
    token_count     INTEGER,
    doc_type        VARCHAR(32)  NOT NULL,
    vertical        VARCHAR(32)  NOT NULL,
    criticality     VARCHAR(32)  NOT NULL,
    source_filename TEXT,
    version_id      VARCHAR(64)  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- Validaciones a nivel SQL (defensa en profundidad)
    CONSTRAINT documents_embeddings_criticality_check
        CHECK (criticality IN ('financial', 'legal', 'operational', 'informational')),
    CONSTRAINT documents_embeddings_doc_type_check
        CHECK (doc_type IN (
            'contract', 'sla', 'policy_credit',
            'dossier_icp', 'manual_tech', 'catalog',
            'case_study', 'faq', 'process_op', 'unknown'
        ))
);

COMMENT ON TABLE documents_embeddings IS
    'Tabla principal de embeddings del Marketplace B2B PyME Acme Co.
     Cada fila = un chunk semantico + su vector de 1024 dim (Titan V2).
     UPSERT por chunk_id desde ECS Fargate indexer.';

COMMENT ON COLUMN documents_embeddings.chunk_id IS
    'sha1(document_id:page:idx:content_hash). Idempotente — reindexar
     mismo chunk produce mismo id.';

COMMENT ON COLUMN documents_embeddings.criticality IS
    'Determina ruteo regulatorio: financial = subset critico CNBV/CONDUSEF
     con KPI de precision top-5 >= 95% en docs/01_caso_de_uso.md.';

COMMENT ON COLUMN documents_embeddings.embedding IS
    'Vector 1024 dim normalizado (Titan V2 con normalize=true).
     Usar <=> (cosine distance) o <#> (negative inner product, equivalente
     a cosine para vectores normalizados).';

-- ---- 3. Indice HNSW para busqueda ANN ----
-- HNSW es el algoritmo recomendado para volumenes < 1M vectores
-- (caso fase 1 y fase 2 del proyecto). Trade-off: mas memoria que
-- IVFFlat pero queries mas rapidos y mejor recall.
--
-- Parametros:
--   m              = 16   (conexiones por nodo; default razonable)
--   ef_construction = 64  (calidad del build; mas alto = mejor recall, mas lento)
--
-- Para tuning fino en queries: SET LOCAL hnsw.ef_search = 100
-- (default 40; mas alto = mejor recall, mas lento).

CREATE INDEX IF NOT EXISTS idx_documents_embeddings_hnsw
    ON documents_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON INDEX idx_documents_embeddings_hnsw IS
    'HNSW para ANN con cosine similarity. Titan V2 normaliza, por lo
     que cosine == inner product (vector_ip_ops seria equivalente
     con potencialmente menos calculo).';

-- ---- 4. Indices B-tree para filtros frecuentes ----
-- Estos indices aceleran consultas hibridas: WHERE vertical = X
-- + ORDER BY embedding <=> Y.
CREATE INDEX IF NOT EXISTS idx_documents_embeddings_doc_type
    ON documents_embeddings (doc_type);

CREATE INDEX IF NOT EXISTS idx_documents_embeddings_vertical
    ON documents_embeddings (vertical);

CREATE INDEX IF NOT EXISTS idx_documents_embeddings_criticality
    ON documents_embeddings (criticality);

CREATE INDEX IF NOT EXISTS idx_documents_embeddings_version_id
    ON documents_embeddings (version_id);

CREATE INDEX IF NOT EXISTS idx_documents_embeddings_document_id
    ON documents_embeddings (document_id);

-- Indice compuesto para queries del subset financiero por version
CREATE INDEX IF NOT EXISTS idx_documents_embeddings_crit_version
    ON documents_embeddings (criticality, version_id)
    WHERE criticality = 'financial';

-- ---- 5. Indice GIN sobre metadata_json para filtros ad-hoc ----
CREATE INDEX IF NOT EXISTS idx_documents_embeddings_metadata_gin
    ON documents_embeddings
    USING GIN (metadata_json jsonb_path_ops);

-- ---- 6. Indice full-text en espanol para busqueda hibrida ----
-- Permite combinar busqueda vectorial + keyword tipo BM25.
-- Ejemplo en 01_query_examples.sql.
CREATE INDEX IF NOT EXISTS idx_documents_embeddings_chunk_text_fts
    ON documents_embeddings
    USING GIN (to_tsvector('spanish', chunk_text));

-- ---- 7. Trigger para updated_at ----
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_updated_at ON documents_embeddings;
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON documents_embeddings
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ---- 8. Vista materializada — stats por version (para dashboards) ----
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_version_stats AS
SELECT
    version_id,
    COUNT(*)                            AS total_chunks,
    COUNT(DISTINCT document_id)         AS total_documents,
    COUNT(*) FILTER (WHERE criticality = 'financial')     AS financial_chunks,
    COUNT(*) FILTER (WHERE criticality = 'legal')         AS legal_chunks,
    COUNT(*) FILTER (WHERE criticality = 'operational')   AS operational_chunks,
    COUNT(*) FILTER (WHERE criticality = 'informational') AS informational_chunks,
    AVG(token_count)::INTEGER           AS avg_token_count,
    MIN(created_at)                     AS first_indexed_at,
    MAX(updated_at)                     AS last_updated_at
FROM documents_embeddings
GROUP BY version_id;

CREATE UNIQUE INDEX IF NOT EXISTS mv_version_stats_pk
    ON mv_version_stats (version_id);

COMMENT ON MATERIALIZED VIEW mv_version_stats IS
    'Estadisticas agregadas por version del indice. Refrescar con:
     REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats;';

-- ---- 9. Configuracion recomendada de sesion ----
-- (Aplicar via parameter group del cluster o por sesion antes de
-- queries vectoriales pesadas)
--
-- SET hnsw.ef_search = 100;          -- mejor recall, mas lento
-- SET maintenance_work_mem = '2GB';  -- para CREATE INDEX
-- SET max_parallel_workers_per_gather = 4;
