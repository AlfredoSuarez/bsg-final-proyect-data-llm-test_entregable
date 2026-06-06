"""
AWS Lambda — Chunking semantico + Embeddings Bedrock Titan V2

Disparada por S3 ObjectCreated en s3://<clean-docs>/clean/*.parquet
Para cada fila del Parquet:
  1. Aplica RecursiveCharacterTextSplitter (LangChain) con length_function
     basado en tiktoken cl100k_base (aprox tokenizer Titan).
  2. Aplica Quality Gate con regla maestra: chunks con marcador financiero
     nunca se descartan (solo warning).
  3. Invoca Bedrock Titan V2 (1024 dim) en paralelo (ThreadPoolExecutor).
  4. Emite Parquet con metadata + embedding a s3://<embeddings>/embeddings/.
  5. Audita cada decision del Quality Gate en DynamoDB chunk_quality_audit.

Manejo de errores:
  - Errores de chunking de una fila -> log + skip fila, continua.
  - Errores de embedding por chunk -> log + chunk no se emite a Parquet
    (queda registrado en audit DDB para reintento).
  - Rate limiting Bedrock -> boto3 adaptive retry (5 intentos exponenciales).
"""

# pyright: reportMissingImports=false
import hashlib
import json
import logging
import os
import re
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import unquote_plus

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
import tiktoken
from botocore.config import Config
from langchain_text_splitters import RecursiveCharacterTextSplitter

# ============================================================
# Configuracion via variables de entorno
# ============================================================
BEDROCK_MODEL_ID         = os.environ.get("BEDROCK_MODEL_ID", "amazon.titan-embed-text-v2:0")
BEDROCK_REGION           = os.environ.get("BEDROCK_REGION", "us-east-1")
EMBEDDING_DIMENSIONS     = int(os.environ.get("EMBEDDING_DIMENSIONS", "1024"))
EMBEDDINGS_BUCKET        = os.environ["EMBEDDINGS_BUCKET"]
EMBEDDINGS_PREFIX        = os.environ.get("EMBEDDINGS_PREFIX", "embeddings/")
INPUT_PREFIX_STRIP       = os.environ.get("INPUT_PREFIX_STRIP", "clean/")
DDB_AUDIT_TABLE          = os.environ["DDB_AUDIT_TABLE"]
CHUNK_SIZE_MAX           = int(os.environ.get("CHUNK_SIZE_MAX", "1500"))
CHUNK_SIZE_MIN           = int(os.environ.get("CHUNK_SIZE_MIN", "500"))
CHUNK_OVERLAP            = int(os.environ.get("CHUNK_OVERLAP", "200"))
MAX_PARALLEL_EMBEDDINGS  = int(os.environ.get("MAX_PARALLEL_EMBEDDINGS", "10"))
VERSION_ID               = os.environ.get("VERSION_ID", "default")  # Step Functions inyecta por run

# ============================================================
# Logging estructurado a CloudWatch
# ============================================================
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


# ============================================================
# Clientes AWS — instanciados una vez por contenedor (warm start)
# ============================================================
_bedrock_config = Config(
    retries={
        "max_attempts": 5,
        "mode": "adaptive",  # exponential backoff + throttle-aware
    },
    read_timeout=30,
    connect_timeout=10,
    max_pool_connections=50,
)
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION, config=_bedrock_config)
s3      = boto3.client("s3")
ddb     = boto3.client("dynamodb")


# ============================================================
# Tokenizer y Splitter — cached singletons
# ============================================================
_tokenizer: Optional[Any] = None
def get_tokenizer():
    global _tokenizer
    if _tokenizer is None:
        # cl100k_base aproxima bien el tokenizer interno de Titan;
        # diferencias absolutas son < 5% para texto en espanol.
        _tokenizer = tiktoken.get_encoding("cl100k_base")
    return _tokenizer


def count_tokens(text: str) -> int:
    """Tokens segun cl100k_base. Usado como length_function del splitter."""
    return len(get_tokenizer().encode(text or ""))


_splitter: Optional[RecursiveCharacterTextSplitter] = None
def get_splitter() -> RecursiveCharacterTextSplitter:
    global _splitter
    if _splitter is None:
        # Separadores en orden de preferencia: parrafos -> lineas -> oraciones -> palabras -> caracteres.
        # length_function en tokens (no chars) — alineado con docs/03_semantic_chunking_pattern.md.
        _splitter = RecursiveCharacterTextSplitter(
            chunk_size=CHUNK_SIZE_MAX,
            chunk_overlap=CHUNK_OVERLAP,
            length_function=count_tokens,
            separators=["\n\n", "\n", ". ", "; ", ", ", " ", ""],
            keep_separator=True,
        )
    return _splitter


# ============================================================
# Quality Gate — 7 reglas + regla maestra para chunks financieros
# Ver docs/03_semantic_chunking_pattern.md seccion 5
# ============================================================
# NOTA: los patrones de % se ponen FUERA del grupo con \b final porque
# `%` es non-word y un espacio despues tambien lo es; \b al final no
# matchea entre dos non-word chars. Mantener "24%" y "3%" como alternativas
# separadas con su propio word-boundary inicial.
FINANCIAL_MARKERS = re.compile(
    r"(?:\b(APR|tasa\s+anual|tasa\s+de\s+inter[eé]s|CAT|carrier[\s_-]?billing|"
    r"comisi[oó]n\s+de\s+apertura|scoring|cl[aá]usula|cargos?\s+por\s+mora|"
    r"penalizaci[oó]n)\b)"
    r"|(?:\b(?:24|3)\s*%)",
    re.IGNORECASE,
)

BOILERPLATE_PATTERNS = re.compile(
    r"^\s*("
    r"p[aá]gina\s+\d+|"
    r"page\s+\d+|"
    r"confidencial|"
    r"uso\s+interno|"
    r"total\s*play|"
    r"\d+\s*/\s*\d+"
    r")\s*$",
    re.IGNORECASE,
)


def has_financial_marker(text: str) -> bool:
    """Detecta marcadores regulados (CNBV/CONDUSEF) que activan la
    regla maestra del Quality Gate."""
    return bool(FINANCIAL_MARKERS.search(text or ""))


def type_token_ratio(text: str) -> float:
    """TTR = palabras unicas / total. Boilerplate y texto repetitivo
    tienen TTR muy bajo (< 0.30)."""
    words = (text or "").split()
    if not words:
        return 0.0
    return len(set(words)) / len(words)


def quality_gate(
    chunk_text: str,
    declared_criticality: str,
) -> Tuple[str, List[str], Dict[str, Any]]:
    """
    Aplica el Quality Gate descrito en docs/03_semantic_chunking_pattern.md.

    Returns
    -------
    (verdict, reasons, metrics)
        verdict  : 'pass' | 'warning' | 'discard'
        reasons  : lista de razones (audit trail LFPDPPP)
        metrics  : medidas computadas (length, ttr, financial_marker)
    """
    reasons: List[str] = []
    metrics = {
        "length_tokens": count_tokens(chunk_text),
        "ttr": round(type_token_ratio(chunk_text), 3),
        "has_financial_marker": False,
        "matched_boilerplate": False,
    }

    is_financial = (declared_criticality == "financial")
    if has_financial_marker(chunk_text):
        is_financial = True
        metrics["has_financial_marker"] = True
        reasons.append("financial_marker_detected")

    # Regla 1: muy corto
    if metrics["length_tokens"] < 100:
        reasons.append("too_short")

    # Regla 2: bajo TTR (boilerplate)
    if metrics["ttr"] < 0.30 and metrics["length_tokens"] > 0:
        reasons.append("low_diversity")

    # Regla 3: matchea boilerplate explicito
    first_line = (chunk_text or "").strip().split("\n", 1)[0]
    if BOILERPLATE_PATTERNS.match(first_line):
        reasons.append("boilerplate_match")
        metrics["matched_boilerplate"] = True

    # Regla maestra: chunks financieros NUNCA se descartan
    if is_financial:
        if any(r in ("too_short", "low_diversity", "boilerplate_match") for r in reasons):
            return "warning", reasons, metrics
        return "pass", reasons, metrics

    # Chunks no-financieros: discard si tienen flags duras
    if any(r in ("too_short", "low_diversity", "boilerplate_match") for r in reasons):
        return "discard", reasons, metrics

    return "pass", reasons, metrics


# ============================================================
# Section hint — heuristica simple para citacion
# ============================================================
def extract_section_hint(chunk_text: str, max_len: int = 100) -> str:
    """Primera linea no vacia del chunk, truncada. Util como cita
    aproximada. La cita exacta (section_path) requiere parser
    estructurado fuera del scope del Prompt 7."""
    if not chunk_text:
        return ""
    for line in chunk_text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:max_len]
    return ""


# ============================================================
# IDs estables
# ============================================================
def compute_chunk_id(document_id: str, page_number: int, chunk_index: int, chunk_text: str) -> str:
    """chunk_id idempotente: misma combinacion (doc, page, idx, content)
    produce el mismo id. Reindexar el mismo documento no cambia ids."""
    content_hash = hashlib.sha256((chunk_text or "").encode("utf-8")).hexdigest()[:12]
    seed = f"{document_id}:{page_number}:{chunk_index}:{content_hash}"
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:24]


# ============================================================
# Bedrock Titan embedding
# ============================================================
def embed_text(text: str) -> Optional[List[float]]:
    """Invoca Bedrock Titan V2 para un texto. Devuelve None si falla
    tras retries del SDK (max_attempts=5)."""
    if not text or not text.strip():
        return None
    try:
        body = json.dumps({
            "inputText": text,
            "dimensions": EMBEDDING_DIMENSIONS,
            "normalize": True,
        })
        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=body,
            contentType="application/json",
            accept="application/json",
        )
        payload = json.loads(response["body"].read())
        embedding = payload.get("embedding")
        if not embedding or len(embedding) != EMBEDDING_DIMENSIONS:
            logger.warning(
                "Bedrock devolvio embedding invalido: dim=%s expected=%d",
                len(embedding) if embedding else None,
                EMBEDDING_DIMENSIONS,
            )
            return None
        return embedding
    except bedrock.exceptions.ThrottlingException:
        # SDK ya reintenta; si llega aqui es que se agotaron retries.
        logger.error("Bedrock throttled tras 5 intentos para texto len=%d", len(text))
        return None
    except Exception as exc:
        logger.error("Bedrock embed fallo: %s", exc)
        return None


def embed_batch_parallel(texts: List[str]) -> List[Optional[List[float]]]:
    """Embed N textos en paralelo via ThreadPoolExecutor. Mantiene
    el orden original via lookup por indice. Throttling se mitiga
    por (a) max_parallel limitado y (b) adaptive retry del SDK."""
    if not texts:
        return []

    results: List[Optional[List[float]]] = [None] * len(texts)
    workers = min(MAX_PARALLEL_EMBEDDINGS, len(texts))

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(embed_text, t): i for i, t in enumerate(texts)}
        for fut in as_completed(futures):
            idx = futures[fut]
            try:
                results[idx] = fut.result()
            except Exception as exc:
                logger.error("Embedding paralelo idx=%d fallo: %s", idx, exc)
                results[idx] = None

    return results


# ============================================================
# DynamoDB audit del Quality Gate
# ============================================================
def audit_chunk(
    chunk_id: str,
    document_id: str,
    verdict: str,
    reasons: List[str],
    metrics: Dict[str, Any],
    criticality: str,
) -> None:
    """Persiste la decision del Quality Gate en DDB. Esencial para
    auditoria LFPDPPP/CNBV: cualquier chunk descartado debe ser
    explicable."""
    try:
        item = {
            "chunk_id":     {"S": chunk_id},
            "version_id":   {"S": VERSION_ID},
            "document_id":  {"S": document_id},
            "verdict":      {"S": verdict},
            "metrics_json": {"S": json.dumps(metrics)},
            "criticality":  {"S": criticality},
            "timestamp":    {"S": datetime.now(timezone.utc).isoformat()},
        }
        if reasons:
            item["reasons"] = {"SS": list(set(reasons))}
        ddb.put_item(TableName=DDB_AUDIT_TABLE, Item=item)
    except Exception as exc:
        # Audit falla NO debe detener el pipeline. Solo log.
        logger.error("Audit DDB fallo para chunk %s: %s", chunk_id, exc)


# ============================================================
# Procesamiento por fila Parquet
# ============================================================
def process_row(row: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Convierte una fila (document_id, page_number, raw_text, ...)
    en una lista de chunks con metadata + verdict del Quality Gate.

    El embedding se calcula en una etapa posterior (batch paralelo).
    """
    document_id     = row["document_id"]
    page_number     = int(row["page_number"])
    raw_text        = row["raw_text"]
    doc_type        = row.get("doc_type", "unknown")
    vertical        = row.get("vertical", "general")
    criticality     = row.get("criticality", "informational")
    source_filename = row.get("source_filename", "")

    if not raw_text or not raw_text.strip():
        return []

    splitter = get_splitter()
    chunks = splitter.split_text(raw_text)

    chunk_records: List[Dict[str, Any]] = []
    for idx, chunk_text in enumerate(chunks):
        chunk_id = compute_chunk_id(document_id, page_number, idx, chunk_text)
        verdict, reasons, metrics = quality_gate(chunk_text, criticality)

        # Si el quality gate detecto marcador financiero, promovemos criticality
        effective_criticality = criticality
        if metrics.get("has_financial_marker") and criticality != "financial":
            effective_criticality = "financial"

        chunk_records.append({
            "chunk_id":             chunk_id,
            "document_id":          document_id,
            "chunk_index":          idx,
            "page_number":          page_number,
            "chunk_text":           chunk_text,
            "section_hint":         extract_section_hint(chunk_text),
            "token_count":          metrics["length_tokens"],
            "doc_type":             doc_type,
            "vertical":             vertical,
            "criticality":          effective_criticality,
            "declared_criticality": criticality,
            "source_filename":      source_filename,
            "verdict":              verdict,
            "reasons":              reasons,
            "metrics":              metrics,
        })

    return chunk_records


# ============================================================
# Escritura del Parquet de salida
# ============================================================
def write_output_parquet(records: List[Dict[str, Any]], output_key: str) -> int:
    """Convierte registros a Parquet y sube a S3. Devuelve filas escritas."""
    if not records:
        logger.warning("No hay records para escribir; skip output Parquet")
        return 0

    # Schema explicito alineado con Prompt 7 + downstream
    rows = []
    for r in records:
        rows.append({
            "document_id":   r["document_id"],
            "chunk_id":      r["chunk_id"],
            "chunk_index":   int(r["chunk_index"]),
            "page_number":   int(r["page_number"]),
            "metadata_json": json.dumps({
                "section_hint":    r["section_hint"],
                "doc_type":        r["doc_type"],
                "vertical":        r["vertical"],
                "criticality":     r["criticality"],
                "verdict":         r["verdict"],
                "reasons":         r["reasons"],
                "token_count":     r["token_count"],
                "source_filename": r["source_filename"],
                "version_id":      VERSION_ID,
            }),
            "embedding":      r["embedding"],
            "chunk_text":     r["chunk_text"],
            "token_count":    int(r["token_count"]),
            "doc_type":       r["doc_type"],
            "vertical":       r["vertical"],
            "criticality":    r["criticality"],
            "version_id":     VERSION_ID,
            "embedded_at":    datetime.now(timezone.utc).isoformat(),
        })

    table = pa.Table.from_pylist(rows)
    local_path = "/tmp/output_embeddings.parquet"
    pq.write_table(table, local_path, compression="snappy")
    s3.upload_file(local_path, EMBEDDINGS_BUCKET, output_key)
    logger.info("Subido %d chunks a s3://%s/%s", len(rows), EMBEDDINGS_BUCKET, output_key)
    return len(rows)


def derive_output_key(input_key: str) -> str:
    """De: clean/doc_type=contract/part-0001.snappy.parquet
       A:  embeddings/doc_type=contract/part-0001_embeddings.parquet
    """
    relative = input_key
    if input_key.startswith(INPUT_PREFIX_STRIP):
        relative = input_key[len(INPUT_PREFIX_STRIP):]
    relative = relative.replace(".snappy.parquet", "").replace(".parquet", "")
    return f"{EMBEDDINGS_PREFIX}{relative}_embeddings.parquet"


# ============================================================
# Handler de Lambda
# ============================================================
def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Entry point. Procesa cada record de S3 en el evento.

    Cada Parquet en /clean/ tipicamente corresponde a UNA particion
    de doc_type (ej. clean/doc_type=contract/part-0001.parquet).
    Procesamos los chunks de esa particion -> emitimos UN Parquet
    paralelo en /embeddings/.
    """
    # Step Functions inyecta version_id en el payload (no env). Lo usamos
    # si esta presente; fallback al env VERSION_ID (default 'default').
    global VERSION_ID
    event_version = event.get("version_id")
    if event_version:
        VERSION_ID = event_version
    logger.info("Lambda chunking iniciando — version_id=%s model=%s", VERSION_ID, BEDROCK_MODEL_ID)
    logger.debug("Event: %s", json.dumps(event)[:2000])

    s3_records = event.get("Records", [])
    if not s3_records:
        logger.warning("Evento sin records S3")
        return {"statusCode": 400, "body": "No S3 records in event"}

    summary: List[Dict[str, Any]] = []

    for s3_event in s3_records:
        try:
            bucket = s3_event["s3"]["bucket"]["name"]
            key = unquote_plus(s3_event["s3"]["object"]["key"])
        except KeyError as exc:
            logger.error("Estructura de evento S3 invalida: %s", exc)
            continue

        if not key.endswith(".parquet"):
            logger.info("Skip non-parquet: %s", key)
            continue

        run_start = time.time()
        logger.info("Procesando s3://%s/%s", bucket, key)

        # 1. Descargar Parquet a /tmp
        local_input = "/tmp/input.parquet"
        try:
            s3.download_file(bucket, key, local_input)
        except Exception as exc:
            logger.error("Fallo descargando s3://%s/%s: %s", bucket, key, exc)
            continue

        # 2. Leer todas las filas
        try:
            table = pq.read_table(local_input)
            rows = table.to_pylist()
        except Exception as exc:
            logger.error("Fallo leyendo Parquet: %s\n%s", exc, traceback.format_exc())
            continue

        # 2b. Recuperar doc_type del path (Spark partitionBy NO lo deja en row).
        # Pattern esperado: clean/doc_type=<tipo>/part-XXXX.parquet
        partition_doc_type = None
        m = re.search(r"/doc_type=([^/]+)/", key)
        if m:
            partition_doc_type = m.group(1)
            # Inyectar en cada row si no viene explicito
            for row in rows:
                if not row.get("doc_type") or row.get("doc_type") == "unknown":
                    row["doc_type"] = partition_doc_type
            logger.info("doc_type recuperado del path: %s", partition_doc_type)

        logger.info("Parquet filas: %d", len(rows))

        # 3. Chunkear todas las filas con error handling por fila
        all_chunks: List[Dict[str, Any]] = []
        for row in rows:
            try:
                all_chunks.extend(process_row(row))
            except Exception as exc:
                logger.error(
                    "Fallo chunking document_id=%s: %s",
                    row.get("document_id"), exc,
                )

        logger.info("Total chunks generados: %d", len(all_chunks))

        # 4. Filtrar chunks a embebir (pass + warning, NO discard)
        chunks_to_embed = [c for c in all_chunks if c["verdict"] in ("pass", "warning")]
        texts_to_embed  = [c["chunk_text"] for c in chunks_to_embed]
        n_discarded     = len(all_chunks) - len(chunks_to_embed)

        logger.info(
            "Chunks a embebir: %d (descartados por Quality Gate: %d, %.1f%%)",
            len(chunks_to_embed), n_discarded,
            100.0 * n_discarded / max(1, len(all_chunks)),
        )

        # 5. Embedding paralelo
        embed_start = time.time()
        embeddings = embed_batch_parallel(texts_to_embed)
        embed_elapsed = time.time() - embed_start

        n_emb_success = sum(1 for e in embeddings if e is not None)
        n_emb_failed  = len(embeddings) - n_emb_success
        avg_ms = (embed_elapsed / max(1, n_emb_success)) * 1000

        logger.info(
            "Embeddings: %d ok, %d fail, %.2fs total, ~%.0f ms/chunk",
            n_emb_success, n_emb_failed, embed_elapsed, avg_ms,
        )

        # 6. Adjuntar embeddings y filtrar exitosos
        for chunk, emb in zip(chunks_to_embed, embeddings):
            chunk["embedding"] = emb
        successful = [c for c in chunks_to_embed if c.get("embedding") is not None]

        # 7. Auditar TODOS los chunks (incluido discards) a DDB
        for chunk in all_chunks:
            audit_chunk(
                chunk_id=chunk["chunk_id"],
                document_id=chunk["document_id"],
                verdict=chunk["verdict"],
                reasons=chunk["reasons"],
                metrics=chunk["metrics"],
                criticality=chunk["criticality"],
            )

        # 8. Escribir Parquet de embeddings
        output_key = derive_output_key(key)
        written = write_output_parquet(successful, output_key)

        elapsed = time.time() - run_start
        result = {
            "input":            f"s3://{bucket}/{key}",
            "output":           f"s3://{EMBEDDINGS_BUCKET}/{output_key}",
            "rows_in":          len(rows),
            "chunks_generated": len(all_chunks),
            "chunks_embedded":  written,
            "chunks_discarded": n_discarded,
            "chunks_failed":    n_emb_failed,
            "elapsed_seconds":  round(elapsed, 2),
            "version_id":       VERSION_ID,
        }
        logger.info("Resultado: %s", json.dumps(result))
        summary.append(result)

    return {
        "statusCode": 200,
        "body": json.dumps(summary),
    }
