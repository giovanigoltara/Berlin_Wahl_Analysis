"""Initialise the Earth Engine client, and check that it works.

Two ways to authenticate, chosen automatically:
  1. EE_SERVICE_ACCOUNT_KEY is set: a service-account JSON key, given as the raw JSON or as
     base64 of it (one line, easier to store as an environment variable). The key is used from
     memory and never written to disk. For unattended runs, e.g. a cloud environment.
  2. Otherwise: the user credentials stored by `earthengine authenticate` (README, manual setup).
EE_PROJECT names the Google Cloud project registered for Earth Engine in both cases.

Usage: uv run python src/ee_auth.py   (prints the identity and a small test computation)
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import sys

import ee


def _service_account_key() -> dict | None:
    raw = os.environ.get("EE_SERVICE_ACCOUNT_KEY", "").strip()
    if not raw:
        return None
    if not raw.startswith("{"):
        try:
            raw = base64.b64decode(raw, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError) as e:
            raise SystemExit("EE_SERVICE_ACCOUNT_KEY is neither JSON nor base64 of JSON") from e
    try:
        key = json.loads(raw)
    except json.JSONDecodeError as e:
        # Never echo the key; position and length are enough to spot a truncated copy.
        raise SystemExit(
            f"EE_SERVICE_ACCOUNT_KEY is not valid JSON ({e.msg}, character {e.pos} of "
            f"{len(raw)}); the stored value is probably truncated, so copy the key again"
        ) from None
    if key.get("type") != "service_account":
        raise SystemExit("EE_SERVICE_ACCOUNT_KEY is not a service-account key")
    return key


def init() -> str:
    """Initialise Earth Engine and return a description of the identity used."""
    project = os.environ.get("EE_PROJECT", "").strip()
    if not project:
        raise SystemExit(
            "EE_PROJECT is not set (see README, manual setup). If it is set in the environment, "
            "check that .env does not assign it an empty value."
        )
    key = _service_account_key()
    if key:
        creds = ee.ServiceAccountCredentials(key["client_email"], key_data=json.dumps(key))
        ee.Initialize(credentials=creds, project=project)
        return f"service account {key['client_email']}, project {project}"
    ee.Initialize(project=project)
    return f"user credentials from `earthengine authenticate`, project {project}"


def main() -> int:
    who = init()
    # Smallest useful round trip: count Landsat 9 scenes over Berlin in one summer.
    berlin = ee.Geometry.Point(13.40, 52.52)
    n = (
        ee.ImageCollection("LANDSAT/LC09/C02/T1_L2")
        .filterBounds(berlin)
        .filterDate("2025-06-01", "2025-09-01")
        .size()
        .getInfo()
    )
    print(f"ok    Earth Engine initialised with {who}")
    print(f"ok    test query: {n} Landsat 9 scenes over central Berlin, June to August 2025")
    return 0


if __name__ == "__main__":
    sys.exit(main())
