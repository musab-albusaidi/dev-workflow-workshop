"""Orders pipeline: bronze -> silver -> gold.

The SAME code runs in every environment (dev, uat, prod). Only configuration
changes between them: which database the pipeline writes to.

Each stage lives in its own module under ``etl/``:

    etl/source.py   the raw orders, as received
    etl/config.py   ENV and DATABASE_URL
    etl/bronze.py   land the raw data untouched
    etl/silver.py   clean, type, deduplicate
    etl/gold.py     business-ready tables
    etl/quality.py  data quality rules
    etl/load.py     write every layer to Postgres

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

import pandas as pd

from etl.bronze import bronze
from etl.config import load_config
from etl.gold import gold
from etl.load import write_to_postgres
from etl.quality import DataQualityError, check_quality
from etl.silver import silver

log = logging.getLogger("pipeline")


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

    write_to_postgres(url, raw, orders, tables)
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
