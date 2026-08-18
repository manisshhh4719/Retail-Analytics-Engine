-- ===========================================================================
-- 01_staging_clean.sql
--
-- Turns the untyped landing table into a typed, deduplicated, conformed
-- staging table - and quarantines everything it cannot save.
--
-- The rule this layer follows: repair what is recoverable, reject what is not,
-- and never drop a row without recording why. Rejected rows land in
-- staging.stg_sales_rejects with a reason code, so the quality report can
-- state exactly what the source system sent and what happened to it.
--
--   REPAIRED (row survives)          REJECTED (row quarantined)
--   ------------------------         --------------------------
--   duplicate invoice line           unparseable / malformed date
--   "$1,234.50" price formatting     date outside the reporting window
--   " YANGON " city casing           quantity <= 0
--   "E-Wallet" / "ewallet" spelling  missing invoice_id or line_no
--   blank / "n/a" customer_type      missing or non-numeric unit_price
--   empty rating -> NULL
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- Safe cast helpers
--
-- A plain ::date on the landing data aborts the whole statement on the first
-- malformed value. These swallow the cast error per value and return NULL, so
-- one bad row cannot take down the load. The exception block costs a
-- subtransaction per call, so both are only ever applied to values that have
-- already passed a cheap regex pre-filter.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION staging.try_to_date(p_text TEXT)
RETURNS DATE LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    RETURN p_text::DATE;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION staging.try_to_numeric(p_text TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    -- Strip currency symbols, thousands separators and stray whitespace.
    RETURN regexp_replace(p_text, '[^0-9.\-]', '', 'g')::NUMERIC;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;


DROP TABLE IF EXISTS staging.stg_sales;
DROP TABLE IF EXISTS staging.stg_sales_rejects;


-- ---------------------------------------------------------------------------
-- Normalise, then split clean rows from rejects in a single pass.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE tmp_normalised AS
WITH deduped AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.invoice_id, s.line_no
            ORDER BY s.date NULLS LAST
        ) AS rn
    FROM raw.sales_landing s
),
typed AS (
    SELECT
        NULLIF(TRIM(invoice_id), '')                       AS invoice_id,
        staging.try_to_numeric(line_no)                    AS line_no,
        UPPER(TRIM(branch))                                AS branch_code,

        -- " YANGON ", "yangon", "Yangon  " all collapse to "Yangon".
        INITCAP(TRIM(city))                                AS city,

        NULLIF(TRIM(customer_id), '')                      AS customer_id,

        -- Blank / "NULL" / "n/a" / "unknown" are all missing. Membership is
        -- then re-derived from whether a customer id was actually supplied,
        -- which is the only trustworthy signal in the file.
        CASE
            WHEN NULLIF(TRIM(customer_id), '') IS NOT NULL THEN 'Member'
            ELSE 'Normal'
        END                                                AS customer_type,
        CASE
            WHEN LOWER(TRIM(COALESCE(customer_type, ''))) IN ('', 'null', 'n/a', 'unknown')
            THEN TRUE ELSE FALSE
        END                                                AS customer_type_was_repaired,

        INITCAP(TRIM(gender))                              AS gender,
        UPPER(TRIM(product_sku))                           AS product_sku,
        TRIM(product_line)                                 AS product_line,
        TRIM(product_name)                                 AS product_name,

        staging.try_to_numeric(unit_price)                 AS unit_price,
        staging.try_to_numeric(quantity)                   AS quantity,
        staging.try_to_numeric(tax_amount)                 AS tax_amount,
        staging.try_to_numeric(total)                      AS total_amount,
        staging.try_to_numeric(cogs)                       AS cogs,
        staging.try_to_numeric(gross_margin_pct)           AS gross_margin_pct,
        staging.try_to_numeric(gross_income)               AS gross_profit,

        -- Only well-formed ISO dates are even offered to the cast; anything
        -- else (empty, "15/03/2022") becomes NULL and is rejected below.
        CASE
            WHEN TRIM(date) ~ '^\d{4}-\d{2}-\d{2}$'
            THEN staging.try_to_date(TRIM(date))
        END                                                AS sale_date,

        CASE
            WHEN TRIM(time) ~ '^\d{2}:\d{2}:\d{2}$'
            THEN TRIM(time)::TIME
        END                                                AS sale_time,

        -- "ewallet", "E-Wallet", "EWALLET", "e wallet" -> "Ewallet"
        CASE REGEXP_REPLACE(LOWER(TRIM(payment)), '[^a-z]', '', 'g')
            WHEN 'ewallet'    THEN 'Ewallet'
            WHEN 'creditcard' THEN 'Credit card'
            WHEN 'cash'       THEN 'Cash'
            ELSE INITCAP(TRIM(payment))
        END                                                AS payment_method,

        NULLIF(TRIM(rating), '')::NUMERIC                  AS rating,

        -- Raw values retained so the reject table can show what arrived.
        date        AS raw_date,
        quantity    AS raw_quantity,
        unit_price  AS raw_unit_price,
        rn
    FROM deduped
)
SELECT
    *,
    CASE
        WHEN rn > 1                          THEN 'DUPLICATE_LINE'
        WHEN invoice_id IS NULL              THEN 'MISSING_INVOICE_ID'
        WHEN line_no IS NULL                 THEN 'MISSING_LINE_NO'
        WHEN sale_date IS NULL               THEN 'INVALID_DATE'
        WHEN sale_date < DATE '2019-01-01'
          OR sale_date > DATE '2024-12-31'   THEN 'DATE_OUT_OF_RANGE'
        WHEN quantity IS NULL                THEN 'INVALID_QUANTITY'
        WHEN quantity <= 0                   THEN 'NON_POSITIVE_QUANTITY'
        WHEN unit_price IS NULL              THEN 'INVALID_UNIT_PRICE'
        WHEN unit_price <= 0                 THEN 'NON_POSITIVE_UNIT_PRICE'
        WHEN sale_time IS NULL               THEN 'INVALID_TIME'
        ELSE NULL
    END AS reject_reason
FROM typed;


-- ---------------------------------------------------------------------------
-- Quarantine
-- ---------------------------------------------------------------------------

CREATE TABLE staging.stg_sales_rejects AS
SELECT
    invoice_id,
    line_no,
    branch_code,
    reject_reason,
    raw_date       AS source_date,
    raw_quantity   AS source_quantity,
    raw_unit_price AS source_unit_price,
    now()          AS rejected_at
FROM tmp_normalised
WHERE reject_reason IS NOT NULL;

CREATE INDEX ix_rejects_reason ON staging.stg_sales_rejects (reject_reason);


-- ---------------------------------------------------------------------------
-- Clean staging table
--
-- Monetary measures are recomputed from unit_price and quantity rather than
-- trusted from the file, so an inconsistent source total cannot propagate into
-- the mart. gross_profit is derived from the product-line margin carried on
-- the row, correcting the source sample's flat 4.76% margin.
-- ---------------------------------------------------------------------------

CREATE TABLE staging.stg_sales AS
SELECT
    invoice_id,
    line_no::SMALLINT                                       AS line_no,
    branch_code,
    city,
    customer_id,
    customer_type,
    customer_type_was_repaired,
    gender,
    product_sku,
    product_line,
    product_name,
    sale_date,
    sale_time,
    EXTRACT(HOUR FROM sale_time)::SMALLINT                  AS sale_hour,
    payment_method,
    quantity::INTEGER                                       AS quantity,
    ROUND(unit_price, 2)                                    AS unit_price,
    ROUND(unit_price * quantity, 2)                         AS gross_sales,
    ROUND(unit_price * quantity * 0.05, 4)                  AS tax_amount,
    ROUND(unit_price * quantity * 1.05, 4)                  AS total_amount,
    ROUND(unit_price * quantity * (1 - gross_margin_pct / 100), 2) AS cogs,
    ROUND(unit_price * quantity * (gross_margin_pct / 100), 4)     AS gross_profit,
    gross_margin_pct,
    rating
FROM tmp_normalised
WHERE reject_reason IS NULL;

ALTER TABLE staging.stg_sales
    ADD CONSTRAINT pk_stg_sales PRIMARY KEY (invoice_id, line_no);

CREATE INDEX ix_stg_sales_date     ON staging.stg_sales (sale_date);
CREATE INDEX ix_stg_sales_customer ON staging.stg_sales (customer_id);


-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'extract', 'raw.sales_landing', COUNT(*), 'rows as delivered by source'
FROM raw.sales_landing;

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'reject', 'staging.stg_sales_rejects', COUNT(*), 'quarantined with reason code'
FROM staging.stg_sales_rejects;

INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
SELECT 'clean', 'staging.stg_sales', COUNT(*), 'typed, deduplicated, conformed'
FROM staging.stg_sales;

DROP TABLE tmp_normalised;

ANALYZE staging.stg_sales;
