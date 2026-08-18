-- ===========================================================================
-- 02_dimensions.sql
--
-- Populates every dimension. Each one gets a -1 "Unknown" member first, so the
-- fact table can hold NOT NULL foreign keys and inner joins never silently
-- discard rows whose dimension lookup failed.
--
-- dim_customer is loaded here with its static attributes only; the behavioural
-- columns (first/last purchase, cohort month) are backfilled in
-- 04_customer_enrich.sql once the fact table exists.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- dim_date - generated, not loaded
--
-- Spans 2018-2026 rather than just the data range so Power BI time
-- intelligence has full years either side and SAMEPERIODLASTYEAR resolves
-- cleanly at the boundaries.
-- ---------------------------------------------------------------------------

INSERT INTO marts.dim_date
WITH days AS (
    SELECT generate_series(DATE '2018-01-01', DATE '2026-12-31', '1 day')::DATE AS d
),
promo AS (
    -- Recurring campaign windows, matching the events built into the data.
    SELECT * FROM (VALUES
        (11, 24, 4),   -- Black Friday weekend
        (12, 26, 6),   -- Boxing-week clearance
        (1,   2, 5),   -- New-year clearance
        (4,  13, 5),   -- Thingyan festival
        (7,   7, 3)    -- Mid-year sale
    ) AS t(m, dd, span)
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER              AS date_key,
    d                                            AS full_date,
    EXTRACT(DAY FROM d)::SMALLINT                AS day_of_month,
    EXTRACT(ISODOW FROM d)::SMALLINT             AS day_of_week,
    TRIM(TO_CHAR(d, 'Day'))                      AS day_name,
    TRIM(TO_CHAR(d, 'Dy'))                       AS day_abbr,
    EXTRACT(ISODOW FROM d) >= 6                  AS is_weekend,
    EXTRACT(WEEK FROM d)::SMALLINT               AS week_of_year,
    TO_CHAR(d, 'IYYY-"W"IW')                     AS iso_year_week,
    EXTRACT(MONTH FROM d)::SMALLINT              AS month_number,
    TRIM(TO_CHAR(d, 'Month'))                    AS month_name,
    TRIM(TO_CHAR(d, 'Mon'))                      AS month_abbr,
    TO_CHAR(d, 'YYYY-MM')                        AS year_month,
    DATE_TRUNC('month', d)::DATE                 AS month_start_date,
    (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE AS month_end_date,
    EXTRACT(QUARTER FROM d)::SMALLINT            AS quarter_number,
    TO_CHAR(d, 'YYYY-"Q"Q')                      AS quarter_name,
    EXTRACT(YEAR FROM d)::SMALLINT               AS year_number,
    EXTRACT(DOY FROM d)::SMALLINT                AS day_of_year,
    EXTRACT(MONTH FROM d) IN (11, 12)            AS is_holiday_season,
    EXISTS (
        SELECT 1 FROM promo p
        WHERE d >= MAKE_DATE(EXTRACT(YEAR FROM d)::INT, p.m, p.dd)
          AND d <  MAKE_DATE(EXTRACT(YEAR FROM d)::INT, p.m, p.dd) + p.span
    )                                            AS is_promo_window
FROM days;


-- ---------------------------------------------------------------------------
-- dim_branch
-- ---------------------------------------------------------------------------

INSERT INTO marts.dim_branch
    (branch_key, branch_code, branch_name, city, region,
     opened_date, size_factor, size_band, is_active)
VALUES (-1, 'UNK', 'Unknown Branch', 'Unknown', 'Unknown', NULL, NULL, 'Unknown', FALSE);

INSERT INTO marts.dim_branch
    (branch_key, branch_code, branch_name, city, region,
     opened_date, size_factor, size_band, is_active)
SELECT
    ROW_NUMBER() OVER (ORDER BY branch_code)::INTEGER,
    UPPER(TRIM(branch_code)),
    'Branch ' || UPPER(TRIM(branch_code)) || ' - ' || INITCAP(TRIM(city)),
    INITCAP(TRIM(city)),
    INITCAP(TRIM(region)),
    opened_date::DATE,
    size_factor::NUMERIC(4,2),
    CASE
        WHEN size_factor::NUMERIC < 0.85 THEN 'Small'
        WHEN size_factor::NUMERIC < 1.05 THEN 'Medium'
        ELSE 'Large'
    END,
    TRUE
FROM raw.branches_landing;


-- ---------------------------------------------------------------------------
-- dim_product
--
-- Price bands come from tertiles of the catalogue rather than hard-coded
-- thresholds, so they stay meaningful if the catalogue changes.
-- ---------------------------------------------------------------------------

INSERT INTO marts.dim_product
    (product_key, sku, product_name, product_line, base_price, margin_pct, price_band)
VALUES (-1, 'UNKNOWN', 'Unknown Product', 'Unknown', NULL, NULL, 'Unknown');

INSERT INTO marts.dim_product
    (product_key, sku, product_name, product_line, base_price, margin_pct, price_band)
SELECT
    ROW_NUMBER() OVER (ORDER BY sku)::INTEGER,
    UPPER(TRIM(sku)),
    TRIM(product_name),
    TRIM(product_line),
    base_price::NUMERIC(10,2),
    margin_pct::NUMERIC(6,4),
    CASE NTILE(3) OVER (ORDER BY base_price::NUMERIC)
        WHEN 1 THEN 'Budget'
        WHEN 2 THEN 'Mid'
        ELSE        'Premium'
    END
FROM raw.products_landing;


-- ---------------------------------------------------------------------------
-- dim_payment
-- ---------------------------------------------------------------------------

INSERT INTO marts.dim_payment (payment_key, payment_method, payment_group)
VALUES (-1, 'Unknown', 'Unknown');

INSERT INTO marts.dim_payment (payment_key, payment_method, payment_group)
SELECT
    ROW_NUMBER() OVER (ORDER BY payment_method)::INTEGER,
    payment_method,
    CASE payment_method
        WHEN 'Cash'        THEN 'Cash'
        WHEN 'Credit card' THEN 'Card'
        WHEN 'Ewallet'     THEN 'Digital'
        ELSE 'Other'
    END
FROM (SELECT DISTINCT payment_method FROM staging.stg_sales) p;


-- ---------------------------------------------------------------------------
-- dim_customer
--
-- The Unknown member (-1) carries every anonymous walk-in transaction. Roughly
-- half of all invoices land here, which is exactly why customer analysis has
-- to be scoped to customer_key <> -1 rather than assuming full coverage.
-- ---------------------------------------------------------------------------

INSERT INTO marts.dim_customer
    (customer_key, customer_id, gender, signup_date,
     home_branch_code, home_city, is_member)
VALUES (-1, 'ANONYMOUS', NULL, NULL, NULL, NULL, FALSE);

INSERT INTO marts.dim_customer
    (customer_key, customer_id, gender, signup_date,
     home_branch_code, home_city, is_member)
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_id)::INTEGER,
    TRIM(customer_id),
    INITCAP(TRIM(gender)),
    signup_date::DATE,
    UPPER(TRIM(home_branch)),
    INITCAP(TRIM(home_city)),
    TRUE
FROM raw.customers_landing;


INSERT INTO staging.load_audit (step_name, table_name, row_count)
SELECT 'dimensions', 'marts.dim_date',     COUNT(*) FROM marts.dim_date
UNION ALL
SELECT 'dimensions', 'marts.dim_branch',   COUNT(*) FROM marts.dim_branch
UNION ALL
SELECT 'dimensions', 'marts.dim_product',  COUNT(*) FROM marts.dim_product
UNION ALL
SELECT 'dimensions', 'marts.dim_customer', COUNT(*) FROM marts.dim_customer
UNION ALL
SELECT 'dimensions', 'marts.dim_payment',  COUNT(*) FROM marts.dim_payment;
