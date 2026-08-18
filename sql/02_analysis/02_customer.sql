-- ===========================================================================
-- 02_customer.sql  -  Customer segmentation, retention and value
--
-- Scope note that governs every query in this file: only about half of all
-- invoices carry a loyalty id. The other half are anonymous walk-ins mapped to
-- customer_key = -1. Customer-level analysis is therefore always filtered to
-- customer_key <> -1, and every rate is expressed against the identified base,
-- never against total revenue - which would silently understate everything by
-- roughly half.
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/02_customer.sql
-- ===========================================================================

\echo '\n=== 2.1 Customer base overview ==='

WITH tx AS (
    SELECT
        SUM(total_amount)                                              AS revenue_all,
        SUM(total_amount) FILTER (WHERE customer_key <> -1)            AS revenue_identified,
        COUNT(DISTINCT invoice_id)                                     AS invoices_all,
        COUNT(DISTINCT invoice_id) FILTER (WHERE customer_key <> -1)   AS invoices_identified,
        COUNT(DISTINCT customer_key) FILTER (WHERE customer_key <> -1) AS active_customers
    FROM marts.fact_sales
)
SELECT
    (SELECT COUNT(*) FROM marts.dim_customer WHERE is_member)          AS registered_members,
    tx.active_customers                                                AS members_who_purchased,
    (SELECT COUNT(*) FROM marts.dim_customer
      WHERE is_member AND first_purchase_date IS NULL)                 AS never_activated,
    ROUND(100.0 * tx.active_customers
          / (SELECT COUNT(*) FROM marts.dim_customer WHERE is_member), 1) AS activation_rate_pct,
    ROUND(100.0 * tx.invoices_identified / tx.invoices_all, 1)         AS pct_invoices_identified,
    ROUND(100.0 * tx.revenue_identified / tx.revenue_all, 1)           AS pct_revenue_identified,
    ROUND(tx.revenue_identified / tx.active_customers, 2)              AS revenue_per_customer
FROM tx;


\echo '\n=== 2.2 RFM segmentation ==='

-- Scoring lives in the pipeline, not here: see
-- sql/01_transform/05_customer_rfm.sql. Keeping one definition means the
-- segment a customer carries on the dashboard is the same one this query
-- reports - recomputing quintiles ad hoc in two places is how the same
-- customer ends up labelled differently in two artefacts.

SELECT
    rfm_segment,
    COUNT(*)                                                   AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)         AS pct_customers,
    ROUND(SUM(monetary), 0)                                    AS revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue,
    ROUND(AVG(monetary), 0)                                    AS avg_value,
    ROUND(AVG(frequency), 1)                                   AS avg_orders,
    ROUND(AVG(recency_days), 0)                                AS avg_days_since_purchase
FROM staging.customer_rfm
GROUP BY rfm_segment
ORDER BY revenue DESC;


\echo '\n=== 2.3 Value concentration (Pareto on customers) ==='

WITH ranked AS (
    SELECT
        customer_key,
        monetary,
        NTILE(10) OVER (ORDER BY monetary DESC) AS value_decile
    FROM staging.customer_rfm
)
SELECT
    value_decile,
    COUNT(*)                                                       AS customers,
    ROUND(SUM(monetary), 0)                                        AS revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1)   AS pct_of_revenue,
    ROUND(SUM(SUM(monetary)) OVER (ORDER BY value_decile)
          * 100.0 / SUM(SUM(monetary)) OVER (), 1)                 AS cumulative_pct,
    ROUND(AVG(monetary), 0)                                        AS avg_customer_value
FROM ranked
GROUP BY value_decile
ORDER BY value_decile;


\echo '\n=== 2.4 Cohort retention matrix (% of cohort active in month N) ==='

-- Cohort = month of first observed purchase. month_index counts whole months
-- between that first purchase and each subsequent order, so month 0 is always
-- 100% by construction and month 1 onward is the number that matters.
WITH activity AS (
    SELECT DISTINCT
        c.cohort_month,
        f.customer_key,
        (DATE_PART('year',  f.sale_date) - DATE_PART('year',  c.cohort_month)) * 12
      + (DATE_PART('month', f.sale_date) - DATE_PART('month', c.cohort_month)) AS month_index
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
    TO_CHAR(s.cohort_month, 'YYYY-MM') AS cohort,
    s.cohort_size,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 1)  / s.cohort_size, 1) AS m1,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 2)  / s.cohort_size, 1) AS m2,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 3)  / s.cohort_size, 1) AS m3,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 6)  / s.cohort_size, 1) AS m6,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 12) / s.cohort_size, 1) AS m12,
    ROUND(100.0 * COUNT(DISTINCT a.customer_key) FILTER (WHERE a.month_index = 24) / s.cohort_size, 1) AS m24
FROM sizes s
JOIN activity a ON a.cohort_month = s.cohort_month
WHERE s.cohort_month < DATE '2024-01-01'      -- exclude cohorts too young to judge
GROUP BY s.cohort_month, s.cohort_size
ORDER BY s.cohort_month;


\echo '\n=== 2.5 Average retention curve across all cohorts ==='

WITH activity AS (
    SELECT DISTINCT
        c.cohort_month,
        f.customer_key,
        (DATE_PART('year',  f.sale_date) - DATE_PART('year',  c.cohort_month)) * 12
      + (DATE_PART('month', f.sale_date) - DATE_PART('month', c.cohort_month)) AS month_index
    FROM marts.fact_sales f
    JOIN marts.dim_customer c ON c.customer_key = f.customer_key
    WHERE f.customer_key <> -1 AND c.cohort_month IS NOT NULL
),
sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_key) AS cohort_size
    FROM activity WHERE month_index = 0 GROUP BY cohort_month
),
retention AS (
    SELECT
        a.month_index,
        COUNT(DISTINCT a.customer_key)::NUMERIC AS retained,
        SUM(s.cohort_size)                      AS exposed
    FROM activity a
    JOIN sizes s ON s.cohort_month = a.cohort_month
    -- Only count cohorts old enough to have had the chance to reach month N.
    WHERE a.cohort_month + (a.month_index || ' months')::INTERVAL
          <= (SELECT MAX(sale_date) FROM marts.fact_sales)
    GROUP BY a.month_index
)
SELECT
    r.month_index::INT AS month_n,
    ROUND(100.0 * r.retained / NULLIF(
        (SELECT SUM(s2.cohort_size) FROM sizes s2
          WHERE s2.cohort_month + (r.month_index || ' months')::INTERVAL
                <= (SELECT MAX(sale_date) FROM marts.fact_sales)), 0), 1) AS retention_pct
FROM retention r
WHERE r.month_index BETWEEN 0 AND 24
ORDER BY r.month_index;


\echo '\n=== 2.6 Customer lifetime value and behaviour by segment ==='

SELECT
    rfm_segment,
    COUNT(*)                                           AS customers,
    ROUND(AVG(monetary), 0)                            AS avg_lifetime_revenue,
    ROUND(AVG(profit), 0)                              AS avg_lifetime_profit,
    ROUND(AVG(monetary / NULLIF(frequency, 0)), 2)     AS avg_order_value,
    ROUND(AVG(frequency), 1)                           AS avg_orders,
    ROUND(AVG(tenure_days), 0)                         AS avg_tenure_days,
    -- Orders per active year: normalises frequency for how long the customer
    -- has actually been on file, so a 5-year customer is not compared with a
    -- 3-month one on raw order count.
    ROUND(AVG(frequency / NULLIF(tenure_days / 365.0, 0))
          FILTER (WHERE tenure_days > 90), 2)          AS orders_per_year
FROM staging.customer_rfm
GROUP BY rfm_segment
ORDER BY avg_lifetime_revenue DESC;


\echo '\n=== 2.7 Revenue at risk from lapsing high-value customers ==='

-- The commercial point of RFM. Sizes the annual revenue attached to customers
-- who were valuable and have gone quiet, which is the number a retention
-- budget gets justified against.
WITH lapsed AS (
    SELECT
        rfm_segment,
        customer_key,
        monetary,
        frequency,
        recency_days,
        monetary / NULLIF(GREATEST(tenure_days, 1) / 365.0, 0) AS annualised_value
    FROM staging.customer_rfm
    WHERE rfm_segment IN ('At Risk', 'Hibernating', 'Lost')
      AND m_score >= 4                       -- valuable while they were active
      AND tenure_days > 90
)
SELECT
    rfm_segment,
    COUNT(*)                              AS customers,
    ROUND(AVG(recency_days), 0)           AS avg_days_inactive,
    ROUND(SUM(monetary), 0)               AS historic_revenue,
    ROUND(SUM(annualised_value), 0)       AS annual_revenue_at_risk,
    ROUND(AVG(annualised_value), 0)       AS avg_annual_value_per_customer
FROM lapsed
GROUP BY rfm_segment
ORDER BY annual_revenue_at_risk DESC;


\echo '\n=== 2.8 New vs returning revenue by year ==='

WITH tagged AS (
    SELECT
        d.year_number AS yr,
        f.total_amount,
        f.invoice_id,
        CASE
            WHEN DATE_PART('year', c.first_purchase_date) = d.year_number
            THEN 'New' ELSE 'Returning'
        END AS customer_status
    FROM marts.fact_sales f
    JOIN marts.dim_date     d ON d.date_key     = f.date_key
    JOIN marts.dim_customer c ON c.customer_key = f.customer_key
    WHERE f.customer_key <> -1
)
SELECT
    yr,
    ROUND(SUM(total_amount) FILTER (WHERE customer_status = 'New'), 0)       AS new_revenue,
    ROUND(SUM(total_amount) FILTER (WHERE customer_status = 'Returning'), 0) AS returning_revenue,
    ROUND(100.0 * SUM(total_amount) FILTER (WHERE customer_status = 'Returning')
          / SUM(total_amount), 1)                                            AS returning_share_pct,
    COUNT(DISTINCT invoice_id) FILTER (WHERE customer_status = 'New')         AS new_invoices,
    COUNT(DISTINCT invoice_id) FILTER (WHERE customer_status = 'Returning')   AS returning_invoices
FROM tagged
GROUP BY yr
ORDER BY yr;


\echo '\n=== 2.9 Purchase gap: how long between orders ==='

-- LAG over each customer's own order history gives the inter-purchase interval,
-- which is what a "we have not seen you in a while" trigger should be set from
-- rather than an arbitrary 90-day rule.
WITH orders AS (
    SELECT DISTINCT customer_key, invoice_id, sale_date
    FROM marts.fact_sales
    WHERE customer_key <> -1
),
gaps AS (
    SELECT
        customer_key,
        sale_date - LAG(sale_date) OVER (PARTITION BY customer_key ORDER BY sale_date) AS gap_days
    FROM orders
)
SELECT
    COUNT(*)                                                             AS repeat_orders,
    ROUND(AVG(gap_days), 1)                                              AS avg_gap_days,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap_days)               AS median_gap_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_days)               AS p75_gap_days,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gap_days)               AS p90_gap_days
FROM gaps
WHERE gap_days IS NOT NULL;
