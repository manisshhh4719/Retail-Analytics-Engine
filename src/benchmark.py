"""
Benchmark the partitioned + indexed fact table against an unoptimised control.

Both tables hold identical rows. marts.fact_sales is RANGE-partitioned by month
with composite covering indexes; marts.fact_sales_unoptimised is a plain heap
with neither. Running the same query against each isolates what the physical
design actually buys.

Method: each query runs once to warm the cache, then N timed runs; the median
is reported. Median rather than mean because a single checkpoint or background
autovacuum during one run would drag a mean around and misstate the result.

Usage:
    python src/benchmark.py [--runs 7]

Writes docs/benchmark_results.md.
"""

from __future__ import annotations

import argparse
import os
import statistics
import sys
import time

import psycopg
from dotenv import load_dotenv

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each query is written once with a {t} placeholder for the table, so the
# optimised and control runs are guaranteed to be executing identical SQL.
QUERIES = [
    (
        "Single-month revenue by branch",
        "Filters one month. The partitioned table can prune 71 of 72 "
        "partitions; the heap must scan all 1.19M rows.",
        """
        SELECT branch_key, SUM(total_amount) AS revenue, COUNT(*) AS lines
        FROM {t}
        WHERE sale_date >= DATE '2024-07-01' AND sale_date < DATE '2024-08-01'
        GROUP BY branch_key
        ORDER BY revenue DESC
        """,
    ),
    (
        "Full-year category aggregation",
        "Twelve months joined to the product dimension. Prunes to a "
        "twelfth of the table, then aggregates.",
        """
        SELECT p.product_line,
               SUM(f.total_amount) AS revenue,
               SUM(f.gross_profit) AS profit
        FROM {t} f
        JOIN marts.dim_product p ON p.product_key = f.product_key
        WHERE f.sale_date >= DATE '2024-01-01' AND f.sale_date < DATE '2025-01-01'
        GROUP BY p.product_line
        ORDER BY revenue DESC
        """,
    ),
    (
        "Single customer order history",
        "Highly selective point lookup. The partial index on customer_key "
        "turns a full scan into an index seek.",
        """
        SELECT invoice_id, sale_date, SUM(total_amount) AS basket
        FROM {t}
        WHERE customer_key = 17342
        GROUP BY invoice_id, sale_date
        ORDER BY sale_date DESC
        """,
    ),
    (
        "Single invoice lookup",
        "The most selective query in the set - one invoice out of 605K.",
        """
        SELECT line_no, product_key, quantity, total_amount
        FROM {t}
        WHERE invoice_id = (SELECT invoice_id FROM marts.fact_sales
                            WHERE sale_date = DATE '2023-06-15' LIMIT 1)
        ORDER BY line_no
        """,
    ),
    (
        "Quarterly branch scorecard",
        "Range filter plus grouping and ordering - the shape behind most "
        "dashboard tiles.",
        """
        SELECT branch_key,
               COUNT(DISTINCT invoice_id) AS invoices,
               SUM(total_amount)          AS revenue,
               AVG(rating)                AS avg_rating
        FROM {t}
        WHERE sale_date >= DATE '2024-10-01' AND sale_date < DATE '2025-01-01'
        GROUP BY branch_key
        ORDER BY revenue DESC
        LIMIT 10
        """,
    ),
    (
        "Full-table aggregate (no date filter)",
        "Deliberate control: with nothing to prune and nothing to seek, both "
        "tables must read everything. Near-parity here is the honest result "
        "and shows the gains elsewhere are pruning, not measurement error.",
        """
        SELECT COUNT(*) AS lines, SUM(total_amount) AS revenue
        FROM {t}
        """,
    ),
]


def connect() -> psycopg.Connection:
    load_dotenv(os.path.join(PROJECT_ROOT, ".env"))
    return psycopg.connect(
        host=os.getenv("PGHOST", "127.0.0.1"),
        port=os.getenv("PGPORT", "5433"),
        dbname=os.getenv("PGDATABASE", "walmart_dw"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", ""),
        autocommit=True,
    )


def time_query(conn: psycopg.Connection, sql: str, runs: int) -> float:
    """Median wall-clock milliseconds over `runs` timed executions."""
    with conn.cursor() as cur:
        cur.execute(sql)      # warm-up, not timed
        cur.fetchall()
        samples = []
        for _ in range(runs):
            t0 = time.perf_counter()
            cur.execute(sql)
            cur.fetchall()
            samples.append((time.perf_counter() - t0) * 1000)
    return statistics.median(samples)


def get_plan_summary(conn: psycopg.Connection, sql: str) -> str:
    """First meaningful plan node, for showing scan type in the report."""
    with conn.cursor() as cur:
        cur.execute("EXPLAIN (FORMAT TEXT) " + sql)
        lines = [r[0].strip() for r in cur.fetchall()]
    for line in lines:
        for marker in ("Index Scan", "Index Only Scan", "Bitmap Heap Scan",
                       "Seq Scan", "Parallel Seq Scan", "Append"):
            if marker in line:
                return marker
    return lines[0][:40] if lines else "n/a"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs", type=int, default=7)
    args = ap.parse_args()

    conn = connect()

    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM marts.fact_sales")
        n_opt = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM marts.fact_sales_unoptimised")
        n_ctl = cur.fetchone()[0]

    if n_opt != n_ctl or n_opt == 0:
        sys.exit(f"Tables must hold identical rows (optimised={n_opt:,}, "
                 f"control={n_ctl:,}). Run load_warehouse.py --benchmark first.")

    print(f"Benchmarking {n_opt:,} rows, median of {args.runs} runs\n")
    header = f"  {'query':<38} {'control':>10} {'optimised':>10} {'speedup':>9}"
    print(header)
    print("  " + "-" * (len(header) - 2))

    results = []
    for name, note, template in QUERIES:
        ctl_sql = template.format(t="marts.fact_sales_unoptimised")
        opt_sql = template.format(t="marts.fact_sales")

        ctl_ms = time_query(conn, ctl_sql, args.runs)
        opt_ms = time_query(conn, opt_sql, args.runs)
        ctl_plan = get_plan_summary(conn, ctl_sql)
        opt_plan = get_plan_summary(conn, opt_sql)
        speedup = ctl_ms / opt_ms if opt_ms > 0 else 0

        results.append({
            "name": name, "note": note,
            "ctl_ms": ctl_ms, "opt_ms": opt_ms, "speedup": speedup,
            "ctl_plan": ctl_plan, "opt_plan": opt_plan,
        })
        print(f"  {name:<38} {ctl_ms:>9.1f}ms {opt_ms:>9.1f}ms {speedup:>8.1f}x")

    # Physical sizes -------------------------------------------------------
    with conn.cursor() as cur:
        # relkind = 'r' restricts this to the partition tables themselves.
        # Without it pg_class also returns each partition's indexes, which both
        # inflates the partition count and double-counts index bytes that
        # pg_total_relation_size already includes.
        cur.execute("""
            SELECT
                pg_size_pretty(SUM(pg_total_relation_size(c.oid))) AS total,
                COUNT(*) AS parts,
                COUNT(*) FILTER (WHERE c.reltuples > 0) AS populated
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'marts'
              AND c.relkind = 'r'
              AND c.relispartition
              AND c.relname LIKE 'fact_sales_%'
        """)
        part_total, n_parts, n_populated = cur.fetchone()
        cur.execute("SELECT pg_size_pretty(pg_total_relation_size("
                    "'marts.fact_sales_unoptimised'))")
        ctl_size = cur.fetchone()[0]

    # Report ---------------------------------------------------------------
    speedups = [r["speedup"] for r in results if r["speedup"] > 1.2]
    out = [
        "# Query performance benchmark",
        "",
        "Identical rows in both tables. `marts.fact_sales` is RANGE-partitioned "
        "by month with composite covering indexes; `marts.fact_sales_unoptimised` "
        "is an unindexed heap.",
        "",
        f"- Rows: **{n_opt:,}**",
        f"- Partitions: **{n_parts}** declared, {n_populated} populated, "
        f"{part_total} on disk including indexes (control heap: {ctl_size})",
        f"- Timing: median of {args.runs} runs after a warm-up execution",
        f"- PostgreSQL 17.6, `shared_buffers=1GB`, `work_mem=128MB`",
        "",
        "| Query | Control | Optimised | Speedup | Control plan | Optimised plan |",
        "|---|---:|---:|---:|---|---|",
    ]
    for r in results:
        out.append(
            f"| {r['name']} | {r['ctl_ms']:.1f} ms | {r['opt_ms']:.1f} ms | "
            f"**{r['speedup']:.1f}x** | {r['ctl_plan']} | {r['opt_plan']} |"
        )

    out += ["", "## Notes", ""]
    for r in results:
        out.append(f"- **{r['name']}** — {r['note']}")

    if speedups:
        out += [
            "",
            f"Across the {len(speedups)} queries that benefit from the physical "
            f"design, the median speedup is **{statistics.median(speedups):.1f}x** "
            f"and the best case is **{max(speedups):.1f}x**. The full-table "
            "aggregate is included precisely because it does *not* improve.",
        ]

    docs_dir = os.path.join(PROJECT_ROOT, "docs")
    os.makedirs(docs_dir, exist_ok=True)
    path = os.path.join(docs_dir, "benchmark_results.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")

    print(f"\n  partitions: {n_parts} declared / {n_populated} populated, "
          f"{part_total} on disk   control heap: {ctl_size}")
    if speedups:
        print(f"  median speedup (queries that benefit): "
              f"{statistics.median(speedups):.1f}x")
    print(f"\nWrote {path}")
    conn.close()


if __name__ == "__main__":
    main()
