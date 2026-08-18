# Walmart Retail Analytics Warehouse

A PostgreSQL data warehouse and Power BI dashboard built over **1.19 million
retail transactions** spanning 2019–2024 across 20 branches — covering
dimensional modelling, an ETL pipeline with a data-quality gate, advanced
analytical SQL, and query performance engineering.

```
1,194,949 line items  ·  605,743 invoices  ·  $182.2M revenue  ·  6 years  ·  20 branches
```

---

## About the data

**This dataset is simulated, and that is a deliberate design decision.**

The project began from the [Kaggle Walmart sales
sample](https://www.kaggle.com/datasets/aungpyaeap/supermarket-sales) — 1,000
rows, three branches, three months. That file cannot support the analysis this
project is about: it has no year-on-year comparison, no repeat customers to
build cohorts from, and its category distribution is almost perfectly uniform
(every product line falls between 15.2% and 17.4% of revenue). There is nothing
to find in it.

So `src/generate_data.py` reads the real sample to learn its price bands,
basket sizes and rating distribution, then extends it into a six-year
transaction log with structure deliberately built in — growth, seasonality,
customer churn, category mix shift, product affinities, and injected data
defects.

Two consequences worth being explicit about:

- Every figure quoted below is a **genuine query result** against real rows. No
  number in this README was estimated, rounded up, or asserted without a query
  behind it.
- The underlying *behaviour* was authored by the generator. The analysis
  recovers it; it does not discover facts about the real Walmart.

The generator's full method, including every engineered signal and its
intended magnitude, is documented in
[`docs/data_generation.md`](docs/data_generation.md).
`src/validate_generation.py` asserts all 13 signals are actually present and
recoverable before the data is allowed into the warehouse.

---

## Architecture

```
                  ┌──────────────────────────┐
   Kaggle sample  │  src/generate_data.py    │
   (1,000 rows) → │  learns distributions,   │
                  │  simulates 6 years       │
                  └────────────┬─────────────┘
                               │  4 CSVs (200 MB)
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  raw        untyped landing zone — all TEXT columns          │
│             malformed dates and "$1,234.50" prices survive   │
│             load so the quality layer can report on them     │
└────────────────────────────┬─────────────────────────────────┘
                             │  repair what's recoverable,
                             │  quarantine what isn't
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  staging    stg_sales           1,194,949 rows conformed     │
│             stg_sales_rejects      18,034 rows + reason code │
│             customer_rfm           25,536 scored customers   │
│             load_audit          row counts at every hop      │
└────────────────────────────┬─────────────────────────────────┘
                             │  resolve natural → surrogate keys
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  marts      STAR SCHEMA                                      │
│                                                              │
│    dim_date ─┐                                               │
│  dim_branch ─┤                                               │
│ dim_product ─┼──→  fact_sales  (grain: one invoice line)     │
│dim_customer ─┤     RANGE-partitioned by month, 72 populated  │
│ dim_payment ─┘     7 indexes incl. covering + partial        │
└────────────────────────────┬─────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
     45 analytical queries          Power BI (Import)
     6 modules                      4 pages, 35+ DAX measures
```

Full pipeline: **~162 seconds** from raw CSV to query-ready warehouse.

---

## Quickstart

Requires PostgreSQL 17 and Python 3.11+.

```bash
# 1. Install Python dependencies
pip install -r requirements.txt

# 2. Point at your database
cp .env.example .env        # then edit credentials

# 3. Create the database
createdb walmart_dw

# 4. Generate data, build the warehouse, populate the benchmark control
python src/load_warehouse.py --benchmark

# 5. Confirm the data carries the signals it should
python src/validate_generation.py

# 6. Run the data-quality gate
psql -d walmart_dw -f sql/02_analysis/05_quality_assertions.sql

# 7. Run the analysis
psql -d walmart_dw -f sql/02_analysis/01_growth.sql
psql -d walmart_dw -f sql/02_analysis/02_customer.sql
psql -d walmart_dw -f sql/02_analysis/03_product.sql
psql -d walmart_dw -f sql/02_analysis/04_branch_ops.sql

# 8. Benchmark the physical design
python src/benchmark.py
```

---

## Findings

### 1. Headline growth is flattered by store openings

Revenue grew at a **21.5% CAGR**, from $18.1M in 2019 to $48.0M in 2024. But
splitting like-for-like branches (trading the full prior year) from new stores
tells a different story:

| Year | Headline growth | Like-for-like | New-store share |
|---|---:|---:|---:|
| 2020 | −7.6% | **−11.0%** | 3.7% |
| 2021 | +55.6% | +39.0% | 14.0% |
| 2022 | +28.3% | +15.4% | 16.8% |
| 2023 | +19.0% | +11.9% | 8.9% |
| 2024 | +20.6% | +13.6% | 9.5% |

The 2020 downturn was **44% deeper** than the headline suggests (−11.0% vs
−7.6%), and roughly **half of reported growth in 2022** came from opening
stores rather than from stores selling more.

> **Recommendation.** Report like-for-like alongside headline growth in board
> reporting. On the current mix, headline overstates underlying trading
> performance by 5–13 percentage points a year.

### 2. Revenue rankings and profit rankings disagree

| Product line | Revenue | Rank | Gross profit | Rank | Margin |
|---|---:|---:|---:|---:|---:|
| Fashion accessories | $44.7M | 1 | $14.3M | 1 | 33.7% |
| Electronic accessories | $33.9M | **2** | $6.2M | **5** | 19.2% |
| Home and lifestyle | $30.3M | 3 | $6.6M | 4 | 22.9% |
| Sports and travel | $28.5M | 4 | $7.0M | 2 | 25.6% |
| Health and beauty | $24.9M | 5 | $6.8M | 3 | 28.6% |
| Food and beverages | $19.9M | 6 | $2.2M | 6 | 11.5% |

Electronic accessories is the **fastest-growing category** (13.3% → 21.7% of
revenue, +8.5pts over six years) and second by revenue — but only fifth by
profit. It is buying share at a 19.2% margin while Fashion accessories earns
33.7%.

> **Recommendation.** The category mix is shifting toward a low-margin growth
> engine. Electronics has gained share at ~1.7pts a year; if that continues,
> blended margin erodes even with every category margin held flat. Attach a
> margin floor to electronics promotions.

### 3. Customer value is extremely concentrated

- The **top decile of customers drives 56.9%** of identified revenue.
- **Champions** — 18.6% of customers — generate **51.2%** of revenue.
- **77.4%** of customers purchase more than once; average lifetime value
  **$3,848**.

Retention decays as expected and then stabilises: **42.3%** of a cohort returns
in month 1, **22.2%** are still active at month 12, **13.3%** at month 24.

| RFM segment | Customers | % | Revenue | % of revenue |
|---|---:|---:|---:|---:|
| Champions | 4,749 | 18.6% | $50.3M | 51.2% |
| At Risk | 3,148 | 12.3% | $24.1M | 24.6% |
| Loyal | 4,381 | 17.2% | $16.4M | 16.7% |
| All others | 13,258 | 51.9% | $7.4M | 7.5% |

> **Recommendation.** 3,151 previously high-value customers have lapsed,
> carrying **$20.8M in annualised revenue**. At even a 10% win-back rate that
> is $2.1M — which comfortably funds a targeted retention programme. Trigger
> intervention at the observed 75th-percentile repurchase gap (41 days), not at
> an arbitrary 90-day threshold.

### 4. The busiest hours are the worst-served

Trading peaks at 18:00–20:00, which carries **29.0% of all revenue**. Customer
ratings in those same hours drop to **6.53 vs 6.96** off-peak, and the share of
poor ratings (≤5) rises from **13.1% to 19.4%** — a 48% relative increase in
dissatisfaction, concentrated in the three hours that matter most.

> **Recommendation.** The rating gap tracks traffic, not product mix — the same
> SKUs rate higher earlier in the day. This is a staffing distribution problem.
> Shifting cover into the evening peak addresses the 29% of revenue currently
> being served worst.

### 5. Nearly half of baskets are single-item

**44.1% of invoices contain one line** but produce only **22.1% of revenue**.
Market-basket analysis surfaces strong, actionable pairings:

| Product A | Product B | Lift | Type |
|---|---|---:|---|
| Travel Backpack | Luggage 24in | **9.15** | Within-category |
| Olive Oil 1L | Snack Variety Box | 7.74 | Within-category |
| Yoga Mat | Resistance Band Set | 7.71 | Within-category |
| Shampoo 750ml | Running Shoes | 5.44 | **Cross-category** |
| Power Bank | Travel Backpack | 3.48 | **Cross-category** |

> **Recommendation.** Average basket value rises from $150.79 (1 line) to
> $304.31 (2 lines) — an uplift of $153.52 per converted basket. Converting 5%
> of the 267,133 single-item baskets is worth **$2.05M across the period, about
> $342K a year**. The cross-category pairs are the ones current store layout
> almost certainly does not exploit.

### 6. Payment behaviour has shifted decisively

E-wallet rose from **38.2% to 48.8%** of revenue while cash fell from **27.8%
to 15.0%** — a 12.8-point collapse over six years.

> **Recommendation.** Cash handling infrastructure is sized for roughly double
> current usage. Review cash-office staffing and armoured-collection frequency.

---

## Data quality

The pipeline repairs what is recoverable and quarantines what is not — and
never drops a row without recording why.

**3.76%** of source rows arrived carrying at least one defect. Of those,
**18,034 (1.49%)** could not be saved and are held in
`staging.stg_sales_rejects` with a reason code:

| Reason | Rows | % of source |
|---|---:|---:|
| `DUPLICATE_LINE` | 9,626 | 0.79% |
| `NON_POSITIVE_QUANTITY` | 4,798 | 0.40% |
| `DATE_OUT_OF_RANGE` | 1,983 | 0.16% |
| `INVALID_DATE` | 1,627 | 0.13% |

Repaired in place, without losing the row: currency-formatted prices
(`"$1,234.50"`), city casing and whitespace variants (`" YANGON "`, `"yangon"`),
payment-method spellings (`"E-Wallet"`, `"ewallet"`, `"EWALLET"`), blank and
`"n/a"` customer types, and empty ratings converted to `NULL`.

`sql/02_analysis/05_quality_assertions.sql` runs **18 assertions** across five
categories and raises an exception if any fail, so it can gate a scheduled
pipeline rather than merely describe a problem after the fact:

```
 category       | checks | passed | failed
----------------+--------+--------+--------
 completeness   |      3 |      3 |      0
 consistency    |      3 |      3 |      0
 integrity      |      4 |      4 |      0
 reconciliation |      3 |      3 |      0
 validity       |      5 |      5 |      0
```

Reconciliation is exact end to end: 1,212,983 raw = 1,194,949 staged + 18,034
rejected, and revenue ties from staging to mart to the cent.

**A correction to the source data.** The Kaggle sample defines `gross_income`
as the tax amount and holds gross margin constant at 4.7619% on every row —
which is not a margin at all, but 5/105. This model computes
`gross_profit = gross_sales − cogs` with margin varying by product line
(11.5%–33.7%), which is what makes the profitability analysis in Finding 2
possible. Assertion 15 exists specifically to catch a regression to a flat
margin.

---

## Query performance

`marts.fact_sales` is RANGE-partitioned by month with seven indexes, including
a covering index and a partial index excluding anonymous walk-ins.
`marts.fact_sales_unoptimised` holds identical rows as an unindexed heap. Same
SQL, both tables, median of 15 runs:

| Query | Control | Optimised | Speedup |
|---|---:|---:|---:|
| Single-month revenue by branch | 79.0 ms | 8.1 ms | **9.7×** |
| Single customer order history | 105.2 ms | 1.1 ms | **98.4×** |
| Single invoice lookup | 99.9 ms | 1.7 ms | **60.2×** |
| Quarterly branch scorecard | 144.3 ms | 93.8 ms | 1.5× |
| Full-year category aggregation | 130.6 ms | 104.1 ms | 1.3× |
| Full-table aggregate (no filter) | 138.9 ms | 162.4 ms | **0.9×** |

Median speedup across queries that benefit: **9.7×**.

The last row is reported deliberately. With no date predicate there is nothing
to prune, and the partitioned table is marginally *slower* — the planner opens
and appends 72 relations instead of scanning one. Partitioning is a targeted
optimisation for date-filtered access, not a free win, and the point-lookup
figures above vary with cache state. Quoting only the favourable cases would
misrepresent the design.

Cost: 405 MB partitioned and indexed, against a 183 MB heap.

Full plans, including `Partitions removed by pruning` and index-only scan
evidence, are in [`sql/02_analysis/06_performance.sql`](sql/02_analysis/06_performance.sql).
Results: [`docs/benchmark_results.md`](docs/benchmark_results.md).

---

## Power BI

[`powerbi/build_guide.md`](powerbi/build_guide.md) is the complete
specification: connection setup, model relationships, 35+ documented DAX
measures, and a visual-by-visual layout for four pages.

| Page | Answers |
|---|---|
| Executive Overview | Are we growing, and where is the growth coming from? |
| Product & Category | What should we stock more of, and what is quietly unprofitable? |
| Customer Segmentation | Who is valuable, who is leaving, and what is that worth? |
| Branch & Operations | Which stores need attention, and when are we understaffed? |

The warehouse pre-computes what does not belong in DAX. RFM quintiles, the
cohort matrix and basket affinities are materialised as
`marts.dim_customer_rfm`, `marts.v_cohort_retention` and
`marts.v_basket_affinity` — all three need window functions or self-joins that
would run on every model refresh for a result that never changes within one.
`marts.v_kpi_monthly` pre-aggregates the executive page to 1,214 rows instead
of 1.19M.

---

## Repository layout

```
walmart-retail-analytics/
├── src/
│   ├── config.py                  every parameter shaping the simulation
│   ├── generate_data.py           vectorised generator (1.2M rows in ~10s)
│   ├── validate_generation.py     13 assertions on engineered signal
│   ├── load_warehouse.py          orchestrates the full build
│   └── benchmark.py               partitioned vs heap, writes the report
├── sql/
│   ├── 00_schema/
│   │   ├── 01_schemas_and_raw.sql     three-layer structure + audit trail
│   │   ├── 02_marts_ddl.sql           star schema, partitions, constraints
│   │   └── 03_indexes.sql             covering + partial indexes
│   ├── 01_transform/
│   │   ├── 01_staging_clean.sql       repair, reject, reconcile
│   │   ├── 02_dimensions.sql          generated date dim + conformed dims
│   │   ├── 03_fact_sales.sql          surrogate key resolution
│   │   ├── 04_customer_enrich.sql     behavioural cohort anchoring
│   │   ├── 05_customer_rfm.sql        single source of RFM truth
│   │   └── 06_powerbi_model.sql       semantic-layer objects
│   └── 02_analysis/
│       ├── 01_growth.sql              YoY, CAGR, LFL decomposition
│       ├── 02_customer.sql            RFM, cohorts, CLV, revenue at risk
│       ├── 03_product.sql             ABC/Pareto, market basket, mix
│       ├── 04_branch_ops.sql          scorecards, hour×day, staffing
│       ├── 05_quality_assertions.sql  18-assertion gate
│       └── 06_performance.sql         EXPLAIN ANALYZE evidence
├── powerbi/build_guide.md         model, DAX, page specifications
├── docs/
│   ├── data_generation.md         simulation method and honesty statement
│   └── benchmark_results.md       generated by src/benchmark.py
└── data/
    ├── raw/                       original 1,000-row Kaggle sample
    └── generated/                 simulated CSVs (gitignored, ~200 MB)
```

---

## Techniques demonstrated

**SQL** — Kimball dimensional modelling · RANGE partitioning · covering and
partial indexes · window functions (`LAG`, `NTILE`, `RANK`, `ROW_NUMBER`,
`FIRST_VALUE`, framed aggregates) · recursive-free cohort construction ·
`FILTER` aggregates · `ROLLUP` · `PERCENTILE_CONT` · market-basket self-joins ·
`EXPLAIN ANALYZE` interpretation · assertion-based testing

**Analytics** — RFM segmentation · cohort retention · CLV · ABC/Pareto
classification · market-basket affinity (support/confidence/lift) ·
like-for-like growth decomposition · seasonality indexing · promotional uplift
measurement

**Engineering** — three-layer warehouse · idempotent rebuilds · reject
quarantine with reason codes · row-count reconciliation · load audit trail ·
vectorised data generation (NumPy) · streamed `COPY` bulk loading

**BI** — star-schema semantic modelling · DAX time intelligence · Import vs
DirectQuery reasoning · pushing computation to the right layer

---

## Relationship to the original project

This repository grew out of a single-file MySQL script that answered 26
business questions against one flat 1,000-row table. **All 26 of those
questions are still answered** — inside `sql/02_analysis/`, against a
dimensional model, at 1,000× the volume, alongside analysis the original data
could not support.

| | Original | This project |
|---|---|---|
| Rows | 1,000 | 1,194,949 |
| Period | 3 months | 6 years |
| Schema | one flat table | star schema, 5 dimensions |
| Data quality | none (`NOT NULL` only) | 18 assertions, reject quarantine |
| Analysis | 26 `GROUP BY` queries | 45 queries, 6 modules |
| Performance | not addressed | partitioned, indexed, benchmarked |
| BI layer | none | 4-page Power BI dashboard |
