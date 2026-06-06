# ============================================================
# Lambda chunking + embeddings — Multi-stage container image
# ============================================================
# Stage 1 (builder): instala dependencias en una capa separada para
# aprovechar cache de Docker.
# Stage 2 (runtime): imagen final con base AWS Lambda Python 3.11 arm64,
# sólo lo necesario para ejecutar la Lambda.
#
# Tamaño esperado de la imagen final: ~700 MB (PyArrow + LangChain pesan).
# Arquitectura: arm64 — 20% más barato y ~10% más rápido que x86_64 en
# AWS Lambda para cargas Python típicas.

# ----------------------------------------------------------------
# STAGE 1: builder — sólo para instalar deps en un directorio limpio
# ----------------------------------------------------------------
FROM public.ecr.aws/lambda/python:3.11-arm64 AS builder

# Copiar requirements y precompilar wheels al directorio de Lambda
COPY requirements.txt /tmp/requirements.txt

# pip target instala en una ruta que copiamos al stage final;
# --no-cache-dir reduce el tamaño de la capa.
# IMPORTANTE: separamos pip install del cleanup para que un fallo de pip
# aborte el build (el chaining anterior con || true enmascaraba fallas).
RUN pip install --no-cache-dir \
        --target /opt/python \
        -r /tmp/requirements.txt \
 && test -d /opt/python \
 && echo "deps instaladas:" && ls /opt/python | head -10

# Limpieza de archivos no necesarios para runtime (mantenemos dist-info
# para que pip pueda introspectar versiones en debugging).
RUN find /opt/python -type d -name "__pycache__" -prune -exec rm -rf {} + ; \
    find /opt/python -type d -name "tests"       -prune -exec rm -rf {} + ; \
    find /opt/python -type d -name "test"        -prune -exec rm -rf {} + ; \
    true

# ----------------------------------------------------------------
# STAGE 2: runtime — imagen final, mínima
# ----------------------------------------------------------------
FROM public.ecr.aws/lambda/python:3.11-arm64

# Copiar dependencias instaladas del builder
COPY --from=builder /opt/python ${LAMBDA_TASK_ROOT}

# Copiar el código de la Lambda
COPY lambda_function.py ${LAMBDA_TASK_ROOT}/

# La imagen base de AWS Lambda ya ejecuta como usuario no-root (sbx_user1051)
# y expone PYTHONPATH=${LAMBDA_TASK_ROOT} automáticamente.

# Pre-descargar tokenizer tiktoken durante el build.
# La Lambda corre en VPC privado sin egress a Azure Blob — sin esta cache
# el primer invoke falla con ConnectTimeoutError contra openaipublic.blob.core.windows.net.
ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken_cache
RUN mkdir -p ${TIKTOKEN_CACHE_DIR} && \
    python -c "import os; os.environ['TIKTOKEN_CACHE_DIR']='/opt/tiktoken_cache'; import tiktoken; enc=tiktoken.get_encoding('cl100k_base'); print('cl100k_base tokens en test:', len(enc.encode('Acme Co Marketplace test')))"

# Healthcheck minimo + verificar que el tokenizer carga desde cache
RUN python -c "import os; os.environ['TIKTOKEN_CACHE_DIR']='/opt/tiktoken_cache'; import boto3, pyarrow, tiktoken, langchain_text_splitters; tiktoken.get_encoding('cl100k_base'); print('OK con tokenizer cacheado')"

# Handler entry point — AWS Lambda lo invoca automáticamente
CMD ["lambda_function.lambda_handler"]
