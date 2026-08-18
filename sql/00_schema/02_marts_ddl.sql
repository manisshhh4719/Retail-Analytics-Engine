-- ===========================================================================
-- 02_marts_ddl.sql
--
-- Kimball-style star schema.
--
--   fact_sales   grain = one invoice line item
--   dim_date     one row per calendar day, 2018-2026
--   dim_branch   store network, including opening date for like-for-like work
--   dim_product  SKU level, rolling up to product line
--   dim_customer loyalty members, plus an Unknown member for walk-ins
--   dim_payment  payment method
--
-- fact_sales is RANGE-partitioned by month. Six years of daily retail data is
-- almost always queried through a date filter, so partition pruning removes
-- the majority of the table before any index is consulted. The unpartitioned
-- twin created at the bottom exists purely as the control in the performance
-- benchmark (sql/02_analysis/06_performance.sql).
--
-- Every dimension carries a -1 "Unknown" member so the fact table can stay
-- NOT NULL on all foreign keys and inner joins never silently drop rows.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- dim_date
-- ---------------------------------------------------------------------------

CREATE TABLE marts.dim_date (
    date_key          INTEGER     PRIMARY KEY,   -- yyyymmdd
    full_date         DATE        NOT NULL UNIQUE,
    day_of_month      SMALLINT    NOT NULL,
    day_of_week       SMALLINT    NOT NULL,      -- 1 = Monday
    day_name          TEXT        NOT NULL,
    day_abbr          TEXT        NOT NULL,
    is_weekend        BOOLEAN     NOT NULL,
    week_of_year      SMALLINT    NOT NULL,
    iso_year_week     TEXT        NOT NULL,
    month_number      SMALLINT    NOT NULL,
    month_name        TEXT        NOT NULL,
    month_abbr        TEXT        NOT NULL,
    year_month        TEXT        NOT NULL,      -- 2024-07
    month_start_date  DATE        NOT NULL,
    month_end_date    DATE        NOT NULL,
    quarter_number    SMALLINT    NOT NULL,
    quarter_name      TEXT        NOT NULL,      -- 2024-Q3
    year_number       SMALLINT    NOT NULL,
    day_of_year       SMALLINT    NOT NULL,
    is_holiday_season BOOLEAN     NOT NULL,      -- Nov-Dec trading peak
    is_promo_window   BOOLEAN     NOT NULL       -- known campaign dates
);

COMMENT ON TABLE marts.dim_date IS
    'Conformed date dimension. Marked as the date table in the Power BI model '
    'so DAX time intelligence (SAMEPERIODLASTYEAR, DATESYTD) resolves.';


-- ---------------------------------------------------------------------------
-- dim_branch
-- ---------------------------------------------------------------------------

CREATE TABLE marts.dim_branch (
    branch_key    INTEGER     PRIMARY KEY,
    branch_code   TEXT        NOT NULL,
    branch_name   TEXT        NOT NULL,
    city          TEXT        NOT NULL,
    region        TEXT        NOT NULL,
    opened_date   DATE,
    size_factor   NUMERIC(4,2),
    size_band     TEXT,                          -- Small / Medium / Large
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX ux_dim_branch_code ON marts.dim_branch (branch_code);

COMMENT ON COLUMN marts.dim_branch.opened_date IS
    'Drives the like-for-like vs new-store split in the growth decomposition.';


-- ---------------------------------------------------------------------------
-- dim_product
-- ---------------------------------------------------------------------------

CREATE TABLE marts.dim_product (
    product_key      INTEGER      PRIMARY KEY,
    sku              TEXT         NOT NULL,
    product_name     TEXT         NOT NULL,
    product_line     TEXT         NOT NULL,
    base_price       NUMERIC(10,2),
    margin_pct       NUMERIC(6,4),
    price_band       TEXT                         -- Budget / Mid / Premium
);

CREATE UNIQUE INDEX ux_dim_product_sku ON marts.dim_product (sku);
CREATE INDEX ix_dim_product_line       ON marts.dim_product (product_line);


-- ---------------------------------------------------------------------------
-- dim_customer
--
-- first_purchase_date is derived from the fact table after load, not taken
-- from the source signup date: cohort analysis has to be anchored on observed
-- behaviour, and a signup with no purchase is not a cohort member.
-- ---------------------------------------------------------------------------

CREATE TABLE marts.dim_customer (
    customer_key         INTEGER   PRIMARY KEY,
    customer_id          TEXT      NOT NULL,
    gender               TEXT,
    signup_date          DATE,
    home_branch_code     TEXT,
    home_city            TEXT,
    first_purchase_date  DATE,
    last_purchase_date   DATE,
    cohort_month         DATE,                    -- first day of cohort month
    is_member            BOOLEAN   NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX ux_dim_customer_id  ON marts.dim_customer (customer_id);
CREATE INDEX ix_dim_customer_cohort     ON marts.dim_customer (cohort_month);


-- ---------------------------------------------------------------------------
-- dim_payment
-- ---------------------------------------------------------------------------

CREATE TABLE marts.dim_payment (
    payment_key     INTEGER  PRIMARY KEY,
    payment_method  TEXT     NOT NULL,
    payment_group   TEXT     NOT NULL             -- Cash / Card / Digital
);

CREATE UNIQUE INDEX ux_dim_payment_method ON marts.dim_payment (payment_method);


-- ---------------------------------------------------------------------------
-- fact_sales  (partitioned by month on sale_date)
--
-- Postgres requires the partition key to be part of any unique constraint,
-- hence the composite (sale_id, sale_date) primary key.
-- ---------------------------------------------------------------------------

CREATE TABLE marts.fact_sales (
    sale_id        BIGINT        NOT NULL,
    invoice_id     TEXT          NOT NULL,
    line_no        SMALLINT      NOT NULL,
    sale_date      DATE          NOT NULL,
    date_key       INTEGER       NOT NULL,
    sale_time      TIME          NOT NULL,
    sale_hour      SMALLINT      NOT NULL,
    branch_key     INTEGER       NOT NULL,
    product_key    INTEGER       NOT NULL,
    customer_key   INTEGER       NOT NULL,
    payment_key    INTEGER       NOT NULL,
    customer_type  TEXT          NOT NULL,
    gender         TEXT,
    quantity       INTEGER       NOT NULL,
    unit_price     NUMERIC(10,2) NOT NULL,
    gross_sales    NUMERIC(12,2) NOT NULL,   -- unit_price * quantity, ex-tax
    tax_amount     NUMERIC(12,4) NOT NULL,
    total_amount   NUMERIC(12,4) NOT NULL,   -- gross_sales + tax
    cogs           NUMERIC(12,2) NOT NULL,
    gross_profit   NUMERIC(12,4) NOT NULL,   -- gross_sales - cogs
    rating         NUMERIC(3,1),             -- nullable: not every sale rated
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

COMMENT ON TABLE marts.fact_sales IS
    'Transaction fact at invoice-line grain. Additive measures only; ratios '
    'such as margin % are computed at query time from their components.';

COMMENT ON COLUMN marts.fact_sales.gross_profit IS
    'gross_sales - cogs. The source Kaggle sample defined gross_income as the '
    'tax amount and held margin constant at 4.76% for every row; this model '
    'corrects that and varies margin by product line.';

-- Foreign keys are declared on the parent and inherited by every partition.
ALTER TABLE marts.fact_sales
    ADD CONSTRAINT fk_fact_date     FOREIGN KEY (date_key)     REFERENCES marts.dim_date (date_key),
    ADD CONSTRAINT fk_fact_branch   FOREIGN KEY (branch_key)   REFERENCES marts.dim_branch (branch_key),
    ADD CONSTRAINT fk_fact_product  FOREIGN KEY (product_key)  REFERENCES marts.dim_product (product_key),
    ADD CONSTRAINT fk_fact_customer FOREIGN KEY (customer_key) REFERENCES marts.dim_customer (customer_key),
    ADD CONSTRAINT fk_fact_payment  FOREIGN KEY (payment_key)  REFERENCES marts.dim_payment (payment_key);

ALTER TABLE marts.fact_sales
    ADD CONSTRAINT ck_fact_quantity_positive CHECK (quantity > 0),
    ADD CONSTRAINT ck_fact_rating_range      CHECK (rating IS NULL OR rating BETWEEN 1 AND 10);


-- Monthly partitions for 2019-01 .. 2025-12, generated rather than hand-listed.
DO $$
DECLARE
    p_start DATE := DATE '2019-01-01';
    p_end   DATE := DATE '2026-01-01';
    d       DATE;
BEGIN
    d := p_start;
    WHILE d < p_end LOOP
        EXECUTE format(
            'CREATE TABLE marts.fact_sales_%s PARTITION OF marts.fact_sales '
            'FOR VALUES FROM (%L) TO (%L)',
            to_char(d, 'YYYY_MM'), d, d + INTERVAL '1 month');
        d := d + INTERVAL '1 month';
    END LOOP;
END $$;

-- Catch-all so an out-of-range date fails loudly at load rather than silently.
CREATE TABLE marts.fact_sales_default PARTITION OF marts.fact_sales DEFAULT;


-- ---------------------------------------------------------------------------
-- Benchmark control table
--
-- Same rows, same columns, no partitioning and no indexes. Used only by
-- sql/02_analysis/06_performance.sql to measure what the physical design buys.
-- ---------------------------------------------------------------------------

CREATE TABLE marts.fact_sales_unoptimised (LIKE marts.fact_sales INCLUDING DEFAULTS);

COMMENT ON TABLE marts.fact_sales_unoptimised IS
    'Unpartitioned, unindexed copy of fact_sales. Benchmark control only - '
    'never query this for analysis.';
