"""
Tests del Lambda chunking — Quality Gate + chunker + funciones auxiliares.

Crítico: la regla maestra (chunks financieros NUNCA se descartan) es el
test más importante para compliance CNBV. Si rompe, el riesgo regulatorio
es material.

NO se testea:
  - Llamada real a Bedrock (require AWS credentials + cuota)
  - S3 download/upload (require AWS)
  - DynamoDB writes (require AWS)
Estos se cubren en la mini-demo (Opción 2) con un run real del pipeline.
"""

import pytest
import lambda_function as lf  # type: ignore


# ============================================================
# Quality Gate — REGLA MAESTRA (chunks financieros NUNCA discard)
# ============================================================
class TestQualityGateReglaMaestra:
    """Estos tests son los mas criticos del proyecto. Si fallan,
    es riesgo CNBV/CONDUSEF material."""

    def test_chunk_corto_pero_financiero_NO_se_descarta(self):
        # Texto muy corto pero con marcador financiero CNBV
        chunk = "APR 24% comisión de apertura 3%"
        verdict, reasons, metrics = lf.quality_gate(chunk, "informational")
        assert verdict in ("warning", "pass"), \
            f"REGRESION CRITICA: chunk financiero se descarto. reasons={reasons}"
        assert metrics["has_financial_marker"] is True

    def test_chunk_financial_declarado_con_flags_va_a_warning(self):
        # criticality=financial declarado + texto corto -> warning, no discard
        chunk = "Cláusula 4.2"  # muy corto
        verdict, reasons, _ = lf.quality_gate(chunk, "financial")
        assert verdict == "warning"
        assert "too_short" in reasons

    def test_chunk_no_financiero_corto_si_se_descarta(self):
        chunk = "Hola"  # < 100 tokens, sin financial markers
        verdict, _, _ = lf.quality_gate(chunk, "informational")
        assert verdict == "discard"

    def test_marcador_carrier_billing_promueve_a_financial(self):
        chunk = "El servicio Carrier Billing está disponible para PyMEs " * 10
        verdict, reasons, metrics = lf.quality_gate(chunk, "informational")
        assert metrics["has_financial_marker"] is True
        assert "financial_marker_detected" in reasons

    def test_marcador_clausula_promueve_a_financial(self):
        chunk = "Esta cláusula regula el tratamiento de datos " * 10
        _, _, metrics = lf.quality_gate(chunk, "informational")
        assert metrics["has_financial_marker"] is True


# ============================================================
# Quality Gate — reglas estándar
# ============================================================
class TestQualityGateReglas:
    def test_texto_largo_diverso_pasa(self):
        # Texto > 120 tokens (umbral minimo del Quality Gate es 100) y con
        # alta diversidad lexica (TTR > 0.30) — debe pasar limpio.
        chunk = (
            "Este es un párrafo extenso con vocabulario diverso, conteniendo "
            "información sustantiva sobre los procesos operativos del marketplace. "
            "Cubre múltiples aspectos del flujo de trabajo, incluyendo onboarding, "
            "validación de identidad, criterios comerciales y reglas de escalamiento. "
            "El equipo de Customer Success utiliza esta documentación de referencia "
            "para resolver consultas de PyMEs en las verticales operativas activas. "
            "Los asesores consultan guías técnicas, dossiers actualizados, "
            "y políticas operativas vigentes antes de responder consultas críticas "
            "que requieren conocimiento especializado del marketplace y sus reglas. "
            "Esta documentación se actualiza mensualmente con feedback del campo, "
            "manteniendo coherencia narrativa entre versiones consecutivas del índice."
        )
        verdict, _, _ = lf.quality_gate(chunk, "informational")
        assert verdict == "pass"

    def test_texto_repetitivo_se_descarta_por_ttr_bajo(self):
        # TTR muy bajo: pocas palabras únicas
        chunk = ("uno dos uno dos " * 50)  # más de 100 tokens pero TTR ~ 0.04
        verdict, reasons, metrics = lf.quality_gate(chunk, "informational")
        # TTR bajo + texto corto/repetitivo
        assert metrics["ttr"] < 0.30
        assert verdict == "discard"
        assert "low_diversity" in reasons

    def test_boilerplate_pagina_se_descarta(self):
        chunk = "Página 3"
        verdict, reasons, _ = lf.quality_gate(chunk, "informational")
        assert verdict == "discard"
        # too_short + boilerplate_match son ambos válidos
        assert "too_short" in reasons or "boilerplate_match" in reasons

    def test_metricas_se_reportan_correctamente(self):
        chunk = "Este es un texto de prueba con cierta diversidad léxica."
        _, _, metrics = lf.quality_gate(chunk, "informational")
        assert "length_tokens" in metrics
        assert "ttr" in metrics
        assert "has_financial_marker" in metrics
        assert metrics["length_tokens"] > 0
        assert 0 <= metrics["ttr"] <= 1.0


# ============================================================
# Detección de marcadores financieros
# ============================================================
class TestHasFinancialMarker:
    @pytest.mark.parametrize("text,expected", [
        ("APR 24% sobre saldo",                      True),
        ("La tasa anual del 24% se aplica",          True),
        ("El CAT regulatorio vigente es 35%",        True),
        ("Servicio Carrier Billing disponible",      True),
        ("Comisión de apertura del 3%",              True),
        ("Esta cláusula no aplica",                  True),
        ("Cargos por mora aplicables",               True),
        ("Penalización del 1.5% mensual",            True),
        ("Scoring crediticio favorable",             True),
        ("Aplicamos un 24% de descuento",            True),  # match en "24%"
        ("Texto totalmente neutro sobre productos",  False),
        ("",                                          False),
        ("Hola mundo bonito",                        False),
    ])
    def test_deteccion(self, text, expected):
        assert lf.has_financial_marker(text) == expected


# ============================================================
# Type-Token Ratio
# ============================================================
class TestTypeTokenRatio:
    def test_ttr_alto_para_texto_diverso(self):
        text = "uno dos tres cuatro cinco seis siete ocho nueve diez"
        assert lf.type_token_ratio(text) == 1.0  # 10/10

    def test_ttr_bajo_para_texto_repetitivo(self):
        text = "hola " * 50
        assert lf.type_token_ratio(text) < 0.1

    def test_ttr_vacio(self):
        assert lf.type_token_ratio("") == 0.0
        assert lf.type_token_ratio(None) == 0.0


# ============================================================
# Chunk ID — idempotencia y unicidad
# ============================================================
class TestComputeChunkId:
    def test_idempotente(self):
        cid1 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        cid2 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        assert cid1 == cid2
        assert len(cid1) == 24

    def test_distinto_por_content(self):
        cid1 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        cid2 = lf.compute_chunk_id("doc1", 1, 0, "Hello mundo")
        assert cid1 != cid2

    def test_distinto_por_chunk_index(self):
        cid1 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        cid2 = lf.compute_chunk_id("doc1", 1, 1, "Hello world")
        assert cid1 != cid2

    def test_distinto_por_document_id(self):
        cid1 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        cid2 = lf.compute_chunk_id("doc2", 1, 0, "Hello world")
        assert cid1 != cid2

    def test_distinto_por_page(self):
        cid1 = lf.compute_chunk_id("doc1", 1, 0, "Hello world")
        cid2 = lf.compute_chunk_id("doc1", 2, 0, "Hello world")
        assert cid1 != cid2


# ============================================================
# Extract section hint
# ============================================================
class TestExtractSectionHint:
    def test_primera_linea_no_vacia(self):
        chunk = "Cláusula 4.2 Cargos por mora\n\nEl cliente acepta..."
        assert lf.extract_section_hint(chunk) == "Cláusula 4.2 Cargos por mora"

    def test_saltos_iniciales(self):
        chunk = "\n\n\n\nTítulo real\n\nContenido"
        assert lf.extract_section_hint(chunk) == "Título real"

    def test_truncamiento_a_max_len(self):
        long_line = "x" * 200
        hint = lf.extract_section_hint(long_line, max_len=80)
        assert len(hint) == 80

    def test_texto_vacio(self):
        assert lf.extract_section_hint("") == ""
        assert lf.extract_section_hint(None) == ""

    def test_solo_whitespace(self):
        assert lf.extract_section_hint("   \n   \n   ") == ""


# ============================================================
# Splitter — sanity check de RecursiveCharacterTextSplitter
# ============================================================
class TestSplitter:
    def test_split_devuelve_lista_de_chunks(self):
        splitter = lf.get_splitter()
        text = "Esto es una oración. " * 200  # texto largo
        chunks = splitter.split_text(text)
        assert isinstance(chunks, list)
        assert len(chunks) >= 1
        assert all(isinstance(c, str) for c in chunks)

    def test_split_respeta_chunk_size_max_aproximadamente(self):
        splitter = lf.get_splitter()
        text = "palabra " * 5000  # ~5000 tokens approx
        chunks = splitter.split_text(text)
        # Algún chunk podría exceder ligeramente debido al overlap
        # y a la regla de unidad atómica. Tolerancia: 20%.
        for c in chunks:
            tokens = lf.count_tokens(c)
            assert tokens <= int(lf.CHUNK_SIZE_MAX * 1.2), \
                f"Chunk de {tokens} tokens excede 1500*1.2={1500*1.2}"

    def test_split_texto_corto(self):
        splitter = lf.get_splitter()
        text = "Texto muy corto."
        chunks = splitter.split_text(text)
        assert len(chunks) == 1


# ============================================================
# Count tokens
# ============================================================
class TestCountTokens:
    def test_count_no_vacio(self):
        assert lf.count_tokens("Hola mundo") > 0

    def test_count_vacio(self):
        assert lf.count_tokens("") == 0
        assert lf.count_tokens(None) == 0

    def test_count_creciente(self):
        c1 = lf.count_tokens("Hola")
        c2 = lf.count_tokens("Hola mundo")
        c3 = lf.count_tokens("Hola mundo bonito")
        assert c1 < c2 < c3
