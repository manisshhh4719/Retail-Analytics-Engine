"""
Sanity-check the generated dataset before it goes anywhere near the warehouse.

Every claim the project makes in its README has to be recoverable from the data
by a query. This script reads the dirty landing file, applies the same cleaning
the SQL staging layer will apply, and confirms each engineered signal is
present and large enough to be worth reporting.

Usage:
    python src/validate_generation.py
"""

from __future__ import annotations

import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as cfg  # noqa: E402

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANDING = os.path.join(PROJECT_ROOT, cfg.OUTPUT_DIR, cfg.FACT_FILE)

results: list[tuple[str, bool, str]] = []


def check(name: str, passed: bool, detail: str) -> None:
    results.append((name, passed, detail))


def load_clean() -> tuple[pd.DataFrame, dict]:
    raw = pd.read_csv(LANDING, dtype=str, keep_default_na=False)
    stats = {"raw_rows": len(raw)}

    # Count rows carrying at least one defect. Most defects are repaired by the
    # staging layer rather than rejected, so this is not the same as the share
    # of rows that get dropped.
    dup = raw.duplicated(subset=["invoice_id", "line_no"], keep="first")
    dirty = (
        dup
        | (raw["rating"] == "")
        | raw["quantity"].str.startswith("-")
        | (raw["city"] != raw["city"].str.strip().str.title())
        | ~raw["customer_type"].isin(["Member", "Normal"])
        | raw["unit_price"].str.contains(r"[$,]", regex=True)
        | ~raw["payment"].isin(["Ewallet", "Credit card", "Cash"])
        | ~raw["date"].str.match(r"^\d{4}-\d{2}-\d{2}$")
    )
    stats["dirty_rows"] = int(dirty.sum())

    df = raw.drop_duplicates(subset=["invoice_id", "line_no"], keep="first").copy()
    stats["after_dedupe"] = len(df)

    df["date"] = pd.to_datetime(df["date"], format="%Y-%m-%d", errors="coerce")
    df["unit_price"] = pd.to_numeric(
        df["unit_price"].str.replace(r"[$,]", "", regex=True), errors="coerce")
    df["quantity"] = pd.to_numeric(df["quantity"], errors="coerce")
    for c in ("total", "cogs", "gross_income", "tax_amount"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["rating"] = pd.to_numeric(df["rating"], errors="coerce")
    df["city"] = df["city"].str.strip().str.title()
    df["payment"] = (df["payment"].str.strip().str.lower()
                     .replace({"e-wallet": "ewallet", "e wallet": "ewallet",
                               "creditcard": "credit card"}).str.title())

    valid = (
        df["date"].notna()
        & df["date"].between(pd.Timestamp(cfg.START_DATE), pd.Timestamp(cfg.END_DATE))
        & (df["quantity"] > 0)
        & df["unit_price"].notna()
    )
    stats["rejected"] = int((~valid).sum())
    df = df[valid].copy()
    stats["clean_rows"] = len(df)

    df["year"] = df["date"].dt.year
    df["month"] = df["date"].dt.month
    df["hour"] = df["time"].str.slice(0, 2).astype(int)
    return df, stats


def main() -> None:
    if not os.path.exists(LANDING):
        sys.exit(f"Missing {LANDING} - run src/generate_data.py first")

    print("Loading and cleaning landing file...\n")
    df, stats = load_clean()

    defect_rate = stats["dirty_rows"] / stats["raw_rows"]
    reject_rate = 1 - stats["clean_rows"] / stats["raw_rows"]
    print(f"  raw rows          {stats['raw_rows']:>10,}")
    print(f"  rows w/ defect    {stats['dirty_rows']:>10,}  ({defect_rate:.2%})")
    print(f"  after dedupe      {stats['after_dedupe']:>10,}")
    print(f"  rejected outright {stats['rejected']:>10,}  ({reject_rate:.2%})")
    print(f"  clean rows        {stats['clean_rows']:>10,}\n")
    check("defect rate in 3-6% band", 0.03 <= defect_rate <= 0.06,
          f"{defect_rate:.2%}")

    # --- growth -----------------------------------------------------------
    yearly = df.groupby("year")["total"].sum()
    yoy = yearly.pct_change().dropna()
    print("Revenue by year")
    for y, v in yearly.items():
        g = f"{yoy[y]:+7.1%}" if y in yoy.index else "      -"
        print(f"  {y}   ${v:>14,.0f}   {g}")
    print()
    cagr = (yearly.iloc[-1] / yearly.iloc[0]) ** (1 / (len(yearly) - 1)) - 1
    check("multi-year CAGR > 15%", cagr > 0.15, f"CAGR {cagr:.1%}")
    check("2020 COVID dip present", yoy.get(2020, 1) < 0.05,
          f"2020 YoY {yoy.get(2020, float('nan')):.1%}")
    check("2021 rebound present", yoy.get(2021, 0) > 0.15,
          f"2021 YoY {yoy.get(2021, float('nan')):.1%}")

    # --- seasonality ------------------------------------------------------
    monthly = df.groupby("month")["total"].sum()
    idx = monthly / monthly.mean()
    q4 = idx.loc[[11, 12]].mean()
    check("Q4 seasonal peak", q4 > 1.20, f"Nov-Dec index {q4:.2f}")

    dow = df.assign(d=df["date"].dt.dayofweek).groupby("d")["total"].sum()
    dow_idx = dow / dow.mean()
    check("weekend lift", dow_idx.loc[[5, 6]].mean() > 1.15,
          f"Sat-Sun index {dow_idx.loc[[5, 6]].mean():.2f}")

    # --- category mix shift ----------------------------------------------
    mix = (df.pivot_table(index="year", columns="product_line",
                          values="total", aggfunc="sum")
             .pipe(lambda x: x.div(x.sum(axis=1), axis=0)))
    ele = mix["Electronic accessories"]
    hom = mix["Home and lifestyle"]
    print("Category mix shift 2019 -> 2024")
    print(f"  Electronic accessories  {ele.iloc[0]:.1%} -> {ele.iloc[-1]:.1%}")
    print(f"  Home and lifestyle      {hom.iloc[0]:.1%} -> {hom.iloc[-1]:.1%}\n")
    check("electronics gaining share", ele.iloc[-1] - ele.iloc[0] > 0.04,
          f"{(ele.iloc[-1] - ele.iloc[0]):+.1%}")
    check("home losing share", hom.iloc[-1] - hom.iloc[0] < -0.03,
          f"{(hom.iloc[-1] - hom.iloc[0]):+.1%}")

    # --- customer behaviour ----------------------------------------------
    members = df[df["customer_id"] != ""]
    per_cust = members.groupby("customer_id").agg(
        orders=("invoice_id", "nunique"), spend=("total", "sum"))
    repeat = (per_cust["orders"] > 1).mean()
    top20 = (per_cust["spend"].nlargest(int(len(per_cust) * 0.2)).sum()
             / per_cust["spend"].sum())
    print(f"Members with a purchase   {len(per_cust):,}")
    print(f"  repeat-purchase rate    {repeat:.1%}")
    print(f"  top 20% share of spend  {top20:.1%}")
    print(f"  orders p50 / p90 / max  {per_cust['orders'].median():.0f} / "
          f"{per_cust['orders'].quantile(0.9):.0f} / {per_cust['orders'].max():.0f}\n")
    check("repeat-purchase rate > 55%", repeat > 0.55, f"{repeat:.1%}")
    check("spend concentration (top 20% > 40%)", top20 > 0.40, f"{top20:.1%}")

    # --- peak hour / rating trade-off ------------------------------------
    hourly = df.groupby("hour").agg(rev=("total", "sum"),
                                    rating=("rating", "mean"))
    peak = hourly.loc[sorted(cfg.PEAK_HOURS), "rating"].mean()
    off = hourly.loc[[h for h in hourly.index if h not in cfg.PEAK_HOURS],
                     "rating"].mean()
    peak_rev = hourly.loc[sorted(cfg.PEAK_HOURS), "rev"].sum() / hourly["rev"].sum()
    print(f"Peak hours {sorted(cfg.PEAK_HOURS)}: {peak_rev:.1%} of revenue, "
          f"rating {peak:.2f} vs {off:.2f} off-peak\n")
    check("peak-hour rating penalty visible", off - peak > 0.25,
          f"{off - peak:.2f} pts")

    # --- market basket affinity ------------------------------------------
    baskets = df.groupby("invoice_id")["product_sku"].apply(set)
    multi = baskets[baskets.map(len) > 1]
    a, b = cfg.AFFINITY_PAIRS[0]
    both = multi.map(lambda s: a in s and b in s).mean()
    pa = multi.map(lambda s: a in s).mean()
    pb = multi.map(lambda s: b in s).mean()
    lift = both / (pa * pb) if pa and pb else 0
    print(f"Affinity check {a} + {b}: support {both:.4f}, lift {lift:.2f}\n")
    check("known affinity pair shows lift > 2", lift > 2.0, f"lift {lift:.2f}")

    # --- margin spread ----------------------------------------------------
    marg = (df.groupby("product_line")
              .apply(lambda g: g["gross_income"].sum()
                     / (g["total"].sum() / (1 + cfg.TAX_RATE)),
                     include_groups=False)
              .sort_values())
    print("Gross margin by product line")
    for k, v in marg.items():
        print(f"  {k:26s} {v:6.1%}")
    print()
    check("margin spread across lines > 15pts",
          marg.max() - marg.min() > 0.15,
          f"{(marg.max() - marg.min()) * 100:.1f} pts")

    # --- headline numbers -------------------------------------------------
    print("=" * 62)
    print("HEADLINE FIGURES")
    print("=" * 62)
    print(f"  transactions (line items) {stats['clean_rows']:>14,}")
    print(f"  invoices                  {df['invoice_id'].nunique():>14,}")
    print(f"  customers                 {len(per_cust):>14,}")
    print(f"  branches / cities         "
          f"{df['branch'].nunique():>6} / {df['city'].nunique():<6}")
    print(f"  date range                "
          f"{df['date'].min():%Y-%m-%d} to {df['date'].max():%Y-%m-%d}")
    print(f"  total revenue             ${df['total'].sum():>13,.0f}")
    print(f"  gross profit              ${df['gross_income'].sum():>13,.0f}")
    print(f"  avg basket value          ${df.groupby('invoice_id')['total'].sum().mean():>13,.2f}")
    print(f"  revenue CAGR              {cagr:>13.1%}")

    print("\n" + "=" * 62)
    print("VALIDATION")
    print("=" * 62)
    failed = 0
    for name, passed, detail in results:
        flag = "PASS" if passed else "FAIL"
        if not passed:
            failed += 1
        print(f"  [{flag}] {name:38s} {detail}")
    print(f"\n{len(results) - failed}/{len(results)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
