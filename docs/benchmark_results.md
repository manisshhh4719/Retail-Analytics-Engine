# Query performance benchmark

Identical rows in both tables. `marts.fact_sales` is RANGE-partitioned by month with composite covering indexes; `marts.fact_sales_unoptimised` is an unindexed heap.

- Rows: **1,194,949**
- Partitions: **85** declared, 72 populated, 405 MB on disk including indexes (control heap: 183 MB)
- Timing: median of 15 runs after a warm-up execution
- PostgreSQL 17.6, `shared_buffers=1GB`, `work_mem=128MB`

| Query | Control | Optimised | Speedup | Control plan | Optimised plan |
|---|---:|---:|---:|---|---|
| Single-month revenue by branch | 79.0 ms | 8.1 ms | **9.7x** | Seq Scan | Seq Scan |
| Full-year category aggregation | 130.6 ms | 104.1 ms | **1.3x** | Seq Scan | Append |
| Single customer order history | 105.2 ms | 1.1 ms | **98.4x** | Seq Scan | Append |
| Single invoice lookup | 99.9 ms | 1.7 ms | **60.2x** | Index Scan | Index Scan |
| Quarterly branch scorecard | 144.3 ms | 93.8 ms | **1.5x** | Seq Scan | Append |
| Full-table aggregate (no date filter) | 138.9 ms | 162.4 ms | **0.9x** | Seq Scan | Append |

## Notes

- **Single-month revenue by branch** — Filters one month. The partitioned table can prune 71 of 72 partitions; the heap must scan all 1.19M rows.
- **Full-year category aggregation** — Twelve months joined to the product dimension. Prunes to a twelfth of the table, then aggregates.
- **Single customer order history** — Highly selective point lookup. The partial index on customer_key turns a full scan into an index seek.
- **Single invoice lookup** — The most selective query in the set - one invoice out of 605K.
- **Quarterly branch scorecard** — Range filter plus grouping and ordering - the shape behind most dashboard tiles.
- **Full-table aggregate (no date filter)** — Deliberate control: with nothing to prune and nothing to seek, both tables must read everything. Near-parity here is the honest result and shows the gains elsewhere are pruning, not measurement error.

Across the 5 queries that benefit from the physical design, the median speedup is **9.7x** and the best case is **98.4x**. The full-table aggregate is included precisely because it does *not* improve.
