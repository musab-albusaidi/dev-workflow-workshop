"""Data quality: rules checked on every run, in every environment."""

from __future__ import annotations

import pandas as pd

from etl.source import RAW_COLUMNS


class DataQualityError(Exception):
    """Raised when the data breaks a rule the business relies on."""


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
