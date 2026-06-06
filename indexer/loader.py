"""
ECS Fargate Indexer — Carga embeddings desde S3 a Aurora pgvector.

Pipeline:
  1. Leer Parquet con embeddings desde S3 /embeddings/.
  2. UPSERT por chunk_id en Aurora documents_embeddings (en batches).
  3. Registrar nueva version en DynamoDB index_versions.

Triggered por:
  - Step Functions tras la Lambda chunking termine (Prompt 9).
  - Manualmente via `docker run` para reindexacion ad-hoc.

Variables de entorno requeridas:
  AWS_REGION, EMBEDDINGS_BUCKET, AURORA_SECRET_ARN,
  DDB_VERSIONS_TABLE, VERSION_ID (opcional, autogenera si falta).
"""

# pyright: reportMissingImports=false
import hashlib
import json
import logging
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

import boto3
import psycopg2
import psycopg2.extras
import pyarrow.parquet as pq

# ============================================================
# Configuracion via variables de entorno
# ============================================================
AWS_REGION         = os.environ.get("AWS_REGION", "us-east-1")
EMBEDDINGS_BUCKET  = os.environ["EMBEDDINGS_BUCKET"]
EMBEDDINGS_PREFIX  = os.environ.get("EMBEDDINGS_PREFIX", "embeddings/")
AURORA_SECRET_ARN  = os.environ["AURORA_SECRET_ARN"]
DDB_VERSIONS_TABLE = os.environ["DDB_VERSIONS_TABLE"]
EMBEDDING_MODEL    = os.environ.get("EMBEDDING_MODEL", "amazon.titan-embed-text-v2:0")
BATCH_SIZE         = int(os.environ.get("BATCH_SIZE", "500"))
GIT_COMMIT         = os.environ.get("GIT_COMMIT", "unknown")

# VERSION_ID se autogenera si no se inyecta desde Step Functions
VERSION_ID = os.environ.get(
    "VERSION_ID",
    f"run-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
)

# ============================================================
# Logging estructurado (CloudWatch via ECS awslogs driver)
# ============================================================
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("rag-indexer")


# ============================================================
# Clientes AWS
# ============================================================
secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)
s3_client      = boto3.client("s3", region_name=AWS_REGION)
ddb_client     = boto3.client("dynamodb", region_name=AWS_REGION)


# ============================================================
# Conexion Aurora desde Secrets Manager
# ============================================================
def get_aurora_credentials() -> Dict[str, Any]:
    """Recupera y parsea el JSON del secret de Aurora."""
    response = secrets_client.get_secret_value(SecretId=AURORA_SECRET_ARN)
    return json.loads(response["SecretString"])


def connect_aurora() -> Any:
    """Crea conexion psycopg2 con autocommit=False y SSL requerido."""
    creds = get_aurora_credentials()
    conn = psycopg2.connect(
        host=creds["host"],
        port=int(creds.get("port", 5432)),
        dbname=creds.get("dbname", "ragvectors"),
        user=creds["username"],
        password=creds["password"],
        connect_timeout=10,
        sslmode="require",
        application_name="rag-indexer",
    )
    conn.autocommit = False
    return conn


# ============================================================
# Listado y lectura de Parquet desde S3
# ============================================================
def list_parquet_files(bucket: str, prefix: str) -> List[str]:
    """Lista todos los .parquet bajo el prefijo, ordenados alfabeticamente."""
    paginator = s3_client.get_paginator("list_objects_v2")
    keys: List[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".parquet"):
                keys.append(obj["Key"])
    keys.sort()
    return keys


def read_parquet_rows(bucket: str, key: str) -> List[Dict[str, Any]]:
    """Descarga Parquet a /tmp y devuelve filas como lista de dict."""
    local_path = f"/tmp/{hashlib.md5(key.encode()).hexdigest()}.parquet"
    s3_client.download_file(bucket, key, local_path)
    table = pq.read_table(local_path)
    rows = table.to_pylist()
    # Cleanup local file inmediatamente para no llenar /tmp
    try:
        os.remove(local_path)
    except OSError:
        pass
    return rows


# ============================================================
# Conversion de vector Python -> formato pgvector
# ============================================================
def format_vector_literal(embedding: List[float]) -> str:
    """pgvector acepta strings de la forma '[1.0, 2.0, ...]'.
    Tambien acepta el casting via ::vector en el SQL.
    """
    return "[" + ",".join(f"{x:.7g}" for x in embedding) + "]"


# ============================================================
# UPSERT batch a Aurora
# ============================================================
UPSERT_SQL = """
INSERT INTO documents_embeddings (
    chunk_id, document_id, page_number, chunk_index,
    chunk_text, metadata_json, embedding,
    token_count, doc_type, vertical, criticality,
    source_filename, version_id
)
VALUES %s
ON CONFLICT (chunk_id) DO UPDATE SET
    metadata_json = EXCLUDED.metadata_json,
    embedding     = EXCLUDED.embedding,
    chunk_text    = EXCLUDED.chunk_text,
    token_count   = EXCLUDED.token_count,
    doc_type      = EXCLUDED.doc_type,
    vertical      = EXCLUDED.vertical,
    criticality   = EXCLUDED.criticality,
    version_id    = EXCLUDED.version_id,
    updated_at    = NOW()
"""


def upsert_batch(conn: Any, batch: List[Dict[str, Any]]) -> int:
    """UPSERT un batch usando execute_values (mucho mas rapido que
    executemany para INSERT masivos).

    Retorna el numero de filas afectadas (insertadas + actualizadas).
    """
    if not batch:
        return 0

    values: List[Tuple] = []
    for row in batch:
        # metadata_json viene como string serializado del Parquet
        meta_str = row.get("metadata_json") or "{}"
        if isinstance(meta_str, (dict, list)):
            meta_str = json.dumps(meta_str)
        # Parsear para extraer source_filename si esta dentro
        try:
            meta_dict = json.loads(meta_str) if isinstance(meta_str, str) else meta_str
        except (json.JSONDecodeError, TypeError):
            meta_dict = {}

        source_filename = meta_dict.get("source_filename", row.get("source_filename", ""))

        # Embedding viene como lista de float; convertir a literal pgvector
        emb = row.get("embedding")
        if emb is None or len(emb) == 0:
            logger.warning("Skip row con embedding nulo: chunk_id=%s", row.get("chunk_id"))
            continue

        values.append((
            row["chunk_id"],
            row["document_id"],
            row.get("page_number"),
            row.get("chunk_index"),
            row.get("chunk_text", ""),
            meta_str,                            # JSONB se castea automaticamente
            format_vector_literal(list(emb)),   # vector se castea por contexto
            row.get("token_count"),
            row.get("doc_type", "unknown"),
            row.get("vertical", "general"),
            row.get("criticality", "informational"),
            source_filename,
            row.get("version_id", VERSION_ID),
        ))

    if not values:
        return 0

    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            UPSERT_SQL,
            values,
            page_size=BATCH_SIZE,
            # Template explicito para forzar el cast de embedding a vector
            template="(%s,%s,%s,%s,%s,%s::jsonb,%s::vector,%s,%s,%s,%s,%s,%s)",
        )
    return len(values)


# ============================================================
# Registro de version en DynamoDB
# ============================================================
def register_version(stats: Dict[str, Any]) -> None:
    """PutItem en index_versions con resumen de la corrida.
    Habilita rollback (cambiar version_id activa) y auditoria.
    """
    item = {
        "version_id":        {"S": VERSION_ID},
        "created_at":        {"S": datetime.now(timezone.utc).isoformat()},
        "documents_count":   {"N": str(stats["documents_count"])},
        "chunks_count":      {"N": str(stats["chunks_count"])},
        "embeddings_count":  {"N": str(stats["embeddings_count"])},
        "embedding_model":   {"S": EMBEDDING_MODEL},
        "cost_estimate_usd": {"N": str(round(stats["cost_estimate_usd"], 4))},
        "dataset_hash":      {"S": stats.get("dataset_hash", "")},
        "git_commit":        {"S": GIT_COMMIT},
        "notes":             {"S": stats.get("notes", "")},
    }
    ddb_client.put_item(TableName=DDB_VERSIONS_TABLE, Item=item)


def compute_dataset_hash(processed_keys: List[str]) -> str:
    """SHA-256 sobre la lista ordenada de keys procesadas.
    Igual entrada -> mismo hash -> versionado deterministico.
    """
    h = hashlib.sha256()
    for key in sorted(processed_keys):
        h.update(key.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


# ============================================================
# Main
# ============================================================
def main() -> int:
    started_at = time.time()
    logger.info("=" * 70)
    logger.info("RAG Indexer iniciando")
    logger.info("VERSION_ID    : %s", VERSION_ID)
    logger.info("S3 source     : s3://%s/%s", EMBEDDINGS_BUCKET, EMBEDDINGS_PREFIX)
    logger.info("AURORA secret : %s", AURORA_SECRET_ARN)
    logger.info("DDB versions  : %s", DDB_VERSIONS_TABLE)
    logger.info("Batch size    : %d", BATCH_SIZE)
    logger.info("=" * 70)

    # 1. Conectar Aurora
    try:
        conn = connect_aurora()
        logger.info("Conectado a Aurora")
    except Exception as exc:
        logger.error("Fallo conectando a Aurora: %s\n%s", exc, traceback.format_exc())
        return 2

    documents: Set[str] = set()
    total_chunks_inserted = 0
    total_files = 0
    failed_files: List[str] = []
    processed_keys: List[str] = []

    try:
        # 2. Listar archivos Parquet
        keys = list_parquet_files(EMBEDDINGS_BUCKET, EMBEDDINGS_PREFIX)
        total_files = len(keys)
        logger.info("Archivos Parquet encontrados: %d", total_files)

        if not keys:
            logger.warning("Nada que indexar. Saliendo limpio.")
            return 0

        # 3. Procesar cada archivo en transaccion independiente
        for i, key in enumerate(keys, start=1):
            file_start = time.time()
            try:
                logger.info("[%d/%d] Procesando s3://%s/%s", i, total_files, EMBEDDINGS_BUCKET, key)
                rows = read_parquet_rows(EMBEDDINGS_BUCKET, key)
                if not rows:
                    logger.info("  Archivo vacio, skip")
                    continue

                # 3a. Batch UPSERT en transacciones de BATCH_SIZE
                batch: List[Dict[str, Any]] = []
                file_chunks = 0
                for row in rows:
                    batch.append(row)
                    documents.add(row["document_id"])
                    if len(batch) >= BATCH_SIZE:
                        upserted = upsert_batch(conn, batch)
                        conn.commit()
                        file_chunks += upserted
                        batch = []

                # Flush ultimo batch parcial
                if batch:
                    upserted = upsert_batch(conn, batch)
                    conn.commit()
                    file_chunks += upserted

                total_chunks_inserted += file_chunks
                processed_keys.append(key)
                elapsed = time.time() - file_start
                logger.info("  OK — %d chunks upserted en %.2fs", file_chunks, elapsed)

            except Exception as exc:
                conn.rollback()
                failed_files.append(key)
                logger.error("  FAIL %s: %s\n%s", key, exc, traceback.format_exc())
                # Continuar con siguiente archivo (no detiene el indexer)

        # 4. Refrescar vista materializada de stats
        try:
            with conn.cursor() as cur:
                cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY mv_version_stats")
            conn.commit()
            logger.info("Vista mv_version_stats refrescada")
        except Exception as exc:
            logger.warning("No se pudo refrescar vista materializada: %s", exc)

        # 5. Registrar version en DDB
        # Costo estimado: $0.02 / 1M tokens Titan V2.
        # Aprox 750 tokens por chunk en promedio (cap 1500, min 100).
        cost_estimate = (total_chunks_inserted * 750) / 1_000_000 * 0.02

        stats = {
            "documents_count":   len(documents),
            "chunks_count":      total_chunks_inserted,
            "embeddings_count":  total_chunks_inserted,
            "cost_estimate_usd": cost_estimate,
            "dataset_hash":      compute_dataset_hash(processed_keys),
            "notes":             f"files_ok={len(processed_keys)} files_failed={len(failed_files)}",
        }
        register_version(stats)
        logger.info("Version registrada: %s", VERSION_ID)

        elapsed_total = time.time() - started_at
        logger.info("=" * 70)
        logger.info("RAG Indexer COMPLETADO")
        logger.info("Archivos procesados   : %d / %d", len(processed_keys), total_files)
        logger.info("Documents unicos      : %d", len(documents))
        logger.info("Chunks upserted       : %d", total_chunks_inserted)
        logger.info("Cost embeddings estim : USD %.4f", cost_estimate)
        logger.info("Failed files          : %d", len(failed_files))
        logger.info("Elapsed total         : %.2fs", elapsed_total)
        logger.info("=" * 70)

        return 0 if not failed_files else 1

    finally:
        conn.close()
        logger.info("Conexion Aurora cerrada")


if __name__ == "__main__":
    sys.exit(main())
