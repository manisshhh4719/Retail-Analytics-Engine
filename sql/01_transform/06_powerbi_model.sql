-- ===========================================================================
-- 05_powerbi_model.sql
--
-- Objects created specifically for the Power BI semantic model.
--
-- Design rule followed here: push anything expensive, row-heavy or
-- order-dependent into SQL, and leave Power BI to do aggregation and time
-- intelligence. RFM quintiles need a window function over the whole customer
-- base; reproducing that in DAX would mean a calculated column evaluated over
-- 25K rows on every model refresh, for a result that never varies within a
-- refresh. It belongs in the warehouse.
--
-- Run after 04_customer_enrich.sql and after 02_analysis/02_customer.sql has
-- built staging.customer_rfm.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- dim_customer_rfm - a conformed segment dimension keyed on customer_key
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS marts.dim_customer_rfm;

CREATE TABLE marts.dim_customer_rfm AS
SELECT
    r.customer_key,
    r.rfm_segment,
    r.r_score,
    r.f_score,
    r.m_score,
    r.fm_score,
    r.recency_days,
    r.frequency          AS lifetime_orders,
    ROUND(r.monetary, 2) AS lifetime_revenue,
    ROUND(r.profit, 2)   AS lifetime_profit,
    r.first_purchase,
    r.last_purchase,
    r.tenure_days,
    -- Banding is done here rather than in DAX so the same definition serves
    -- the SQL analysis and the dashboard. Two definitions of "high value"
    -- drifting apart is a reporting bug waiting to happen.
    CASE
        WHEN r.m_score = 5 THEN 'High value'
        WHEN r.m_score >= 3 THEN 'Mid value'
        ELSE 'Low value'
    END AS value_band,
    CASE
        WHEN r.recency_days <=  90 THEN 'Active'
        WHEN r.recency_days <= 180 THEN 'Cooling'
        WHEN r.recency_days <= 365 THEN 'Lapsing'
        ELSE 'Dormant'
    END AS activity_status
FROM staging.customer_rfm r;

ALTER TABLE marts.dim_customer_rfm
    ADD CONSTRAINT pk_dim_customer_rfm PRIMARY KEY (customer_key);

CREATE INDEX ix_rfm_seg     ON marts.dim_customer_rfm (rfm_segment);
CREATE INDEX ix_rfm_status  ON marts.dim_customer_rfm (activity_status);


-- ---------------------------------------------------------------------------
-- v_cohort_retention - the cohort matrix, pre-shaped for a heatmap
--
-- Power BI cannot easily build a triangular cohort grid from the fact table
-- alone, and a DAX version needs a disconnected month-index table plus a
-- measure that recalculates cohort sizes on every cell. Materialising the
-- long-form result here keeps the visual to a plain matrix.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW marts.v_cohort_retention AS
WITH activity AS (
    SELECT DISTINCT
        c.cohort_month,
        f.customer_key,
        ((DATE_PART('year',  f.sale_date) - DATE_PART('year',  c.cohort_month)) * 12
       + (DATE_PART('month', f.sale_date) - DATE_PART('month', c.cohort_month)))::INT AS month_index
    FROM marts.fact_sales f
    JOIN marts.dim_customer c ON c.customer_key = f.customer_key
    WHERE f.customer_key <> -1
      AND c.cohort_month IS NOT NULL
),
sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_key) AS cohort_size
    FROM activity
    WHERE month_index = 0
    GROUP BY cohort_month
)
SELECT
    a.cohort_month,
    TO_CHAR(a.cohort_month, 'YYYY-MM')                      AS cohort_label,
    a.month_index,
    s.cohort_size,
    COUNT(DISTINCT a.customer_key)                          AS retained_customers,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) / s.cohort_size, 2) AS retention_pct
FROM activity a
JOIN sizes s ON s.cohort_month = a.cohort_month
WHERE a.month_index BETWEEN 0 AND 24
GROUP BY a.cohort_month, a.month_index, s.cohort_size;


-- ---------------------------------------------------------------------------
-- v_basket_affinity - top product pairs, precomputed
--
-- The self-join behind this is O(pairs per basket) over 605K invoices. It is
-- fine as a batch job and completely unsuitable for an interactive visual, so
-- the dashboard reads the result rather than the calculation.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW marts.v_basket_affinity AS
WITH baskets AS (
    SELECT DISTINCT invoice_id, product_key FROM marts.fact_sales
),
basket_total AS (
    SELECT COUNT(DISTINCT invoice_id)::NUMERIC AS n FROM marts.fact_sales
),
item_freq AS (
    SELECT product_key, COUNT(*)::NUMERIC AS cnt FROM baskets GROUP BY product_key
),
pairs AS (
    SELECT a.product_key AS key_a, b.product_key AS key_b,
           COUNT(*)::NUMERIC AS pair_count
    FROM baskets a
    JOIN baskets b ON a.invoice_id = b.invoice_id AND a.product_key < b.product_key
    GROUP BY a.product_key, b.product_key
    HAVING COUNT(*) >= 200
)
SELECT
    pa.product_name                                  AS product_a,
    pb.product_name                                  AS product_b,
    pa.product_line                                  AS line_a,
    pb.product_line                                  AS line_b,
    p.pair_count::INT                                AS baskets_together,
    ROUND(100.0 * p.pair_count / bt.n, 3)            AS support_pct,
    ROUND(100.0 * p.pair_count / ia.cnt, 1)          AS confidence_pct,
    ROUND((p.pair_count / bt.n)
          / ((ia.cnt / bt.n) * (ib.cnt / bt.n)), 2)  AS lift,
    CASE WHEN pa.product_line <> pb.product_line
         THEN 'Cross-category' ELSE 'Within-category' END AS pair_type
FROM pairs p
CROSS JOIN basket_total bt
JOIN item_freq ia ON ia.product_key = p.key_a
JOIN item_freq ib ON ib.product_key = p.key_b
JOIN marts.dim_product pa ON pa.product_key = p.key_a
JOIN marts.dim_product pb ON pb.product_key = p.key_b;


-- ---------------------------------------------------------------------------
-- v_kpi_summary - one row per month per branch, the dashboard's base grain
--
-- Importing 1.19M fact rows into Power BI works, but every card on the
-- executive page then re-aggregates the full table. This pre-aggregate covers
-- the overview page at roughly 1/800th the row count; detail pages still hit
-- the fact table directly.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW marts.v_kpi_monthly AS
SELECT
    d.year_month,
    d.month_start_date,
    d.year_number,
    d.month_number,
    f.branch_key,
    b.branch_code,
    b.city,
    b.region,
    COUNT(*)                                        AS line_items,
    COUNT(DISTINCT f.invoice_id)                    AS invoices,
    COUNT(DISTINCT f.customer_key)
        FILTER (WHERE f.customer_key <> -1)         AS active_customers,
    SUM(f.quantity)                                 AS units,
    SUM(f.total_amount)                             AS revenue,
    SUM(f.gross_sales)                              AS gross_sales,
    SUM(f.gross_profit)                             AS gross_profit,
    AVG(f.rating)                                   AS avg_rating
FROM marts.fact_sales f
JOIN marts.dim_date   d ON d.date_key   = f.date_key
JOIN marts.dim_branch b ON b.branch_key = f.branch_key
GROUP BY d.year_month, d.month_start_date, d.year_number, d.month_number,
         f.branch_key, b.branch_code, b.city, b.region;


ANALYZE marts.dim_customer_rfm;

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'powerbi', 'marts.dim_customer_rfm', COUNT(*), 'RFM segment dimension'
FROM marts.dim_customer_rfm;
