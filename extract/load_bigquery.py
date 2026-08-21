"""
Load the OSFI landing zone into BigQuery raw.

Dumb loader by design: every value lands exactly as filed, as a string,
plus audit columns. No data cleaning, no value casting -- that all belongs
in dbt.

One structural accommodation: raw OSFI headers contain characters BigQuery
column identifiers cannot hold at all (spaces, slashes, e.g. "Fiscal
Year/Année fiscale"), and BigQuery's "flexible column names" workaround for
that only applies when the schema is autodetected -- autodetect cannot be
trusted here, because some columns look purely numeric in early rows but
contain alphanumeric codes later in the file (e.g. Data Point Address:
"0791" early, "calcP300016" later -- confirmed in Phase 2 profiling), and
autodetect infers a type from the sample that then hard-fails the load the
moment it hits a later, non-conforming row. There is no combination of
BigQuery load options that gives literal headers AND guaranteed string
typing in one step. Columns are therefore renamed to the same deterministic
slug already recorded as each column's "normalized" alias in schema.yml
(generate_schema.py's normalize()) -- not an ad hoc rename, and no value in
any row is touched.

WRITE_TRUNCATE is safe here: the landing zone on disk is the durable,
content-addressed record. Raw in the warehouse is derived and rebuildable
from it at any time, so truncate-and-reload is not a data-loss risk.

Usage:
    python extract/load_bigquery.py
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from google.cloud import bigquery

from generate_schema import normalize

load_dotenv()

PROJECT = os.environ["GCP_PROJECT_ID"]
TABLE = f"{PROJECT}.osfi_raw.filings"
RAW = Path("data/raw")
OSFI_RETURN_CODES = {"M4", "P3", "E3"}


def load_landed_frames() -> pd.DataFrame:
    frames = []
    for meta_path in RAW.rglob("*.meta.json"):
        meta = json.loads(meta_path.read_text())
        if meta.get("return_code") not in OSFI_RETURN_CODES:
            continue  # skip boc_extract.py's sidecar -- different shape, different table
        csv_path = Path(meta["path"])
        df = pd.read_csv(csv_path, low_memory=False, dtype=str)
        df["source_file_name"] = csv_path.name
        df["source_file_hash"] = meta["file_hash"]
        df["source_return_code"] = meta["return_code"]
        df["ckan_last_modified"] = meta["ckan_last_modified"]
        df["ingested_at"] = meta["ingested_at"]
        frames.append(df)
    if not frames:
        raise RuntimeError(f"No landed OSFI files found under {RAW} -- run osfi_extract.py first")
    return pd.concat(frames, ignore_index=True)


def main() -> None:
    client = bigquery.Client(project=PROJECT)
    combined = load_landed_frames()
    combined = combined.rename(columns={c: normalize(c) for c in combined.columns})

    # Explicit STRING schema for every column -- never autodetect. See
    # module docstring for why autodetect cannot be trusted on this data.
    schema = [bigquery.SchemaField(col, "STRING") for col in combined.columns]

    job_config = bigquery.LoadJobConfig(
        write_disposition="WRITE_TRUNCATE",
        schema=schema,
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
    )

    # Written to a temp file on disk rather than held as an in-memory CSV
    # buffer -- avoids holding both the ~2M-row dataframe and its full CSV
    # serialization in memory at once.
    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    combined.to_csv(tmp_path, index=False)
    try:
        with tmp_path.open("rb") as fh:
            job = client.load_table_from_file(fh, TABLE, job_config=job_config)
        job.result()
    finally:
        tmp_path.unlink(missing_ok=True)

    print(f"Loaded {job.output_rows:,} rows into {TABLE}")


if __name__ == "__main__":
    main()
