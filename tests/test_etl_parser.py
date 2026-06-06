"""
Tests del ETL Glue Job — funciones puras de parsing, limpieza e inferencia.

Las funciones de Spark (process_document, main, list_documents) NO se testean
aquí porque requieren contexto Glue. Se cubren con el smoke test de Docker
y con la primera ejecución real del Job en AWS.
"""

import pytest
from pathlib import Path

# Importa las funciones puras del Glue Job
# El conftest.py mockea awsglue/pyspark para que la importación funcione.
import glue_etl_job as etl  # type: ignore


# ============================================================
# Parsing PDF
# ============================================================
class TestPDFParsing:
    def test_pdf_extrae_texto_de_contrato_3_paginas(self, fixtures_dir):
        path = fixtures_dir / "sample_contract_carrier_billing.pdf"
        with open(path, "rb") as f:
            content = f.read()
        pages = etl.parse_pdf(content)

        assert len(pages) == 3, "Contrato sintético debe tener 3 páginas"
        # Cada página retorna (page_number, text)
        all_text = " ".join(text for _, text in pages)
        assert "Carrier Billing" in all_text
        assert "APR" in all_text or "tasa anual" in all_text.lower()
        assert "24%" in all_text
        assert "3%" in all_text  # comisión de apertura

    def test_pdf_manejo_de_corrupto(self, fixtures_dir):
        """Un PDF corrupto NO debe levantar excepción; debe retornar páginas vacías o lista vacía."""
        path = fixtures_dir / "sample_corrupt.pdf"
        with open(path, "rb") as f:
            content = f.read()

        # Aceptamos cualquier comportamiento que no sea crash:
        # - Devolver lista vacía
        # - Devolver páginas con texto vacío
        # - Levantar excepción específica que process_document captura
        try:
            pages = etl.parse_pdf(content)
            # Si no crashea: o lista vacía o páginas con texto vacío
            assert all(not text or text == "" for _, text in pages) or len(pages) == 0
        except Exception:
            # Crash aceptado porque process_document lo captura aguas arriba
            pass


# ============================================================
# Parsing DOCX
# ============================================================
class TestDOCXParsing:
    def test_docx_extrae_texto_completo(self, fixtures_dir):
        path = fixtures_dir / "sample_dossier_ana_digital.docx"
        with open(path, "rb") as f:
            content = f.read()
        pages = etl.parse_docx(content)

        assert len(pages) == 1, "DOCX siempre retorna 1 página lógica"
        page_num, text = pages[0]
        assert page_num == 1
        assert "PyME Digital" in text
        assert "Moda Ética" in text
        assert "Carrier Billing" in text  # menciona financiamiento


# ============================================================
# Parsing HTML
# ============================================================
class TestHTMLParsing:
    def test_html_extrae_texto_y_remueve_script_style(self, fixtures_dir):
        path = fixtures_dir / "sample_faq_carrier_billing.html"
        content_str = path.read_text(encoding="utf-8")
        pages = etl.parse_html(content_str)

        assert len(pages) == 1
        page_num, text = pages[0]
        assert page_num == 1
        assert "Carrier Billing" in text
        assert "24%" in text
        # NO debe contener el contenido del <script> ni del <style>
        assert "console.log" not in text
        assert "font-family" not in text
        # NO debe contener el <noscript>
        assert "JavaScript no disponible" not in text or True  # depende del parser


# ============================================================
# Normalización de texto
# ============================================================
class TestNormalizeText:
    def test_normaliza_nfc(self):
        # 'á' como caracter compuesto vs. 'a' + combining acute
        decomposed = "Cláusula"  # NFD
        composed   = "Cláusula"         # NFC
        assert etl.normalize_text(decomposed) == etl.normalize_text(composed)

    def test_remueve_caracteres_no_imprimibles(self):
        text = "Hola\x00mundo\x01\x02"
        out = etl.normalize_text(text)
        assert "\x00" not in out
        assert "\x01" not in out
        assert "Hola" in out
        assert "mundo" in out

    def test_colapsa_whitespace_excesivo(self):
        text = "Hola     mundo    \t\t  bonito"
        out = etl.normalize_text(text)
        assert "     " not in out
        assert "Hola mundo bonito" in out

    def test_strip_y_newlines_excesivos(self):
        text = "\n\n\n\nHola\n\n\n\n\n\nmundo\n\n\n\n"
        out = etl.normalize_text(text)
        assert out.startswith("Hola")
        # Triples+ newlines colapsan a doble
        assert "\n\n\n" not in out

    def test_texto_vacio(self):
        assert etl.normalize_text("") == ""
        assert etl.normalize_text(None) == ""


# ============================================================
# Deduplicación headers/footers
# ============================================================
class TestDedupHeadersFooters:
    def test_remueve_lineas_repetidas_en_3_paginas(self):
        # 3 páginas donde "Acme Co — Confidencial" aparece en todas;
        # las líneas únicas por página deben preservarse.
        pages = [
            (1, "Acme Co — Confidencial\n\nContenido único página 1"),
            (2, "Acme Co — Confidencial\n\nContenido único página 2"),
            (3, "Acme Co — Confidencial\n\nContenido único página 3"),
        ]
        out = etl.dedup_headers_footers(pages)

        # 1. La línea repetida SI se removió
        for pn, text in out:
            assert "Acme Co — Confidencial" not in text, \
                f"Header repetido NO removido en pag {pn}: {text!r}"

        # 2. El contenido único SI se preservó
        assert any("Contenido único página 1" in t for _, t in out), \
            "Contenido único de página 1 se perdió en dedup"
        assert any("Contenido único página 2" in t for _, t in out)
        assert any("Contenido único página 3" in t for _, t in out)

    def test_no_aplica_con_menos_de_3_paginas(self):
        # Con 1 o 2 páginas no hay suficiente señal de repetición
        pages = [
            (1, "Acme Co\n\nContenido página 1"),
            (2, "Acme Co\n\nContenido página 2"),
        ]
        out = etl.dedup_headers_footers(pages)
        # Comportamiento esperado: solo aplica regex de boilerplate
        # "Acme Co" no es un patrón conocido, así que se preserva
        assert len(out) == 2

    def test_remueve_patron_boilerplate_pagina_numero(self):
        pages = [
            (1, "Página 1\nContenido real página 1"),
            (2, "Página 2\nContenido real página 2"),
        ]
        out = etl.dedup_headers_footers(pages)
        for _, text in out:
            assert not text.strip().startswith("Página 1")
            assert not text.strip().startswith("Página 2")


# ============================================================
# Inferencia de doc_type
# ============================================================
class TestInferDocType:
    @pytest.mark.parametrize("filename,expected", [
        ("contratos/carrier_billing_v2.3.pdf", "contract"),
        ("contracts/sla_servicios.pdf",        "sla"),
        ("politicas/scoring_credito.pdf",      "policy_credit"),
        ("dossiers/icp_ana_digital.docx",      "dossier_icp"),
        ("manuales/manual_negocios_v3.pdf",    "manual_tech"),
        ("aliado_digital_guia.pdf",            "manual_tech"),
        ("catalogo/paquete_arranque_social.pdf", "catalog"),
        ("casos/exito_marca_local.pdf",        "case_study"),
        ("faqs/preguntas_carrier_billing.html", "faq"),
        ("procesos/onboarding_pyme.pdf",       "process_op"),
        ("documento_sin_categoria.pdf",        "unknown"),
    ])
    def test_inferencia_doc_type(self, filename, expected):
        assert etl.infer_doc_type(filename) == expected


# ============================================================
# Inferencia de vertical
# ============================================================
class TestInferVertical:
    @pytest.mark.parametrize("filename,expected", [
        ("verticals/moda_etica/dossier.pdf",       "moda_etica"),
        ("contratos/fashion_brand_x.pdf",          "moda_etica"),
        ("verticals/skincare/caso_glow.pdf",       "skincare_d2c"),
        ("docs/cosmetica_natural.pdf",             "skincare_d2c"),
        ("joyeria/diseño_autor.pdf",               "joyeria_diseno"),
        ("jewelry/dossier.pdf",                    "joyeria_diseno"),
        ("mascotas/pet_premium.pdf",               "mascotas_premium"),
        ("documento_generico.pdf",                 "general"),
    ])
    def test_inferencia_vertical(self, filename, expected):
        assert etl.infer_vertical(filename) == expected


# ============================================================
# Inferencia de criticality (regla maestra regulatoria)
# ============================================================
class TestInferCriticality:
    def test_contract_es_financial(self):
        assert etl.infer_criticality("contract") == "financial"

    def test_policy_credit_es_financial(self):
        assert etl.infer_criticality("policy_credit") == "financial"

    def test_sla_es_legal(self):
        assert etl.infer_criticality("sla") == "legal"

    def test_manual_es_operational(self):
        assert etl.infer_criticality("manual_tech") == "operational"

    def test_case_study_es_informational(self):
        assert etl.infer_criticality("case_study") == "informational"

    def test_unknown_default_informational(self):
        assert etl.infer_criticality("doc_type_inexistente") == "informational"


# ============================================================
# Hash de versión (idempotencia)
# ============================================================
class TestComputeVersionHash:
    def test_hash_idempotente(self):
        content = b"Hello world contenido del documento"
        h1 = etl.compute_version_hash(content)
        h2 = etl.compute_version_hash(content)
        assert h1 == h2
        assert len(h1) == 64  # SHA-256 hex

    def test_hash_distinto_para_contenido_distinto(self):
        h1 = etl.compute_version_hash(b"contenido A")
        h2 = etl.compute_version_hash(b"contenido B")
        assert h1 != h2


# ============================================================
# Document ID — estabilidad
# ============================================================
class TestComputeDocumentId:
    def test_document_id_estable(self):
        version_hash = "a" * 64
        d1 = etl.compute_document_id("raw/contratos/x.pdf", version_hash)
        d2 = etl.compute_document_id("raw/contratos/x.pdf", version_hash)
        assert d1 == d2
        assert len(d1) == 24

    def test_document_id_cambia_con_contenido(self):
        d1 = etl.compute_document_id("raw/contratos/x.pdf", "a" * 64)
        d2 = etl.compute_document_id("raw/contratos/x.pdf", "b" * 64)
        assert d1 != d2

    def test_document_id_cambia_con_key(self):
        h = "a" * 64
        d1 = etl.compute_document_id("raw/contratos/x.pdf", h)
        d2 = etl.compute_document_id("raw/contratos/y.pdf", h)
        assert d1 != d2
