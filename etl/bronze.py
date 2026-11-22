"""Bronze: land the raw data exactly as received, plus load metadata."""

from __future__ import annotations

from datetime import UTC, datetime

import pandas as pd

from etl.source import RAW_COLUMNS, RAW_ORDERS


def bronze(env: str = "local") -> pd.DataFrame:
    df = pd.DataFrame(RAW_ORDERS, columns=RAW_COLUMNS, dtype=object)
    df["_ingested_at"] = datetime.now(UTC).isoformat(timespec="seconds")
    df["_env"] = env
    return df
