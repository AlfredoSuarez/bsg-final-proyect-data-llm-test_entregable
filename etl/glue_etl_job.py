"""
AWS Glue 4.0 ETL Job — RAG Pipeline Acme Co Marketplace B2B PyME

Lee documentos PDF / DOCX / HTML desde S3 raw-docs, ejecuta limpieza
y normalizacion, y emite Parquet a S3 clean-docs con el contrato de
salida del Prompt 6:

    columnas obligatorias:  document_id, page_number, raw_text
    columnas adicionales:   source_filename, doc_type, vertical,
                            criticality, content_length, language,
                            version_hash, extracted_at

Compatible con Glue 4.0 (Python 3.10 + Spark 3.3.0).

Argumentos del Job (todos como --<nombre> <valor>):
    --JOB_NAME          (estandar, lo inyecta Glue)
    --input_bucket      nombre del bucket s3 raw-docs
    --output_bucket     nombre del bucket s3 clean-docs
    --input_prefix      prefijo dentro del bucket (default: "raw/")
    --output_prefix     prefijo dentro del bucket (default: "clean/")
    --max_workers       num de tareas Spark (default: 50)

Ejemplo de invocacion via AWS CLI:

    aws glue start-job-run \\
        --job-name bsg-acmeco-rag-dev-etl \\
        --arguments '{
            "--input_bucket":  "bsg-acmeco-rag-dev-raw-docs-275541169383",
            "--output_bucket": "bsg-acmeco-rag-dev-clean-docs-275541169383",
            "--input_prefix":  "raw/",
            "--output_prefix": "clean/"
        }'
"""

# pyright: reportMissingImports=false
import hashlib
import io
import logging
import re
import sys
import traceback
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple

import boto3

# ----------------------------------------------------------------
# Glue / Spark imports (provistos en runtime de Glue 4.0)
# ----------------------------------------------------------------
from awsglue.context import GlueContext  # type: ignore
from awsglue.job import Job  # type: ignore
from awsglue.utils import getResolvedOptions  # type: ignore
from pyspark.context import SparkContext  # type: ignore
from pyspark.sql import SparkSession  # type: ignore
from pyspark.sql.types import (  # type: ignore
    IntegerType,
    StringType,
    StructField,
    StructType,
)

# ============================================================
# Configuracion de logging — salida a CloudWatch via stdout
# ============================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("rag-etl")

# ============================================================
# Constantes y heuristicas
# ============================================================
SUPPORTED_EXTENSIONS = {".pdf", ".docx", ".html", ".htm"}

# Mapas de inferencia heuristica desde el nombre del archivo o ruta.
# Las regex se aplican SOBRE EL FILENAME NORMALIZADO (ver
# _normalize_for_inference), que reemplaza /, _, -, ., \ con espacios
# para que los word boundaries (\b) funcionen correctamente.
# Cubren plurales en espanol e ingles para alinear con el corpus real
# del Marketplace B2B PyME (ver docs/03_semantic_chunking_pattern.md).
# Orden importa: patrones MÁS específicos primero.
# `carrier billing` se removió del patrón de contract porque es señal
# financiera (ya detectada por FINANCIAL_MARKERS en chunking/lambda_function.py),
# no un tipo de documento — capturaba falsos positivos en FAQs y manuales.
DOC_TYPE_PATTERNS = [
    (re.compile(r"\bsla\b", re.I), "sla"),
    (re.compile(r"\b(faq|faqs|preguntas|objeciones)\b", re.I), "faq"),
    (re.compile(r"\b(scoring|credito|crédito|politica|política|politicas|políticas|riesgo|apr)\b", re.I), "policy_credit"),
    (re.compile(r"\b(icp|dossier|dossiers|perfil|perfiles)\b", re.I), "dossier_icp"),
    (re.compile(r"\b(manual|manuales|negocios|aliado\s*digital)\b", re.I), "manual_tech"),
    (re.compile(r"\b(catalogo|catálogo|catalogos|catálogos|catalog|paquete|paquetes|arranque\s*social)\b", re.I), "catalog"),
    (re.compile(r"\b(caso|casos|case|cases|exito|éxito|success)\b", re.I), "case_study"),
    (re.compile(r"\b(proceso|procesos|process|processes|onboarding|workflow)\b", re.I), "process_op"),
    (re.compile(r"\b(contrato|contratos|contract|contracts)\b", re.I), "contract"),
]

VERTICAL_PATTERNS = [
    # joyeria PRIMERO para que "joyeria/diseño" no caiga en moda por "diseño"
    (re.compile(r"\b(joyer[ií]a|jewelry|accesori[oa]s?)\b", re.I), "joyeria_diseno"),
    (re.compile(r"\b(moda|moda\s*etica|moda\s*ética|fashion|prenda|prendas|ropa|slow\s*fashion)\b", re.I), "moda_etica"),
    (re.compile(r"\b(skincare|belleza|beauty|cosmetica|cosmética|cosmetic[oa]s?)\b", re.I), "skincare_d2c"),
    (re.compile(r"\b(mascota|mascotas|pet|pets|perro|perros|gato|gatos)\b", re.I), "mascotas_premium"),
]

# Separadores tipicos de paths/filenames que rompen los word boundaries
# de regex si no se normalizan a espacio.
_INFERENCE_SEPARATORS = re.compile(r"[/_\-.\\]")

CRITICALITY_BY_DOC_TYPE = {
    "contract":      "financial",
    "policy_credit": "financial",
    "sla":           "legal",
    "dossier_icp":   "informational",
    "manual_tech":   "operational",
    "catalog":       "operational",
    "case_study":    "informational",
    "faq":           "informational",
    "process_op":    "operational",
    "unknown":       "informational",
}

# Regex de caracteres no imprimibles (preservamos \n y \t)
NON_PRINTABLE = re.compile(r"[^\x09\x0A\x20-\x7E -￿]")
MULTI_WHITESPACE = re.compile(r"[ \t]+")
MULTI_NEWLINES = re.compile(r"\n{3,}")

# Patrones tipicos de boilerplate por linea (para deteccion de
# headers/footers repetidos)
BOILERPLATE_HINTS = re.compile(
    r"^\s*("
    r"p[aá]gina\s+\d+|"
    r"page\s+\d+|"
    r"confidencial|"
    r"uso\s+interno|"
    r"total\s*play|"
    r"\d+\s*/\s*\d+"
    r")\s*$",
    re.I,
)

# Schema de salida explicito para Parquet (orden estable)
OUTPUT_SCHEMA = StructType([
    StructField("document_id",     StringType(),  nullable=False),
    StructField("page_number",     IntegerType(), nullable=False),
    StructField("raw_text",        StringType(),  nullable=False),
    StructField("source_filename", StringType(),  nullable=False),
    StructField("doc_type",        StringType(),  nullable=False),
    StructField("vertical",        StringType(),  nullable=False),
    StructField("criticality",     StringType(),  nullable=False),
    StructField("content_length",  IntegerType(), nullable=False),
    StructField("language",        StringType(),  nullable=False),
    StructField("version_hash",    StringType(),  nullable=False),
    StructField("extracted_at",    StringType(),  nullable=False),
])


# ============================================================
# Utilidades de inferencia de metadata
# ============================================================
def _normalize_for_inference(text: str) -> str:
    """Reemplaza separadores comunes de paths/filenames (/, _, -, ., \\)
    con espacios para que las regex con word boundaries (\\b) funcionen
    correctamente. Ejemplo:
        'contratos/carrier_billing_v2.3.pdf'
            -> 'contratos carrier billing v2 3 pdf'
    """
    if not text:
        return ""
    return _INFERENCE_SEPARATORS.sub(" ", text)


def infer_doc_type(path: str) -> str:
    """Heuristica: infiere doc_type desde la ruta/nombre del archivo."""
    normalized = _normalize_for_inference(path)
    for pattern, label in DOC_TYPE_PATTERNS:
        if pattern.search(normalized):
            return label
    return "unknown"


def infer_vertical(path: str) -> str:
    """Heuristica: infiere vertical comercial desde la ruta."""
    normalized = _normalize_for_inference(path)
    for pattern, label in VERTICAL_PATTERNS:
        if pattern.search(normalized):
            return label
    return "general"


def infer_criticality(doc_type: str) -> str:
    """Mapea doc_type a criticality regulatoria (LFPDPPP/CNBV)."""
    return CRITICALITY_BY_DOC_TYPE.get(doc_type, "informational")


def compute_version_hash(content_bytes: bytes) -> str:
    """SHA-256 del contenido bruto — usado para idempotencia."""
    return hashlib.sha256(content_bytes).hexdigest()


def compute_document_id(s3_key: str, version_hash: str) -> str:
    """document_id = sha1(key + first 8 chars de version_hash). Estable
    para mismo archivo con mismo contenido; cambia si cambia el contenido.
    """
    seed = f"{s3_key}:{version_hash[:8]}"
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:24]


# ============================================================
# Parsers por formato
# ============================================================
def parse_pdf(content_bytes: bytes) -> List[Tuple[int, str]]:
    """Extrae texto de PDF -> [(page_number, text)].

    Usa PyPDF2 por compatibilidad con Glue (preinstalable via
    --additional-python-modules). En produccion conviene migrar a
    PyMuPDF (fitz) por mejor layout-awareness, pero PyPDF2 cumple
    para fase 1.
    """
    from PyPDF2 import PdfReader  # type: ignore

    pages: List[Tuple[int, str]] = []
    reader = PdfReader(io.BytesIO(content_bytes))
    for i, page in enumerate(reader.pages, start=1):
        try:
            text = page.extract_text() or ""
        except Exception as e:
            logger.warning("PDF page %d extract failure: %s", i, e)
            text = ""
        pages.append((i, text))
    return pages


def parse_docx(content_bytes: bytes) -> List[Tuple[int, str]]:
    """Extrae texto de DOCX -> [(page_number=1, full_text)].

    DOCX no tiene concepto nativo de paginas hasta render. Para fase 1
    devolvemos todo en una sola "pagina logica" (page_number=1); la
    paginacion real puede agregarse despues si el chunker lo necesita.
    """
    from docx import Document  # type: ignore

    document = Document(io.BytesIO(content_bytes))
    paragraphs = [p.text for p in document.paragraphs if p.text.strip()]
    full_text = "\n".join(paragraphs)
    return [(1, full_text)]


def parse_html(content_str: str) -> List[Tuple[int, str]]:
    """Extrae texto de HTML -> [(page_number=1, full_text)]."""
    from bs4 import BeautifulSoup  # type: ignore

    soup = BeautifulSoup(content_str, "html.parser")
    # Remover tags no textuales
    for tag in soup(["script", "style", "noscript", "iframe"]):
        tag.decompose()
    # Extraer texto preservando saltos de bloque
    text = soup.get_text(separator="\n", strip=True)
    return [(1, text)]


# ============================================================
# Limpieza y normalizacion
# ============================================================
def normalize_text(text: str) -> str:
    """Aplica las 4 reglas de limpieza del Prompt 6:
       1. Normalizacion UTF-8 NFC.
       2. Eliminar caracteres no imprimibles.
       3. Colapsar whitespace excesivo.
       4. Strip leading/trailing.
    """
    if not text:
        return ""
    text = unicodedata.normalize("NFC", text)
    text = NON_PRINTABLE.sub("", text)
    text = MULTI_WHITESPACE.sub(" ", text)
    text = MULTI_NEWLINES.sub("\n\n", text)
    return text.strip()


def dedup_headers_footers(pages: List[Tuple[int, str]]) -> List[Tuple[int, str]]:
    """Detecta y elimina lineas que aparecen en headers/footers
    repetidos a lo largo del documento.

    Estrategia:
      - Tomar la primera y la ultima linea no vacia de cada pagina.
      - Contar frecuencia de esas lineas a traves del documento.
      - Si una linea aparece en >= 60% de las paginas, removerla.
      - Adicionalmente remover lineas que matchean patrones tipicos
        de boilerplate (numeracion de pagina, "Confidencial", etc.).

    Solo se aplica si el documento tiene >= 3 paginas; con menos no
    hay suficiente senal para detectar repeticion.
    """
    if len(pages) < 3:
        # Pocos paginas: solo aplicar regex de boilerplate sin frequency check
        return [
            (pn, _strip_boilerplate_lines(text)) for pn, text in pages
        ]

    # Recolectar lineas frontera de cada pagina.
    # Usamos set() para evitar contar dos veces la MISMA linea si una
    # pagina es corta (<=4 lineas) y lines[:2] y lines[-2:] se solapan.
    # Sin esto, en docs cortos el contenido legitimo se cuenta como
    # repetido y se descarta erroneamente.
    boundary_lines: Counter = Counter()
    for _, text in pages:
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        if not lines:
            continue
        # Candidatas a header/footer: primeras 2 + ultimas 2, deduplicadas
        # por pagina antes de contar (evita double-count en paginas cortas).
        candidates = set(lines[:2] + lines[-2:])
        boundary_lines.update(candidates)

    repeat_threshold = max(2, int(0.6 * len(pages)))
    repeated_lines = {ln for ln, count in boundary_lines.items() if count >= repeat_threshold}

    cleaned: List[Tuple[int, str]] = []
    for page_num, text in pages:
        new_lines: List[str] = []
        for ln in text.splitlines():
            stripped = ln.strip()
            if stripped in repeated_lines:
                continue
            if BOILERPLATE_HINTS.match(stripped):
                continue
            new_lines.append(ln)
        cleaned.append((page_num, "\n".join(new_lines)))
    return cleaned


def _strip_boilerplate_lines(text: str) -> str:
    """Solo remueve lineas matching regex de boilerplate (sin frequency)."""
    return "\n".join(
        ln for ln in text.splitlines()
        if not BOILERPLATE_HINTS.match(ln.strip())
    )


# ============================================================
# Procesamiento por documento
# ============================================================
def process_document(s3_key: str, input_bucket: str) -> List[Dict[str, Any]]:
    """Procesa un documento end-to-end. Devuelve lista de filas
    (una por pagina logica) listas para Parquet.

    Maneja errores capturandolos y registrandolos a CloudWatch — un
    documento fallido NO detiene el job completo.
    """
    s3 = boto3.client("s3")
    extracted_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    try:
        # Descargar el documento desde S3
        response = s3.get_object(Bucket=input_bucket, Key=s3_key)
        content_bytes = response["Body"].read()

        # Inferir metadata desde la ruta + contenido
        version_hash = compute_version_hash(content_bytes)
        document_id  = compute_document_id(s3_key, version_hash)
        doc_type     = infer_doc_type(s3_key)
        vertical     = infer_vertical(s3_key)
        criticality  = infer_criticality(doc_type)

        # Parsear segun extension
        ext = s3_key.lower().rsplit(".", 1)[-1] if "." in s3_key else ""
        if ext == "pdf":
            pages = parse_pdf(content_bytes)
        elif ext == "docx":
            pages = parse_docx(content_bytes)
        elif ext in ("html", "htm"):
            try:
                content_str = content_bytes.decode("utf-8")
            except UnicodeDecodeError:
                content_str = content_bytes.decode("latin-1", errors="replace")
            pages = parse_html(content_str)
        else:
            logger.warning("Skipping unsupported extension '%s': %s", ext, s3_key)
            return []

        # Limpieza global por documento (headers/footers entre paginas)
        pages = dedup_headers_footers(pages)

        # Normalizar texto por pagina y emitir filas
        rows: List[Dict[str, Any]] = []
        for page_number, raw_text in pages:
            clean = normalize_text(raw_text)
            if not clean:
                # Skip empty page despues de limpieza (no error)
                continue
            rows.append({
                "document_id":     document_id,
                "page_number":     int(page_number),
                "raw_text":        clean,
                "source_filename": s3_key,
                "doc_type":        doc_type,
                "vertical":        vertical,
                "criticality":     criticality,
                "content_length":  len(clean),
                "language":        "es-MX",
                "version_hash":    version_hash,
                "extracted_at":    extracted_at,
            })

        logger.info(
            "Processed %s: doc_id=%s pages_emitted=%d doc_type=%s vertical=%s",
            s3_key, document_id, len(rows), doc_type, vertical,
        )
        return rows

    except Exception as exc:
        # CRUCIAL: capturamos cualquier excepcion y devolvemos []
        # para que el job continue con el resto de documentos.
        logger.error(
            "FAILED %s: %s\n%s",
            s3_key, exc, traceback.format_exc()
        )
        return []


# ============================================================
# Descubrimiento de documentos en S3
# ============================================================
def list_documents(bucket: str, prefix: str) -> List[str]:
    """Lista todos los objetos S3 bajo el prefijo cuya extension es
    soportada. Usa el paginador para manejar buckets grandes.
    """
    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")
    keys: List[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            ext = key.lower().rsplit(".", 1)[-1] if "." in key else ""
            if f".{ext}" in SUPPORTED_EXTENSIONS:
                keys.append(key)
    return keys


# ============================================================
# Entrada principal
# ============================================================
def main() -> None:
    # 1. Resolver argumentos del Job
    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "input_bucket",
            "output_bucket",
            "input_prefix",
            "output_prefix",
            "max_workers",
        ],
    )

    input_bucket  = args["input_bucket"]
    output_bucket = args["output_bucket"]
    input_prefix  = args.get("input_prefix", "raw/")
    output_prefix = args.get("output_prefix", "clean/")
    max_workers   = int(args.get("max_workers", "50"))

    logger.info("=" * 70)
    logger.info("RAG ETL Job iniciando — %s", args["JOB_NAME"])
    logger.info("Input  : s3://%s/%s", input_bucket, input_prefix)
    logger.info("Output : s3://%s/%s", output_bucket, output_prefix)
    logger.info("Max workers (parallelism): %d", max_workers)
    logger.info("=" * 70)

    # 2. Inicializar Spark + Glue
    sc = SparkContext.getOrCreate()
    glue_context = GlueContext(sc)
    spark: SparkSession = glue_context.spark_session
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    # 3. Descubrir documentos
    document_keys = list_documents(input_bucket, input_prefix)
    total = len(document_keys)
    logger.info("Discovered %d documentos a procesar", total)

    if total == 0:
        logger.warning("No documents found at s3://%s/%s — job exits clean.", input_bucket, input_prefix)
        job.commit()
        return

    # 4. Distribuir documentos como RDD para parsing paralelo
    #    Cada particion procesa un subconjunto de documentos. El parsing
    #    de PDF/DOCX es CPU-bound — usar tantas particiones como workers
    #    permita Glue (G.1X = 4 vCPU, G.2X = 8 vCPU). Default 50 es
    #    suficiente para fase 1 (500 docs).
    num_partitions = min(total, max_workers)
    rdd = sc.parallelize(document_keys, numSlices=num_partitions)

    # Broadcast del bucket name para evitar serializacion repetida
    input_bucket_bc = sc.broadcast(input_bucket)

    def process_partition_doc(key: str) -> Iterable[Dict[str, Any]]:
        # boto3 client se crea por partition / por executor (no es picklable)
        return process_document(key, input_bucket_bc.value)

    results_rdd = rdd.flatMap(process_partition_doc)

    # 5. Convertir RDD a DataFrame con schema explicito y escribir Parquet
    rows_df = spark.createDataFrame(results_rdd, schema=OUTPUT_SCHEMA)
    rows_df.cache()
    emitted = rows_df.count()

    # Distribucion por doc_type para metricas
    logger.info("Filas emitidas: %d (de %d documentos)", emitted, total)
    if emitted > 0:
        dist = (
            rows_df.groupBy("doc_type")
                   .count()
                   .orderBy("count", ascending=False)
                   .collect()
        )
        for row in dist:
            logger.info("  doc_type=%s  rows=%d", row["doc_type"], row["count"])

    output_path = f"s3://{output_bucket}/{output_prefix}"
    logger.info("Escribiendo Parquet a %s", output_path)
    (rows_df.write
            .mode("overwrite")
            .option("compression", "snappy")
            .partitionBy("doc_type")
            .parquet(output_path))

    # 6. Metricas finales para CloudWatch (visible en logs)
    failed = total - rdd.map(
        lambda k: 1 if process_document.__name__ else 0
    ).count()  # heuristica simple; en prod usar accumulator
    logger.info("=" * 70)
    logger.info("RAG ETL Job COMPLETADO")
    logger.info("Documents processed total : %d", total)
    logger.info("Rows emitted              : %d", emitted)
    logger.info("Output path               : %s", output_path)
    logger.info("=" * 70)

    job.commit()


if __name__ == "__main__":
    main()
