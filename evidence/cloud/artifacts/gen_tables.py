"""Genera markdown tables desde los exports JSON."""
import json
from datetime import datetime


def render_md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for row in rows:
        out.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(out)


lines = ["# Tablas de evidencia - run-demo-20260601-015935", ""]

# ===== DDB index_versions =====
lines.append("## DynamoDB: `bsg-acmeco-rag-dev-index-versions`")
lines.append("")
data = json.load(open("ddb_index_versions.json"))
headers = ["version_id", "created_at", "embeddings_count",
           "embedding_model", "dataset_hash (sha256)", "cost_estimate_usd"]
rows = []
for item in sorted(data["Items"], key=lambda x: x["created_at"]["S"]):
    rows.append([
        item["version_id"]["S"],
        item["created_at"]["S"][:19],
        item["embeddings_count"]["N"],
        item["embedding_model"]["S"],
        item["dataset_hash"]["S"][:16] + "...",
        item.get("cost_estimate_usd", {}).get("N", "-"),
    ])
lines.append(render_md_table(headers, rows))
lines.append("")
lines.append(f"**Total versions:** {len(data['Items'])}")
lines.append("")
lines.append("---")
lines.append("")

# ===== DDB chunk_quality_audit (5to run) =====
lines.append("## DynamoDB: `bsg-acmeco-rag-dev-chunk-quality-audit`")
lines.append("Filtrado por `version_id = run-demo-20260601-015935`")
lines.append("")
audit = json.load(open("ddb_qaudit.json"))

# Resumen por verdict
from collections import Counter
verdicts = Counter(i["verdict"]["S"] for i in audit["Items"])
lines.append("### Distribucion del Quality Gate")
lines.append("")
lines.append(render_md_table(
    ["Veredicto", "Count", "%"],
    [[v, c, f"{c/len(audit['Items'])*100:.1f}%"]
     for v, c in verdicts.most_common()]
))
lines.append("")

# Tabla detallada
lines.append("### Detalle por chunk")
lines.append("")
headers = ["chunk_id", "verdict", "criticality", "reasons", "tokens", "TTR", "has_financial"]
rows = []
for item in audit["Items"]:
    metrics = json.loads(item["metrics_json"]["S"])
    reasons = item.get("reasons", {}).get("SS", [])
    rows.append([
        item["chunk_id"]["S"][:16] + "...",
        item["verdict"]["S"],
        item["criticality"]["S"],
        ",".join(reasons)[:30],
        metrics.get("length_tokens", "-"),
        f"{metrics.get('ttr', 0):.3f}",
        metrics.get("has_financial_marker", False),
    ])
lines.append(render_md_table(headers, rows))
lines.append("")
lines.append("---")
lines.append("")

# ===== Step Functions history summary =====
lines.append("## Step Functions execution history")
lines.append("")
hist = json.load(open("sfn_history.json"))
events = hist["events"]

# Timeline visible
state_times = {}
for e in events:
    ts = e["timestamp"]
    if e["type"] == "TaskStateEntered" or e["type"] == "MapStateEntered":
        name = e.get("stateEnteredEventDetails", {}).get("name", "?")
        state_times.setdefault(name, {"in": ts})
    elif e["type"] == "TaskStateExited" or e["type"] == "MapStateExited":
        name = e.get("stateExitedEventDetails", {}).get("name", "?")
        if name in state_times:
            state_times[name]["out"] = ts

# Tabla de timing
lines.append(render_md_table(
    ["State", "Entered (UTC)", "Exited (UTC)", "Status"],
    [[name,
      times.get("in", "-")[:23] if times.get("in") else "-",
      times.get("out", "-")[:23] if times.get("out") else "-",
      "OK" if times.get("out") else "incomplete"]
     for name, times in state_times.items()]
))
lines.append("")
lines.append(f"**Total events:** {len(events)}")
lines.append(f"**Eventos tipo Task/MapStateExited:** {sum(1 for e in events if 'StateExited' in e['type'])}")

with open("tables.md", "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"tables.md generado: {len(lines)} lineas")
print(f"DDB index_versions: {len(data['Items'])} items")
print(f"DDB audit: {len(audit['Items'])} items con {dict(verdicts)}")
print(f"SFN states con timing: {len(state_times)}")
