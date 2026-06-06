# Tablas de evidencia - run-demo-20260601-015935

## DynamoDB: `bsg-acmeco-rag-dev-index-versions`

| version_id | created_at | embeddings_count | embedding_model | dataset_hash (sha256) | cost_estimate_usd |
|---|---|---|---|---|---|
| run-demo-20260601-014747 | 2026-06-01T01:50:05 | 5 | amazon.titan-embed-text-v2:0 | cdedbcf165b0cddb... | 0.0001 |
| run-demo-20260601-015935 | 2026-06-01T02:02:04 | 10 | amazon.titan-embed-text-v2:0 | 422a51c8d317c27a... | 0.0001 |

**Total versions:** 2

---

## DynamoDB: `bsg-acmeco-rag-dev-chunk-quality-audit`
Filtrado por `version_id = run-demo-20260601-015935`

### Distribucion del Quality Gate

| Veredicto | Count | % |
|---|---|---|
| pass | 5 | 62.5% |
| discard | 3 | 37.5% |

### Detalle por chunk

| chunk_id | verdict | criticality | reasons | tokens | TTR | has_financial |
|---|---|---|---|---|---|---|
| 1c8f7db106ae69d4... | pass | financial | financial_marker_detected | 169 | 0.735 | True |
| 6973507c5c78256e... | pass | financial | financial_marker_detected | 149 | 0.767 | True |
| cdd4eee77c67b7a3... | pass | financial | financial_marker_detected | 313 | 0.765 | True |
| 9c1672e4e4918854... | discard | operational | too_short | 87 | 0.922 | False |
| 4bf81aef1d337ab3... | discard | operational | too_short | 46 | 0.885 | False |
| 557411306ade398a... | pass | financial | financial_marker_detected | 299 | 0.702 | True |
| 0d0a5da76ec8e55a... | discard | operational | too_short | 75 | 0.875 | False |
| 5a1378ed5e6bf697... | pass | financial | financial_marker_detected | 175 | 0.727 | True |

---

## Step Functions execution history

| State | Entered (UTC) | Exited (UTC) | Status |
|---|---|---|---|
| StartGlueETL | 2026-05-31T19:59:36.546 | 2026-05-31T20:01:42.040 | OK |
| ListCleanParquetFiles | 2026-05-31T20:01:42.040 | 2026-05-31T20:01:42.176 | OK |
| ChunkAllParquetsInParallel | 2026-05-31T20:01:42.176 | 2026-05-31T20:01:42.751 | OK |
| InvokeChunkingLambda | 2026-05-31T20:01:42.176 | 2026-05-31T20:01:42.751 | OK |
| RunIndexerTask | 2026-05-31T20:01:42.751 | 2026-05-31T20:02:32.015 | OK |
| PublishCustomMetric | 2026-05-31T20:02:32.015 | 2026-05-31T20:02:32.143 | OK |
| NotifySuccess | 2026-05-31T20:02:32.143 | 2026-05-31T20:02:32.294 | OK |

**Total events:** 63
**Eventos tipo Task/MapStateExited:** 11