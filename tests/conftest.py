"""
Pytest conftest — setup global para tests del pipeline RAG.

Mocks:
  - awsglue, pyspark (no se instalan en WSL local)
  - psycopg2 (evitar dependencia de libpq en WSL para tests puros)
  - boto3 clients no se mockean: boto3.client() no hace network calls
    en construccion, solo cuando se invocan metodos.

Env vars: setdefault para los modulos que requieren env at import time.

Paths: agrega etl/, chunking/, indexer/ al sys.path para importar
los modulos del proyecto.
"""

import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

# ============================================================
# 1. Mock de modulos no instalados en WSL local
# ============================================================
_MOCK_MODULES = [
    "awsglue",
    "awsglue.context",
    "awsglue.job",
    "awsglue.utils",
    "awsglue.transforms",
    "pyspark",
    "pyspark.context",
    "pyspark.sql",
    "pyspark.sql.types",
    "psycopg2",
    "psycopg2.extras",
]
for _mod in _MOCK_MODULES:
    if _mod not in sys.modules:
        sys.modules[_mod] = MagicMock()


# ============================================================
# 2. Env vars necesarios para que los modulos importen sin KeyError
# ============================================================
os.environ.setdefault("AWS_REGION", "us-east-1")
os.environ.setdefault("EMBEDDINGS_BUCKET", "test-embeddings-bucket")
os.environ.setdefault("DDB_AUDIT_TABLE", "test-chunk-quality-audit")
os.environ.setdefault("AURORA_SECRET_ARN", "arn:aws:secretsmanager:us-east-1:000000000000:secret:test")
os.environ.setdefault("DDB_VERSIONS_TABLE", "test-index-versions")
os.environ.setdefault("BEDROCK_MODEL_ID", "amazon.titan-embed-text-v2:0")
os.environ.setdefault("EMBEDDING_DIMENSIONS", "1024")


# ============================================================
# 3. Path setup — importar modulos del proyecto
# ============================================================
PROJECT_ROOT = Path(__file__).resolve().parent.parent
for _p in ("etl", "chunking", "indexer"):
    _path = str(PROJECT_ROOT / _p)
    if _path not in sys.path:
        sys.path.insert(0, _path)


# ============================================================
# 4. Fixtures pytest
# ============================================================
import pytest  # noqa: E402  (despues del path setup)


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Genera (si no existen) los documentos sintéticos y devuelve el dir."""
    d = PROJECT_ROOT / "tests" / "fixtures" / "samples"
    d.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(PROJECT_ROOT / "tests" / "fixtures"))
    from generate_docs import ensure_all  # type: ignore
    ensure_all(d)
    return d


@pytest.fixture(scope="session")
def project_root() -> Path:
    return PROJECT_ROOT
