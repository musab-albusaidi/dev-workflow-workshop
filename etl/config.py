"""Configuration: which environment we are and which database to write to."""

from __future__ import annotations

import os
from pathlib import Path

# etl/config.py -> etl/ -> app/ -> the environment folder that holds .env
ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


def load_config() -> dict[str, str]:
    """Read ENV and DATABASE_URL from ../.env, then let real env vars override."""
    config: dict[str, str] = {}
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip().strip("'\"")
    for key in ("ENV", "DATABASE_URL"):
        if key in os.environ:
            config[key] = os.environ[key]
    config.setdefault("ENV", "local")
    return config
