# ============================================================
# RAG Indexer — Multi-stage Docker image
# ============================================================
# Stage 1 (builder): instala dependencias en un venv aislado.
# Stage 2 (runtime): copia solo el venv + codigo, usuario no-root.
#
# Base: python:3.11-slim-bookworm (Debian, mas chica que la oficial
# y con security patches recientes).
# Arquitectura: arm64 (Fargate arm64 es ~20% mas barato que x86_64).
#
# Tamano esperado: ~250 MB (psycopg2 binary + pyarrow + boto3).

# ----------------------------------------------------------------
# STAGE 1: builder
# ----------------------------------------------------------------
FROM python:3.11-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Dependencias del sistema necesarias para compilar psycopg2 (no
# necesarias con psycopg2-binary, pero las dejamos por si cambiamos)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Crear venv aislado en /opt/venv
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip && \
    pip install -r /tmp/requirements.txt

# ----------------------------------------------------------------
# STAGE 2: runtime
# ----------------------------------------------------------------
FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Dependencias runtime minimas (libpq solo para psycopg2-binary,
# que ya incluye su propia copia, pero la dejamos para fallback)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copiar venv del builder
COPY --from=builder /opt/venv /opt/venv

# Crear usuario no-root y workdir
RUN useradd --create-home --shell /bin/bash --uid 1001 indexer && \
    mkdir -p /app && chown indexer:indexer /app
WORKDIR /app

# Copiar codigo
COPY --chown=indexer:indexer loader.py /app/loader.py
COPY --chown=indexer:indexer sql/ /app/sql/

USER indexer

# Healthcheck: imports principales cargan correctamente
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import boto3, psycopg2, pyarrow; print('OK')" || exit 1

# Entry point
ENTRYPOINT ["python", "-u", "/app/loader.py"]
