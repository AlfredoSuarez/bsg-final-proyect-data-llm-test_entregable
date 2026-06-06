"""Genera el PDF consolidado del entregable usando Chrome headless (Playwright).

Resuelve el issue de tablas encimadas que tenia xhtml2pdf (CSS3 limitado).
Chrome renderiza CSS completo: table-layout fixed, word-wrap, page-break, etc.

Salida: evidence/Proyecto12_Entregable_Final.pdf
"""
from pathlib import Path
import re
import markdown
import base64
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent  # Proyecto_Final/
OUT = ROOT / "evidence" / "Proyecto12_Entregable_Final.pdf"

# Orden de los documentos
SECTIONS = [
    ("Parte I — Overview ejecutivo", [
        ("README.md",                                   "README"),
        ("docs/CHECKPOINT.md",                          "Estado del proyecto"),
    ]),
    ("Parte II — Especificacion tecnica", [
        ("docs/00_decisiones_clave.md",                 "Decisiones clave (sintesis ejecutiva AWS + Titan V2)"),
        ("docs/01_caso_de_uso.md",                      "Caso de uso"),
        ("docs/02_seleccion_embeddings.md",             "Seleccion de embeddings"),
        ("docs/03_semantic_chunking_pattern.md",        "Semantic chunking pattern"),
        ("docs/04_arquitectura.md",                     "Arquitectura"),
        ("docs/08_indexacion_aurora_pgvector.md",       "Indexacion Aurora + pgvector"),
        ("docs/09_versionamiento_observabilidad.md",    "Versionamiento + observabilidad"),
        ("docs/SECURITY.md",                            "Seguridad y entorno"),
    ]),
    ("Parte III — Operacion", [
        ("docs/10_guia_usuario.md",                     "Guia de usuario"),
        ("docs/11_guia_administrador.md",               "Guia de administrador"),
        ("docs/12_lecciones_aprendidas.md",             "Lecciones aprendidas (incluye 12 bugs reales del deploy)"),
    ]),
    ("Parte IV — KPIs y medicion", [
        ("docs/13_indicadores_y_justificacion.md",      "Indicadores y justificacion (4 capas)"),
        ("docs/14_kpis_agente_llm_referencia.md",       "Catalogo KPIs agente LLM (referencia)"),
    ]),
    ("Parte V — Evidencia del deploy real a AWS", [
        ("evidence/cloud/RUN_demo-20260601-015935.md",  "RUN principal SUCCEEDED end-to-end"),
        ("evidence/cloud/RUN_demo-20260601-014747.md",  "RUN historico pre-fix doc_type (referencia)"),
        ("evidence/cloud/artifacts/README.md",          "Inventario de artefactos visuales"),
        ("evidence/cloud/artifacts/tables.md",          "Tablas DDB + Step Functions history"),
    ]),
]


# Las imagenes se referencian via file:// para evitar HTML enorme con base64.
# El HTML final vive en evidence/ asi que apuntamos a cloud/artifacts/*.png (mismo dir).
IMG_SFN = (ROOT / "evidence/cloud/artifacts/sfn_diagram.png").as_uri()
IMG_CW = (ROOT / "evidence/cloud/artifacts/cw_metrics.png").as_uri()
print(f"Imagen sfn_diagram: {IMG_SFN}")
print(f"Imagen cw_metrics:  {IMG_CW}")


def fix_md(content: str) -> str:
    content = content.replace("evidence/cloud/artifacts/sfn_diagram.png", IMG_SFN)
    content = content.replace("artifacts/sfn_diagram.png", IMG_SFN)
    content = content.replace("evidence/cloud/artifacts/cw_metrics.png", IMG_CW)
    content = content.replace("artifacts/cw_metrics.png", IMG_CW)
    return content


# Construir mega-markdown
mega_md_parts = []

mega_md_parts.append("""
# Proyecto 12 — LLM Data Engineering Pipeline

## Acme Co Marketplace B2B PyME · Economic Graph de la PyME Mexicana

**Curso:** Diseño de Infraestructura Escalable — BSG Institute
**Estudiante:** Alfredo Suarez · arse.alf@gmail.com
**Profesor:** Msc. Andres Felipe Rojas Parra · andres.rojas@triskelss.com
**Fecha de entrega final:** 2026-06-01
**Repo:** https://github.com/AlfredoSuarez/bsg-final-proyect-data-llm-test (privado)

### Entregable consolidado

Este documento PDF reune los 17 archivos del proyecto en un solo output:
- 1 README ejecutivo + 1 documento de decisiones clave + 14 documentos de especificacion
- 2 archivos de evidencia del deploy real a AWS
- 2 visualizaciones inline (Step Functions diagram + CloudWatch charts)
- Tablas con datos reales medidos en AWS

### Estado del entregable

- 12/12 componentes de la rubrica (~92/100 pts directos)
- Tests locales: 93/93 pytest verde
- Docker builds arm64: healthcheck OK
- pgvector local + Aurora real: HNSW + cosine search funcional
- Deploy real end-to-end SUCCEEDED en AWS (`run-demo-20260601-015935`, 2 min 30s)
- 5 chunks indexados en Aurora con embeddings Titan V2 (1024 dim) y HNSW
- Regla maestra CNBV verificada: 100% chunks pass con marcador financiero detectado
- KPIs en 4 capas: tecnica + negocio + compliance + roadmap agente LLM
- 12 bugs reales del deploy documentados como lecciones aprendidas

---
""")

# Indice
mega_md_parts.append("\n## Indice del documento\n\n")
for part_idx, (part_title, files) in enumerate(SECTIONS, 1):
    mega_md_parts.append(f"\n**{part_title}**\n\n")
    for rel_path, title in files:
        mega_md_parts.append(f"- {title} (`{rel_path}`)\n")

mega_md_parts.append("\n---\n\n")

# Procesar secciones
total_chars = 0
for part_idx, (part_title, files) in enumerate(SECTIONS, 1):
    print(f"Procesando {part_title}...")
    mega_md_parts.append(f"\n\n<div class='page-break'></div>\n\n")
    mega_md_parts.append(f"# {part_title}\n\n")

    for rel_path, title in files:
        full = ROOT / rel_path
        if not full.exists():
            print(f"  [SKIP] No existe: {rel_path}")
            continue
        try:
            raw = full.read_text(encoding="utf-8")
        except Exception as e:
            print(f"  [ERR ] {rel_path}: {e}")
            continue

        # Bajar todos los headers un nivel
        adjusted = re.sub(r"^(#+) ", lambda m: "#" + m.group(1) + " ", raw, flags=re.MULTILINE)

        mega_md_parts.append(f"\n\n<div class='page-break'></div>\n\n")
        mega_md_parts.append(f"## {title}\n\n")
        mega_md_parts.append(f"_Fuente: `{rel_path}`_\n\n")
        mega_md_parts.append("---\n\n")
        mega_md_parts.append(fix_md(adjusted))
        total_chars += len(adjusted)

mega_md = "".join(mega_md_parts)
print(f"\nMega markdown: {len(mega_md):,} chars ({total_chars:,} de contenido)")

# Guardar .md
md_path = ROOT / "evidence" / "Proyecto12_Entregable_Final.md"
md_path.write_text(mega_md, encoding="utf-8")

# Markdown -> HTML
print("Convirtiendo a HTML...")
html_body = markdown.markdown(
    mega_md,
    extensions=["tables", "fenced_code", "sane_lists"],
)

# CSS para Chrome headless (no usa @page header/footer - eso lo hace displayHeaderFooter)
css = """
@page {
    size: A4;
    margin: 1.8cm 1.5cm 1.8cm 1.5cm;
}

* { box-sizing: border-box; }

body {
    font-family: 'Segoe UI', 'Helvetica Neue', Arial, sans-serif;
    font-size: 10pt;
    line-height: 1.55;
    color: #2c3e50;
    margin: 0;
    padding: 0;
}

.page-break {
    page-break-before: always;
    break-before: page;
}

h1 {
    font-size: 22pt;
    color: #16a085;
    border-bottom: 3px solid #16a085;
    padding-bottom: 8px;
    margin-top: 1em;
    margin-bottom: 0.6em;
    page-break-after: avoid;
}

h2 {
    font-size: 16pt;
    color: #2980b9;
    border-bottom: 1.5px solid #bdc3c7;
    padding-bottom: 4px;
    margin-top: 1.4em;
    margin-bottom: 0.5em;
    page-break-after: avoid;
}

h3 {
    font-size: 13pt;
    color: #34495e;
    margin-top: 1.1em;
    margin-bottom: 0.4em;
    page-break-after: avoid;
}

h4 { font-size: 11.5pt; color: #7f8c8d; margin-top: 1em; page-break-after: avoid; }
h5, h6 { font-size: 10.5pt; color: #95a5a6; page-break-after: avoid; }

p {
    margin: 0.4em 0;
    text-align: justify;
    hyphens: auto;
}

strong { color: #c0392b; }
em { color: #555; }

code {
    background: #ecf0f1;
    padding: 1.5px 5px;
    border-radius: 3px;
    font-family: 'Consolas', 'Courier New', monospace;
    font-size: 9pt;
    color: #c0392b;
    word-break: break-word;
}

pre {
    background: #2c3e50;
    color: #ecf0f1;
    padding: 10px 14px;
    border-radius: 4px;
    font-size: 8pt;
    overflow: hidden;
    white-space: pre-wrap;
    word-wrap: break-word;
    word-break: break-all;
    page-break-inside: avoid;
    margin: 0.8em 0;
}

pre code {
    background: transparent;
    color: inherit;
    padding: 0;
    word-break: normal;
}

/* TABLAS - layout fixed para evitar encimado */
table {
    border-collapse: collapse;
    margin: 0.8em 0;
    width: 100%;
    font-size: 8.5pt;
    table-layout: fixed;
    page-break-inside: auto;
}

table thead {
    display: table-header-group;
}

table tr {
    page-break-inside: avoid;
}

th, td {
    border: 1px solid #bdc3c7;
    padding: 5px 7px;
    text-align: left;
    vertical-align: top;
    word-wrap: break-word;
    overflow-wrap: break-word;
    hyphens: auto;
    max-width: 0;
}

th {
    background-color: #16a085 !important;
    color: white;
    font-weight: 600;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
}

tr:nth-child(even) td {
    background-color: #f8f9fa;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
}

table code {
    font-size: 7.5pt;
}

blockquote {
    border-left: 4px solid #f39c12;
    background: #fef9e7;
    margin: 0.8em 0;
    padding: 8px 14px;
    font-style: italic;
    color: #7f5b00;
    page-break-inside: avoid;
}

img {
    max-width: 100%;
    height: auto;
    display: block;
    margin: 1em auto;
    border: 1px solid #bdc3c7;
    border-radius: 4px;
    page-break-inside: avoid;
}

a {
    color: #2980b9;
    text-decoration: none;
    word-break: break-word;
}

ul, ol {
    margin: 0.4em 0;
    padding-left: 1.8em;
}

li {
    margin: 0.15em 0;
    text-align: justify;
}

hr {
    border: none;
    border-top: 1px solid #bdc3c7;
    margin: 1.5em 0;
}

/* Mejoras para tablas con muchas columnas (>4): font mas pequena */
table.wide {
    font-size: 7.5pt;
}
table.wide th, table.wide td {
    padding: 3px 5px;
}
"""

html_full = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>Proyecto 12 — Entregable Final</title>
  <style>{css}</style>
</head>
<body>
{html_body}
</body>
</html>
"""

html_path = ROOT / "evidence" / "Proyecto12_Entregable_Final.html"
html_path.write_text(html_full, encoding="utf-8")
print(f"HTML guardado: {html_path} ({len(html_full):,} bytes)")

# Header y footer HTML para displayHeaderFooter (Chrome nativo)
header_html = """
<div style="width:100%; font-size:8px; color:#16a085; padding: 0 1.5cm; text-align:right;">
  Acme Co Marketplace B2B PyME &middot; Proyecto 12 BSG
</div>
"""

footer_html = """
<div style="width:100%; font-size:7.5px; color:#888; padding: 0 1.5cm; display: flex; justify-content: space-between;">
  <span>Proyecto 12 - LLM Data Engineering Pipeline - BSG Institute</span>
  <span>Pagina <span class="pageNumber"></span> de <span class="totalPages"></span></span>
</div>
"""

# Renderizar con Chrome headless via Playwright
print("\nRenderizando a PDF con Chrome headless (esto tarda 30-90 s)...")

html_uri = html_path.as_uri()  # file:///C:/...
print(f"Cargando: {html_uri}")

with sync_playwright() as p:
    browser = p.chromium.launch()
    context = browser.new_context()
    page = context.new_page()
    page.set_default_timeout(120000)  # 2 min
    page.goto(html_uri, wait_until="load")
    page.wait_for_load_state("networkidle", timeout=60000)
    print("HTML cargado, generando PDF...")
    page.pdf(
        path=str(OUT),
        format="A4",
        print_background=True,
        margin={"top": "2cm", "bottom": "1.8cm", "left": "1.5cm", "right": "1.5cm"},
        display_header_footer=True,
        header_template=header_html,
        footer_template=footer_html,
    )
    browser.close()

size_mb = OUT.stat().st_size / (1024*1024)
print(f"\n[OK] PDF generado: {OUT}")
print(f"     Tamano: {size_mb:.2f} MB")
