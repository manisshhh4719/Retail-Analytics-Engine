-- ===========================================================================
-- 01_schemas_and_raw.sql
--
-- Creates the three-layer warehouse structure and the raw landing table.
--
--   raw      : untyped landing zone, mirrors the source file exactly
--   staging  : typed, cleaned, deduplicated; rejects quarantined with reasons
--   marts    : conformed star schema consumed by SQL analysis and Power BI
--
-- Every column in raw is TEXT on purpose. The landing file carries malformed
-- dates, currency-formatted prices and blank numerics; typing them at load
-- time would abort the COPY and lose the very rows the quality layer needs to
-- report on.
-- ===========================================================================

DROP SCHEMA IF EXISTS raw     CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS marts   CASCADE;

CREATE SCHEMA raw;
CREATE SCHEMA staging;
CREATE SCHEMA marts;

COMMENT ON SCHEMA raw     IS 'Landing zone. Untyped, unmodified source data.';
COMMENT ON SCHEMA staging IS 'Cleaned and conformed. Rejects quarantined.';
COMMENT ON SCHEMA marts   IS 'Star schema serving analysis and Power BI.';


-- ---------------------------------------------------------------------------
-- Landing tables
-- ---------------------------------------------------------------------------

CREATE TABLE raw.sales_landing (
    invoice_id        TEXT,
    line_no           TEXT,
    branch            TEXT,
    city              TEXT,
    customer_id       TEXT,
    customer_type     TEXT,
    gender            TEXT,
    product_sku       TEXT,
    product_line      TEXT,
    product_name      TEXT,
    unit_price        TEXT,
    quantity          TEXT,
    tax_pct           TEXT,
    tax_amount        TEXT,
    total             TEXT,
    date              TEXT,
    time              TEXT,
    payment           TEXT,
    cogs              TEXT,
    gross_margin_pct  TEXT,
    gross_income      TEXT,
    rating            TEXT
);

COMMENT ON TABLE raw.sales_landing IS
    'One row per invoice line as delivered by the source system. All TEXT: '
    'the file contains malformed dates and currency-formatted numerics that '
    'must survive load in order to be reported on by the quality layer.';

CREATE TABLE raw.customers_landing (
    customer_id   TEXT,
    signup_date   TEXT,
    gender        TEXT,
    home_branch   TEXT,
    home_city     TEXT
);

CREATE TABLE raw.products_landing (
    sku           TEXT,
    product_line  TEXT,
    product_name  TEXT,
    base_price    TEXT,
    margin_pct    TEXT
);

CREATE TABLE raw.branches_landing (
    branch_code   TEXT,
    city          TEXT,
    region        TEXT,
    opened_date   TEXT,
    size_factor   TEXT
);


-- ---------------------------------------------------------------------------
-- Load audit trail
--
-- Row counts are captured at every hop so the quality layer can prove nothing
-- was silently lost between raw, staging and marts.
-- ---------------------------------------------------------------------------

CREATE TABLE staging.load_audit (
    audit_id     BIGSERIAL PRIMARY KEY,
    step_name    TEXT        NOT NULL,
    table_name   TEXT        NOT NULL,
    row_count    BIGINT      NOT NULL,
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    notes        TEXT
);

-- Steps are recorded with INSERT ... SELECT rather than a procedure call:
-- Postgres does not allow a subquery as a CALL argument, and every count here
-- is naturally a subquery over the table just written.
--
--   INSERT INTO staging.load_audit (step_name, table_name, row_count, notes)
--   SELECT 'clean', 'staging.stg_sales', COUNT(*), 'conformed'
--   FROM staging.stg_sales;

CREATE OR REPLACE VIEW staging.v_load_audit AS
SELECT
    step_name,
    table_name,
    row_count,
    row_count - LAG(row_count) OVER (ORDER BY audit_id) AS delta_from_prev,
    loaded_at,
    notes
FROM staging.load_audit
ORDER BY audit_id;
