-- ===========================================================================
-- 03_indexes.sql
--
-- Run AFTER the fact table is loaded. Building indexes on a populated table is
-- substantially faster than maintaining them row by row during the load, and
-- it lets the performance benchmark measure a genuine before/after.
--

-- Index choices are driven by the actual query patterns in sql/02_analysis:
--
--   * every analytical query filters or groups by date        -> date_key lead
--   * branch scorecards filter branch then aggregate by date  -> composite
--   * category analysis groups product then date              -> composite
--   * RFM and cohort work scans by customer                   -> customer_key
--   * market-basket self-joins the fact on invoice_id         -> invoice_id
--
-- The composite indexes lead with the equality-filtered column and follow with
-- the range-scanned one, which is the order Postgres can actually use.
-- ===========================================================================

-- Fact ------------------------------------------------------------------------
CREATE INDEX ix_fact_date_key
    ON marts.fact_sales (date_key);

CREATE INDEX ix_fact_branch_date
    ON marts.fact_sales (branch_key, date_key)
    INCLUDE (total_amount, gross_profit, quantity);

CREATE INDEX ix_fact_product_date
    ON marts.fact_sales (product_key, date_key)
    INCLUDE (total_amount, gross_profit, quantity);

CREATE INDEX ix_fact_customer
    ON marts.fact_sales (customer_key, sale_date)
    WHERE customer_key <> -1;      -- partial: walk-ins are never analysed by customer

CREATE INDEX ix_fact_invoice
    ON marts.fact_sales (invoice_id);

CREATE INDEX ix_fact_payment
    ON marts.fact_sales (payment_key, date_key);

CREATE INDEX ix_fact_hour
    ON marts.fact_sales (sale_hour);

-- Dimensions ------------------------------------------------------------------
CREATE INDEX ix_dim_date_year_month  ON marts.dim_date (year_number, month_number);
CREATE INDEX ix_dim_date_full        ON marts.dim_date (full_date);
CREATE INDEX ix_dim_branch_city      ON marts.dim_branch (city);

-- Planner statistics ----------------------------------------------------------
-- Without this the planner works from stale defaults on a freshly bulk-loaded
-- table and will happily pick a nested loop over 1.2M rows.
ANALYZE marts.fact_sales;
ANALYZE marts.dim_date;
ANALYZE marts.dim_branch;
ANALYZE marts.dim_product;
ANALYZE marts.dim_customer;
ANALYZE marts.dim_payment;
