# Power BI build guide

Everything needed to build the dashboard on top of the warehouse: connection,
model, DAX, and a page-by-page visual specification.

The `.pbix` file itself is a binary that has to be assembled in Power BI
Desktop — this guide is the specification it is built from. Follow it top to
bottom and the result is reproducible.

---

## 1. Connect

Power BI Desktop → **Get Data → PostgreSQL database**.

| Field | Value |
|---|---|
| Server | `127.0.0.1:5433` |
| Database | `walmart_dw` |
| Data Connectivity mode | **Import** |
| Authentication | **Database** (not Windows) |
| Username | `postgres` |
| Password | the `PGPASSWORD` line in your `.env` file — `walmart_dw_pw` on the default local setup |

Credentials live in `.env` (gitignored) rather than in this file, so the repo
can be shared without leaking them. `.env.example` carries a placeholder for
anyone cloning it.

Three things that commonly go wrong on a first connection:

- **Wrong port.** This cluster runs on **5433**, not the default 5432. Power BI
  needs `127.0.0.1:5433` — the port is part of the Server field, not a separate
  box.

- **Npgsql missing.** Power BI needs the Npgsql ADO.NET provider for
  PostgreSQL. If the connector errors immediately, install Npgsql and restart
  Power BI Desktop.
- **SSL.** A local server has no certificate. Untick *Encrypt connection* in
  the connection dialog, or the handshake fails.

### Import, not DirectQuery


Import is the right call here and it is worth being able to say why. The fact
table is 1.19M rows — comfortably inside Import's working range, and it
compresses well under VertiPaq. DirectQuery would push a SQL round trip for
every visual interaction, and the measures below use time intelligence that
DirectQuery either blocks or degrades. Import also means the dashboard keeps
working when the local Postgres instance is not running, which matters for a
portfolio piece someone else will open.

### Tables to load

| Object | Role | Rows |
|---|---|---|
| `marts.fact_sales` | Fact | 1,194,949 |
| `marts.dim_date` | Date dimension | 3,287 |
| `marts.dim_branch` | Dimension | 21 |
| `marts.dim_product` | Dimension | 33 |
| `marts.dim_customer` | Dimension | 40,001 |
| `marts.dim_payment` | Dimension | 4 |
| `marts.dim_customer_rfm` | Segment dimension | 25,536 |
| `marts.v_cohort_retention` | Helper (cohort matrix) | 1,500 |
| `marts.v_basket_affinity` | Helper (product pairs) | 495 |

Do **not** load `marts.fact_sales_unoptimised` — it is the benchmark control
and would double the model size for nothing.

In Power Query, drop the columns the model never uses: `sale_id`, `cogs`,
`tax_amount`, `gross_sales`. Every column kept is stored, indexed and
compressed on refresh, and a narrower fact table refreshes faster and uses less
memory. Keep `gross_sales` only if you want margin computed against ex-tax
revenue in DAX rather than reading `Gross Margin %` below.

---

## 2. Model

Relationships — all **one-to-many**, single direction, from dimension to fact:

```
dim_date[date_key]           1 --→ *  fact_sales[date_key]
dim_branch[branch_key]       1 --→ *  fact_sales[branch_key]
dim_product[product_key]     1 --→ *  fact_sales[product_key]
dim_customer[customer_key]   1 --→ *  fact_sales[customer_key]
dim_payment[payment_key]     1 --→ *  fact_sales[payment_key]

dim_customer[customer_key]   1 --→ 1  dim_customer_rfm[customer_key]
```

Keep cross-filter direction **single** everywhere. Bidirectional filtering on a
star schema is the most common cause of ambiguous-path errors and of measures
silently returning the wrong grain; there is no relationship here that needs
it.

### Mark the date table

Select `dim_date` → **Table tools → Mark as date table** → date column
`full_date`.

This is not optional. Without it, `SAMEPERIODLASTYEAR`, `DATESYTD` and
`DATEADD` fall back on Power BI's auto date/time hierarchy, which is built per
date column, bloats the model, and produces wrong results the moment the fact
table has gaps.

Also turn off **File → Options → Data Load → Auto date/time** for the file.

### Hide from report view

Hide every key column (`*_key`) and `dim_date[date_key]`. They are model
plumbing; leaving them visible invites someone to drag a surrogate key onto a
visual and get a meaningless integer sum.

---

## 3. DAX measures

Create a blank table named `_Measures` (**Enter data**, no columns) and put
every measure in it, so measures are not scattered across fact and dimension
tables.

### 3.1 Base measures

```dax
Total Revenue =
SUM ( fact_sales[total_amount] )

Gross Profit =
SUM ( fact_sales[gross_profit] )

Gross Margin % =
DIVIDE (
    [Gross Profit],
    SUM ( fact_sales[gross_sales] )
)
-- Margin is measured against ex-tax sales, not tax-inclusive revenue.
-- Dividing by total_amount understates margin by the 5% tax component.

Invoices =
DISTINCTCOUNT ( fact_sales[invoice_id] )

Line Items =
COUNTROWS ( fact_sales )

Units Sold =
SUM ( fact_sales[quantity] )

Avg Basket Value =
DIVIDE ( [Total Revenue], [Invoices] )
-- Deliberately not AVERAGE(total_amount): that averages line items, not
-- baskets, and reads ~50% low because most invoices carry multiple lines.

Avg Rating =
AVERAGE ( fact_sales[rating] )
-- AVERAGE ignores blanks, which is correct here: an unrated sale is missing
-- data, not a zero-star review.

Active Customers =
CALCULATE (
    DISTINCTCOUNT ( fact_sales[customer_key] ),
    fact_sales[customer_key] <> -1
)
-- -1 is the Unknown member carrying anonymous walk-ins. Counting it would add
-- a phantom customer to every single grouping.
```

### 3.2 Time intelligence

```dax
Revenue LY =
CALCULATE ( [Total Revenue], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )

Revenue YoY % =
VAR Current = [Total Revenue]
VAR Prior   = [Revenue LY]
RETURN
    IF ( NOT ISBLANK ( Prior ), DIVIDE ( Current - Prior, Prior ) )
-- The IF guard suppresses the meaningless "+infinity%" on the first year,
-- where there is no prior period to compare against.

Revenue YTD =
TOTALYTD ( [Total Revenue], dim_date[full_date] )

Revenue LY YTD =
CALCULATE ( [Revenue YTD], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )

Revenue MoM % =
VAR Prior =
    CALCULATE ( [Total Revenue], DATEADD ( dim_date[full_date], -1, MONTH ) )
RETURN
    IF ( NOT ISBLANK ( Prior ), DIVIDE ( [Total Revenue] - Prior, Prior ) )

Revenue 3M Avg =
AVERAGEX (
    DATESINPERIOD ( dim_date[full_date], MAX ( dim_date[full_date] ), -3, MONTH ),
    [Total Revenue]
)

Revenue Rolling 12M =
CALCULATE (
    [Total Revenue],
    DATESINPERIOD ( dim_date[full_date], MAX ( dim_date[full_date] ), -12, MONTH )
)

Profit YoY % =
VAR Prior = CALCULATE ( [Gross Profit], SAMEPERIODLASTYEAR ( dim_date[full_date] ) )
RETURN IF ( NOT ISBLANK ( Prior ), DIVIDE ( [Gross Profit] - Prior, Prior ) )
```

### 3.3 Ranking and share

```dax
Revenue Share % =
DIVIDE (
    [Total Revenue],
    CALCULATE ( [Total Revenue], REMOVEFILTERS () )
)

Branch Rank =
IF (
    NOT ISBLANK ( [Total Revenue] ),
    RANKX ( ALLSELECTED ( dim_branch[branch_code] ), [Total Revenue],, DESC, DENSE )
)
-- ALLSELECTED, not ALL: the rank should respect slicers the user has applied,
-- so filtering to one city re-ranks within that city instead of showing the
-- national position.

Product Rank =
IF (
    NOT ISBLANK ( [Total Revenue] ),
    RANKX ( ALLSELECTED ( dim_product[product_name] ), [Total Revenue],, DESC, DENSE )
)

Revenue Running Total =
CALCULATE (
    [Total Revenue],
    FILTER (
        ALLSELECTED ( dim_product[product_name] ),
        [Total Revenue] >= [Total Revenue]
    )
)

Pareto Cumulative % =
VAR CurrentRevenue = [Total Revenue]
VAR RunningTotal =
    SUMX (
        FILTER (
            ALLSELECTED ( dim_product[product_name] ),
            CALCULATE ( [Total Revenue] ) >= CurrentRevenue
        ),
        CALCULATE ( [Total Revenue] )
    )
RETURN
    DIVIDE ( RunningTotal, CALCULATE ( [Total Revenue], ALLSELECTED () ) )
-- Drives the Pareto line on the ABC chart. The FILTER compares each product's
-- revenue to the current row's, which is what produces a descending running
-- total without needing a physical rank column.
```

### 3.4 Customer measures

```dax
Champions Revenue =
CALCULATE ( [Total Revenue], dim_customer_rfm[rfm_segment] = "Champions" )

Champions Revenue % =
DIVIDE (
    [Champions Revenue],
    CALCULATE ( [Total Revenue], REMOVEFILTERS ( dim_customer_rfm ) )
)

Revenue At Risk =
CALCULATE (
    [Total Revenue],
    dim_customer_rfm[rfm_segment] IN { "At Risk", "Hibernating" },
    dim_customer_rfm[m_score] >= 4
)
-- Scoped to customers who were genuinely valuable while active. Without the
-- m_score filter this counts every lapsed low-value customer and overstates
-- the retention opportunity several times over.

Customer Lifetime Value =
AVERAGE ( dim_customer_rfm[lifetime_revenue] )

Repeat Customer % =
VAR Repeaters =
    CALCULATE (
        DISTINCTCOUNT ( dim_customer_rfm[customer_key] ),
        dim_customer_rfm[lifetime_orders] > 1
    )
VAR AllCustomers = DISTINCTCOUNT ( dim_customer_rfm[customer_key] )
RETURN DIVIDE ( Repeaters, AllCustomers )

New Customers =
CALCULATE (
    DISTINCTCOUNT ( dim_customer[customer_key] ),
    USERELATIONSHIP ( dim_date[full_date], dim_customer[first_purchase_date] )
)
-- Requires an inactive relationship from dim_date[full_date] to
-- dim_customer[first_purchase_date]. Create it, set it inactive, and activate
-- it here so acquisition is counted on first-purchase date while every other
-- measure still filters on sale date.

Avg Days Since Purchase =
AVERAGE ( dim_customer_rfm[recency_days] )
```

### 3.5 Operations

```dax
Peak Hour Revenue =
CALCULATE ( [Total Revenue], fact_sales[sale_hour] IN { 18, 19, 20 } )

Peak Hour Revenue % =
DIVIDE ( [Peak Hour Revenue], CALCULATE ( [Total Revenue], REMOVEFILTERS ( fact_sales[sale_hour] ) ) )

Peak Hour Rating =
CALCULATE ( [Avg Rating], fact_sales[sale_hour] IN { 18, 19, 20 } )

Off Peak Rating =
CALCULATE ( [Avg Rating], NOT fact_sales[sale_hour] IN { 18, 19, 20 } )

Rating Gap =
[Off Peak Rating] - [Peak Hour Rating]

Detractor % =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_sales ), fact_sales[rating] <= 5 ),
    CALCULATE ( COUNTROWS ( fact_sales ), NOT ISBLANK ( fact_sales[rating] ) )
)

Revenue per Trading Day =
DIVIDE ( [Total Revenue], DISTINCTCOUNT ( fact_sales[sale_date] ) )
-- The fair branch comparison. Ranking branches on total revenue penalises any
-- store that opened mid-period simply for having traded fewer days.
```

### 3.6 Formatting helpers

```dax
KPI Trend Colour =
IF ( [Revenue YoY %] >= 0, "#2E7D32", "#C62828" )

Rating Colour =
SWITCH (
    TRUE (),
    [Avg Rating] >= 7.0, "#2E7D32",
    [Avg Rating] >= 6.6, "#F9A825",
    "#C62828"
)

Revenue Label =
VAR V = [Total Revenue]
RETURN
    SWITCH (
        TRUE (),
        V >= 1e9, FORMAT ( V / 1e9, "0.00" ) & "B",
        V >= 1e6, FORMAT ( V / 1e6, "0.0" ) & "M",
        V >= 1e3, FORMAT ( V / 1e3, "0.0" ) & "K",
        FORMAT ( V, "0" )
    )
```

Set number formats on the measures themselves (Measure tools → Format), not on
each visual. Currency to 0 decimals, percentages to 1 decimal.

---

## 4. Pages

### Page 1 — Executive Overview

*Question it answers: are we growing, and where is the growth coming from?*

| Position | Visual | Fields |
|---|---|---|
| Top row | 5 × KPI card | `Total Revenue`, `Gross Profit`, `Gross Margin %`, `Invoices`, `Avg Basket Value` — each with `Revenue YoY %` as the trend indicator |
| Left, large | Line + clustered column | Axis `dim_date[year_month]`; column `Total Revenue`; line `Revenue 3M Avg` |
| Right | Line chart | Axis `dim_date[month_number]`, legend `dim_date[year_number]`, value `Total Revenue` — seasonality overlay by year |
| Mid-left | Waterfall | Category `dim_date[year_number]`, value `Total Revenue` — year-on-year bridge |
| Mid-right | Map (bubble) | Location `dim_branch[city]`, size `Total Revenue`, colour `Gross Margin %` |
| Bottom | Matrix | Rows `dim_branch[region]` / `dim_branch[city]`; values `Total Revenue`, `Revenue YoY %`, `Gross Margin %`, `Avg Rating` |
| Slicers | Year, Region, Product line | Sync across all pages |

Annotate the 2020 dip directly on the trend chart. A reviewer should not have
to work out what happened; a text box reading *"COVID-19: like-for-like −1.7%,
recovered by Q4 2020"* is the difference between a chart and a finding.

### Page 2 — Product & Category

*Question: what should we stock more of, and what is quietly unprofitable?*

| Position | Visual | Fields |
|---|---|---|
| Top left | Scatter | X `Total Revenue`, Y `Gross Margin %`, size `Units Sold`, legend `dim_product[product_line]` — the revenue/margin trade-off in one chart |
| Top right | Line + column (Pareto) | Axis `dim_product[product_name]` sorted by revenue desc; column `Total Revenue`; line `Pareto Cumulative %` with a constant line at 80% |
| Mid left | Stacked area (100%) | Axis `dim_date[year_number]`, legend `dim_product[product_line]`, value `Revenue Share %` — the mix shift |
| Mid right | Table | From `v_basket_affinity`: `product_a`, `product_b`, `lift`, `confidence_pct`, `pair_type`; sorted by `lift` desc; data bars on `lift` |
| Bottom | Matrix | Rows `dim_product[product_line]`; values `Total Revenue`, `Gross Profit`, `Gross Margin %`, `Product Rank`, `Avg Rating` |

Conditional-format `Gross Margin %` on a red-to-green scale. The point that
should jump out: Electronic accessories is second by revenue and fifth by
profit.

### Page 3 — Customer Segmentation

*Question: who is valuable, who is leaving, and what is that worth?*

| Position | Visual | Fields |
|---|---|---|
| Top row | 4 × card | `Active Customers`, `Repeat Customer %`, `Customer Lifetime Value`, `Revenue At Risk` |
| Left | Matrix (RFM grid) | Rows `dim_customer_rfm[r_score]`, columns `dim_customer_rfm[f_score]`, values `Active Customers`; background colour scale |
| Right | Bar chart | Axis `dim_customer_rfm[rfm_segment]`, value `Total Revenue`, sorted desc; data labels showing `Revenue Share %` |
| Mid | Matrix (cohort heatmap) | From `v_cohort_retention`: rows `cohort_label`, columns `month_index`, values `retention_pct`; background colour scale, no totals |
| Bottom left | Column | Axis `dim_customer_rfm[activity_status]`, value `Total Revenue` |
| Bottom right | Column | Axis `dim_date[year_number]`, values `New Customers` and returning revenue |

Set the cohort matrix column headers to stop at 24 and switch totals off — a
row total on a retention matrix is meaningless and reviewers notice.

### Page 4 — Branch & Store Operations

*Question: which stores need attention, and when are we understaffed?*

| Position | Visual | Fields |
|---|---|---|
| Top | Matrix (scorecard) | Rows `dim_branch[branch_code]`; values `Total Revenue`, `Revenue per Trading Day`, `Branch Rank`, `Gross Margin %`, `Avg Rating`, `Detractor %` |
| Left | Matrix (heatmap) | Rows `fact_sales[sale_hour]`, columns `dim_date[day_name]`, values `Total Revenue`; background colour scale |
| Right | Line + column (dual axis) | Axis `fact_sales[sale_hour]`; column `Total Revenue`; line `Avg Rating` on a secondary axis — the staffing finding, in one visual |
| Bottom left | Cards | `Peak Hour Revenue %`, `Rating Gap`, `Detractor %` |
| Bottom right | Stacked column (100%) | Axis `dim_date[year_number]`, legend `dim_payment[payment_method]`, value `Revenue Share %` |

The dual-axis chart is the page's argument: revenue peaks at 19:00 and ratings
bottom out in the same hour. Put a text box next to it stating the size of the
gap and what it implies.

---

## 5. Finishing

- **Sort order.** Set `dim_date[month_abbr]` to sort by `month_number` and
  `dim_date[day_abbr]` by `day_of_week`. Otherwise both sort alphabetically and
  the week starts on Friday.
- **Sync slicers** across pages (View → Sync slicers) so a filter follows the
  reader.
- **Drill-through** page on `dim_branch[branch_code]`, so any branch on any
  visual can be right-clicked for its own detail.
- **Tooltips.** Add `Gross Margin %` and `Avg Rating` as tooltip fields on the
  revenue visuals; it costs nothing and answers the obvious follow-up.
- **Performance.** Run **View → Performance analyzer**, refresh visuals, and
  check nothing exceeds ~300 ms. If the cohort matrix is slow, it is being
  built from the fact table rather than `v_cohort_retention`.
- **Theme.** One accent colour plus neutral greys. Reserve red and green for
  good/bad only — using them as categorical series colours makes every chart
  look like a judgement.

## 6. Refresh

For a local Postgres, refresh is manual (**Home → Refresh**). Scheduled refresh
against a local instance requires an On-premises Data Gateway; publishing to
the Power BI Service without one leaves the dataset static. Either install the
gateway, or state plainly that refresh is manual — do not claim a scheduled
refresh that does not exist.
