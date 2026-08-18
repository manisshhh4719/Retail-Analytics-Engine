-- ===========================================================================
-- 05_quality_assertions.sql  -  Data quality test suite
--
-- Every assertion returns one row: a name, a PASS/FAIL verdict and the actual
-- value that decided it. The final query fails loudly (RAISE EXCEPTION) if any
-- assertion failed, so this file can be wired into a scheduler or CI job and
-- will stop a bad load from being published rather than merely describing it.
--
-- The categories mirror where warehouse bugs actually come from:
--   reconciliation - did every row survive each hop
--   integrity      - do the keys and grain hold
--   validity       - are the values inside their declared domains
--   consistency    - do derived measures agree with their components
--   freshness      - is the data complete across the reporting window
--
-- Run:  psql -d walmart_dw -f sql/02_analysis/05_quality_assertions.sql
-- ===========================================================================

DROP TABLE IF EXISTS staging.dq_results;
CREATE TABLE staging.dq_results (
    check_id      INT,
    category      TEXT,
    check_name    TEXT,
    status        TEXT,
    actual_value  TEXT,
    expected      TEXT,
    checked_at    TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Reconciliation
-- ---------------------------------------------------------------------------

-- 1. raw = clean + rejected. If this drifts, rows are vanishing silently.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 1, 'reconciliation', 'raw rows = staged + rejected',
       CASE WHEN r.n = s.n + j.n THEN 'PASS' ELSE 'FAIL' END,
       FORMAT('raw=%s staged=%s rejected=%s diff=%s', r.n, s.n, j.n, r.n - s.n - j.n),
       'diff = 0'
FROM (SELECT COUNT(*) n FROM raw.sales_landing) r,
     (SELECT COUNT(*) n FROM staging.stg_sales) s,
     (SELECT COUNT(*) n FROM staging.stg_sales_rejects) j;

-- 2. staging = fact. The load must not drop or duplicate rows.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 2, 'reconciliation', 'staged rows = fact rows',
       CASE WHEN s.n = f.n THEN 'PASS' ELSE 'FAIL' END,
       FORMAT('staged=%s fact=%s', s.n, f.n), 'equal'
FROM (SELECT COUNT(*) n FROM staging.stg_sales) s,
     (SELECT COUNT(*) n FROM marts.fact_sales) f;

-- 3. Revenue ties between staging and the mart to the cent.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 3, 'reconciliation', 'revenue ties staging to mart',
       CASE WHEN ABS(s.v - f.v) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
       FORMAT('staging=%s mart=%s diff=%s',
              ROUND(s.v, 2), ROUND(f.v, 2), ROUND(ABS(s.v - f.v), 4)),
       'difference < 0.01'
FROM (SELECT SUM(total_amount) v FROM staging.stg_sales) s,
     (SELECT SUM(total_amount) v FROM marts.fact_sales) f;

-- ---------------------------------------------------------------------------
-- Integrity
-- ---------------------------------------------------------------------------

-- 4. Declared grain holds: one row per invoice line, no duplicates.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 4, 'integrity', 'fact grain is unique (invoice_id, line_no)',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 duplicate keys'
FROM (
    SELECT COUNT(*) n FROM (
        SELECT invoice_id, line_no
        FROM marts.fact_sales
        GROUP BY invoice_id, line_no
        HAVING COUNT(*) > 1
    ) d
) x;

-- 5. No orphaned dimension keys. FKs enforce this, so a failure here means
--    the constraint was dropped rather than that the data is bad.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 5, 'integrity', 'no orphaned foreign keys',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 orphans'
FROM (
    SELECT COUNT(*) n
    FROM marts.fact_sales f
    LEFT JOIN marts.dim_date     d  ON d.date_key     = f.date_key
    LEFT JOIN marts.dim_branch   b  ON b.branch_key   = f.branch_key
    LEFT JOIN marts.dim_product  p  ON p.product_key  = f.product_key
    LEFT JOIN marts.dim_customer c  ON c.customer_key = f.customer_key
    LEFT JOIN marts.dim_payment  pm ON pm.payment_key = f.payment_key
    WHERE d.date_key IS NULL OR b.branch_key IS NULL OR p.product_key IS NULL
       OR c.customer_key IS NULL OR pm.payment_key IS NULL
) x;

-- 6. Unresolved keys routed to the Unknown member. Nonzero is not corrupt, but
--    it means a natural key failed to match and the mapping needs review.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 6, 'integrity', 'no rows fell back to Unknown dimension members',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 rows'
FROM (
    SELECT COUNT(*) n FROM marts.fact_sales
    WHERE branch_key = -1 OR product_key = -1 OR payment_key = -1
) x;

-- 7. Default partition empty - a row here means a date outside every range.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 7, 'integrity', 'default partition is empty',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 rows'
FROM (SELECT COUNT(*) n FROM marts.fact_sales_default) x;

-- ---------------------------------------------------------------------------
-- Validity
-- ---------------------------------------------------------------------------

-- 8. Quantities strictly positive.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 8, 'validity', 'quantity > 0 on every row',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 violations'
FROM (SELECT COUNT(*) n FROM marts.fact_sales WHERE quantity <= 0) x;

-- 9. Ratings inside the declared 1-10 domain (NULL is allowed: not every
--    transaction is rated, and that absence is meaningful).
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 9, 'validity', 'rating within 1-10 or NULL',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 violations'
FROM (
    SELECT COUNT(*) n FROM marts.fact_sales
    WHERE rating IS NOT NULL AND (rating < 1 OR rating > 10)
) x;

-- 10. Every sale falls inside the declared reporting window.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 10, 'validity', 'sale_date within 2019-2024 window',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 out of range'
FROM (
    SELECT COUNT(*) n FROM marts.fact_sales
    WHERE sale_date < DATE '2019-01-01' OR sale_date > DATE '2024-12-31'
) x;

-- 11. City values conformed to a controlled vocabulary - this is the check
--     that catches the " YANGON " / "yangon" casing defects returning.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 11, 'validity', 'city values conformed (no casing/whitespace variants)',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 variants'
FROM (
    SELECT COUNT(*) n FROM marts.dim_branch
    WHERE city <> INITCAP(TRIM(city))
) x;

-- 12. Payment methods restricted to the known set.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 12, 'validity', 'payment methods in controlled vocabulary',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END,
       COALESCE(v, 'none'), 'only Cash/Credit card/Ewallet'
FROM (
    SELECT COUNT(*) n, STRING_AGG(payment_method, ', ') v
    FROM marts.dim_payment
    WHERE payment_method NOT IN ('Cash', 'Credit card', 'Ewallet', 'Unknown')
) x;

-- ---------------------------------------------------------------------------
-- Consistency
-- ---------------------------------------------------------------------------

-- 13. gross_sales must equal unit_price * quantity. A tolerance of 0.01 per
--     row absorbs rounding; anything larger is a calculation bug.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 13, 'consistency', 'gross_sales = unit_price * quantity',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 mismatches'
FROM (
    SELECT COUNT(*) n FROM marts.fact_sales
    WHERE ABS(gross_sales - unit_price * quantity) > 0.01
) x;

-- 14. total = gross_sales + tax, and profit = gross_sales - cogs.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 14, 'consistency', 'total = gross + tax and profit = gross - cogs',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT, '0 mismatches'
FROM (
    SELECT COUNT(*) n FROM marts.fact_sales
    WHERE ABS(total_amount - (gross_sales + tax_amount)) > 0.01
       OR ABS(gross_profit - (gross_sales - cogs)) > 0.01
) x;

-- 15. Gross margin must land in a plausible retail band. This is the check
--     that would have caught the source sample's flat 4.76% margin.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 15, 'consistency', 'blended gross margin within 5-60%',
       CASE WHEN m BETWEEN 5 AND 60 THEN 'PASS' ELSE 'FAIL' END,
       ROUND(m, 2)::TEXT || '%', 'between 5% and 60%'
FROM (
    SELECT 100.0 * SUM(gross_profit) / SUM(gross_sales) m FROM marts.fact_sales
) x;

-- ---------------------------------------------------------------------------
-- Completeness / freshness
-- ---------------------------------------------------------------------------

-- 16. No missing trading days across the window. A gap almost always means a
--     partial load rather than a genuinely closed estate.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 16, 'completeness', 'no missing trading days in the window',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT || ' missing days', '0 gaps'
FROM (
    SELECT COUNT(*) n
    FROM generate_series(DATE '2019-01-01', DATE '2024-12-31', '1 day') g(d)
    LEFT JOIN (SELECT DISTINCT sale_date FROM marts.fact_sales) f ON f.sale_date = g.d
    WHERE f.sale_date IS NULL
) x;

-- 17. Every branch trades in every month after it opens.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 17, 'completeness', 'every open branch trades every month',
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END, n::TEXT || ' branch-months', '0 gaps'
FROM (
    SELECT COUNT(*) n
    FROM marts.dim_branch b
    CROSS JOIN generate_series(DATE '2019-01-01', DATE '2024-12-01', '1 month') m(mth)
    LEFT JOIN (
        SELECT branch_key, DATE_TRUNC('month', sale_date)::DATE AS mth
        FROM marts.fact_sales GROUP BY 1, 2
    ) f ON f.branch_key = b.branch_key AND f.mth = m.mth::DATE
    WHERE b.branch_key <> -1
      AND b.opened_date <= m.mth
      AND f.branch_key IS NULL
) x;

-- 18. Rating nulls stay within a tolerable share. Rising null rates are the
--     usual early symptom of an upstream capture failure.
INSERT INTO staging.dq_results (check_id, category, check_name, status, actual_value, expected)
SELECT 18, 'completeness', 'rating null rate below 2%',
       CASE WHEN p < 2.0 THEN 'PASS' ELSE 'FAIL' END,
       ROUND(p, 2)::TEXT || '%', '< 2%'
FROM (
    SELECT 100.0 * COUNT(*) FILTER (WHERE rating IS NULL) / COUNT(*) p
    FROM marts.fact_sales
) x;


-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

\echo '\n=== Data quality assertion results ==='

SELECT check_id, category, check_name, status, actual_value, expected
FROM staging.dq_results
ORDER BY check_id;

\echo '\n=== Summary by category ==='

SELECT
    category,
    COUNT(*)                                    AS checks,
    COUNT(*) FILTER (WHERE status = 'PASS')     AS passed,
    COUNT(*) FILTER (WHERE status = 'FAIL')     AS failed
FROM staging.dq_results
GROUP BY category
ORDER BY category;

\echo '\n=== Rejected rows by reason (from the load) ==='

SELECT
    reject_reason,
    COUNT(*)                                                    AS rows_rejected,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_rejects,
    ROUND(100.0 * COUNT(*)
          / (SELECT COUNT(*) FROM raw.sales_landing), 2)        AS pct_of_source
FROM staging.stg_sales_rejects
GROUP BY reject_reason
ORDER BY rows_rejected DESC;


-- Fail the run if anything failed, so this can gate a pipeline.
DO $$
DECLARE n INT;
BEGIN
    SELECT COUNT(*) INTO n FROM staging.dq_results WHERE status = 'FAIL';
    IF n > 0 THEN
        RAISE EXCEPTION 'DATA QUALITY GATE FAILED: % assertion(s) failed', n;
    ELSE
        RAISE NOTICE 'DATA QUALITY GATE PASSED: all % assertions passed',
            (SELECT COUNT(*) FROM staging.dq_results);
    END IF;
END $$;
