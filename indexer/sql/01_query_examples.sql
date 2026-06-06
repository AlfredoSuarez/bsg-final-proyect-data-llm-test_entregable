-- ============================================================
-- Ejemplos de consultas vectoriales — documents_embeddings
-- ============================================================
-- Cada ejemplo asume que ya hay datos cargados via el indexer
-- (ver indexer/loader.py) y la extension pgvector activa.
--
-- Operadores pgvector usados:
--   <->   distancia L2 (euclidean)
--   <=>   distancia coseno (1 - cosine_similarity)
--   <#>   negative inner product (mejor performance si vectores
--         normalizados, equivalente a coseno)
--
-- Titan V2 normaliza los vectores por defecto (normalize=true en
-- la Lambda chunking), por lo que <=> y <#> dan resultados
-- equivalentes — preferir <=> por legibilidad.
-- ============================================================

-- ============================================================
-- 1. k-Nearest Neighbors basico
-- ============================================================
-- Devuelve los 5 chunks mas similares al embedding de consulta.
-- En produccion, el embedding viene de invocar Bedrock con la
-- query del usuario (no se hardcodea como aqui).

SELECT
    chunk_id,
    document_id,
    LEFT(chunk_text, 200) AS chunk_preview,
    metadata_json->>'section_hint' AS section_hint,
    metadata_json->>'source_filename' AS source,
    doc_type,
    vertical,
    criticality,
    1 - (embedding <=> '[0.012, -0.045, ...]'::vector) AS similarity
FROM documents_embeddings
ORDER BY embedding <=> '[0.012, -0.045, ...]'::vector
LIMIT 5;


-- ============================================================
-- 2. k-NN filtrado por vertical (Moda Etica)
-- ============================================================
-- Util cuando el frontend conoce la vertical del usuario (PyME Digital).
-- El filtro WHERE se aplica ANTES del ranking ANN, gracias al indice
-- compuesto en (vertical) + el HNSW.

SELECT
    chunk_id,
    LEFT(chunk_text, 300) AS chunk_preview,
    metadata_json->>'section_hint' AS section,
    1 - (embedding <=> '[...]'::vector) AS similarity
FROM documents_embeddings
WHERE vertical = 'moda_etica'
  AND version_id = (
      -- Usa la version mas reciente del indice
      SELECT version_id
      FROM mv_version_stats
      ORDER BY last_updated_at DESC
      LIMIT 1
  )
ORDER BY embedding <=> '[...]'::vector
LIMIT 5;


-- ============================================================
-- 3. Subset financiero critico (CNBV / CONDUSEF)
-- ============================================================
-- Para consultas sobre Carrier Billing, 24% APR, scoring, clausulas
-- contractuales. KPI: precision top-5 >= 95% en este subset.
-- Devuelve metadata completa + URL firmada al documento fuente
-- para citacion verificable (requisito regulatorio).

SELECT
    chunk_id,
    document_id,
    chunk_text,
    metadata_json AS full_metadata,
    metadata_json->>'section_hint' AS section_hint,
    metadata_json->>'source_filename' AS source_doc,
    version_id,
    created_at,
    1 - (embedding <=> '[...]'::vector) AS similarity
FROM documents_embeddings
WHERE criticality = 'financial'
ORDER BY embedding <=> '[...]'::vector
LIMIT 5;


-- ============================================================
-- 4. Busqueda hibrida vector + keyword (BM25 simplificado)
-- ============================================================
-- Combina similaridad semantica (70%) con relevancia lexica (30%).
-- Util cuando hay terminologia exacta (nombres de paquete, codigos
-- de cliente) que el embedding semantico subestima.
--
-- ts_rank devuelve rank en [0, 1+]; cosine similarity tambien en
-- [0, 1] para vectores normalizados. Ponderacion ajustable.

WITH semantic AS (
    SELECT
        chunk_id,
        1 - (embedding <=> '[...]'::vector) AS sem_score
    FROM documents_embeddings
    ORDER BY embedding <=> '[...]'::vector
    LIMIT 50
),
lexical AS (
    SELECT
        chunk_id,
        ts_rank(to_tsvector('spanish', chunk_text), q) AS lex_score
    FROM documents_embeddings,
         plainto_tsquery('spanish', 'comision apertura carrier billing') q
    WHERE to_tsvector('spanish', chunk_text) @@ q
    LIMIT 50
)
SELECT
    e.chunk_id,
    e.document_id,
    LEFT(e.chunk_text, 300) AS preview,
    e.metadata_json->>'section_hint' AS section,
    COALESCE(s.sem_score, 0) * 0.7 + COALESCE(l.lex_score, 0) * 0.3 AS hybrid_score
FROM documents_embeddings e
LEFT JOIN semantic s USING (chunk_id)
LEFT JOIN lexical  l USING (chunk_id)
WHERE s.chunk_id IS NOT NULL OR l.chunk_id IS NOT NULL
ORDER BY hybrid_score DESC
LIMIT 10;


-- ============================================================
-- 5. Multi-filter con JSONB metadata
-- ============================================================
-- Filtros complejos sobre metadata_json (que vive en GIN index).
-- Ejemplo: chunks de vertical moda, criticality operational,
-- excluyendo el ICP que ya conocemos.

SELECT
    chunk_id,
    metadata_json->>'section_hint' AS section,
    chunk_text,
    1 - (embedding <=> '[...]'::vector) AS similarity
FROM documents_embeddings
WHERE vertical = 'moda_etica'
  AND criticality = 'operational'
  AND metadata_json @> '{"doc_type": "catalog"}'::jsonb
  AND metadata_json->>'source_filename' NOT LIKE '%dossier_ana%'
ORDER BY embedding <=> '[...]'::vector
LIMIT 10;


-- ============================================================
-- 6. Tuning de recall vs latency
-- ============================================================
-- Por defecto HNSW usa ef_search=40. Para queries criticas
-- (subset financiero) elevar a 100+ mejora recall a costa de ~2x
-- latencia. Aplicar solo a la sesion (no global).

BEGIN;
    SET LOCAL hnsw.ef_search = 100;

    SELECT chunk_id, document_id,
           1 - (embedding <=> '[...]'::vector) AS similarity
    FROM documents_embeddings
    WHERE criticality = 'financial'
    ORDER BY embedding <=> '[...]'::vector
    LIMIT 5;
COMMIT;


-- ============================================================
-- 7. Agregaciones por version (auditoria)
-- ============================================================

-- 7a. Stats globales del indice activo
SELECT * FROM mv_version_stats
ORDER BY last_updated_at DESC
LIMIT 5;

-- 7b. Distribucion de chunks por vertical y doc_type
SELECT
    vertical,
    doc_type,
    COUNT(*) AS chunks,
    AVG(token_count)::INTEGER AS avg_tokens
FROM documents_embeddings
GROUP BY vertical, doc_type
ORDER BY vertical, chunks DESC;

-- 7c. Drift detection — chunks que cambiaron entre versiones
SELECT
    chunk_id,
    document_id,
    LEFT(chunk_text, 200) AS preview,
    version_id,
    created_at,
    updated_at
FROM documents_embeddings
WHERE updated_at > created_at  -- chunk fue UPSERT (no INSERT)
ORDER BY updated_at DESC
LIMIT 50;


-- ============================================================
-- 8. Operaciones de mantenimiento
-- ============================================================

-- 8a. Refrescar vista materializada (post-indexacion)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats;

-- 8b. Vacuum + analyze tras carga masiva
VACUUM ANALYZE documents_embeddings;

-- 8c. Reconstruir indice HNSW (raro; tras cambio masivo de embeddings)
-- DROP INDEX idx_documents_embeddings_hnsw;
-- SET maintenance_work_mem = '2GB';
-- CREATE INDEX idx_documents_embeddings_hnsw ...

-- 8d. Verificar salud del indice HNSW
SELECT
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    idx_scan         AS scans,
    idx_tup_read     AS tuples_read,
    idx_tup_fetch    AS tuples_fetched
FROM pg_stat_user_indexes
WHERE relname = 'documents_embeddings'
ORDER BY pg_relation_size(indexrelid) DESC;
