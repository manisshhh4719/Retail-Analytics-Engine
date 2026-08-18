-- ===========================================================================
-- 04_customer_enrich.sql
--
-- Backfills the behavioural columns on dim_customer from the loaded fact.
--
-- cohort_month is anchored on the customer's FIRST OBSERVED PURCHASE, not on
-- their signup date. Those are not the same thing: the source file contains
-- sign-ups that never transacted, and a retention curve built on signup date
-- would show an artificial month-0 population that never bought anything. The
-- cohort has to be defined by the behaviour being measured.
-- ===========================================================================

WITH activity AS (
    SELECT
        customer_key,
        MIN(sale_date) AS first_purchase_date,
        MAX(sale_date) AS last_purchase_date
    FROM marts.fact_sales
    WHERE customer_key <> -1
    GROUP BY customer_key
)
UPDATE marts.dim_customer c
SET first_purchase_date = a.first_purchase_date,
    last_purchase_date  = a.last_purchase_date,
    cohort_month        = DATE_TRUNC('month', a.first_purchase_date)::DATE
FROM activity a
WHERE c.customer_key = a.customer_key;


-- Members who signed up but never transacted stay in the dimension with NULL
-- behavioural columns. They are a genuine finding - see the never-activated
-- segment in 02_customer.sql - so they are not deleted.

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'enrich', 'marts.dim_customer', COUNT(*),
       'customers with at least one purchase'
FROM marts.dim_customer
WHERE first_purchase_date IS NOT NULL;

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'enrich', 'marts.dim_customer.never_activated', COUNT(*),
       'signed up, never transacted'
FROM marts.dim_customer
WHERE is_member AND first_purchase_date IS NULL;

ANALYZE marts.dim_customer;
