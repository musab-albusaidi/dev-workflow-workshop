"""Gold: business-ready tables. Only completed orders count as revenue."""

from __future__ import annotations

import pandas as pd


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
