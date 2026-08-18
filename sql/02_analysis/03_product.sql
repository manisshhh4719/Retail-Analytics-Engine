-- ===========================================================================
-- 03_product.sql  -  Category, assortment and basket analysis
--
-- Revenue alone is a poor way to rank an assortment: the highest-selling line
-- here is also close to the lowest-margin one. Every ranking in this file
-- therefore carries profit alongside revenue.
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/03_product.sql
-- ===========================================================================

\echo '\n=== 3.1 Product line performance ==='

SELECT
    p.product_line,
    COUNT(*)                                                      AS line_items,
    SUM(f.quantity)                                               AS units_sold,
    ROUND(SUM(f.total_amount), 0)                                 AS revenue,
    ROUND(100.0 * SUM(f.total_amount)
          / SUM(SUM(f.total_amount)) OVER (), 1)                  AS pct_revenue,
    ROUND(SUM(f.gross_profit), 0)                                 AS gross_profit,
    ROUND(100.0 * SUM(f.gross_profit)
          / SUM(SUM(f.gross_profit)) OVER (), 1)                  AS pct_profit,
    ROUND(100.0 * SUM(f.gross_profit) / SUM(f.gross_sales), 1)    AS margin_pct,
    ROUND(AVG(f.rating), 2)                                       AS avg_rating,
    -- Revenue rank vs profit rank. A line that ranks well on one and badly on
    -- the other is where the assortment decision actually lives.
    RANK() OVER (ORDER BY SUM(f.total_amount) DESC)               AS revenue_rank,
    RANK() OVER (ORDER BY SUM(f.gross_profit) DESC)               AS profit_rank
FROM marts.fact_sales f
JOIN marts.dim_product p ON p.product_key = f.product_key
GROUP BY p.product_line
ORDER BY revenue DESC;


\echo '\n=== 3.2 ABC classification of SKUs (Pareto) ==='

-- Standard inventory ABC: A = SKUs making the first 80% of revenue, B = next
-- 15%, C = the tail. The cumulative share is taken on the running total
-- *including* the current row, so a SKU is graded by where it ends, not where
-- it starts - the off-by-one here is what makes ABC cutoffs disagree between
-- two analysts looking at the same data.
WITH sku_perf AS (
    SELECT
        p.sku,
        p.product_name,
        p.product_line,
        SUM(f.total_amount) AS revenue,
        SUM(f.gross_profit) AS profit,
        SUM(f.quantity)     AS units
    FROM marts.fact_sales f
    JOIN marts.dim_product p ON p.product_key = f.product_key
    GROUP BY p.sku, p.product_name, p.product_line
),
cumulative AS (
    SELECT
        s.*,
        SUM(revenue) OVER (ORDER BY revenue DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(revenue) OVER () AS cum_share,
        ROW_NUMBER() OVER (ORDER BY revenue DESC) AS revenue_rank
    FROM sku_perf s
)
SELECT
    revenue_rank,
    sku,
    product_name,
    product_line,
    ROUND(revenue, 0)               AS revenue,
    ROUND(profit, 0)                AS profit,
    units,
    ROUND(100.0 * cum_share, 1)     AS cumulative_pct,
    CASE
        WHEN cum_share <= 0.80 THEN 'A'
        WHEN cum_share <= 0.95 THEN 'B'
        ELSE 'C'
    END                             AS abc_class
FROM cumulative
ORDER BY revenue_rank;


\echo '\n=== 3.3 ABC class summary ==='

WITH sku_perf AS (
    SELECT p.sku, SUM(f.total_amount) AS revenue, SUM(f.gross_profit) AS profit
    FROM marts.fact_sales f
    JOIN marts.dim_product p ON p.product_key = f.product_key
    GROUP BY p.sku
),
classified AS (
    SELECT
        sku, revenue, profit,
        CASE
            WHEN SUM(revenue) OVER (ORDER BY revenue DESC
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                 / SUM(revenue) OVER () <= 0.80 THEN 'A'
            WHEN SUM(revenue) OVER (ORDER BY revenue DESC
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                 / SUM(revenue) OVER () <= 0.95 THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM sku_perf
)
SELECT
    abc_class,
    COUNT(*)                                                        AS skus,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)              AS pct_of_skus,
    ROUND(SUM(revenue), 0)                                          AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)      AS pct_of_revenue,
    ROUND(SUM(profit), 0)                                           AS profit,
    ROUND(100.0 * SUM(profit) / SUM(SUM(profit)) OVER (), 1)        AS pct_of_profit
FROM classified
GROUP BY abc_class
ORDER BY abc_class;


\echo '\n=== 3.4 Category mix shift over time ==='

-- Share of revenue by line and year, with the change in share since the first
-- year. Share shift, not absolute growth: in a business growing 20% a year
-- every category grows, and only the share tells you which are winning.
WITH yearly AS (
    SELECT
        d.year_number AS yr,
        p.product_line,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN marts.dim_date    d ON d.date_key    = f.date_key
    JOIN marts.dim_product p ON p.product_key = f.product_key
    GROUP BY d.year_number, p.product_line
),
shares AS (
    SELECT
        yr, product_line, revenue,
        100.0 * revenue / SUM(revenue) OVER (PARTITION BY yr) AS share_pct
    FROM yearly
)
SELECT
    product_line,
    ROUND(MAX(share_pct) FILTER (WHERE yr = 2019), 1) AS share_2019,
    ROUND(MAX(share_pct) FILTER (WHERE yr = 2021), 1) AS share_2021,
    ROUND(MAX(share_pct) FILTER (WHERE yr = 2024), 1) AS share_2024,
    ROUND(MAX(share_pct) FILTER (WHERE yr = 2024)
        - MAX(share_pct) FILTER (WHERE yr = 2019), 1) AS share_change_pts,
    ROUND(100.0 * (MAX(revenue) FILTER (WHERE yr = 2024)
                 / MAX(revenue) FILTER (WHERE yr = 2019) - 1), 1) AS revenue_growth_pct
FROM shares
GROUP BY product_line
ORDER BY share_change_pts DESC;


\echo '\n=== 3.5 Market basket: top product affinities ==='

-- Self-join on invoice_id with a < b to count each unordered pair once.
-- DISTINCT inside the basket CTE guards against the same SKU appearing on two
-- lines of one invoice, which would otherwise inflate its own pair counts.
--
--   support    P(A and B)          - how common the combination is
--   confidence P(B | A)            - how often B follows A
--   lift       P(A,B)/(P(A)*P(B))  - >1 means genuinely associated, not just
--                                    two individually popular products
WITH baskets AS (
    SELECT DISTINCT invoice_id, product_key
    FROM marts.fact_sales
),
basket_total AS (
    SELECT COUNT(DISTINCT invoice_id)::NUMERIC AS n FROM marts.fact_sales
),
item_freq AS (
    SELECT product_key, COUNT(*)::NUMERIC AS cnt
    FROM baskets GROUP BY product_key
),
pairs AS (
    SELECT
        a.product_key AS key_a,
        b.product_key AS key_b,
        COUNT(*)::NUMERIC AS pair_count
    FROM baskets a
    JOIN baskets b
      ON a.invoice_id = b.invoice_id
     AND a.product_key < b.product_key
    GROUP BY a.product_key, b.product_key
    HAVING COUNT(*) >= 200            -- drop noise-level combinations
)
SELECT
    pa.product_name || ' (' || pa.product_line || ')' AS product_a,
    pb.product_name || ' (' || pb.product_line || ')' AS product_b,
    p.pair_count::INT                                  AS baskets_together,
    ROUND(100.0 * p.pair_count / bt.n, 3)              AS support_pct,
    ROUND(100.0 * p.pair_count / ia.cnt, 1)            AS confidence_a_to_b_pct,
    ROUND(100.0 * p.pair_count / ib.cnt, 1)            AS confidence_b_to_a_pct,
    ROUND((p.pair_count / bt.n)
          / ((ia.cnt / bt.n) * (ib.cnt / bt.n)), 2)    AS lift,
    CASE WHEN pa.product_line <> pb.product_line
         THEN 'cross-category' ELSE 'within-category' END AS pair_type
FROM pairs p
CROSS JOIN basket_total bt
JOIN item_freq ia ON ia.product_key = p.key_a
JOIN item_freq ib ON ib.product_key = p.key_b
JOIN marts.dim_product pa ON pa.product_key = p.key_a
JOIN marts.dim_product pb ON pb.product_key = p.key_b
ORDER BY lift DESC
LIMIT 20;


\echo '\n=== 3.6 Cross-category affinity summary ==='

WITH baskets AS (
    SELECT DISTINCT invoice_id, product_key FROM marts.fact_sales
),
pairs AS (
    SELECT a.product_key AS key_a, b.product_key AS key_b, COUNT(*) AS pair_count
    FROM baskets a
    JOIN baskets b ON a.invoice_id = b.invoice_id AND a.product_key < b.product_key
    GROUP BY a.product_key, b.product_key
)
SELECT
    LEAST(pa.product_line, pb.product_line)    AS line_a,
    GREATEST(pa.product_line, pb.product_line) AS line_b,
    SUM(p.pair_count)                          AS baskets_together
FROM pairs p
JOIN marts.dim_product pa ON pa.product_key = p.key_a
JOIN marts.dim_product pb ON pb.product_key = p.key_b
WHERE pa.product_line <> pb.product_line
GROUP BY 1, 2
ORDER BY baskets_together DESC
LIMIT 10;


\echo '\n=== 3.7 Basket size and its effect on value ==='

WITH basket AS (
    SELECT
        invoice_id,
        COUNT(*)          AS lines_in_basket,
        SUM(total_amount) AS basket_value,
        SUM(gross_profit) AS basket_profit
    FROM marts.fact_sales
    GROUP BY invoice_id
)
SELECT
    lines_in_basket,
    COUNT(*)                                                     AS invoices,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_of_invoices,
    ROUND(AVG(basket_value), 2)                                  AS avg_basket_value,
    ROUND(AVG(basket_profit), 2)                                 AS avg_basket_profit,
    ROUND(SUM(basket_value), 0)                                  AS total_revenue,
    ROUND(100.0 * SUM(basket_value) / SUM(SUM(basket_value)) OVER (), 1) AS pct_of_revenue
FROM basket
GROUP BY lines_in_basket
ORDER BY lines_in_basket;


\echo '\n=== 3.8 Price band performance ==='

SELECT
    p.price_band,
    COUNT(DISTINCT p.sku)                                       AS skus,
    SUM(f.quantity)                                             AS units,
    ROUND(SUM(f.total_amount), 0)                               AS revenue,
    ROUND(SUM(f.gross_profit), 0)                               AS profit,
    ROUND(100.0 * SUM(f.gross_profit) / SUM(f.gross_sales), 1)  AS margin_pct,
    ROUND(AVG(f.unit_price), 2)                                 AS avg_unit_price,
    ROUND(AVG(f.rating), 2)                                     AS avg_rating
FROM marts.fact_sales f
JOIN marts.dim_product p ON p.product_key = f.product_key
WHERE p.price_band <> 'Unknown'
GROUP BY p.price_band
ORDER BY revenue DESC;


\echo '\n=== 3.9 Product line performance by customer segment ==='

-- Which categories the most valuable customers actually buy. Champions
-- over-indexing on a category is a merchandising signal; a category bought
-- almost entirely by Lost customers is not one to expand.
WITH seg_sales AS (
    SELECT
        r.rfm_segment,
        p.product_line,
        SUM(f.total_amount) AS revenue
    FROM marts.fact_sales f
    JOIN staging.customer_rfm r ON r.customer_key = f.customer_key
    JOIN marts.dim_product    p ON p.product_key  = f.product_key
    WHERE f.customer_key <> -1
      AND r.rfm_segment IN ('Champions', 'Loyal', 'At Risk')
    GROUP BY r.rfm_segment, p.product_line
)
SELECT
    product_line,
    ROUND(MAX(revenue) FILTER (WHERE rfm_segment = 'Champions'), 0) AS champions_rev,
    ROUND(MAX(revenue) FILTER (WHERE rfm_segment = 'Loyal'), 0)     AS loyal_rev,
    ROUND(MAX(revenue) FILTER (WHERE rfm_segment = 'At Risk'), 0)   AS at_risk_rev,
    -- Index >100 means Champions buy relatively more of this line than the
    -- three segments do on average.
    ROUND(100.0
          * (MAX(revenue) FILTER (WHERE rfm_segment = 'Champions')
             / SUM(MAX(revenue) FILTER (WHERE rfm_segment = 'Champions')) OVER ())
          / (SUM(revenue) / SUM(SUM(revenue)) OVER ()), 0)          AS champion_index
FROM seg_sales
GROUP BY product_line
ORDER BY champion_index DESC;
