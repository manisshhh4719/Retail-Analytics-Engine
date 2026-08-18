"""
Generate the simulated Walmart retail transaction dataset.

This extends the 1,000-row Kaggle sample (data/raw/walmart_source_sample.csv)
into a multi-year, multi-branch transaction log large enough to exercise a real
warehouse design. The output is DELIBERATELY SIMULATED and is labelled as such
in the project README - see docs/data_generation.md for the full method.

What is engineered into the data on purpose, so the SQL layer has something
real to find:

  * compounding like-for-like growth, plus growth from staggered store openings
  * a COVID-19 demand shock in 2020 and its recovery
  * Q4 seasonality, weekend lift and recurring promotional events
  * an evening traffic peak that coincides with a drop in customer ratings
  * a customer base with heterogeneous frequency, lifetime and churn
  * a product mix that shifts across the period (electronics up, home down)
  * frequently-bought-together product affinities
  * ~4% of rows carrying injected data-quality defects

Usage:
    python src/generate_data.py [--rows 1200000] [--seed 20190101]

Everything is vectorised with numpy; 1.2M line items generate in well under a
minute.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import date, timedelta

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as cfg  # noqa: E402

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------------------
# Demand curve
# ---------------------------------------------------------------------------

def build_date_axis() -> pd.DataFrame:
    """One row per calendar day with every demand multiplier resolved."""
    days = pd.date_range(cfg.START_DATE, cfg.END_DATE, freq="D")
    df = pd.DataFrame({"date": days})
    df["day_idx"] = np.arange(len(df))
    df["year"] = df["date"].dt.year
    df["month"] = df["date"].dt.month
    df["dow"] = df["date"].dt.dayofweek

    years_elapsed = (df["date"] - pd.Timestamp(cfg.START_DATE)).dt.days / 365.25
    df["f_growth"] = (1.0 + cfg.ANNUAL_GROWTH) ** years_elapsed
    df["f_month"] = df["month"].map(lambda m: cfg.MONTH_SEASONALITY[m - 1])
    df["f_dow"] = df["dow"].map(lambda d: cfg.DOW_FACTOR[d])
    df["f_covid"] = _covid_multiplier(df["date"])
    df["f_promo"] = _promo_multiplier(df["date"])
    return df


def _covid_multiplier(dates: pd.Series) -> np.ndarray:
    """Sharp drop into the trough, then a linear recovery through 2020."""
    d = dates.dt.date.to_numpy()
    out = np.ones(len(d))

    falling = (d >= cfg.COVID_START) & (d < cfg.COVID_TROUGH)
    span = (cfg.COVID_TROUGH - cfg.COVID_START).days
    if span > 0:
        prog = np.array([(x - cfg.COVID_START).days / span if f else 0.0
                         for x, f in zip(d, falling)])
        out = np.where(falling,
                       1.0 - prog * (1.0 - cfg.COVID_TROUGH_MULTIPLIER), out)

    rising = (d >= cfg.COVID_TROUGH) & (d <= cfg.COVID_RECOVERED)
    span = (cfg.COVID_RECOVERED - cfg.COVID_TROUGH).days
    if span > 0:
        prog = np.array([(x - cfg.COVID_TROUGH).days / span if f else 0.0
                         for x, f in zip(d, rising)])
        out = np.where(rising,
                       cfg.COVID_TROUGH_MULTIPLIER
                       + prog * (1.0 - cfg.COVID_TROUGH_MULTIPLIER), out)
    return out


def _promo_multiplier(dates: pd.Series) -> np.ndarray:
    out = np.ones(len(dates))
    d = dates.dt.date.to_numpy()
    for month, day, span, uplift in cfg.PROMO_EVENTS:
        for year in range(cfg.START_DATE.year, cfg.END_DATE.year + 1):
            try:
                start = date(year, month, day)
            except ValueError:
                continue
            window = (d >= start) & (d < start + timedelta(days=span))
            out = np.where(window, np.maximum(out, uplift), out)
    return out


def build_branch_frame() -> pd.DataFrame:
    rows = []
    for i, (code, city, region, opened, size) in enumerate(cfg.BRANCHES):
        rows.append({
            "branch_idx": i, "branch_code": code, "city": city,
            "region": region, "opened_date": opened, "size_factor": size,
        })
    return pd.DataFrame(rows)


def build_demand_matrix(dates: pd.DataFrame, branches: pd.DataFrame,
                        rng: np.random.Generator) -> np.ndarray:
    """Expected invoices for every (day, branch) cell."""
    n_days, n_branches = len(dates), len(branches)

    base = (cfg.BASE_INVOICES_PER_DAY
            * dates["f_growth"].to_numpy()
            * dates["f_month"].to_numpy()
            * dates["f_dow"].to_numpy()
            * dates["f_covid"].to_numpy()
            * dates["f_promo"].to_numpy())
    noise = rng.lognormal(0.0, cfg.DAILY_NOISE_SIGMA, size=n_days)
    daily = base * noise

    matrix = np.outer(daily, branches["size_factor"].to_numpy())

    # Apply opening dates and the post-opening ramp. Branches already trading
    # on day one are established stores, so they start at full productivity -
    # ramping them too would make 2019 look like a chain launch and distort
    # every year-on-year comparison that uses it as the base year.
    day_dates = dates["date"].dt.date.to_numpy()
    for i, opened in enumerate(branches["opened_date"]):
        if opened <= cfg.START_DATE:
            continue
        age_days = np.array([(x - opened).days for x in day_dates],
                            dtype=float)
        ramp = np.clip(0.55 + 0.45 * age_days / (cfg.RAMP_MONTHS * 30.0),
                       0.0, 1.0)
        ramp = np.where(age_days < 0, 0.0, ramp)
        matrix[:, i] *= ramp

    return matrix


# ---------------------------------------------------------------------------
# Customers
# ---------------------------------------------------------------------------

def build_customers(demand: np.ndarray, dates: pd.DataFrame,
                    branches: pd.DataFrame,
                    rng: np.random.Generator) -> pd.DataFrame:
    """Loyalty members, acquired in proportion to each branch's traffic."""
    n = cfg.N_CUSTOMERS
    branch_share = demand.sum(axis=0) / demand.sum()
    home = rng.choice(len(branches), size=n, p=branch_share)

    # Sign-up day drawn from the branch's own daily demand curve, so a branch
    # cannot acquire customers before it opens.
    acq = np.empty(n, dtype=np.int64)
    for b in range(len(branches)):
        mask = home == b
        k = int(mask.sum())
        if k == 0:
            continue
        col = demand[:, b]
        total = col.sum()
        if total <= 0:
            acq[mask] = 0
            continue
        cum = np.cumsum(col) / total
        acq[mask] = np.searchsorted(cum, rng.random(k))

    seg_names = list(cfg.CUSTOMER_SEGMENTS.keys())
    seg_probs = [cfg.CUSTOMER_SEGMENTS[s][0] for s in seg_names]
    seg = rng.choice(len(seg_names), size=n, p=seg_probs)

    weight = np.array([cfg.CUSTOMER_SEGMENTS[s][1] for s in seg_names])[seg]
    life_mean = np.array([cfg.CUSTOMER_SEGMENTS[s][2] for s in seg_names])[seg]
    spend = np.array([cfg.CUSTOMER_SEGMENTS[s][3] for s in seg_names])[seg]

    # Exponential lifetime around the segment mean produces the churn signal.
    life = np.maximum(rng.exponential(life_mean), 14).astype(np.int64)

    genders = list(cfg.GENDER_SPLIT.keys())
    gender = rng.choice(genders, size=n, p=list(cfg.GENDER_SPLIT.values()))

    day_dates = dates["date"].dt.date.to_numpy()
    return pd.DataFrame({
        "customer_id": [f"CUST-{i:06d}" for i in range(1, n + 1)],
        "cust_idx": np.arange(n),
        "home_branch_idx": home,
        "acq_day_idx": acq,
        "signup_date": [day_dates[i] for i in acq],
        "life_days": life,
        "weight": weight,
        "spend_mult": spend,
        "gender": gender,
    })


def assign_customers(inv_day: np.ndarray, inv_branch: np.ndarray,
                     customers: pd.DataFrame,
                     rng: np.random.Generator) -> np.ndarray:
    """
    Attach a member to each invoice, or -1 for an anonymous walk-in.

    Members are sampled from those already signed up at that branch, weighted by
    purchase propensity. An attempt that lands on a churned customer falls
    through to anonymous - which is what makes lapsed customers actually stop
    appearing in the data.
    """
    n_inv = len(inv_day)
    out = np.full(n_inv, -1, dtype=np.int64)
    attempt = rng.random(n_inv) < cfg.P_MEMBER_ATTEMPT

    for b in range(int(inv_branch.max()) + 1):
        inv_mask = attempt & (inv_branch == b)
        k = int(inv_mask.sum())
        if k == 0:
            continue

        pool = customers[customers["home_branch_idx"] == b]
        if len(pool) == 0:
            continue
        pool = pool.sort_values("acq_day_idx")
        pool_acq = pool["acq_day_idx"].to_numpy()
        pool_idx = pool["cust_idx"].to_numpy()
        pool_life = pool["life_days"].to_numpy()
        prefix = np.cumsum(pool["weight"].to_numpy())

        days = inv_day[inv_mask]
        # How many of this branch's customers had signed up by each invoice day.
        eligible = np.searchsorted(pool_acq, days, side="right")
        has_pool = eligible > 0

        u = rng.random(k) * np.where(has_pool, prefix[np.maximum(eligible - 1, 0)], 1.0)
        picked = np.searchsorted(prefix, u, side="left")
        picked = np.minimum(picked, np.maximum(eligible - 1, 0))

        active = has_pool & (pool_acq[picked] + pool_life[picked] >= days)
        chosen = np.where(active, pool_idx[picked], -1)

        out[np.flatnonzero(inv_mask)] = chosen

    return out


# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------

def build_product_frame(rng: np.random.Generator) -> pd.DataFrame:
    skus = list(cfg.PRODUCTS.keys())
    rows = []
    for i, sku in enumerate(skus):
        line, name, price, pop = cfg.PRODUCTS[sku]
        margin = cfg.LINE_MARGIN[line] + rng.uniform(-0.025, 0.025)
        rows.append({
            "sku_idx": i, "sku": sku, "product_line": line,
            "product_name": name, "base_price": price,
            "popularity": pop, "margin_pct": round(float(margin), 4),
        })
    return pd.DataFrame(rows)


def build_year_sku_cdfs(products: pd.DataFrame) -> dict[int, np.ndarray]:
    """Per-year cumulative distribution over SKUs (line mix x popularity)."""
    cdfs = {}
    for year, mix in cfg.LINE_MIX_BY_YEAR.items():
        p = np.zeros(len(products))
        for line, share in mix.items():
            sel = products["product_line"].to_numpy() == line
            pop = products["popularity"].to_numpy() * sel
            p += share * pop / pop.sum()
        cdfs[year] = np.cumsum(p / p.sum())
    return cdfs


def build_affinity_table(products: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
    """Padded partner-index matrix plus a per-SKU partner count."""
    idx_of = dict(zip(products["sku"], products["sku_idx"]))
    partners: dict[int, list[int]] = {i: [] for i in products["sku_idx"]}
    for a, b in cfg.AFFINITY_PAIRS:
        ia, ib = idx_of[a], idx_of[b]
        partners[ia].append(ib)
        partners[ib].append(ia)

    width = max(len(v) for v in partners.values())
    table = np.full((len(products), width), -1, dtype=np.int64)
    counts = np.zeros(len(products), dtype=np.int64)
    for i, plist in partners.items():
        table[i, :len(plist)] = plist
        counts[i] = len(plist)
    return table, counts


def sample_skus_by_year(years: np.ndarray, cdfs: dict[int, np.ndarray],
                        rng: np.random.Generator) -> np.ndarray:
    out = np.empty(len(years), dtype=np.int64)
    for year, cdf in cdfs.items():
        mask = years == year
        k = int(mask.sum())
        if k:
            out[mask] = np.searchsorted(cdf, rng.random(k))
    return out


# ---------------------------------------------------------------------------
# Main build
# ---------------------------------------------------------------------------

def generate(target_rows: int, seed: int) -> dict[str, pd.DataFrame]:
    rng = np.random.default_rng(seed)
    t0 = time.time()

    dates = build_date_axis()
    branches = build_branch_frame()
    products = build_product_frame(rng)

    demand = build_demand_matrix(dates, branches, rng)

    # Scale the demand curve so the run lands on the requested row count.
    basket_sizes = np.array(list(cfg.BASKET_SIZE_PROBS.keys()))
    basket_probs = np.array(list(cfg.BASKET_SIZE_PROBS.values()))
    avg_basket = float((basket_sizes * basket_probs).sum())
    demand *= (target_rows / avg_basket) / demand.sum()

    counts = rng.poisson(demand)
    n_invoices = int(counts.sum())
    print(f"  invoices              : {n_invoices:,}")

    # Expand the (day, branch) counts into invoice-level arrays.
    flat = counts.ravel()
    cell = np.repeat(np.arange(flat.size), flat)
    inv_day = (cell // len(branches)).astype(np.int64)
    inv_branch = (cell % len(branches)).astype(np.int64)

    customers = build_customers(demand, dates, branches, rng)
    inv_cust = assign_customers(inv_day, inv_branch, customers, rng)
    print(f"  member invoices       : {(inv_cust >= 0).sum():,} "
          f"({100 * (inv_cust >= 0).mean():.1f}%)")

    # --- time of day ------------------------------------------------------
    dow = dates["dow"].to_numpy()[inv_day]
    is_weekend = dow >= 5
    cdf_wd = np.cumsum(cfg.HOUR_WEIGHTS_WEEKDAY)
    cdf_we = np.cumsum(cfg.HOUR_WEIGHTS_WEEKEND)
    cdf_wd /= cdf_wd[-1]
    cdf_we /= cdf_we[-1]
    u = rng.random(n_invoices)
    hour_pos = np.where(is_weekend,
                        np.searchsorted(cdf_we, u),
                        np.searchsorted(cdf_wd, u))
    inv_hour = np.array(cfg.HOURS)[np.minimum(hour_pos, len(cfg.HOURS) - 1)]
    inv_minute = rng.integers(0, 60, n_invoices)

    # --- baskets ----------------------------------------------------------
    n_lines = rng.choice(basket_sizes, size=n_invoices,
                         p=basket_probs / basket_probs.sum())
    n_rows = int(n_lines.sum())
    print(f"  line items            : {n_rows:,}")

    row_inv = np.repeat(np.arange(n_invoices), n_lines)
    line_no = (np.arange(n_rows)
               - np.repeat(np.cumsum(n_lines) - n_lines, n_lines) + 1)

    row_day = inv_day[row_inv]
    row_branch = inv_branch[row_inv]
    row_year = dates["year"].to_numpy()[row_day]

    # --- product selection with affinity ---------------------------------
    year_cdfs = build_year_sku_cdfs(products)
    base_pick = sample_skus_by_year(row_year, year_cdfs, rng)

    first_of_invoice = base_pick[np.repeat(np.cumsum(n_lines) - n_lines, n_lines)]
    aff_table, aff_counts = build_affinity_table(products)

    is_addon = line_no > 1
    wants_aff = is_addon & (rng.random(n_rows) < cfg.P_AFFINITY_PICK)
    can_aff = aff_counts[first_of_invoice] > 0
    use_aff = wants_aff & can_aff

    slot = (rng.random(n_rows) * np.maximum(aff_counts[first_of_invoice], 1)).astype(np.int64)
    aff_pick = aff_table[first_of_invoice, slot]
    row_sku = np.where(use_aff, aff_pick, base_pick)

    # --- money ------------------------------------------------------------
    years_elapsed = (row_year - cfg.START_DATE.year).astype(float)
    price_jitter = rng.uniform(0.93, 1.07, n_rows)
    unit_price = np.round(
        products["base_price"].to_numpy()[row_sku]
        * (1 + cfg.ANNUAL_INFLATION) ** years_elapsed
        * price_jitter, 2)

    qty_probs = np.array(cfg.QUANTITY_PROBS)
    base_qty = rng.choice(np.arange(1, 11), size=n_rows,
                          p=qty_probs / qty_probs.sum())
    spend_mult = np.where(inv_cust[row_inv] >= 0,
                          customers["spend_mult"].to_numpy()[np.maximum(inv_cust[row_inv], 0)],
                          0.85)
    quantity = np.maximum(1, np.round(base_qty * spend_mult)).astype(np.int64)

    gross_sales = np.round(unit_price * quantity, 2)
    tax_amount = np.round(gross_sales * cfg.TAX_RATE, 4)
    total = np.round(gross_sales + tax_amount, 4)
    margin_pct = products["margin_pct"].to_numpy()[row_sku]
    cogs = np.round(gross_sales * (1 - margin_pct), 2)
    gross_income = np.round(gross_sales - cogs, 4)

    # --- ratings ----------------------------------------------------------
    line_of_sku = products["product_line"].to_numpy()[row_sku]
    offset = pd.Series(line_of_sku).map(cfg.LINE_RATING_OFFSET).to_numpy()
    row_hour = inv_hour[row_inv]
    peak_pen = np.isin(row_hour, list(cfg.PEAK_HOURS)) * cfg.PEAK_HOUR_RATING_PENALTY
    rating = np.round(np.clip(
        rng.normal(cfg.RATING_MEAN + offset + peak_pen, cfg.RATING_SD), 1.0, 10.0), 1)

    # --- payment (with adoption drift) ------------------------------------
    methods = list(cfg.PAYMENT_METHODS.keys())
    pay_idx = np.empty(n_rows, dtype=np.int64)
    for year in range(cfg.START_DATE.year, cfg.END_DATE.year + 1):
        mask = row_year == year
        k = int(mask.sum())
        if not k:
            continue
        elapsed = year - cfg.START_DATE.year
        p = np.array([max(0.02, cfg.PAYMENT_METHODS[m]
                          + cfg.PAYMENT_DRIFT_PER_YEAR[m] * elapsed)
                      for m in methods])
        pay_idx[mask] = rng.choice(len(methods), size=k, p=p / p.sum())

    # --- identifiers ------------------------------------------------------
    perm = rng.permutation(n_invoices)
    inv_num = perm + 100_000_000
    invoice_id = np.array([f"{v // 1_000_000:03d}-{(v // 10_000) % 100:02d}-{v % 10_000:04d}"
                           for v in inv_num])

    day_str = dates["date"].dt.strftime("%Y-%m-%d").to_numpy()
    cust_ids = customers["customer_id"].to_numpy()
    row_cust = inv_cust[row_inv]

    fact = pd.DataFrame({
        "invoice_id": invoice_id[row_inv],
        "line_no": line_no,
        "branch": branches["branch_code"].to_numpy()[row_branch],
        "city": branches["city"].to_numpy()[row_branch],
        "customer_id": np.where(row_cust >= 0,
                                cust_ids[np.maximum(row_cust, 0)], ""),
        "customer_type": np.where(row_cust >= 0, "Member", "Normal"),
        "gender": np.where(
            row_cust >= 0,
            customers["gender"].to_numpy()[np.maximum(row_cust, 0)],
            rng.choice(list(cfg.GENDER_SPLIT.keys()), size=n_rows,
                       p=list(cfg.GENDER_SPLIT.values()))),
        "product_sku": products["sku"].to_numpy()[row_sku],
        "product_line": line_of_sku,
        "product_name": products["product_name"].to_numpy()[row_sku],
        "unit_price": unit_price,
        "quantity": quantity,
        "tax_pct": cfg.TAX_RATE,
        "tax_amount": tax_amount,
        "total": total,
        "date": day_str[row_day],
        "time": [f"{h:02d}:{m:02d}:00" for h, m in zip(row_hour, inv_minute[row_inv])],
        "payment": np.array(methods)[pay_idx],
        "cogs": cogs,
        "gross_margin_pct": np.round(margin_pct * 100, 4),
        "gross_income": gross_income,
        "rating": rating,
    })

    fact = fact.sort_values(["date", "time", "invoice_id", "line_no"],
                            kind="stable").reset_index(drop=True)

    print(f"  generated in {time.time() - t0:.1f}s")
    return {
        "fact": fact,
        "customers": customers[["customer_id", "signup_date", "gender"]].assign(
            home_branch=branches["branch_code"].to_numpy()[customers["home_branch_idx"]],
            home_city=branches["city"].to_numpy()[customers["home_branch_idx"]],
        ),
        "products": products[["sku", "product_line", "product_name",
                              "base_price", "margin_pct"]],
        "branches": branches[["branch_code", "city", "region",
                              "opened_date", "size_factor"]],
    }


# ---------------------------------------------------------------------------
# Data-quality defect injection
# ---------------------------------------------------------------------------

def inject_defects(fact: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    """Dirty the landing file so the staging layer has real work to do."""
    n = len(fact)
    fact = fact.copy()
    for col in ("unit_price", "quantity", "city", "customer_type",
                "payment", "rating", "date"):
        fact[col] = fact[col].astype(object)

    def pick(rate: float) -> np.ndarray:
        return rng.choice(n, size=int(n * rate), replace=False)

    report = {}

    idx = pick(cfg.DEFECT_RATES["null_rating"])
    fact.loc[idx, "rating"] = ""
    report["null_rating"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["negative_quantity"])
    fact.loc[idx, "quantity"] = -fact.loc[idx, "quantity"].astype(int)
    report["negative_quantity"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["messy_city"])
    forms = rng.choice(cfg.MESSY_CITY_FORMS, size=len(idx))
    fact.loc[idx, "city"] = [
        f.format(u=c.upper(), l=c.lower(), t=c)
        for f, c in zip(forms, fact.loc[idx, "city"])
    ]
    report["messy_city"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["invalid_date"])
    bad = rng.choice(["1900-01-01", "2031-07-14", "15/03/2022", ""],
                     size=len(idx), p=[0.3, 0.25, 0.3, 0.15])
    fact.loc[idx, "date"] = bad
    report["invalid_date"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["blank_customer_type"])
    fact.loc[idx, "customer_type"] = rng.choice(["", "NULL", "n/a", "unknown"],
                                                size=len(idx))
    report["blank_customer_type"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["formatted_price"])
    fact.loc[idx, "unit_price"] = [
        f"${v:,.2f}" for v in fact.loc[idx, "unit_price"].astype(float)
    ]
    report["formatted_price"] = len(idx)

    idx = pick(cfg.DEFECT_RATES["messy_payment"])
    fact.loc[idx, "payment"] = [
        rng.choice(cfg.MESSY_PAYMENT_FORMS[p]) for p in fact.loc[idx, "payment"]
    ]
    report["messy_payment"] = len(idx)

    # Exact duplicate rows, appended and re-sorted so they are not adjacent.
    dup_idx = pick(cfg.DEFECT_RATES["duplicate_row"])
    dups = fact.loc[dup_idx].copy()
    fact = pd.concat([fact, dups], ignore_index=True)
    fact = fact.sort_values(["date", "invoice_id", "line_no"],
                            kind="stable").reset_index(drop=True)
    report["duplicate_row"] = len(dups)

    print("  injected defects:")
    for k, v in sorted(report.items(), key=lambda x: -x[1]):
        print(f"    {k:22s} {v:>7,}")
    return fact


# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rows", type=int, default=cfg.TARGET_LINE_ITEMS)
    ap.add_argument("--seed", type=int, default=cfg.SEED)
    args = ap.parse_args()

    out_dir = os.path.join(PROJECT_ROOT, cfg.OUTPUT_DIR)
    os.makedirs(out_dir, exist_ok=True)

    print(f"Generating ~{args.rows:,} line items (seed={args.seed})")
    frames = generate(args.rows, args.seed)

    rng = np.random.default_rng(args.seed + 1)
    fact = inject_defects(frames["fact"], rng)

    targets = [
        (cfg.FACT_FILE, fact),
        (cfg.CUSTOMER_FILE, frames["customers"]),
        (cfg.PRODUCT_FILE, frames["products"]),
        (cfg.BRANCH_FILE, frames["branches"]),
    ]
    for name, df in targets:
        path = os.path.join(out_dir, name)
        df.to_csv(path, index=False)
        size_mb = os.path.getsize(path) / 1e6
        print(f"  wrote {name:20s} {len(df):>9,} rows  {size_mb:>7.1f} MB")

    print(f"\nOutput: {out_dir}")


if __name__ == "__main__":
    main()
