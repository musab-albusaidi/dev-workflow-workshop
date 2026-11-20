"""Orders pipeline: bronze -> silver -> gold.

The SAME code runs in every environment (dev, uat, prod). Only configuration
changes between them: which database the pipeline writes to.

Configuration is read from environment variables, falling back to the
environment folder's ``.env`` file (one level above the deployed ``app/``):

    ENV=uat
    DATABASE_URL=postgresql+psycopg://user:password@localhost:5434/warehouse

Usage:
    python pipeline.py            # run and write bronze/silver/gold to Postgres
    python pipeline.py --dry-run  # run in memory only (used as the deploy smoke test)
"""

from __future__ import annotations

import argparse
import logging
import os
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd

log = logging.getLogger("pipeline")

RAW_COLUMNS = [
    "order_id",
    "customer",
    "country",
    "product",
    "qty",
    "unit_price",
    "order_date",
    "status",
]

# A small, deliberately messy dataset, as if it arrived from a CSV export.
# Every value is a string. The comments mark what silver has to fix.
RAW_ORDERS = [
    ("1001", "alice", "Oman", "laptop", "1", "1200.00", "2026-01-05", "completed"),
    ("1002", "Bob", " oman ", "Mouse", "2", "25.50", "2026-01-07", "COMPLETED"),  # whitespace/case
    ("1003", "carol", "UAE", "Monitor", "1", "300", "2026-01-10", "completed"),
    ("1002", "Bob", " oman ", "Mouse", "2", "25.50", "2026-01-07", "COMPLETED"),  # duplicate
    ("1004", "dave", "uae", "Keyboard", "3", "45", "2026-01-15", "Completed"),
    ("1005", None, "Oman", "Mouse", "1", "25.50", "2026-01-18", "completed"),  # no customer
    ("1006", "alice", "OMAN", "Monitor", "2", "300", "2026-02-02", "completed"),
    ("1007", "eve", "Qatar", "Laptop", "1", "1150", "2026-02-03", "cancelled"),  # not revenue
    ("1008", "bob", "Oman", "Keyboard", "-1", "45", "2026-02-05", "completed"),  # negative qty
    ("1009", "frank", "Qatar", "Mouse", "4", "25.50", "not-a-date", "completed"),  # bad date
    ("1010", "carol", "UAE ", "Laptop", "1", "1200", "2026-02-11", "completed"),
    ("1011", "eve", "qatar", "Monitor", "1", "300", "2026-02-14", "completed"),
    ("1012", "dave", "UAE", "Mouse", "2", "25.50", "2026-02-20", "pending"),  # not revenue
    ("1013", "grace", "Oman", "Laptop", "1", "1200", "2026-03-01", "completed"),
    ("1010", "carol", "UAE ", "Laptop", "1", "1200", "2026-02-11", "completed"),  # duplicate
    ("1014", "alice", "oman", "mouse", "3", "25.50", "2026-03-03", "completed"),
    ("1015", "frank", "Qatar", "Keyboard", "2", "45", "2026-03-08", "completed"),
    ("1016", "Bob", "Oman", "Monitor", "two", "300", "2026-03-12", "completed"),  # qty not a number
    ("1017", "carol", "UAE", "Keyboard", "1", "45", "2026-03-20", "completed"),
    ("1013", "grace", "Oman", "Laptop", "1", "1200", "2026-03-01", "completed"),  # duplicate
]


class DataQualityError(Exception):
    """Raised when the data breaks a rule the business relies on."""


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
def load_config() -> dict[str, str]:
    """Read ENV and DATABASE_URL from ../.env, then let real env vars override."""
    config: dict[str, str] = {}
    env_file = Path(__file__).resolve().parent.parent / ".env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip().strip("'\"")
    for key in ("ENV", "DATABASE_URL"):
        if key in os.environ:
            config[key] = os.environ[key]
    config.setdefault("ENV", "local")
    return config


# --------------------------------------------------------------------------- #
# Bronze: land the raw data exactly as received, plus load metadata
# --------------------------------------------------------------------------- #
def bronze(env: str = "local") -> pd.DataFrame:
    df = pd.DataFrame(RAW_ORDERS, columns=RAW_COLUMNS, dtype=object)
    df["_ingested_at"] = datetime.now(UTC).isoformat(timespec="seconds")
    df["_env"] = env
    return df


# --------------------------------------------------------------------------- #
# Silver: clean, type, deduplicate. One row per valid order.
# --------------------------------------------------------------------------- #
def silver(raw: pd.DataFrame) -> pd.DataFrame:
    df = raw[RAW_COLUMNS].copy()

    # Normalise text: trim whitespace and make casing consistent.
    for col in ("customer", "country", "product", "status"):
        df[col] = df[col].str.strip()
    df["customer"] = df["customer"].str.title()
    df["country"] = df["country"].str.upper()
    df["product"] = df["product"].str.title()
    df["status"] = df["status"].str.lower()

    # Cast to real types. Anything that can't be parsed becomes null...
    df["order_id"] = pd.to_numeric(df["order_id"], errors="coerce")
    df["qty"] = pd.to_numeric(df["qty"], errors="coerce")
    df["unit_price"] = pd.to_numeric(df["unit_price"], errors="coerce")
    df["order_date"] = pd.to_datetime(df["order_date"], format="%Y-%m-%d", errors="coerce")

    # ...and is then dropped, along with rows that make no business sense.
    df = df.dropna(subset=RAW_COLUMNS)
    df = df[df["qty"] > 0]

    # The same order can arrive more than once. Keep one row per order_id.
    df = df.drop_duplicates(subset="order_id", keep="first")

    df = df.astype({"order_id": "int64", "qty": "int64", "unit_price": "float64"})
    df["revenue"] = (df["qty"] * df["unit_price"]).round(2)
    return df.sort_values("order_id").reset_index(drop=True)


# --------------------------------------------------------------------------- #
# Gold: business-ready tables. Only completed orders count as revenue.
# --------------------------------------------------------------------------- #
def gold(orders: pd.DataFrame) -> dict[str, pd.DataFrame]:
    completed = orders[orders["status"] == "completed"].copy()
    completed["order_month"] = completed["order_date"].dt.strftime("%Y-%m")

    sales = completed.groupby(["order_month", "country"], as_index=False).agg(
        revenue=("revenue", "sum"),
        orders=("order_id", "count"),
        units=("qty", "sum"),
    )
    sales["revenue"] = sales["revenue"].round(2)
    sales["avg_order_value"] = (sales["revenue"] / sales["orders"]).round(2)

    customers = completed.groupby("customer", as_index=False).agg(
        lifetime_value=("revenue", "sum"),
        order_count=("order_id", "count"),
        first_order=("order_date", "min"),
        last_order=("order_date", "max"),
    )
    customers["lifetime_value"] = customers["lifetime_value"].round(2)
    customers = customers.sort_values("lifetime_value", ascending=False).reset_index(drop=True)

    return {"sales_by_country_month": sales, "customer_summary": customers}


# --------------------------------------------------------------------------- #
# Data quality: rules checked on every run, in every environment
# --------------------------------------------------------------------------- #
def check_quality(orders: pd.DataFrame, tables: dict[str, pd.DataFrame]) -> None:
    problems = []
    if orders["order_id"].duplicated().any():
        problems.append("silver.orders has duplicate order_id values")
    if orders[RAW_COLUMNS].isna().any().any():
        problems.append("silver.orders has nulls in required columns")
    if (orders["revenue"] < 0).any():
        problems.append("silver.orders has negative revenue")
    for name, table in tables.items():
        if table.empty:
            problems.append(f"gold.{name} is empty")

    sales_total = round(tables["sales_by_country_month"]["revenue"].sum(), 2)
    customer_total = round(tables["customer_summary"]["lifetime_value"].sum(), 2)
    if sales_total != customer_total:
        problems.append(
            f"gold tables disagree on total revenue ({sales_total} vs {customer_total})"
        )

    if problems:
        raise DataQualityError("; ".join(problems))


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
def run(config: dict[str, str], dry_run: bool = False) -> dict[str, pd.DataFrame]:
    env = config.get("ENV", "local")
    log.info("========== ENV=%s | dry_run=%s ==========", env.upper(), dry_run)

    raw = bronze(env)
    orders = silver(raw)
    tables = gold(orders)
    check_quality(orders, tables)

    log.info("bronze.orders_raw: %d rows", len(raw))
    log.info("silver.orders: %d rows", len(orders))
    for name, table in tables.items():
        log.info("gold.%s: %d rows", name, len(table))
    total = tables["sales_by_country_month"]["revenue"].sum()
    log.info("total completed revenue: %.2f", total)

    if dry_run:
        log.info("dry run: nothing written to the database")
        return tables

    url = config.get("DATABASE_URL")
    if not url:
        raise SystemExit("DATABASE_URL is not set (env var or ../.env)")

    from sqlalchemy import create_engine, text

    engine = create_engine(url)
    with engine.begin() as conn:
        for schema in ("bronze", "silver", "gold"):
            conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema}"))
        raw.to_sql("orders_raw", conn, schema="bronze", if_exists="replace", index=False)
        orders.to_sql("orders", conn, schema="silver", if_exists="replace", index=False)
        for name, table in tables.items():
            table.to_sql(name, conn, schema="gold", if_exists="replace", index=False)
    engine.dispose()
    log.info("written to %s", engine.url.render_as_string(hide_password=True))
    return tables


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Orders pipeline: bronze -> silver -> gold")
    parser.add_argument("--dry-run", action="store_true", help="run in memory, write nothing")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        run(load_config(), dry_run=args.dry_run)
    except DataQualityError as exc:
        log.error("DATA QUALITY FAILED: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
