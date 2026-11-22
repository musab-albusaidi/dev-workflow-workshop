"""Silver: clean, type, deduplicate. One row per valid order."""

from __future__ import annotations

import pandas as pd

from etl.source import RAW_COLUMNS


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
