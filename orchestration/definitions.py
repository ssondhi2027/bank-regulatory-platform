"""
Dagster asset graph for the local dev/demo view of the pipeline. The
scheduled production run lives in .github/workflows/daily_pipeline.yml
(GitHub Actions) -- this is deliberately NOT a second scheduler racing the
same job. Dagster runs locally (`dagster dev`, localhost:3000) to give a
lineage graph and a demoable UI; Actions runs the actual cron. See the
Phase 9 checkpoint notes for why this split exists rather than one tool
doing both.

Usage:
    dagster dev   # from the repo root, or set DAGSTER_HOME

Dependency note: requirements.txt originally pinned dagster==1.13.16 with
dagster-dbt==0.10.9 -- a genuine mismatch (0.10.9 predates Dagster's
dagster.core -> dagster._core rename by years; import dagster_dbt failed
outright). Fixed by upgrading the whole dagster-* family together
(dagster-graphql/dagster-webserver track dagster's own version number;
dagster-dbt/dagster-pandas use independent 0.x schemes and needed
resolving separately).

dbt-core/dbt-bigquery are pinned to 1.11.x, not 1.12.0 -- initially kept
at 1.12.0 after verifying `dagster asset list` worked fine despite
dagster-dbt 0.29.20's declared `dbt-core<1.12` upper bound (judged
conservative, not a real break, and not worth revisiting the checkpoints
already run against 1.12.0 for no observed gain). That held for every
INCREMENTAL local `pip install X==version` I ran, which don't fully
re-resolve the whole graph -- but it does not hold for a one-shot `pip
install -r requirements.txt` from a clean environment, which is exactly
what every GitHub Actions workflow does: pip's resolver treats the
declared conflict as a hard `ResolutionImpossible`, not a warning, when
resolving the full requirements file at once. Found by actually building a
fresh Python 3.11 venv (matching the workflows' `python-version: '3.11'`)
and running the real install, not by inspecting version numbers. Confirmed
after downgrading: full `dbt build` still 57/57 green, and this asset
graph still resolves -- and it's a strictly more correct state than
before, since 1.11.14 actually satisfies dagster-dbt's declared
constraint instead of merely getting away with violating it.
"""

from __future__ import annotations

import sys
from pathlib import Path

from dagster import Definitions, ScheduleDefinition, asset, define_asset_job
from dagster_dbt import DbtCliResource, DbtProject, dbt_assets

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "extract"))

import boc_extract  # noqa: E402
import load_bigquery  # noqa: E402
import osfi_extract  # noqa: E402

dbt_project = DbtProject(project_dir=str(REPO_ROOT / "transform"))
dbt_project.prepare_if_dev()


@asset(group_name="ingestion")
def osfi_raw_files() -> None:
    """Lands M4/P3/E3 + Foreign Bank Branches M4 into the content-addressed
    landing zone. Idempotent -- unchanged files are skipped, not re-landed."""
    osfi_extract.main()


@asset(group_name="ingestion")
def boc_raw_files() -> None:
    """Lands Bank of Canada Valet rate series into the same landing zone."""
    boc_extract.main()


@asset(group_name="ingestion", deps=[osfi_raw_files, boc_raw_files])
def bigquery_raw_load() -> None:
    """Truncate-and-reload of the latest landed file per return code into
    osfi_raw.filings. See load_bigquery.py's module docstring for why
    WRITE_TRUNCATE is safe here (the landing zone on disk is the durable
    record, not the warehouse)."""
    load_bigquery.main()


@dbt_assets(manifest=dbt_project.manifest_path)
def dbt_models(context, dbt: DbtCliResource):
    yield from dbt.cli(["build"], context=context).stream()


daily_job = define_asset_job("daily_pipeline", selection="*")

defs = Definitions(
    assets=[osfi_raw_files, boc_raw_files, bigquery_raw_load, dbt_models],
    resources={"dbt": DbtCliResource(project_dir=str(REPO_ROOT / "transform"))},
    schedules=[
        ScheduleDefinition(job=daily_job, cron_schedule="0 6 * * *"),
    ],
)
