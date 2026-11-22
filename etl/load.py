"""Load: write every layer to Postgres (full refresh)."""

from __future__ import annotations

import logging

import pandas as pd

log = logging.getLogger("pipeline")


def write_to_postgres(
    url: str,
    raw: pd.DataFrame,
    orders: pd.DataFrame,
    tables: dict[str, pd.DataFrame],
) -> None:
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
