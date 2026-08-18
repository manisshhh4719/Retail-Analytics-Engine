# Data generation method

## Why the data is simulated

The source for this project is the [Kaggle Walmart/supermarket sales
sample](https://www.kaggle.com/datasets/aungpyaeap/supermarket-sales): 1,000
rows, 3 branches, 3 months of 2019.

Aggregating that file shows why it cannot support the analysis this project is
built around:

| Dimension | Spread across categories |
|---|---|
| 6 product lines | 15.2% – 17.4% of revenue |
| 3 branches | 32.9% / 32.9% / 34.2% |
| Member vs Normal | 50.8% / 49.2% |
| 3 payment methods | 31.2% / 34.1% / 34.7% |
| Monthly revenue | $116K / $97K / $109K (noise, no trend) |

Every distribution is close to uniform. There is no growth to measure, no
repeat customers to build cohorts from, no margin variation to find, and no
category winning or losing. Any "insight" drawn from it would be noise
presented as a finding.

Rather than overstate what a 1,000-row sample can show, the project generates a
dataset large and structured enough for the techniques to be demonstrated
honestly — and labels it as simulated everywhere it appears.

## What is authored vs what is measured

The generator **authors behaviour**. The SQL layer **measures it**. Those are
different claims, and the distinction is what keeps the project honest:

- The generator decides that electronics gains share. The analysis measures
  that it gained **8.5 points**, and would have measured something different if
  the parameters differed.
- Every figure in the README is a real query result over 1.19M real rows.
- None of it is a fact about the actual Walmart Inc.

`src/validate_generation.py` runs 13 assertions confirming each engineered
signal survives generation *and* the cleaning pipeline at a magnitude worth
reporting. If a signal is too weak to detect, the build fails rather than
producing a dataset with nothing in it.

## Signals built into the data

| Signal | Parameter | Measured result |
|---|---|---|
| Like-for-like growth | 12%/year compounding | 21.5% CAGR (incl. new stores) |
| COVID-19 shock | trough ×0.52, Mar–Dec 2020 | 2020 LFL −11.0% |
| Q4 seasonality | Nov ×1.28, Dec ×1.35 | Dec index 158 vs 100 average |
| Weekend lift | Sat ×1.42, Sun ×1.24 | Sat–Sun index 1.26 |
| Promotional events | 5 recurring windows | +53.4% vs same-month normal days |
| Evening traffic peak | 18–20h weighted | 29.0% of revenue |
| Peak-hour service dip | −0.45 rating penalty | 6.53 vs 6.96 (0.43 gap) |
| Category mix shift | electronics up, home down | +8.5pts / −6.9pts |
| Margin by category | 12%–34% by line | 11.5%–33.7% realised |
| Customer heterogeneity | 4 segments, exponential lifetimes | top decile = 56.9% of revenue |
| Churn | segment-specific lifetimes | M12 retention 22.2% |
| Product affinity | 28 pairs, p=0.55 | lift up to 9.15 |
| Price inflation | 3.1%/year | avg basket $283 → $311 |
| Payment drift | e-wallet up, cash down | 38.2%→48.8% / 27.8%→15.0% |

All parameters live in [`src/config.py`](../src/config.py).

## How it is built

The generator is fully vectorised — 1.2M line items in ~10 seconds — using
NumPy rather than row-by-row loops.

1. **Daily demand curve.** A multiplier per calendar day combining growth,
   month seasonality, day-of-week, COVID and promotional windows, plus
   lognormal noise. Expected invoices per (day, branch) cell, then a Poisson
   draw for actual counts.

2. **Store network.** 14 branches trade from day one; 6 open across the period
   and ramp from 55% to full productivity over 6 months. Day-one branches do
   *not* ramp — they are established stores, and ramping them would make 2019
   look like a chain launch and corrupt every comparison using it as a base
   year.

3. **Customer assignment.** Members are sampled from those already signed up at
   that branch, weighted by purchase propensity via a prefix-sum plus
   `searchsorted`. An attempt landing on a churned customer falls through to an
   anonymous walk-in — which is what makes lapsed customers genuinely stop
   appearing rather than being artificially removed.

4. **Baskets.** Invoice size drawn from a distribution averaging 1.98 lines.
   The first item comes from the year's category mix; add-on items come from
   the first item's affinity list with p=0.55, otherwise from the general mix.
   This is the signal market-basket analysis is meant to recover.

5. **Money.** `gross_sales = unit_price × quantity`; tax at 5%;
   `cogs = gross_sales × (1 − margin)` with margin varying by product line.

   This **corrects a flaw in the source sample**, which defines `gross_income`
   as the tax amount and holds "gross margin percentage" at a constant
   4.7619% — which is 5/105, not a margin. Without this correction there is no
   profitability analysis to do.

6. **Defect injection.** ~3.8% of rows receive at least one defect: duplicate
   lines, null ratings, negative quantities, city casing and whitespace
   variants, malformed and out-of-range dates, blank customer types,
   currency-formatted prices, and payment-method spelling variants.

## Reproducibility

Seeded (`SEED = 20190101`). The same seed reproduces the dataset exactly.

```bash
python src/generate_data.py --rows 1200000 --seed 20190101
python src/validate_generation.py
```

## Known limitations

Stated plainly, because a reviewer will spot them:

- **32 SKUs** is a small assortment. ABC classification is therefore less
  dramatic than in a real catalogue (20 of 32 SKUs make the A class); the
  method is correct but the tail is short.
- **No cross-branch shopping.** Customers transact only at their home branch,
  so no "customer shops multiple stores" analysis is possible.
- **No returns or refunds.** Every transaction is a sale.
- **Affinities are symmetric and static.** Real product affinities shift
  seasonally; these do not.
- **Ratings are independent of the customer.** A given customer has no
  persistent rating bias.
