"""
Land OSFI M4/P3/E3 returns into the content-addressed raw zone.

Rules from CLAUDE.md:
  - never hardcode Open Government download URLs -- resolve via the CKAN
    package_show endpoint
  - the landing zone is append-only and content-addressed: the path is a
    pure function of the file's SHA-256 hash, never the ingest date, so
    identical bytes always resolve to the same path and are never
    re-landed or overwritten
  - assert the downloaded schema matches extract/schema.yml before landing;
    a file that fails validation is never written -- fail loudly instead

Usage:
    python extract/osfi_extract.py
"""

from __future__ import annotations

import datetime as dt
import hashlib
import io
import json
from pathlib import Path

import pandas as pd
import requests

from schema_assert import SchemaDriftError, assert_matches, load_schema

PACKAGE_ID = "91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de"
CKAN = f"https://open.canada.ca/data/api/action/package_show?id={PACKAGE_ID}"
WANTED = {
    "banks_monthly_m4.csv": "M4",
    "banks_quarterly_p3.csv": "P3",
    "banks_quarterly_e3.csv": "E3",
}
RAW = Path("data/raw")


def resolve_resources() -> list[dict]:
    """Never hardcode download URLs -- CKAN is the registry."""
    pkg = requests.get(CKAN, timeout=60).json()["result"]
    out = []
    for r in pkg["resources"]:
        fname = (r.get("url") or "").split("/")[-1].lower()
        if fname in WANTED:
            out.append({
                "return_code": WANTED[fname],
                "url": r["url"],
                "resource_id": r["id"],
                "ckan_last_modified": r.get("last_modified") or r.get("created"),
            })
    missing = set(WANTED.values()) - {r["return_code"] for r in out}
    if missing:
        raise RuntimeError(f"Resources not found in CKAN package: {missing}")
    return out


def landed_path(return_code: str, digest: str) -> Path:
    """Path is a pure function of content hash -- never the ingest date.
    Deliberately deviates from a date-partitioned layout: partitioning by
    ingest date would make identical bytes land at a new path every day,
    which is not content-addressing."""
    return RAW / return_code / f"{digest}.csv"


def fetch(res: dict, schema: dict) -> dict:
    body = requests.get(res["url"], timeout=600).content
    digest = hashlib.sha256(body).hexdigest()
    path = landed_path(res["return_code"], digest)

    if path.exists():
        print(f"{res['return_code']}: unchanged ({digest[:12]}) -- skipping")
        return {**res, "file_hash": digest, "path": str(path), "changed": False}

    # New content -- validate against the pinned schema BEFORE landing.
    df = pd.read_csv(io.BytesIO(body), dtype=str, low_memory=False, encoding="utf-8")
    try:
        warnings = assert_matches(df, res["return_code"], schema)
    except SchemaDriftError as e:
        raise SchemaDriftError(
            f"Refusing to land {res['return_code']}: schema assertion failed.\n{e}"
        ) from e
    for w in warnings:
        print(f"  [{res['return_code']}] WARNING: {w}")

    stamp = dt.datetime.now(dt.timezone.utc)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)

    meta = {
        "return_code": res["return_code"],
        "url": res["url"],
        "resource_id": res["resource_id"],
        "ckan_last_modified": res["ckan_last_modified"],
        "file_hash": digest,
        "path": str(path),
        "ingested_at": stamp.isoformat(),
        "size_bytes": len(body),
        "changed": True,
    }
    path.with_suffix(".meta.json").write_text(json.dumps(meta, indent=2))
    print(f"{res['return_code']}: NEW version {digest[:12]} ({len(body) / 1e6:.1f} MB)")
    return meta


def main() -> None:
    schema = load_schema()
    for res in resolve_resources():
        fetch(res, schema)


if __name__ == "__main__":
    main()
