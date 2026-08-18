-- ===========================================================================
-- 03_fact_sales.sql
--
-- Loads the fact table from staging, resolving every natural key to its
-- surrogate key.
--
-- The joins are deliberately LEFT JOIN + COALESCE(key, -1) rather than INNER
-- JOIN. An inner join here would silently drop any row whose dimension lookup
-- failed, and the row counts would still reconcile against staging only if you
-- never checked - which is precisely the class of bug the assertion layer in
-- 05_quality_assertions.sql exists to catch. Routing misses to the Unknown
-- member keeps the row, keeps the revenue, and makes the failure visible.
-- ===========================================================================

TRUNCATE marts.fact_sales;

INSERT INTO marts.fact_sales (
    sale_id, invoice_id, line_no, sale_date, date_key, sale_time, sale_hour,
    branch_key, product_key, customer_key, payment_key,
    customer_type, gender, quantity, unit_price,
    gross_sales, tax_amount, total_amount, cogs, gross_profit, rating
)
SELECT
    ROW_NUMBER() OVER (ORDER BY s.sale_date, s.sale_time, s.invoice_id, s.line_no) AS sale_id,
    s.invoice_id,
    s.line_no,
    s.sale_date,
    TO_CHAR(s.sale_date, 'YYYYMMDD')::INTEGER AS date_key,
    s.sale_time,
    s.sale_hour,
    COALESCE(b.branch_key,   -1) AS branch_key,
    COALESCE(p.product_key,  -1) AS product_key,
    COALESCE(c.customer_key, -1) AS customer_key,
    COALESCE(pm.payment_key, -1) AS payment_key,
    s.customer_type,
    s.gender,
    s.quantity,
    s.unit_price,
    s.gross_sales,
    s.tax_amount,
    s.total_amount,
    s.cogs,
    s.gross_profit,
    s.rating
FROM staging.stg_sales s
LEFT JOIN marts.dim_branch   b  ON b.branch_code    = s.branch_code
LEFT JOIN marts.dim_product  p  ON p.sku            = s.product_sku
LEFT JOIN marts.dim_customer c  ON c.customer_id    = s.customer_id
LEFT JOIN marts.dim_payment  pm ON pm.payment_method = s.payment_method;


-- The default partition must stay empty. Anything in it means a sale_date fell
-- outside every declared monthly range, which is a load bug, not a data issue.
DO $$
DECLARE n BIGINT;
BEGIN
    SELECT COUNT(*) INTO n FROM marts.fact_sales_default;
    IF n > 0 THEN
        RAISE EXCEPTION
            'fact_sales_default holds % rows - sale_date outside declared partitions', n;
    END IF;
END $$;


INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'load', 'marts.fact_sales', COUNT(*),
       'invoice-line grain, surrogate keys resolved'
FROM marts.fact_sales;

ANALYZE marts.fact_sales;
