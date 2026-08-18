"""
Build the warehouse end to end: schema -> raw load -> transform -> index.

Runs the SQL files in dependency order and bulk-loads the generated CSVs with
COPY (streamed, so a 200 MB file never lands in memory). Each step is timed;
the summary at the end is the pipeline runtime quoted in the README.

Usage:
    python src/load_warehouse.py                 # full rebuild
    python src/load_warehouse.py --skip-generate # reuse existing CSVs
    python src/load_warehouse.py --benchmark     # also fill the control table

Connection settings come from environment variables, or a .env file in the
project root:

    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import psycopg
from dotenv import load_dotenv

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as cfg  # noqa: E402

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(PROJECT_ROOT, "sql")
DATA_DIR = os.path.join(PROJECT_ROOT, cfg.OUTPUT_DIR)

# (csv file, target table) - column order in the CSV matches the DDL.
COPY_TARGETS = [
    (cfg.BRANCH_FILE,   "raw.branches_landing"),
    (cfg.PRODUCT_FILE,  "raw.products_landing"),
    (cfg.CUSTOMER_FILE, "raw.customers_landing"),
    (cfg.FACT_FILE,     "raw.sales_landing"),
]

SQL_STEPS = [
    "00_schema/01_schemas_and_raw.sql",
    # raw CSVs are copied in here
    "00_schema/02_marts_ddl.sql",
    "01_transform/01_staging_clean.sql",
    "01_transform/02_dimensions.sql",
    "01_transform/03_fact_sales.sql",
    "01_transform/04_customer_enrich.sql",
    "00_schema/03_indexes.sql",
    # RFM scoring and the Power BI objects run last: both read the finished
    # fact table, and the RFM window functions benefit from the indexes above.
    "01_transform/05_customer_rfm.sql",
    "01_transform/06_powerbi_model.sql",
]

timings: list[tuple[str, float]] = []


def connect() -> psycopg.Connection:
    load_dotenv(os.path.join(PROJECT_ROOT, ".env"))
    conn = psycopg.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "walmart_dw"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", ""),
        autocommit=True,
    )
    return conn


def run_sql_file(conn: psycopg.Connection, rel_path: str) -> None:
    path = os.path.join(SQL_DIR, rel_path)
    with open(path, "r", encoding="utf-8") as fh:
        sql = fh.read()
    t0 = time.time()
    with conn.cursor() as cur:
        cur.execute(sql)
    elapsed = time.time() - t0
    timings.append((rel_path, elapsed))
    print(f"  {rel_path:44s} {elapsed:7.2f}s")


def copy_csv(conn: psycopg.Connection, filename: str, table: str) -> None:
    path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(path):
        sys.exit(f"Missing {path} - run src/generate_data.py first")

    size_mb = os.path.getsize(path) / 1e6
    t0 = time.time()
    with conn.cursor() as cur, open(path, "r", encoding="utf-8") as fh:
        with cur.copy(f"COPY {table} FROM STDIN WITH (FORMAT csv, HEADER true)") as cp:
            while chunk := fh.read(1 << 20):
                cp.write(chunk)
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        rows = cur.fetchone()[0]
    elapsed = time.time() - t0
    timings.append((f"COPY {table}", elapsed))
    print(f"  COPY {table:39s} {elapsed:7.2f}s  ({rows:,} rows, {size_mb:.0f} MB)")


def fill_benchmark_table(conn: psycopg.Connection) -> None:
    """Populate the unpartitioned, unindexed control used by the benchmark."""
    print("\nPopulating benchmark control table")
    t0 = time.time()
    with conn.cursor() as cur:
        cur.execute("TRUNCATE marts.fact_sales_unoptimised")
        cur.execute("INSERT INTO marts.fact_sales_unoptimised "
                    "SELECT * FROM marts.fact_sales")
        cur.execute("ANALYZE marts.fact_sales_unoptimised")
    elapsed = time.time() - t0
    timings.append(("benchmark control table", elapsed))
    print(f"  fact_sales_unoptimised {' ' * 22} {elapsed:7.2f}s")


def print_audit(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT step_name, table_name, row_count, notes
            FROM staging.load_audit
            ORDER BY audit_id
        """)
        rows = cur.fetchall()

    print("\n" + "=" * 78)
    print("LOAD AUDIT")
    print("=" * 78)
    print(f"  {'step':<12} {'table':<38} {'rows':>12}")
    print("  " + "-" * 74)
    for step, table, count, notes in rows:
        print(f"  {step:<12} {table:<38} {count:>12,}")

    with conn.cursor() as cur:
        cur.execute("""
            SELECT reject_reason, COUNT(*)
            FROM staging.stg_sales_rejects
            GROUP BY reject_reason ORDER BY 2 DESC
        """)
        rejects = cur.fetchall()
    if rejects:
        print("\n  Rejected rows by reason")
        print("  " + "-" * 74)
        for reason, n in rejects:
            print(f"    {reason:<32} {n:>10,}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--skip-generate", action="store_true",
                    help="reuse the CSVs already in data/generated")
    ap.add_argument("--benchmark", action="store_true",
                    help="also populate the unoptimised control table")
    args = ap.parse_args()

    if not args.skip_generate:
        print("Generating source data")
        os.system(f'"{sys.executable}" "{os.path.join(PROJECT_ROOT, "src", "generate_data.py")}"')
        print()

    print("Connecting to Postgres")
    conn = connect()
    with conn.cursor() as cur:
        cur.execute("SELECT version()")
        print(f"  {cur.fetchone()[0].split(',')[0]}\n")

    total0 = time.time()
    print("Building warehouse")

    run_sql_file(conn, SQL_STEPS[0])
    for filename, table in COPY_TARGETS:
        copy_csv(conn, filename, table)
    for step in SQL_STEPS[1:]:
        run_sql_file(conn, step)

    if args.benchmark:
        fill_benchmark_table(conn)

    total = time.time() - total0
    print_audit(conn)

    print("\n" + "=" * 78)
    print(f"PIPELINE COMPLETE in {total:.1f}s")
    print("=" * 78)
    slowest = sorted(timings, key=lambda x: -x[1])[:5]
    print("  slowest steps:")
    for name, sec in slowest:
        print(f"    {name:<50} {sec:7.2f}s")

    conn.close()


if __name__ == "__main__":
    main()
