"""Tests for pipeline.py.

Three kinds of test, from fastest to slowest:
  * unit tests        - is each function's logic right? (in memory, milliseconds)
  * data quality      - do the quality rules catch bad data?
  * integration test  - does the whole pipeline work against a real Postgres?
"""

import os

import pandas as pd
import pytest

import pipeline as p


@pytest.fixture
def raw():
    return p.bronze(env="test")


@pytest.fixture
def orders(raw):
    return p.silver(raw)


@pytest.fixture
def tables(orders):
    return p.gold(orders)


# --------------------------------------------------------------------------- #
# Bronze
# --------------------------------------------------------------------------- #
def test_bronze_lands_every_raw_row_untouched(raw):
    assert len(raw) == 20
    assert list(raw.columns) == p.RAW_COLUMNS + ["_ingested_at", "_env"]
    assert (raw["_env"] == "test").all()
    assert raw.loc[1, "country"] == " oman "  # bronze does NOT clean


# --------------------------------------------------------------------------- #
# Silver
# --------------------------------------------------------------------------- #
def test_silver_keeps_one_row_per_order(orders):
    assert orders["order_id"].is_unique
    assert len(orders) == 13


def test_silver_drops_invalid_rows(orders):
    dropped = {1005, 1008, 1009, 1016}  # no customer, negative qty, bad date, bad qty
    assert dropped.isdisjoint(orders["order_id"])


def test_silver_normalises_text(orders):
    assert set(orders["country"]) == {"OMAN", "UAE", "QATAR"}
    assert set(orders["customer"]) == {"Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace"}
    assert set(orders["status"]) == {"completed", "cancelled", "pending"}


def test_silver_casts_types_and_computes_revenue(orders):
    assert orders["qty"].dtype == "int64"
    assert pd.api.types.is_datetime64_any_dtype(orders["order_date"])
    row = orders.set_index("order_id").loc[1004]
    assert row["qty"] == 3
    assert row["revenue"] == 135.0


# --------------------------------------------------------------------------- #
# Gold
# --------------------------------------------------------------------------- #
def test_gold_sales_by_country_month(tables):
    sales = tables["sales_by_country_month"]
    actual = sales[["order_month", "country", "revenue", "orders", "units"]]
    expected = pd.DataFrame(
        [
            ("2026-01", "OMAN", 1251.0, 2, 3),
            ("2026-01", "UAE", 435.0, 2, 4),
            ("2026-02", "OMAN", 600.0, 1, 2),
            ("2026-02", "QATAR", 300.0, 1, 1),
            ("2026-02", "UAE", 1200.0, 1, 1),
            ("2026-03", "OMAN", 1276.5, 2, 4),
            ("2026-03", "QATAR", 90.0, 1, 2),
            ("2026-03", "UAE", 45.0, 1, 1),
        ],
        columns=["order_month", "country", "revenue", "orders", "units"],
    )
    pd.testing.assert_frame_equal(actual, expected)


def test_gold_total_revenue(tables):
    """The number the business reads. It must count each completed order once."""
    assert tables["sales_by_country_month"]["revenue"].sum() == 5197.5
    assert tables["customer_summary"]["lifetime_value"].sum() == 5197.5


def test_gold_customer_summary(tables):
    customers = tables["customer_summary"].set_index("customer")
    alice = customers.loc["Alice"]
    assert alice["lifetime_value"] == 1876.5
    assert alice["order_count"] == 3
    assert alice["first_order"] == pd.Timestamp("2026-01-05")
    assert alice["last_order"] == pd.Timestamp("2026-03-03")
    # Eve's cancelled 1150 laptop must not count as revenue.
    assert customers.loc["Eve", "lifetime_value"] == 300.0


# --------------------------------------------------------------------------- #
# Data quality
# --------------------------------------------------------------------------- #
def test_quality_checks_pass_on_clean_data(orders, tables):
    p.check_quality(orders, tables)


def test_quality_checks_catch_duplicate_orders(orders, tables):
    with_duplicate = pd.concat([orders, orders.head(1)], ignore_index=True)
    with pytest.raises(p.DataQualityError, match="duplicate order_id"):
        p.check_quality(with_duplicate, tables)


# --------------------------------------------------------------------------- #
# Integration: the whole pipeline against a real Postgres
# --------------------------------------------------------------------------- #
@pytest.mark.integration
def test_run_writes_every_layer_to_postgres_and_is_idempotent():
    url = os.environ.get("DATABASE_URL")
    if not url:
        if os.environ.get("REQUIRE_DB"):
            pytest.fail("REQUIRE_DB is set but DATABASE_URL is missing")
        pytest.skip("DATABASE_URL not set")

    from sqlalchemy import create_engine, text

    config = {"ENV": "test", "DATABASE_URL": url}
    p.run(config)
    p.run(config)  # running twice must give the same result (full refresh)

    engine = create_engine(url)
    with engine.connect() as conn:

        def count(table):
            return conn.execute(text(f"SELECT count(*) FROM {table}")).scalar()

        assert count("bronze.orders_raw") == 20
        assert count("silver.orders") == 13
        assert count("gold.sales_by_country_month") == 8
        assert count("gold.customer_summary") == 7
        total = conn.execute(text("SELECT sum(revenue) FROM gold.sales_by_country_month"))
        assert total.scalar() == 5197.5
    engine.dispose()
