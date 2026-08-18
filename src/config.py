"""
Configuration for the Walmart retail analytics dataset generator.

Everything that shapes the simulated data lives here so the generation logic in
generate_data.py stays readable. Price levels, product-line margins and rating
behaviour are calibrated against the 1,000-row Kaggle sample in
data/raw/walmart_source_sample.csv.
"""

from datetime import date

# ---------------------------------------------------------------------------
# Run parameters
# ---------------------------------------------------------------------------

SEED = 20190101
TARGET_LINE_ITEMS = 1_200_000

START_DATE = date(2019, 1, 1)
END_DATE = date(2024, 12, 31)

N_CUSTOMERS = 40_000

# Share of invoices that *attempt* to attach a loyalty member. Attempts against
# a churned customer fall through to an anonymous walk-in, so the realised
# member share lands below this figure.
P_MEMBER_ATTEMPT = 0.72

TAX_RATE = 0.05

# ---------------------------------------------------------------------------
# Store network
#
# The three branches from the source sample (A/B/C) open on day one. The rest
# are opened in waves, so revenue growth decomposes into like-for-like growth
# plus growth from new-store expansion.
# ---------------------------------------------------------------------------

# 14 branches trade from day one; 6 open across the period. That split keeps
# like-for-like growth as the dominant driver while still leaving a real
# new-store contribution for the growth-decomposition analysis to separate out.
BRANCHES = [
    # code, city, region, opened, size_factor
    ("A",  "Yangon",     "Yangon",     date(2019, 1, 1), 1.00),
    ("B",  "Mandalay",   "Mandalay",   date(2019, 1, 1), 0.98),
    ("C",  "Naypyitaw",  "Naypyitaw",  date(2019, 1, 1), 1.02),
    ("D",  "Yangon",     "Yangon",     date(2019, 1, 1), 0.92),
    ("E",  "Yangon",     "Yangon",     date(2019, 1, 1), 1.10),
    ("F",  "Mandalay",   "Mandalay",   date(2019, 1, 1), 0.85),
    ("G",  "Bago",       "Bago",       date(2019, 1, 1), 0.78),
    ("H",  "Naypyitaw",  "Naypyitaw",  date(2019, 1, 1), 0.88),
    ("I",  "Taunggyi",   "Shan",       date(2019, 1, 1), 0.72),
    ("J",  "Yangon",     "Yangon",     date(2019, 1, 1), 1.15),
    ("K",  "Mandalay",   "Mandalay",   date(2019, 1, 1), 0.95),
    ("L",  "Bago",       "Bago",       date(2019, 1, 1), 0.80),
    ("M",  "Yangon",     "Yangon",     date(2019, 1, 1), 1.05),
    ("N",  "Taunggyi",   "Shan",       date(2019, 1, 1), 0.75),
    ("O",  "Naypyitaw",  "Naypyitaw",  date(2020, 6, 1), 0.90),
    ("P",  "Mandalay",   "Mandalay",   date(2021, 3, 1), 1.00),
    ("Q",  "Yangon",     "Yangon",     date(2021, 9, 1), 1.20),
    ("R",  "Bago",       "Bago",       date(2022, 5, 1), 0.82),
    ("S",  "Shan",       "Shan",       date(2023, 3, 1), 0.86),
    ("T",  "Naypyitaw",  "Naypyitaw",  date(2024, 2, 1), 0.94),
]

# Months a new branch takes to ramp from 55% to full productivity.
RAMP_MONTHS = 6

# ---------------------------------------------------------------------------
# Demand curve
# ---------------------------------------------------------------------------

# Compounding like-for-like growth per year.
ANNUAL_GROWTH = 0.12

# COVID-19 demand shock: (start, end, multiplier at trough).
COVID_START = date(2020, 3, 15)
COVID_TROUGH = date(2020, 5, 1)
COVID_RECOVERED = date(2020, 12, 31)
COVID_TROUGH_MULTIPLIER = 0.52

# Month-of-year seasonality (index 0 = January).
MONTH_SEASONALITY = [
    0.94, 0.88, 0.96, 0.98, 1.00, 0.97,
    0.99, 1.01, 0.98, 1.06, 1.28, 1.35,
]

# Day-of-week factor (index 0 = Monday).
DOW_FACTOR = [0.82, 0.88, 0.92, 0.97, 1.18, 1.42, 1.24]

# Recurring promotional events: (month, day, span_days, uplift).
PROMO_EVENTS = [
    (11, 24, 4, 1.85),   # Black Friday weekend
    (12, 26, 6, 1.45),   # Boxing-week clearance
    (1, 2, 5, 1.30),     # New-year clearance
    (4, 13, 5, 1.40),    # Thingyan new-year festival
    (7, 7, 3, 1.25),     # Mid-year sale
]

# Random daily noise (lognormal sigma).
DAILY_NOISE_SIGMA = 0.13

# Baseline invoices per branch per day at index 1.0.
BASE_INVOICES_PER_DAY = 46

# ---------------------------------------------------------------------------
# Hour-of-day traffic profile (store hours 10:00-20:59)
# ---------------------------------------------------------------------------

HOURS = list(range(10, 21))
HOUR_WEIGHTS_WEEKDAY = [0.070, 0.075, 0.082, 0.105, 0.098, 0.088,
                        0.080, 0.085, 0.110, 0.125, 0.082]
HOUR_WEIGHTS_WEEKEND = [0.090, 0.100, 0.110, 0.115, 0.100, 0.085,
                        0.078, 0.080, 0.095, 0.093, 0.054]

# ---------------------------------------------------------------------------
# Product catalogue
#
# sku -> (product_line, product_name, base_unit_price, popularity_weight)
# Base prices sit in the same 10-100 band as the source sample.
# ---------------------------------------------------------------------------

PRODUCTS = {
    # Electronic accessories
    "ELE-001": ("Electronic accessories", "Wireless Earbuds",        62.40, 1.35),
    "ELE-002": ("Electronic accessories", "Phone Charger 20W",       18.90, 1.55),
    "ELE-003": ("Electronic accessories", "Power Bank 10000mAh",     34.50, 1.20),
    "ELE-004": ("Electronic accessories", "USB-C Cable 2m",          11.25, 1.60),
    "ELE-005": ("Electronic accessories", "Bluetooth Speaker",       48.80, 0.95),
    "ELE-006": ("Electronic accessories", "Phone Case",              15.60, 1.30),
    # Fashion accessories
    "FAS-001": ("Fashion accessories",    "Leather Wallet",          39.90, 1.15),
    "FAS-002": ("Fashion accessories",    "Sunglasses",              52.30, 1.05),
    "FAS-003": ("Fashion accessories",    "Wristwatch",              88.50, 0.70),
    "FAS-004": ("Fashion accessories",    "Silk Scarf",              33.40, 0.85),
    "FAS-005": ("Fashion accessories",    "Handbag",                 76.20, 0.80),
    # Food and beverages
    "FNB-001": ("Food and beverages",     "Ground Coffee 500g",      21.70, 1.70),
    "FNB-002": ("Food and beverages",     "Green Tea Pack",          14.30, 1.50),
    "FNB-003": ("Food and beverages",     "Chocolate Assortment",    26.80, 1.45),
    "FNB-004": ("Food and beverages",     "Olive Oil 1L",            31.20, 1.00),
    "FNB-005": ("Food and beverages",     "Snack Variety Box",       19.60, 1.40),
    # Health and beauty
    "HAB-001": ("Health and beauty",      "Facial Cleanser",         24.90, 1.30),
    "HAB-002": ("Health and beauty",      "Vitamin C Serum",         45.60, 1.00),
    "HAB-003": ("Health and beauty",      "Shampoo 750ml",           17.40, 1.35),
    "HAB-004": ("Health and beauty",      "Sunscreen SPF50",         28.30, 1.10),
    "HAB-005": ("Health and beauty",      "Electric Toothbrush",     71.50, 0.65),
    # Home and lifestyle
    "HOM-001": ("Home and lifestyle",     "Bed Sheet Set",           68.40, 0.90),
    "HOM-002": ("Home and lifestyle",     "Ceramic Dinnerware Set",  82.10, 0.62),
    "HOM-003": ("Home and lifestyle",     "Table Lamp",              41.30, 0.88),
    "HOM-004": ("Home and lifestyle",     "Storage Bins x4",         29.70, 1.05),
    "HOM-005": ("Home and lifestyle",     "Scented Candle Set",      22.50, 1.25),
    # Sports and travel
    "SPT-001": ("Sports and travel",      "Yoga Mat",                27.80, 1.20),
    "SPT-002": ("Sports and travel",      "Running Shoes",           94.60, 0.75),
    "SPT-003": ("Sports and travel",      "Travel Backpack",         58.90, 0.95),
    "SPT-004": ("Sports and travel",      "Water Bottle 1L",         16.40, 1.50),
    "SPT-005": ("Sports and travel",      "Resistance Band Set",     20.30, 1.10),
    "SPT-006": ("Sports and travel",      "Luggage 24in",            98.70, 0.55),
}

# Gross margin by product line, plus per-SKU jitter applied at generation time.
LINE_MARGIN = {
    "Electronic accessories": 0.18,
    "Fashion accessories":    0.34,
    "Food and beverages":     0.12,
    "Health and beauty":      0.29,
    "Home and lifestyle":     0.23,
    "Sports and travel":      0.26,
}

# Product-line share of transactions by year. Electronics gains, Home declines
# so category-mix analysis has a real trend to surface.
LINE_MIX_BY_YEAR = {
    2019: {"Electronic accessories": 0.158, "Fashion accessories": 0.171,
           "Food and beverages": 0.176, "Health and beauty": 0.152,
           "Home and lifestyle": 0.180, "Sports and travel": 0.163},
    2020: {"Electronic accessories": 0.183, "Fashion accessories": 0.152,
           "Food and beverages": 0.205, "Health and beauty": 0.168,
           "Home and lifestyle": 0.172, "Sports and travel": 0.120},
    2021: {"Electronic accessories": 0.201, "Fashion accessories": 0.158,
           "Food and beverages": 0.191, "Health and beauty": 0.170,
           "Home and lifestyle": 0.160, "Sports and travel": 0.120},
    2022: {"Electronic accessories": 0.219, "Fashion accessories": 0.166,
           "Food and beverages": 0.182, "Health and beauty": 0.168,
           "Home and lifestyle": 0.147, "Sports and travel": 0.118},
    2023: {"Electronic accessories": 0.238, "Fashion accessories": 0.172,
           "Food and beverages": 0.175, "Health and beauty": 0.165,
           "Home and lifestyle": 0.133, "Sports and travel": 0.117},
    2024: {"Electronic accessories": 0.259, "Fashion accessories": 0.176,
           "Food and beverages": 0.169, "Health and beauty": 0.162,
           "Home and lifestyle": 0.119, "Sports and travel": 0.115},
}

# Annual price inflation applied to base_unit_price.
ANNUAL_INFLATION = 0.031

# ---------------------------------------------------------------------------
# Basket structure
# ---------------------------------------------------------------------------

# Number of line items per invoice.
BASKET_SIZE_PROBS = {1: 0.44, 2: 0.28, 3: 0.17, 4: 0.08, 5: 0.03}

# Probability that an add-on line is drawn from the first item's affinity list
# rather than the general category mix. This is the signal market-basket
# analysis is meant to recover.
P_AFFINITY_PICK = 0.55

# Frequently-bought-together relationships.
AFFINITY_PAIRS = [
    ("ELE-001", "ELE-003"), ("ELE-001", "ELE-002"), ("ELE-002", "ELE-004"),
    ("ELE-002", "ELE-003"), ("ELE-005", "ELE-001"), ("ELE-006", "ELE-004"),
    ("FAS-001", "FAS-002"), ("FAS-003", "FAS-002"), ("FAS-005", "FAS-001"),
    ("FNB-001", "FNB-003"), ("FNB-002", "FNB-003"), ("FNB-004", "FNB-005"),
    ("HAB-001", "HAB-002"), ("HAB-003", "HAB-004"), ("HAB-001", "HAB-004"),
    ("HOM-001", "HOM-005"), ("HOM-002", "HOM-005"), ("HOM-003", "HOM-001"),
    ("SPT-001", "SPT-005"), ("SPT-002", "SPT-004"), ("SPT-003", "SPT-006"),
    ("SPT-003", "SPT-004"),
    # Cross-category pairs - the interesting findings.
    ("SPT-002", "HAB-003"), ("SPT-003", "ELE-003"), ("FAS-005", "FAS-002"),
    ("FNB-001", "HOM-005"), ("SPT-001", "HAB-004"), ("ELE-001", "SPT-004"),
]

# Quantity distribution (1-10, front-loaded).
QUANTITY_PROBS = [0.26, 0.21, 0.15, 0.11, 0.09, 0.07, 0.05, 0.03, 0.02, 0.01]

# ---------------------------------------------------------------------------
# Customer segments
#
# weight     -> relative purchase propensity (drives RFM frequency spread)
# life_days  -> active lifetime before churn (mean of an exponential draw)
# spend_mult -> multiplier on basket value (drives CLV spread)
# ---------------------------------------------------------------------------

CUSTOMER_SEGMENTS = {
    #                share  weight  life_days  spend_mult
    "loyal":        (0.09,  7.0,    1500,      1.55),
    "regular":      (0.24,  3.0,     900,      1.15),
    "occasional":   (0.38,  1.0,     500,      0.92),
    "one_time":     (0.29,  0.30,    120,      0.80),
}

GENDER_SPLIT = {"Female": 0.501, "Male": 0.499}

PAYMENT_METHODS = {"Ewallet": 0.38, "Credit card": 0.34, "Cash": 0.28}

# E-wallet adoption climbs over the period; cash declines.
PAYMENT_DRIFT_PER_YEAR = {"Ewallet": 0.022, "Credit card": 0.004, "Cash": -0.026}

# ---------------------------------------------------------------------------
# Ratings (1-10, matching the source sample's scale and ~7.0 mean)
# ---------------------------------------------------------------------------

RATING_MEAN = 6.98
RATING_SD = 1.72
# Per-line rating offsets, so satisfaction differs by category.
LINE_RATING_OFFSET = {
    "Electronic accessories": -0.05,
    "Fashion accessories":     0.10,
    "Food and beverages":      0.22,
    "Health and beauty":       0.02,
    "Home and lifestyle":     -0.18,
    "Sports and travel":      -0.11,
}
# Service quality dips when the store is busy - gives the ops analysis a real
# staffing insight to find.
PEAK_HOUR_RATING_PENALTY = -0.45
PEAK_HOURS = {18, 19, 20}

# ---------------------------------------------------------------------------
# Data-quality defects deliberately injected into the raw landing file.
# Total ~4.0% of rows carry at least one defect.
# ---------------------------------------------------------------------------

DEFECT_RATES = {
    "duplicate_row":       0.0080,
    "null_rating":         0.0070,
    "negative_quantity":   0.0040,
    "messy_city":          0.0060,
    "invalid_date":        0.0030,
    "blank_customer_type": 0.0050,
    "formatted_price":     0.0040,
    "messy_payment":       0.0030,
}

MESSY_CITY_FORMS = ["{u}", " {t} ", "{l}", "{t}  ", "  {u}"]
MESSY_PAYMENT_FORMS = {
    "Ewallet":     ["ewallet", "E-Wallet", "EWALLET", "e wallet"],
    "Credit card": ["credit card", "CREDIT CARD", "Credit Card", "creditcard"],
    "Cash": ["cash", "CASH", "Cash "],
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

OUTPUT_DIR = "data/generated"
FACT_FILE = "sales_landing.csv"
CUSTOMER_FILE = "customers.csv"
PRODUCT_FILE = "products.csv"
BRANCH_FILE = "branches.csv"
