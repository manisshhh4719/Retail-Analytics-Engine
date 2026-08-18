-- ===========================================================================
-- 04_branch_ops.sql  -  Branch performance and store operations
--
-- Comparing branches on raw revenue is unfair to any store that opened
-- recently. Where a like-for-like comparison is the point, this file
-- normalises by trading days rather than ranking on totals.
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/04_branch_ops.sql
-- ===========================================================================

\echo '\n=== 4.1 Branch scorecard ==='

WITH branch_perf AS (
    SELECT
        b.branch_key,
        b.branch_code,
        b.city,
        b.size_band,
        b.opened_date,
        COUNT(DISTINCT f.sale_date)                                AS trading_days,
        COUNT(DISTINCT f.invoice_id)                               AS invoices,
        SUM(f.total_amount)                                        AS revenue,
        SUM(f.gross_profit)                                        AS profit,
        AVG(f.rating)                                              AS avg_rating,
        COUNT(DISTINCT f.customer_key)
            FILTER (WHERE f.customer_key <> -1)                    AS customers
    FROM marts.fact_sales f
    JOIN marts.dim_branch b ON b.branch_key = f.branch_key
    GROUP BY b.branch_key, b.branch_code, b.city, b.size_band, b.opened_date
)
SELECT
    branch_code,
    city,
    size_band,
    opened_date,
    trading_days,
    ROUND(revenue, 0)                                              AS revenue,
    ROUND(profit, 0)                                               AS gross_profit,
    ROUND(100.0 * profit / NULLIF(revenue / 1.05, 0), 1)           AS margin_pct,
    -- The fair comparison: revenue earned per day the store was actually open.
    ROUND(revenue / trading_days, 0)                               AS revenue_per_trading_day,
    ROUND(revenue / invoices, 2)                                   AS avg_basket,
    ROUND(avg_rating, 2)                                           AS avg_rating,
    customers,
    RANK() OVER (ORDER BY revenue DESC)                            AS rank_by_revenue,
    RANK() OVER (ORDER BY revenue / trading_days DESC)             AS rank_by_daily_rate,
    RANK() OVER (ORDER BY avg_rating DESC)                         AS rank_by_rating
FROM branch_perf
ORDER BY revenue DESC;


\echo '\n=== 4.2 City and region rollup ==='

SELECT
    b.region,
    b.city,
    COUNT(DISTINCT b.branch_key)                                   AS branches,
    ROUND(SUM(f.total_amount), 0)                                  AS revenue,
    ROUND(100.0 * SUM(f.total_amount)
          / SUM(SUM(f.total_amount)) OVER (), 1)                   AS pct_of_revenue,
    ROUND(SUM(f.gross_profit), 0)                                  AS profit,
    ROUND(SUM(f.total_amount) / COUNT(DISTINCT b.branch_key), 0)   AS revenue_per_branch,
    ROUND(AVG(f.rating), 2)                                        AS avg_rating
FROM marts.fact_sales f
JOIN marts.dim_branch b ON b.branch_key = f.branch_key
GROUP BY ROLLUP (b.region, b.city)
ORDER BY b.region NULLS LAST, revenue DESC NULLS LAST;


\echo '\n=== 4.3 Hour x weekday revenue heatmap ==='

-- The grid a staffing rota is actually built from. Values are revenue per
-- occurrence of that weekday-hour slot, so the numbers are comparable across
-- cells regardless of how many Mondays the period contained.
SELECT
    f.sale_hour,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 1)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 1), 0) AS mon,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 2)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 2), 0) AS tue,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 3)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 3), 0) AS wed,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 4)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 4), 0) AS thu,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 5)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 5), 0) AS fri,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 6)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 6), 0) AS sat,
    ROUND(SUM(f.total_amount) FILTER (WHERE d.day_of_week = 7)
          / COUNT(DISTINCT d.full_date) FILTER (WHERE d.day_of_week = 7), 0) AS sun
FROM marts.fact_sales f
JOIN marts.dim_date d ON d.date_key = f.date_key
GROUP BY f.sale_hour
ORDER BY f.sale_hour;


\echo '\n=== 4.4 Peak trading hours and the service quality trade-off ==='

-- The operational finding of the project. Ranking hours by revenue and by
-- rating side by side shows that the busiest hours are also the worst-rated,
-- which is a staffing problem rather than a merchandising one.
WITH hourly AS (
    SELECT
        f.sale_hour,
        SUM(f.total_amount)          AS revenue,
        COUNT(DISTINCT f.invoice_id) AS invoices,
        AVG(f.rating)                AS avg_rating,
        COUNT(*)                     AS line_items
    FROM marts.fact_sales f
    GROUP BY f.sale_hour
)
SELECT
    sale_hour,
    ROUND(revenue, 0)                                               AS revenue,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 1)                AS pct_of_revenue,
    invoices,
    ROUND(revenue / invoices, 2)                                    AS avg_basket,
    ROUND(avg_rating, 2)                                            AS avg_rating,
    ROUND(avg_rating - AVG(avg_rating) OVER (), 2)                  AS rating_vs_mean,
    RANK() OVER (ORDER BY revenue DESC)                             AS busiest_rank,
    RANK() OVER (ORDER BY avg_rating DESC)                          AS rating_rank
FROM hourly
ORDER BY revenue DESC;


\echo '\n=== 4.5 Sizing the peak-hour service gap ==='

-- Quantifies what the rating drop is attached to in revenue terms, which is
-- how a staffing request gets costed.
WITH classified AS (
    SELECT
        CASE WHEN sale_hour BETWEEN 18 AND 20 THEN 'Peak (18-20)'
             ELSE 'Off-peak' END AS period,
        total_amount, rating, invoice_id, sale_hour
    FROM marts.fact_sales
)
SELECT
    period,
    COUNT(DISTINCT invoice_id)                                      AS invoices,
    ROUND(SUM(total_amount), 0)                                     AS revenue,
    ROUND(100.0 * SUM(total_amount) / SUM(SUM(total_amount)) OVER (), 1) AS pct_of_revenue,
    ROUND(COUNT(DISTINCT invoice_id)::NUMERIC
          / COUNT(DISTINCT sale_hour), 0)                           AS invoices_per_hour_slot,
    ROUND(AVG(rating), 2)                                           AS avg_rating,
    ROUND(100.0 * COUNT(*) FILTER (WHERE rating <= 5)
          / COUNT(*) FILTER (WHERE rating IS NOT NULL), 1)          AS pct_ratings_5_or_below
FROM classified
GROUP BY period
ORDER BY revenue DESC;


\echo '\n=== 4.6 Payment method adoption over time ==='

WITH yearly AS (
    SELECT
        d.year_number   AS yr,
        pm.payment_method,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date    d  ON d.date_key    = f.date_key
    JOIN marts.dim_payment pm ON pm.payment_key = f.payment_key
    GROUP BY d.year_number, pm.payment_method
)
SELECT
    payment_method,
    ROUND(MAX(share) FILTER (WHERE yr = 2019), 1) AS y2019,
    ROUND(MAX(share) FILTER (WHERE yr = 2021), 1) AS y2021,
    ROUND(MAX(share) FILTER (WHERE yr = 2024), 1) AS y2024,
    ROUND(MAX(share) FILTER (WHERE yr = 2024)
        - MAX(share) FILTER (WHERE yr = 2019), 1) AS change_pts
FROM (
    SELECT yr, payment_method, revenue,
           100.0 * revenue / SUM(revenue) OVER (PARTITION BY yr) AS share
    FROM yearly
) s
GROUP BY payment_method
ORDER BY y2024 DESC;


\echo '\n=== 4.7 Branch ranking movement year on year ==='

-- Rank by daily trading rate rather than total revenue so a mid-year opening
-- does not appear to "improve" simply by trading more days in its second year.
WITH branch_year AS (
    SELECT
        d.year_number AS yr,
        b.branch_code,
        SUM(f.total_amount) / COUNT(DISTINCT f.sale_date) AS daily_rate
    FROM marts.fact_sales f
    JOIN marts.dim_date   d ON d.date_key   = f.date_key
    JOIN marts.dim_branch b ON b.branch_key = f.branch_key
    GROUP BY d.year_number, b.branch_code
),
ranked AS (
    SELECT
        yr, branch_code, daily_rate,
        RANK() OVER (PARTITION BY yr ORDER BY daily_rate DESC) AS rank_in_year
    FROM branch_year
)
SELECT
    branch_code,
    MAX(rank_in_year) FILTER (WHERE yr = 2019) AS rank_2019,
    MAX(rank_in_year) FILTER (WHERE yr = 2022) AS rank_2022,
    MAX(rank_in_year) FILTER (WHERE yr = 2024) AS rank_2024,
    MAX(rank_in_year) FILTER (WHERE yr = 2019)
      - MAX(rank_in_year) FILTER (WHERE yr = 2024) AS places_gained,
    ROUND(MAX(daily_rate) FILTER (WHERE yr = 2024), 0) AS daily_rate_2024
FROM ranked
GROUP BY branch_code
ORDER BY places_gained DESC NULLS LAST;


\echo '\n=== 4.8 Customer rating distribution by branch ==='

SELECT
    b.branch_code,
    b.city,
    COUNT(f.rating)                                                 AS rated_transactions,
    ROUND(AVG(f.rating), 2)                                         AS avg_rating,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.rating >= 9)
          / NULLIF(COUNT(f.rating), 0), 1)                          AS pct_promoters,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.rating <= 5)
          / NULLIF(COUNT(f.rating), 0), 1)                          AS pct_detractors,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.rating >= 9)
          / NULLIF(COUNT(f.rating), 0)
        - 100.0 * COUNT(*) FILTER (WHERE f.rating <= 5)
          / NULLIF(COUNT(f.rating), 0), 1)                          AS net_promoter_style_score
FROM marts.fact_sales f
JOIN marts.dim_branch b ON b.branch_key = f.branch_key
GROUP BY b.branch_code, b.city
ORDER BY net_promoter_style_score DESC;
