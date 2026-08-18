-- ===========================================================================
-- 01_growth.sql  -  Revenue growth and trend
--
-- Answers: how fast is the business growing, how much of that is real versus
-- new stores, when does it trade, and what do promotions actually buy.
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/01_growth.sql
-- ===========================================================================

\echo '\n=== 1.1 Executive summary ==='

-- Single-row headline block. Ratios are computed from summed components, never
-- averaged from row-level ratios - averaging a percentage across 1.2M rows of
-- differing basket sizes gives the wrong answer.
SELECT
    COUNT(*)                                      AS line_items,
    COUNT(DISTINCT f.invoice_id)                  AS invoices,
    COUNT(DISTINCT f.customer_key)
        FILTER (WHERE f.customer_key <> -1)       AS identified_customers,
    COUNT(DISTINCT f.branch_key)                  AS branches,
    MIN(f.sale_date)                              AS first_sale,
    MAX(f.sale_date)                              AS last_sale,
    ROUND(SUM(f.total_amount), 0)                 AS total_revenue,
    ROUND(SUM(f.gross_profit), 0)                 AS gross_profit,
    ROUND(100.0 * SUM(f.gross_profit) / SUM(f.gross_sales), 2) AS gross_margin_pct,
    ROUND(SUM(f.total_amount) / COUNT(DISTINCT f.invoice_id), 2) AS avg_basket_value,
    ROUND(AVG(f.rating), 2)                       AS avg_rating
FROM marts.fact_sales f;


\echo '\n=== 1.2 Monthly revenue with MoM, YoY and 3-month moving average ==='

-- LAG(...,1) gives month on month; LAG(...,12) gives the same month last year,
-- which is the comparison that survives seasonality. The moving average uses a
-- ROWS frame rather than RANGE so it counts months, not calendar distance.
WITH monthly AS (
    SELECT
        d.year_month,
        MIN(d.month_start_date)          AS month_start,
        SUM(f.total_amount)              AS revenue,
        SUM(f.gross_profit)              AS profit,
        COUNT(DISTINCT f.invoice_id)     AS invoices
    FROM marts.fact_sales f
    JOIN marts.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_month
)
SELECT
    year_month,
    ROUND(revenue, 0)                                  AS revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER w)
          / NULLIF(LAG(revenue) OVER w, 0), 1)         AS mom_pct,
    ROUND(100.0 * (revenue - LAG(revenue, 12) OVER w)
          / NULLIF(LAG(revenue, 12) OVER w, 0), 1)     AS yoy_pct,
    ROUND(AVG(revenue) OVER (ORDER BY month_start
                             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)
                                                       AS revenue_3mo_ma,
    invoices,
    ROUND(revenue / invoices, 2)                       AS avg_basket
FROM monthly
WINDOW w AS (ORDER BY month_start)
ORDER BY month_start;


\echo '\n=== 1.3 Annual growth and CAGR ==='

WITH yearly AS (
    SELECT
        d.year_number                AS yr,
        SUM(f.total_amount)          AS revenue,
        SUM(f.gross_profit)          AS profit,
        COUNT(DISTINCT f.invoice_id) AS invoices,
        COUNT(DISTINCT f.branch_key) AS branches_trading
    FROM marts.fact_sales f
    JOIN marts.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_number
),
with_growth AS (
    SELECT
        yr, revenue, profit, invoices, branches_trading,
        LAG(revenue) OVER (ORDER BY yr) AS prev_revenue,
        FIRST_VALUE(revenue) OVER (ORDER BY yr) AS base_revenue,
        yr - MIN(yr) OVER () AS years_elapsed
    FROM yearly
)
SELECT
    yr,
    ROUND(revenue, 0)                                     AS revenue,
    ROUND(profit, 0)                                      AS gross_profit,
    branches_trading,
    ROUND(100.0 * (revenue - prev_revenue)
          / NULLIF(prev_revenue, 0), 1)                   AS yoy_growth_pct,
    ROUND(revenue / invoices, 2)                          AS avg_basket,
    -- Compound annual growth rate measured from the first year in the series.
    ROUND(100.0 * (POWER(revenue / base_revenue,
                         1.0 / NULLIF(years_elapsed, 0)) - 1), 1) AS cagr_to_date_pct
FROM with_growth
ORDER BY yr;


\echo '\n=== 1.4 Growth decomposition: like-for-like vs new stores ==='

-- Headline growth flatters a business that is simply opening stores. A branch
-- counts as like-for-like only if it was already trading for the whole of the
-- prior year; everything else is new-store contribution. This is the single
-- most important slide in a retail growth review.
WITH branch_year AS (
    SELECT
        d.year_number      AS yr,
        f.branch_key,
        b.opened_date,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date   d ON d.date_key   = f.date_key
    JOIN marts.dim_branch b ON b.branch_key = f.branch_key
    GROUP BY d.year_number, f.branch_key, b.opened_date
),
classified AS (
    SELECT
        yr,
        branch_key,
        revenue,
        -- Trading for the full previous year => comparable.
        CASE WHEN opened_date <= MAKE_DATE(yr - 1, 1, 1)
             THEN 'like_for_like' ELSE 'new_store' END AS store_class
    FROM branch_year
),
agg AS (
    SELECT
        yr,
        SUM(revenue)                                                    AS total_revenue,
        SUM(revenue) FILTER (WHERE store_class = 'like_for_like')       AS lfl_revenue,
        SUM(revenue) FILTER (WHERE store_class = 'new_store')           AS new_revenue
    FROM classified
    GROUP BY yr
),
lfl_pairs AS (
    -- Prior-year revenue restricted to the same set of comparable branches.
    SELECT
        c.yr,
        SUM(py.revenue) AS lfl_prior_revenue
    FROM classified c
    JOIN branch_year py
      ON py.branch_key = c.branch_key
     AND py.yr = c.yr - 1
    WHERE c.store_class = 'like_for_like'
    GROUP BY c.yr
)
SELECT
    a.yr,
    ROUND(a.total_revenue, 0)                                  AS total_revenue,
    ROUND(a.lfl_revenue, 0)                                    AS lfl_revenue,
    ROUND(COALESCE(a.new_revenue, 0), 0)                       AS new_store_revenue,
    ROUND(100.0 * COALESCE(a.new_revenue, 0)
          / a.total_revenue, 1)                                AS new_store_share_pct,
    ROUND(100.0 * (a.lfl_revenue - l.lfl_prior_revenue)
          / NULLIF(l.lfl_prior_revenue, 0), 1)                 AS lfl_growth_pct,
    ROUND(100.0 * (a.total_revenue - LAG(a.total_revenue) OVER (ORDER BY a.yr))
          / NULLIF(LAG(a.total_revenue) OVER (ORDER BY a.yr), 0), 1) AS headline_growth_pct
FROM agg a
LEFT JOIN lfl_pairs l ON l.yr = a.yr
ORDER BY a.yr;


\echo '\n=== 1.5 Seasonality index by month ==='

-- Index of 100 = an average month. Computed across all years so a single
-- unusual year cannot define the shape.
WITH monthly AS (
    SELECT
        d.year_number  AS yr,
        d.month_number AS mth,
        d.month_abbr,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_number, d.month_number, d.month_abbr
),
indexed AS (
    SELECT
        yr, mth, month_abbr, revenue,
        100.0 * revenue / AVG(revenue) OVER (PARTITION BY yr) AS month_index
    FROM monthly
)
SELECT
    mth,
    MIN(month_abbr)                  AS month,
    ROUND(AVG(month_index), 1)       AS seasonality_index,
    ROUND(MIN(month_index), 1)       AS min_index,
    ROUND(MAX(month_index), 1)       AS max_index,
    CASE
        WHEN AVG(month_index) >= 115 THEN 'Peak'
        WHEN AVG(month_index) >= 100 THEN 'Above average'
        WHEN AVG(month_index) >=  92 THEN 'Below average'
        ELSE 'Trough'
    END                              AS trading_period
FROM indexed
GROUP BY mth
ORDER BY mth;


\echo '\n=== 1.6 Day-of-week trading pattern ==='

SELECT
    d.day_of_week,
    d.day_abbr                                        AS day,
    ROUND(SUM(f.total_amount), 0)                     AS revenue,
    COUNT(DISTINCT f.invoice_id)                      AS invoices,
    ROUND(SUM(f.total_amount) / COUNT(DISTINCT f.invoice_id), 2) AS avg_basket,
    ROUND(100.0 * SUM(f.total_amount)
          / SUM(SUM(f.total_amount)) OVER (), 1)      AS pct_of_revenue,
    ROUND(100.0 * SUM(f.total_amount)
          / AVG(SUM(f.total_amount)) OVER (), 1)      AS index_vs_avg_day
FROM marts.fact_sales f
JOIN marts.dim_date d ON d.date_key = f.date_key
GROUP BY d.day_of_week, d.day_abbr
ORDER BY d.day_of_week;


\echo '\n=== 1.7 Promotional window uplift ==='

-- Compares promo days against non-promo days in the same month, so the
-- comparison is not contaminated by seasonality: Black Friday sits in the
-- strongest trading month of the year, and measuring it against the annual
-- average would overstate the uplift substantially.
WITH daily AS (
    SELECT
        d.full_date,
        d.year_month,
        d.is_promo_window,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date d ON d.date_key = f.date_key
    GROUP BY d.full_date, d.year_month, d.is_promo_window
),
by_month AS (
    SELECT
        year_month,
        AVG(revenue) FILTER (WHERE is_promo_window)       AS promo_day_avg,
        AVG(revenue) FILTER (WHERE NOT is_promo_window)   AS normal_day_avg,
        COUNT(*)     FILTER (WHERE is_promo_window)       AS promo_days
    FROM daily
    GROUP BY year_month
    HAVING COUNT(*) FILTER (WHERE is_promo_window) > 0
)
SELECT
    ROUND(AVG(promo_day_avg), 0)                              AS avg_promo_day_revenue,
    ROUND(AVG(normal_day_avg), 0)                             AS avg_normal_day_revenue,
    ROUND(100.0 * (AVG(promo_day_avg) - AVG(normal_day_avg))
          / AVG(normal_day_avg), 1)                           AS uplift_pct,
    SUM(promo_days)                                           AS total_promo_days,
    ROUND(SUM(promo_days * (promo_day_avg - normal_day_avg)), 0)
                                                              AS incremental_revenue
FROM by_month;


\echo '\n=== 1.8 Rolling 28-day revenue trend (last 120 days) ==='

-- A 28-day window rather than 30 keeps a whole number of weeks in every frame,
-- so the series is not distorted by how many weekends a window happens to
-- contain.
WITH daily AS (
    SELECT d.full_date, SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date d ON d.date_key = f.date_key
    GROUP BY d.full_date
),
rolled AS (
    SELECT
        full_date,
        revenue,
        AVG(revenue) OVER (ORDER BY full_date
                           ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS ma_28,
        SUM(revenue) OVER (PARTITION BY DATE_TRUNC('year', full_date)
                           ORDER BY full_date)                        AS ytd_revenue
    FROM daily
)
SELECT
    full_date,
    ROUND(revenue, 0)   AS revenue,
    ROUND(ma_28, 0)     AS revenue_28d_ma,
    ROUND(ytd_revenue, 0) AS ytd_revenue
FROM rolled
WHERE full_date > (SELECT MAX(full_date) FROM daily) - 120
ORDER BY full_date;
