# Resume bullets

Every number here is a real query result. Nothing is estimated or inflated —
which matters, because an interviewer can ask you to reproduce any of it and
you can.

## Recommended set (pick 3–4)


> **Walmart Retail Analytics Warehouse** — PostgreSQL · SQL · Power BI · Python
>
> - Designed a Kimball star schema over **1.19M retail transactions** (2019–2024,
>   20 branches), replacing a single flat table with 5 conformed dimensions, a
>   month-partitioned fact table, and a 3-layer ETL pipeline running end to end
>   in **162 seconds**.
> - Cut query latency up to **9.7×** on date-filtered analytics (79ms → 8.1ms)
>   and **60×** on point lookups via RANGE partitioning plus covering and
>   partial indexes, benchmarked with `EXPLAIN ANALYZE` against an unindexed
>   control table.
> - Built RFM segmentation and cohort-retention models in SQL showing the top
>   **18.6% of customers drive 51.2% of revenue**; identified **$20.8M in
>   annualised revenue** attached to 3,151 lapsed high-value customers and
>   recommended a trigger threshold from the observed 41-day repurchase gap.
> - Engineered a data-quality layer that reconciled **3.8% defective source
>   rows**, quarantined 18,034 unrecoverable records with reason codes, and
>   gates the pipeline on **18 automated assertions** across reconciliation,
>   integrity, validity, consistency and completeness.
> - Delivered a 4-page Power BI dashboard with **35+ DAX measures** including
>   time intelligence and dynamic RFM segmentation, pushing window-function
>   workloads into SQL views to keep refresh performant.

## Analysis-led alternatives

Use these if the role emphasises business analysis over engineering.

- Decomposed revenue growth into like-for-like and new-store contribution,
  revealing the **2020 downturn was 44% deeper than headline** (−11.0% vs
  −7.6%) and that ~half of 2022 growth came from store openings rather than
  trading.
- Identified that the fastest-growing category (**+8.5pts of revenue share**)
  ranks 2nd by revenue but **5th by profit** at a 19.2% margin against the
  portfolio's 33.7% leader, and quantified the blended-margin erosion risk.
- Found the evening peak carries **29% of revenue** but a **48% higher rate of
  poor ratings** (19.4% vs 13.1%), isolating a staffing-distribution problem
  from a product problem by holding SKU mix constant.
- Applied market-basket analysis (support/confidence/lift) across 605K
  invoices, surfacing cross-category pairings at **up to 9.15× lift** and
  sizing a **$342K/year** opportunity in converting single-item baskets.

## One-line version

> Built a PostgreSQL star-schema warehouse and Power BI dashboard over 1.19M
> retail transactions — 9.7× query speedup via partitioning, an 18-assertion
> data-quality gate, and RFM/cohort analysis identifying $20.8M in at-risk
> revenue.

## How to describe the data honestly

Do not hide that the dataset is simulated — lead with it. It is engineering
work, and framing it correctly turns the obvious interview question into a
strength.

**On the resume**, either phrasing is accurate:

- "over a **1.19M-row simulated retail dataset** extending a public Kaggle sample"
- "engineered a 1.19M-row transaction dataset to stress-test warehouse design at scale"

**When asked "is this real data?"**

> No — I generated it. The Kaggle source is 1,000 rows across three flat months,
> and its category distribution is nearly uniform, so there's no growth, no
> repeat customers, and no margin variation to analyse. I wrote a vectorised
> generator that learns the price and rating distributions from the real sample,
> then simulates six years with deliberate structure: compounding growth, a
> COVID shock, seasonality, customer churn, category mix shift, product
> affinities, and about 4% injected data defects. Then I wrote a validation
> script that asserts all thirteen signals are actually recoverable after
> cleaning. Every number I quote is a genuine query result — the behaviour is
> authored, but the measurement is real.

That answer demonstrates data engineering, statistical reasoning, testing
discipline, and intellectual honesty in about thirty seconds.

## Questions to be ready for

| Question | Where the answer lives |
|---|---|
| "Why partition by month?" | Every analytical query filters on date; pruning drops 71 of 72 partitions. Note it *hurts* unfiltered scans (0.9×) — say so. |
| "Why is RFM in SQL, not DAX?" | NTILE over the full customer base; recomputing per refresh for a static result. Single definition prevents dashboard/query drift. |
| "Why LEFT JOIN in the fact load?" | INNER JOIN silently drops rows whose dimension lookup fails, and counts still reconcile if you never check. Unknown members keep the row and make failure visible. |
| "What's the grain?" | One invoice line item. 1,194,949 rows across 605,743 invoices. |
| "How do you know the cleaning worked?" | 18 assertions, exact row reconciliation, revenue ties to the cent. |
| "Biggest limitation?" | 32 SKUs makes ABC less dramatic than a real catalogue; no returns; no cross-branch shopping. All listed in `docs/data_generation.md`. |
