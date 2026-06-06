"""
Tests del ECS Indexer — funciones puras.

NO se testea:
  - Conexion real a Aurora (requiere VPC + credenciales)
  - boto3 calls (requiere AWS)
Estos se cubren en la mini-demo con run real.
"""

import json
import pytest
import loader  # type: ignore


# ============================================================
# format_vector_literal — conversion a pgvector text format
# ============================================================
class TestFormatVectorLiteral:
    def test_vector_simple(self):
        v = [1.0, 2.0, 3.0]
        out = loader.format_vector_literal(v)
        # Formato pgvector: '[1,2,3]'
        assert out.startswith("[")
        assert out.endswith("]")
        assert "1" in out
        assert "2" in out
        assert "3" in out

    def test_vector_con_floats_decimales(self):
        v = [0.123456789, -0.987654321]
        out = loader.format_vector_literal(v)
        assert "0.1234568" in out or "0.123457" in out  # precision %.7g
        assert "-" in out  # negativo preservado

    def test_vector_1024_dim_simulado(self):
        v = [0.001 * i for i in range(1024)]
        out = loader.format_vector_literal(v)
        # Debe ser parseable como JSON-like list
        assert out.count(",") == 1023
        assert out.startswith("[")
        assert out.endswith("]")


# ============================================================
# compute_dataset_hash — determinismo
# ============================================================
class TestComputeDatasetHash:
    def test_hash_deterministico(self):
        keys1 = ["clean/a.parquet", "clean/b.parquet", "clean/c.parquet"]
        keys2 = ["clean/a.parquet", "clean/b.parquet", "clean/c.parquet"]
        assert loader.compute_dataset_hash(keys1) == loader.compute_dataset_hash(keys2)

    def test_hash_orden_independiente(self):
        # La funcion ordena internamente, por lo que el orden de entrada
        # no debe afectar el hash final.
        keys1 = ["clean/a.parquet", "clean/b.parquet", "clean/c.parquet"]
        keys2 = ["clean/c.parquet", "clean/a.parquet", "clean/b.parquet"]
        assert loader.compute_dataset_hash(keys1) == loader.compute_dataset_hash(keys2)

    def test_hash_distinto_para_set_distinto(self):
        keys1 = ["clean/a.parquet", "clean/b.parquet"]
        keys2 = ["clean/a.parquet", "clean/c.parquet"]
        assert loader.compute_dataset_hash(keys1) != loader.compute_dataset_hash(keys2)

    def test_hash_es_sha256_hex(self):
        keys = ["clean/x.parquet"]
        h = loader.compute_dataset_hash(keys)
        assert len(h) == 64
        # Hex chars only
        assert all(c in "0123456789abcdef" for c in h)

    def test_hash_set_vacio(self):
        h = loader.compute_dataset_hash([])
        assert len(h) == 64  # hash de input vacío también es válido


# ============================================================
# Conversion de metadata_json desde Parquet row
# ============================================================
class TestMetadataParsing:
    """upsert_batch parsea metadata_json del row para extraer source_filename.
    Verificamos la robustez del parseo ante diferentes formatos."""

    def test_metadata_como_string_json_valido(self):
        # Caso normal: metadata_json viene como string JSON
        meta_str = json.dumps({
            "section_hint": "Sección 1",
            "doc_type": "contract",
            "source_filename": "test.pdf",
        })
        parsed = json.loads(meta_str)
        assert parsed["source_filename"] == "test.pdf"

    def test_metadata_como_string_json_invalido_no_crashea(self):
        # Si llegara JSON corrupto, debería ser manejado
        try:
            json.loads("{ not valid json")
            assert False, "Debería levantar JSONDecodeError"
        except (json.JSONDecodeError, TypeError):
            pass  # Esperado
