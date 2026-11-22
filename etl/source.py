"""Source: the raw orders as they arrive, before any processing."""

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
