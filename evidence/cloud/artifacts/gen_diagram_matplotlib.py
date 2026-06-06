"""Genera PNG del flujo Step Functions con matplotlib (sin deps externas)."""
import json
import collections
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

defn = json.load(open("sfn_definition.json"))
history = json.load(open("sfn_history.json"))

# Estados visitados
visited = collections.Counter()
for e in history["events"]:
    name = (e.get("stateEnteredEventDetails") or {}).get("name")
    if name:
        visited[name] += 1

# Layout vertical: nodos en orden lineal del happy path
order = [
    ("InitializeRun", "Pass"),
    ("StartGlueETL", "Glue Job\nsync"),
    ("ListCleanParquetFiles", "S3 ListObjectsV2"),
    ("ChunkAllParquetsInParallel", "Map\n(MaxConcur=5)"),
    ("InvokeChunkingLambda", "Lambda invoke\n(per item)"),
    ("RunIndexerTask", "ECS Fargate\nrun task"),
    ("RegisterIndexVersion", "DDB PutItem"),
    ("PublishCustomMetric", "CW PutMetric"),
    ("NotifySuccess", "SNS Publish"),
]

failure_branch = [
    ("NotifyFailure", "SNS Publish"),
    ("PublishFailureMetric", "CW PutMetric"),
    ("FailState", "Fail"),
]

fig, ax = plt.subplots(figsize=(14, 11))
ax.set_xlim(0, 14)
ax.set_ylim(0, 22)
ax.set_aspect("equal")
ax.axis("off")

# Titulo
plt.suptitle(
    "Step Functions: bsg-acmeco-rag-dev-pipeline\n"
    "Execution demo-20260601-015935 - SUCCEEDED en 2 min 30 s",
    fontsize=14, fontweight="bold",
)

# Pintar nodos del happy path (verticalmente)
node_positions = {}
y = 20
for name, subtitle in order:
    is_visited = name in visited
    color = "#27ae60" if is_visited else "#bdc3c7"
    text_color = "white" if is_visited else "#7f8c8d"

    box = FancyBboxPatch((3, y - 0.7), 6, 1.2,
                         boxstyle="round,pad=0.1",
                         linewidth=2,
                         edgecolor="#16a085" if is_visited else "#95a5a6",
                         facecolor=color)
    ax.add_patch(box)
    # Nombre del estado
    ax.text(6, y, name, ha="center", va="center",
            fontsize=10, fontweight="bold", color=text_color)
    # Subtitle (Type + visit count)
    visits = visited.get(name, 0)
    sub = f"{subtitle}"
    if visits > 0:
        sub += f"  [{visits}x]"
    ax.text(6, y - 0.4, sub, ha="center", va="center",
            fontsize=8, color=text_color, style="italic")

    node_positions[name] = (6, y)
    y -= 2

# Flechas entre nodos del happy path
for i in range(len(order) - 1):
    n1 = order[i][0]
    n2 = order[i+1][0]
    if n1 in node_positions and n2 in node_positions:
        x1, y1 = node_positions[n1]
        x2, y2 = node_positions[n2]
        arrow = FancyArrowPatch((x1, y1 - 0.8), (x2, y2 + 0.7),
                                arrowstyle="->",
                                mutation_scale=20,
                                color="#2c3e50", linewidth=1.5)
        ax.add_patch(arrow)

# Pintar branch de failure a la derecha (no visitado)
y_fail = 14
for name, subtitle in failure_branch:
    box = FancyBboxPatch((10, y_fail - 0.6), 3.5, 1,
                         boxstyle="round,pad=0.1",
                         linewidth=1.5,
                         edgecolor="#bdc3c7",
                         facecolor="#ecf0f1")
    ax.add_patch(box)
    ax.text(11.75, y_fail - 0.1, name, ha="center", va="center",
            fontsize=8, color="#7f8c8d", fontweight="bold")
    ax.text(11.75, y_fail - 0.4, subtitle, ha="center", va="center",
            fontsize=7, color="#95a5a6", style="italic")
    y_fail -= 1.5

# Flecha dotted desde "catch all" hacia NotifyFailure
ax.annotate("Catch [States.ALL]", xy=(10, 14.4), xytext=(7, 18),
            arrowprops=dict(arrowstyle="->", color="#e74c3c",
                            linestyle="dashed", linewidth=1),
            fontsize=8, color="#e74c3c", style="italic")

# Leyenda
legend_handles = [
    mpatches.Patch(facecolor="#27ae60", edgecolor="#16a085",
                   label="Estado visitado en este run"),
    mpatches.Patch(facecolor="#bdc3c7", edgecolor="#95a5a6",
                   label="Estado no visitado (failure path)"),
]
ax.legend(handles=legend_handles, loc="lower left", fontsize=9)

# Anotacion de inputs y outputs
ax.text(0.3, 21, "INPUT",
        fontsize=9, fontweight="bold", color="#34495e")
ax.text(0.3, 20.5, "raw-docs S3 bucket\n4 documentos sinteticos",
        fontsize=7, color="#7f8c8d")

ax.text(0.3, 5, "OUTPUT",
        fontsize=9, fontweight="bold", color="#34495e")
ax.text(0.3, 4.5, "Aurora documents_embeddings\n5 chunks indexados",
        fontsize=7, color="#7f8c8d")

plt.tight_layout()
plt.savefig("sfn_diagram.png", dpi=150, bbox_inches="tight", facecolor="white")
print("PNG generado: sfn_diagram.png")
