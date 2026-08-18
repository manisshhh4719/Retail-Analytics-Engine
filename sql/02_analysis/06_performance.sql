-- ===========================================================================
-- 06_performance.sql  -  Physical design, examined
--
-- The companion to src/benchmark.py. That script reports wall-clock medians;
-- this file shows the plans behind them, which is what actually explains the
-- difference.
--
-- Both tables hold identical rows:
--   marts.fact_sales              RANGE-partitioned by month, 7 indexes
--   marts.fact_sales_unoptimised  plain heap, no indexes
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/06_performance.sql
-- ===========================================================================

\timing on

\echo '\n=== 6.1 Table and index sizes ==='

-- relkind = 'r' AND relispartition isolates the partition tables. Without it
-- pg_class also returns every partition-local index, which inflates the count
-- and double-counts bytes pg_total_relation_size already includes.
SELECT
    'fact_sales (partitioned)' AS object,
    COUNT(*)                                              AS partitions,
    COUNT(*) FILTER (WHERE reltuples > 0)                 AS populated,
    pg_size_pretty(SUM(pg_total_relation_size(c.oid)))    AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'marts' AND c.relkind = 'r'
  AND c.relispartition AND c.relname LIKE 'fact_sales_%'
UNION ALL
SELECT
    'fact_sales_unoptimised (heap)',
    1, 1,
    pg_size_pretty(pg_total_relation_size('marts.fact_sales_unoptimised'));


\echo '\n=== 6.2 Index inventory and usage ==='

-- idx_scan is cumulative since the last stats reset. An index sitting at zero
-- after a full analytical run is dead weight: it costs write throughput and
-- disk on every load while returning nothing.
SELECT
    indexrelname                                  AS index_name,
    idx_scan                                      AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid))  AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'marts' AND relname = 'fact_sales'
ORDER BY idx_scan DESC;


\echo '\n=== 6.3 Partition pruning: one month, control vs optimised ==='

\echo '--- control (unpartitioned heap) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT branch_key, SUM(total_amount) AS revenue
FROM marts.fact_sales_unoptimised
WHERE sale_date >= DATE '2024-07-01' AND sale_date < DATE '2024-08-01'
GROUP BY branch_key;

\echo '--- optimised (partitioned + indexed) ---'
-- Look for "Partitions removed by pruning" in the Append node: that is the
-- whole mechanism. The planner discards 71 of 72 monthly partitions before a
-- single page is read.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT branch_key, SUM(total_amount) AS revenue
FROM marts.fact_sales
WHERE sale_date >= DATE '2024-07-01' AND sale_date < DATE '2024-08-01'
GROUP BY branch_key;


\echo '\n=== 6.4 Selective lookup: one customer ==='

\echo '--- control ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT invoice_id, sale_date, SUM(total_amount)
FROM marts.fact_sales_unoptimised
WHERE customer_key = 17342
GROUP BY invoice_id, sale_date;

\echo '--- optimised ---'
-- ix_fact_customer is a PARTIAL index (WHERE customer_key <> -1). Roughly half
-- of all rows are anonymous walk-ins that no customer-level query ever touches,
-- so excluding them keeps the index materially smaller and faster to traverse.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT invoice_id, sale_date, SUM(total_amount)
FROM marts.fact_sales
WHERE customer_key = 17342
GROUP BY invoice_id, sale_date;


\echo '\n=== 6.5 Covering index: index-only scan ==='

-- ix_fact_branch_date INCLUDEs the measures, so this aggregate can be answered
-- from the index alone. Watch for "Heap Fetches: 0" - that confirms the visibility
-- map is current and no table pages were touched at all.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT branch_key, SUM(total_amount), SUM(gross_profit)
FROM marts.fact_sales
WHERE branch_key = 5
  AND date_key BETWEEN 20240101 AND 20241231
GROUP BY branch_key;


\echo '\n=== 6.6 Where partitioning does NOT help ==='

-- Reported deliberately. With no date predicate there is nothing to prune, and
-- the partitioned table is marginally SLOWER: the planner must open and append
-- 72 relations instead of scanning one. Quoting only the favourable cases
-- would misrepresent what the design does.
\echo '--- control ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT COUNT(*), SUM(total_amount) FROM marts.fact_sales_unoptimised;

\echo '--- optimised ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT COUNT(*), SUM(total_amount) FROM marts.fact_sales;

\timing off
