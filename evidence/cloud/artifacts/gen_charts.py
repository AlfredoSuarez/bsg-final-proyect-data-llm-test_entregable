"""Genera 3 charts CloudWatch desde get-metric-statistics outputs."""
import json
import subprocess
import datetime
import matplotlib.pyplot as plt
from matplotlib.dates import DateFormatter
import os

os.environ["AWS_PROFILE"] = "bsg-deployer"
END = datetime.datetime.utcnow()
START = END - datetime.timedelta(hours=2)


def cw_query(namespace, metric, dim_name, dim_value, stats="Sum", period=60, extended=False):
    cmd = [
        "aws", "--no-verify-ssl", "--profile", "bsg-deployer", "--region", "us-east-1",
        "cloudwatch", "get-metric-statistics",
        "--namespace", namespace,
        "--metric-name", metric,
        "--dimensions", f"Name={dim_name},Value={dim_value}",
        "--start-time", START.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--end-time", END.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--period", str(period),
        "--output", "json",
    ]
    if extended:
        cmd.extend(["--extended-statistics", stats])
    else:
        cmd.extend(["--statistics", stats])
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print("ERROR:", res.stderr[:200])
        return []
    data = json.loads(res.stdout)
    dps = sorted(data["Datapoints"], key=lambda x: x["Timestamp"])
    return dps


# Chart 1: Lambda chunking Duration p95 over time
print("Fetching Lambda Duration p95...")
lambda_dps = cw_query("AWS/Lambda", "Duration",
                      "FunctionName", "bsg-acmeco-rag-dev-chunking",
                      stats="p95", extended=True)

# Chart 2: Lambda Invocations + Errors
print("Fetching Lambda Invocations...")
invs = cw_query("AWS/Lambda", "Invocations",
                "FunctionName", "bsg-acmeco-rag-dev-chunking",
                stats="Sum")
errs = cw_query("AWS/Lambda", "Errors",
                "FunctionName", "bsg-acmeco-rag-dev-chunking",
                stats="Sum")

# Chart 3: Pipeline runs custom metric
print("Fetching pipeline runs custom...")
runs_succ = cw_query("RAGPipeline", "PipelineRunsSucceeded",
                     "Environment", "dev", stats="Sum")
runs_fail = cw_query("RAGPipeline", "PipelineRunsFailed",
                     "Environment", "dev", stats="Sum")

# ---------- Render -----------
fig, axs = plt.subplots(3, 1, figsize=(13, 11))
fmt = DateFormatter("%H:%M")

# Subplot 1: Latencia p95
ax = axs[0]
if lambda_dps:
    times = [datetime.datetime.fromisoformat(d["Timestamp"].replace("Z", "+00:00")) for d in lambda_dps]
    vals = [d["ExtendedStatistics"]["p95"] for d in lambda_dps]
    ax.plot(times, vals, marker="o", color="#3498db", linewidth=2)
    # Umbral objetivo 8000ms del doc 13
    ax.axhline(8000, color="#27ae60", linestyle="--", alpha=0.6, label="Objetivo: 8000 ms")
    ax.axhline(15000, color="#e74c3c", linestyle="--", alpha=0.6, label="Critico: 15000 ms")
    ax.set_title("Lambda chunking - p95 Duration (ms)", fontweight="bold")
    ax.set_ylabel("ms")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(fmt)
    plt.setp(ax.xaxis.get_majorticklabels(), rotation=45, ha="right")
else:
    ax.text(0.5, 0.5, "Sin datos", ha="center", transform=ax.transAxes)

# Subplot 2: Invocations + Errors
ax = axs[1]
if invs:
    times_i = [datetime.datetime.fromisoformat(d["Timestamp"].replace("Z", "+00:00")) for d in invs]
    vals_i = [d["Sum"] for d in invs]
    ax.bar(times_i, vals_i, width=0.0008, color="#3498db", label="Invocations")
if errs:
    times_e = [datetime.datetime.fromisoformat(d["Timestamp"].replace("Z", "+00:00")) for d in errs]
    vals_e = [d["Sum"] for d in errs]
    ax.bar(times_e, vals_e, width=0.0008, color="#e74c3c", label="Errors")
ax.set_title("Lambda chunking - Invocations vs Errors", fontweight="bold")
ax.set_ylabel("Count per min")
ax.legend(loc="upper right", fontsize=8)
ax.grid(alpha=0.3)
ax.xaxis.set_major_formatter(fmt)
plt.setp(ax.xaxis.get_majorticklabels(), rotation=45, ha="right")

# Subplot 3: Pipeline runs
ax = axs[2]
if runs_succ:
    times_s = [datetime.datetime.fromisoformat(d["Timestamp"].replace("Z", "+00:00")) for d in runs_succ]
    vals_s = [d["Sum"] for d in runs_succ]
    ax.bar(times_s, vals_s, width=0.002, color="#27ae60", label="RunsSucceeded")
if runs_fail:
    times_f = [datetime.datetime.fromisoformat(d["Timestamp"].replace("Z", "+00:00")) for d in runs_fail]
    vals_f = [d["Sum"] for d in runs_fail]
    ax.bar(times_f, vals_f, width=0.002, color="#e74c3c", label="RunsFailed")
ax.set_title("RAGPipeline custom metric (Environment=dev)", fontweight="bold")
ax.set_ylabel("Pipeline runs")
ax.legend(loc="upper right", fontsize=8)
ax.grid(alpha=0.3)
ax.xaxis.set_major_formatter(fmt)
plt.setp(ax.xaxis.get_majorticklabels(), rotation=45, ha="right")
ax.set_xlabel("UTC")

plt.suptitle("CloudWatch metrics - RAG Pipeline (ultimas 2h)",
             fontsize=14, fontweight="bold", y=1.00)
plt.tight_layout()
plt.savefig("cw_metrics.png", dpi=150, bbox_inches="tight", facecolor="white")
print("Chart PNG generado: cw_metrics.png")
print(f"Lambda Duration datapoints: {len(lambda_dps)}")
print(f"Lambda Invocations datapoints: {len(invs)}")
print(f"Pipeline runs (success): {len(runs_succ)}")
