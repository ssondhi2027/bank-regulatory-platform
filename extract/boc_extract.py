"""
Land Bank of Canada Valet observations (policy rate, 2Y/10Y GoC benchmark
bond yields, CAD/USD) into the content-addressed raw zone.

Series names were confirmed live against
https://www.bankofcanada.ca/valet/lists/series before use, not guessed:
  V39079              Target for the overnight rate
  BD.CDN.2YR.DQ.YLD   Benchmark bond yield: 2 year
  BD.CDN.10YR.DQ.YLD  Benchmark bond yield: 10 year
  FXCADUSD            CAD/USD daily average reciprocal exchange rate

Usage:
    python extract/boc_extract.py
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
from pathlib import Path

import requests

SERIES = {
    "V39079": "policy_rate",
    "BD.CDN.2YR.DQ.YLD": "goc_2y_yield",
    "BD.CDN.10YR.DQ.YLD": "goc_10y_yield",
    "FXCADUSD": "cad_usd",
}
START_DATE = "2019-01-01"
RAW = Path("data/raw") / "BOC"


def fetch_observations() -> bytes:
    codes = ",".join(SERIES)
    url = f"https://www.bankofcanada.ca/valet/observations/{codes}/json?start_date={START_DATE}"
    return requests.get(url, timeout=120).content


def landed_path(digest: str) -> Path:
    # Same content-addressing rule as osfi_extract.py: path is a pure
    # function of the hash, never the ingest date.
    return RAW / f"{digest}.json"


def main() -> None:
    body = fetch_observations()
    digest = hashlib.sha256(body).hexdigest()
    path = landed_path(digest)

    if path.exists():
        print(f"BOC: unchanged ({digest[:12]}) -- skipping")
        return

    stamp = dt.datetime.now(dt.timezone.utc)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)

    meta = {
        "series": SERIES,
        "start_date": START_DATE,
        "file_hash": digest,
        "path": str(path),
        "ingested_at": stamp.isoformat(),
        "size_bytes": len(body),
    }
    path.with_suffix(".meta.json").write_text(json.dumps(meta, indent=2))
    print(f"BOC: NEW version {digest[:12]} ({len(body) / 1e3:.1f} KB)")


if __name__ == "__main__":
    main()
