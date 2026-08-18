-- ===========================================================================
-- 05_customer_rfm.sql
--
-- Builds the RFM scoring table once, as part of the pipeline, so that the
-- analysis queries and the Power BI model both read a single definition of a
-- customer's segment. Scoring is order-dependent (NTILE over the whole
-- customer base), so recomputing it ad hoc in two places is how the same
-- customer ends up labelled "Champion" on a dashboard and "Loyal" in a query.
--
-- Recency  - days since last purchase, snapshot-dated to the latest sale
-- Frequency- distinct invoices over the customer's lifetime
-- Monetary - total revenue attributed to the customer
-- ===========================================================================

DROP TABLE IF EXISTS staging.customer_rfm;

CREATE TABLE staging.customer_rfm AS
WITH snapshot AS (
    -- Anchored to the last transaction in the warehouse, not to now(), so the
    -- results are reproducible rather than drifting with the wall clock.
    SELECT MAX(sale_date) AS as_of FROM marts.fact_sales
),
base AS (
    SELECT
        f.customer_key,
        MAX(f.sale_date)                                AS last_purchase,
        (SELECT as_of FROM snapshot) - MAX(f.sale_date) AS recency_days,
        COUNT(DISTINCT f.invoice_id)                    AS frequency,
        SUM(f.total_amount)                             AS monetary,
        SUM(f.gross_profit)                             AS profit,
        MIN(f.sale_date)                                AS first_purchase,
        MAX(f.sale_date) - MIN(f.sale_date)             AS tenure_days
    FROM marts.fact_sales f
    WHERE f.customer_key <> -1
    GROUP BY f.customer_key
),
scored AS (
    SELECT
        b.*,
        -- Recency is ordered DESC so a smaller gap earns the higher score.
        -- Getting this backwards is the classic RFM bug: every segment label
        -- downstream inverts, and the output still looks plausible.
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency)         AS f_score,
        NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM base b
)
SELECT
    s.*,
    (s.f_score + s.m_score) / 2.0 AS fm_score,
    -- CASE order matters: Champions must be tested before Loyal, and At Risk
    -- before Hibernating, or the broader rule swallows the narrower one.
    CASE
        WHEN r_score >= 4 AND (f_score + m_score) / 2.0 >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND (f_score + m_score) / 2.0 >= 3 THEN 'Loyal'
        WHEN r_score >= 4 AND (f_score + m_score) / 2.0 <  3 THEN 'Promising'
        WHEN r_score =  3 AND (f_score + m_score) / 2.0 <  3 THEN 'Needs Attention'
        WHEN r_score <= 2 AND (f_score + m_score) / 2.0 >= 4 THEN 'At Risk'
        WHEN r_score <= 2 AND (f_score + m_score) / 2.0 >= 3 THEN 'Hibernating'
        WHEN r_score =  1                                    THEN 'Lost'
        ELSE 'Others'
    END AS rfm_segment
FROM scored s;

ALTER TABLE staging.customer_rfm
    ADD CONSTRAINT pk_customer_rfm PRIMARY KEY (customer_key);

CREATE INDEX ix_rfm_segment ON staging.customer_rfm (rfm_segment);

ANALYZE staging.customer_rfm;

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'rfm', 'staging.customer_rfm', COUNT(*), 'scored customers'
FROM staging.customer_rfm;
