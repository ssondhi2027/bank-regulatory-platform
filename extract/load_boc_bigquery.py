"""
Load the landed Bank of Canada Valet observations into BigQuery raw.

The Valet API returns one JSON record per DATE, with each series present
as a key only on dates it actually published a value (confirmed by
profiling the landed file: V39079 the policy rate is not published daily,
unlike the three market series -- BD.CDN.2YR.DQ.YLD, BD.CDN.10YR.DQ.YLD,
FXCADUSD all have values on 2026-08-28, V39079 does not). This unpivots
that sparse wide shape into series_id/obs_date/value -- one row per
(series, date) actually observed, matching docs/PROJECT_STRUCTURE.md's
declared boc_raw.valet_observations schema.

series_id lands as the raw Valet code (e.g. "V39079"), not the friendly
name from boc_extract.py's SERIES dict -- same "raw lands as-is, renaming
belongs in dbt" rule the OSFI loader follows.

Only the most recently landed file is loaded (same reasoning as
load_bigquery.py: the landing zone on disk is the durable record; raw in
the warehouse is derived and rebuildable from it, WRITE_TRUNCATE is safe).

Usage:
    python extract/load_boc_bigquery.py
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from google.cloud import bigquery

load_dotenv()

PROJECT = os.environ["GCP_PROJECT_ID"]
TABLE = f"{PROJECT}.boc_raw.valet_observations"
RAW = Path("data/raw") / "BOC"


def latest_meta() -> dict:
    metas = [json.loads(p.read_text()) for p in RAW.glob("*.meta.json")]
    if not metas:
        raise RuntimeError(f"No landed BoC file found under {RAW} -- run extract/boc_extract.py first")
    return max(metas, key=lambda m: m["ingested_at"])


def unpivot(meta: dict) -> pd.DataFrame:
    body = json.loads(Path(meta["path"]).read_text(encoding="utf-8"))
    rows = []
    for obs in body["observations"]:
        obs_date = obs["d"]
        for series_id, val in obs.items():
            if series_id == "d":
                continue
            rows.append({"series_id": series_id, "obs_date": obs_date, "value": val["v"]})
    df = pd.DataFrame(rows, dtype=str)
    df["source_file_hash"] = meta["file_hash"]
    df["ingested_at"] = meta["ingested_at"]
    return df


def main() -> None:
    client = bigquery.Client(project=PROJECT)
    meta = latest_meta()
    df = unpivot(meta)

    # Explicit STRING schema for every column -- never autodetect. Same
    # rationale as load_bigquery.py: no cleaning or casting in raw.
    schema = [bigquery.SchemaField(col, "STRING") for col in df.columns]
    job_config = bigquery.LoadJobConfig(
        write_disposition="WRITE_TRUNCATE",
        schema=schema,
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
    )

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    df.to_csv(tmp_path, index=False)
    try:
        with tmp_path.open("rb") as fh:
            job = client.load_table_from_file(fh, TABLE, job_config=job_config)
        job.result()
    finally:
        tmp_path.unlink(missing_ok=True)

    print(f"Loaded {job.output_rows:,} rows into {TABLE}")


if __name__ == "__main__":
    main()
