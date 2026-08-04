# Build Guide — Canadian Bank Regulatory Reporting Platform

End-to-end, in the order you should actually do it. Roughly six focused weekends. Each phase ends with a **checkpoint** — don't move on until it passes.

---

## Phase 0 — Decisions and accounts (30 minutes)

Lock these before writing code. Changing them later is expensive.

| Decision | Recommendation | Why |
|---|---|---|
| Warehouse | **BigQuery** (free tier) | Real cloud warehouse on the resume, Power BI connects natively, volume here is tiny. DuckDB locally if you want zero setup — dbt code is ~95% portable. |
| dbt adapter | `dbt-bigquery` | |
| Orchestration | **Dagster** in-repo + **GitHub Actions** cron for actual runs | Dagster gives you the asset-graph screenshot and the skill; Actions gives you a free, always-on scheduler. Be honest about this split in the README. |
| Dashboard | **Evidence.dev** (public link) + **Power BI** (.pbix in repo) | Evidence means a reviewer can click a URL. Power BI is what Canadian bank teams actually use. |
| Scope | 6 institutions, 5 years, returns M4 + P3 + E3 | Depth over breadth. |

Accounts to create: Google Cloud (BigQuery, free tier — confirm current limits), GitHub, Evidence Cloud or Netlify.

**Scope note:** start with the Big Six (RBC, TD, Scotiabank, BMO, CIBC, National Bank). Add foreign bank subsidiaries only after Phase 8 works.

---

## Phase 1 — Repository and environment (2 hours)

```bash
mkdir bank-regulatory-platform && cd bank-regulatory-platform
git init
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate

pip install dbt-core dbt-bigquery pandas requests pyarrow \
            google-cloud-bigquery dagster dagster-dbt dagster-webserver \
            python-dotenv pytest ruff
pip freeze > requirements.txt
```

Repo layout:

```
bank-regulatory-platform/
├── extract/            # Python ingestion
├── transform/          # the dbt project
├── orchestration/      # Dagster definitions
├── dashboards/         # Evidence project + .pbix
├── docs/               # architecture diagram, ERD, decisions
├── .github/workflows/
├── .env.example
├── .gitignore
└── README.md
```

`.gitignore` must include `.env`, `*.json` (service account keys), `.venv/`, `target/`, `dbt_packages/`, `logs/`, `data/raw/`.

**Commit a service account key exactly zero times.** For a project aimed at bank employers, a leaked credential in git history is a fatal review finding.

**Checkpoint:** `dbt --version` works, repo is on GitHub, `.env` is gitignored.

---

## Phase 2 — Profile the source before you write the extractor (3 hours)

This step is not optional. You cannot model a file you haven't looked at.

### 2.1 Download the reference material by hand

From the OSFI Banks dataset page (`open.canada.ca/data/en/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de`), download and actually read:

- **Data Dictionary** (XLSX) — this becomes your line-item hierarchy seed
- **Banks User Manual** (PDF) — explains return structure and consolidation rules
- **List of Bank Subsidiaries** (XLSX) — parent/child hierarchy, needed to avoid double-counting

### 2.2 Profile the CSVs

`extract/profile_source.py`:

```python
import pandas as pd, requests, io

URLS = {
    "m4": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/d0f6040e-671c-4301-a235-e9e7ba164604/download/banks_monthly_m4.csv",
    "p3": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/027ee7f8-4b87-45cd-a10f-f95d3a5d4e09/download/banks_quarterly_p3.csv",
    "e3": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/1f86e088-7d29-49c2-94de-ddbfe6559725/download/banks_quarterly_e3.csv",
}

for name, url in URLS.items():
    raw = requests.get(url, timeout=180).content
    df = pd.read_csv(io.BytesIO(raw), low_memory=False)
    print(f"\n{'='*70}\n{name.upper()}  shape={df.shape}  size={len(raw)/1e6:.1f} MB")
    print(df.dtypes)
    print(df.head(10).to_string())
    for col in df.columns:
        n = df[col].nunique(dropna=True)
        print(f"  {col:45s} distinct={n:>8,}  nulls={df[col].isna().sum():>8,}")
        if n <= 25:
            print(f"      values: {sorted(df[col].dropna().unique().tolist())[:25]}")
```

Write down the answers to these, because every later phase depends on them:

1. Is the file **long** (one row per line item) or **wide** (one column per line item)?
2. What identifies an institution — a numeric ID, a name string, or both?
3. How is the reporting period expressed — a date, `2025-Q1`, a fiscal indicator?
4. Is there a line-item **code** or only a description? (If only descriptions, your join key is text and you must normalize it hard.)
5. Are amounts in thousands, and is there a units or currency column?
6. Are there embedded subtotal/total rows mixed in with detail rows? (Almost certainly yes — you must exclude them before summing, or every reconciliation control will fail.)

### 2.3 Pin the schema

Write `extract/schema.yml` recording the exact expected columns and dtypes. Your extractor will assert against it, so a silent upstream schema change becomes a loud failure.

**Checkpoint:** you can state the grain of each raw file in one sentence, and you know which rows are subtotals.

---

## Phase 3 — Extractor (1 weekend)

Two rules: **resolve URLs dynamically**, and **never overwrite**.

`extract/osfi_extract.py`:

```python
import hashlib, json, os, io, datetime as dt
from pathlib import Path
import requests, pandas as pd

PACKAGE_ID = "91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de"
CKAN = f"https://open.canada.ca/data/api/action/package_show?id={PACKAGE_ID}"
WANTED = {"banks_monthly_m4.csv": "M4",
          "banks_quarterly_p3.csv": "P3",
          "banks_quarterly_e3.csv": "E3"}
RAW = Path("data/raw")


def resolve_resources() -> list[dict]:
    """Never hardcode download URLs — CKAN is the registry."""
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


def fetch(res: dict) -> dict:
    body = requests.get(res["url"], timeout=600).content
    digest = hashlib.sha256(body).hexdigest()
    stamp = dt.datetime.now(dt.timezone.utc)

    # Content-addressed landing zone: same bytes = same path = no duplicate.
    day = stamp.strftime("%Y-%m-%d")
    path = RAW / res["return_code"] / f"ingest_date={day}" / f"{digest[:12]}.csv"

    if path.exists():
        print(f"{res['return_code']}: unchanged ({digest[:12]}) — skipping")
        return {**res, "file_hash": digest, "path": str(path), "changed": False}

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)

    meta = {**res, "file_hash": digest, "path": str(path),
            "ingested_at": stamp.isoformat(), "size_bytes": len(body),
            "changed": True}
    path.with_suffix(".meta.json").write_text(json.dumps(meta, indent=2))
    print(f"{res['return_code']}: NEW version {digest[:12]} ({len(body)/1e6:.1f} MB)")
    return meta


if __name__ == "__main__":
    for r in resolve_resources():
        fetch(r)
```

Why content-addressing matters: OSFI republishes the **whole file** every cycle. Hashing tells you whether anything actually changed, and gives you an audit trail. This is what makes restatement detection possible at all.

### The honest constraint — write this in your README

These CSVs are full-file replacements with no version history in the source. **Your restatement history begins the day you start pulling.** You cannot reconstruct restatements that happened before your first ingest. That's a real limitation, and stating it plainly is worth more than pretending otherwise.

Practical consequence: **start running this daily now**, even before the rest is built. Every day you wait is history you can't recover.

### Bank of Canada extractor

`extract/boc_extract.py` — Valet needs no key:

```python
SERIES = ["V39079",                      # policy rate (verify current name via /lists/series)
          "BD.CDN.2YR.DQ.YLD",
          "BD.CDN.10YR.DQ.YLD",
          "FXCADUSD"]

url = ("https://www.bankofcanada.ca/valet/observations/"
       f"{','.join(SERIES)}/json?start_date=2019-01-01")
```

Confirm series names against `https://www.bankofcanada.ca/valet/lists/series` — don't trust a name copied from a blog post.

**Checkpoint:** run the extractor twice in a row. The second run must print "unchanged" and create no new files.

---

## Phase 4 — Load to warehouse (half a day)

Keep the loader dumb: raw lands as-is, plus audit columns. All cleaning happens in dbt.

`extract/load_bigquery.py`:

```python
import json
from pathlib import Path
import pandas as pd
from google.cloud import bigquery

client = bigquery.Client()
TABLE = "your_project.osfi_raw.filings"

frames = []
for meta_path in Path("data/raw").rglob("*.meta.json"):
    meta = json.loads(meta_path.read_text())
    df = pd.read_csv(meta["path"], low_memory=False, dtype=str)
    df["source_file_name"] = Path(meta["path"]).name
    df["source_file_hash"] = meta["file_hash"]
    df["source_return_code"] = meta["return_code"]
    df["ckan_last_modified"] = meta["ckan_last_modified"]
    df["ingested_at"] = meta["ingested_at"]
    frames.append(df)

job = client.load_table_from_dataframe(
    pd.concat(frames, ignore_index=True), TABLE,
    job_config=bigquery.LoadJobConfig(
        write_disposition="WRITE_TRUNCATE",   # raw is rebuilt from the landing zone
        autodetect=True,
    ),
)
job.result()
print(f"Loaded {job.output_rows:,} rows")
```

`WRITE_TRUNCATE` is safe here because the landing zone on disk (or S3/GCS) is the durable record — raw in the warehouse is derived and rebuildable. Say that in your README; reviewers will otherwise flag it.

**Checkpoint:** `select source_return_code, count(*) from osfi_raw.filings group by 1` returns sensible counts.

---

## Phase 5 — dbt init, sources, and the snapshot (1 day)

```bash
cd transform
dbt init bank_regulatory_platform
dbt deps          # after adding packages.yml
dbt debug         # must pass before anything else
```

Build in this order:

1. `_osfi__sources.yml` — with `freshness` thresholds taken from OSFI's published calendar (monthly returns land around the 15th of the following month; 2026 quarterlies publish May 23 / Aug 22 / Nov 22 / Mar 19). Warn at 45 days, error at 75.
2. `snapshots/snap_osfi_filings.yml` — `strategy: check`, `check_cols: ['amount']`, `unique_key` = surrogate of institution + return + period + line item.
3. `stg_osfi__filings.sql` — reads **from the snapshot**, not the source.

```bash
dbt snapshot
dbt run --select stg_osfi__filings
```

### Prove the restatement engine works — do this now, not later

This is the single most important validation in the project.

```bash
# 1. Snapshot today's data
dbt snapshot

# 2. Manually edit one amount in one landed CSV (simulate a refiling)
#    then reload and re-snapshot
python extract/load_bigquery.py
dbt snapshot

# 3. You should now see TWO rows for that filing_line_key
```

```sql
select filing_line_key, amount, dbt_valid_from, dbt_valid_to
from snapshots.snap_osfi_filings
where filing_line_key = '<the one you edited>'
order by dbt_valid_from;
```

If you don't get two rows with a closed and an open validity window, stop and fix it. Everything downstream depends on this.

**Checkpoint:** two versions visible, one with `dbt_valid_to` populated, one null.

---

## Phase 6 — Seeds: the unglamorous part that decides whether this works (1 weekend)

Budget real time here. This is where most people quit.

### `seed_line_item_hierarchy.csv`

Derived from the OSFI Data Dictionary. You need, per line item: code, description, parent code, level, statement section, sign convention, and an `is_subtotal` flag.

```csv
line_item_code,line_item_desc,parent_line_item_code,hierarchy_level,statement_section,is_subtotal,expected_sign
A1,Cash and deposits with banks,ASSETS,2,Assets,false,positive
A2,Securities,ASSETS,2,Assets,false,positive
ASSETS,Total assets,,1,Assets,true,positive
...
```

The `is_subtotal` flag is critical. Raw returns interleave detail and total rows; summing without excluding subtotals double-counts everything and every reconciliation control fails for the wrong reason.

### `seed_institution_master.csv`

From "Who we regulate" plus "List of Bank Subsidiaries". Must include **fiscal year end** and **parent institution** — both matter:

```csv
institution_id,legal_name,short_name,schedule_type,fiscal_year_end_month,parent_institution_id,peer_group
0001,Royal Bank of Canada,RBC,Schedule I,10,,BIG_SIX
...
```

`fiscal_year_end_month` drives your completeness control (October FYE and December FYE filers publish on different dates — a naive "did everyone file?" check false-alarms every February). `parent_institution_id` prevents double-counting subsidiaries in industry totals.

### `seed_control_registry.csv`

The 20 controls from the structure doc, plus:

```csv
REC-007,industry_total_ties_to_published,Reconciliation,error,Finance Data,Computed industry aggregate equals published total across domestic foreign subsidiaries and foreign branches,BCBS 239 P3 Accuracy
```

```bash
dbt seed
```

**Checkpoint:** every `line_item_code` in staging joins to the hierarchy seed. Run this and expect zero rows:

```sql
select distinct s.line_item_code
from staging.stg_osfi__filings s
left join reference.seed_line_item_hierarchy h using (line_item_code)
where h.line_item_code is null;
```

---

## Phase 7 — Intermediate and marts (1 weekend)

Order matters:

```bash
dbt run --select int_filings__current_version int_filings__restatement_events
dbt run --select int_filings__balance_sheet_pivoted
dbt run --select dim_institution dim_line_item dim_reporting_period
dbt run --select fct_balance_sheet
```

Then income statement, then metrics.

**The incremental trap, again:** `fct_balance_sheet` filters on `known_from_ts`, never on `reporting_period_end`. A restatement of an old period arrives with a new knowledge timestamp and an old business date — filter on the business date and you drop it silently, forever.

Test it explicitly: restate an old period, run `dbt run --select fct_balance_sheet` (incremental, not full-refresh), and confirm the old period's value updated.

**Checkpoint:** `fct_balance_sheet` has one row per institution per period, and total assets for RBC's most recent quarter is within a rounding error of their published financial statements. Go check against the actual annual report — this is your ground truth, and finding a discrepancy now is much better than in an interview.

---

## Phase 8 — Controls framework (3-4 days)

Build in this order, testing each before adding the next:

1. **Generic tests in YAML** — `unique`, `not_null`, `relationships`, `accepted_values` on every mart.
2. **REC-001** (balance sheet balances) — the flagship. Use a tolerance, not exact equality, because OSFI rounds to thousands.
3. **REC-002** (subtotal rollup) via the custom generic test.
4. **REC-005** (cross-return net income tie-out) and **REC-004** (retained earnings continuity) — the P3 return carries retained earnings directly, so this one is genuinely available to you.
5. **REC-007** (industry total ties to published) — requires the foreign bank branches dataset and the parent/subsidiary exclusion logic.
6. **CMP-001** with fiscal-year-end cohort logic.
7. **Logging macro** → `fct_control_results` → `rpt_control_scorecard`.

```bash
dbt test --select fct_balance_sheet
dbt build --select marts.controls
```

**Expect failures on the first run.** That is the point. Investigate each one — some will be your bugs, some will be real data quirks worth documenting. Keep a `docs/known_data_issues.md` recording each, with the decision you made. That document is an interview asset in itself.

**Checkpoint:** `fct_control_results` has a row per control per run, joined to the registry with severity and owner populated.

---

## Phase 9 — Orchestration and CI (3-4 days)

### GitHub Actions — scheduled production run

`.github/workflows/daily_pipeline.yml`:

```yaml
name: daily-pipeline
on:
  schedule:
    - cron: '0 11 * * *'      # 06:00 America/Toronto (adjust for DST or use 11/12)
  workflow_dispatch:

jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: '3.11'}
      - run: pip install -r requirements.txt

      - name: Auth to GCP
        uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Extract
        run: |
          python extract/osfi_extract.py
          python extract/boc_extract.py

      - name: Load
        run: python extract/load_bigquery.py

      - name: Source freshness
        working-directory: transform
        run: dbt source freshness --target prod
        continue-on-error: true          # freshness warnings shouldn't kill the run

      - name: Snapshot then build
        working-directory: transform
        run: |
          dbt snapshot --target prod
          dbt build --target prod

      - name: Upload artifacts
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: dbt-artifacts
          path: transform/target/
```

### CI on pull requests — this is what most portfolios lack

`.github/workflows/ci.yml`:

```yaml
name: ci
on: [pull_request]

jobs:
  dbt-ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... python + auth setup ...
      - name: Slim CI build
        working-directory: transform
        run: |
          dbt deps
          dbt build --select state:modified+ \
                    --defer --state ./prod-manifest \
                    --target ci
```

Store the production `manifest.json` (committed, or pulled from the last successful prod run's artifacts) so `--defer` works. The result: a PR that breaks a control fails the check and can't merge. Screenshot a red PR check in your README — it's more persuasive than any architecture diagram.

### Dagster — for the asset graph

`orchestration/definitions.py`:

```python
from dagster import Definitions, ScheduleDefinition, define_asset_job, asset
from dagster_dbt import DbtCliResource, dbt_assets

@asset(group_name="ingestion")
def osfi_raw_files(): ...

@asset(group_name="ingestion", deps=[osfi_raw_files])
def bigquery_raw_load(): ...

@dbt_assets(manifest="transform/target/manifest.json")
def dbt_models(context, dbt: DbtCliResource):
    yield from dbt.cli(["build"], context=context).stream()

defs = Definitions(
    assets=[osfi_raw_files, bigquery_raw_load, dbt_models],
    resources={"dbt": DbtCliResource(project_dir="transform")},
    schedules=[ScheduleDefinition(
        job=define_asset_job("daily", selection="*"), cron_schedule="0 6 * * *")],
)
```

```bash
dagster dev   # open localhost:3000, screenshot the asset lineage graph
```

Put that screenshot in the README. Be upfront that Dagster runs locally and Actions runs the schedule — deliberate, explained trade-offs read as engineering judgment; unexplained gaps read as gaps.

**Checkpoint:** a scheduled run completes green end-to-end, and a deliberately broken PR fails CI.

---

## Phase 10 — Dashboards (1 weekend)

Two dashboards, both required.

### Business dashboard

- Big Six total assets and growth, indexed
- Deposit mix and loan mix over time
- Net interest margin vs. Bank of Canada policy rate (dual axis) — your headline chart
- Allowance coverage ratio trend (from E3) — the credit risk angle
- Peer ranking table with quarter-over-quarter movement

### Control scorecard — the differentiator

- Control pass rate by category, trending
- Breach detail table: control ID, severity, owner, failing rows
- Source freshness vs. SLA
- **Restatement frequency by institution** — this chart exists in almost no portfolio and is genuinely interesting

Evidence.dev for the public link:

```bash
npx degit evidence-dev/template dashboards/evidence
cd dashboards/evidence && npm install && npm run dev
```

Then a Power BI version against the same BigQuery marts, `.pbix` committed, screenshots in the README.

**Checkpoint:** a stranger can open a URL and understand what the project does within 30 seconds.

---

## Phase 11 — Documentation and publish (2-3 days)

```bash
cd transform
dbt docs generate
# publish target/ to GitHub Pages via a workflow
```

### README structure — reviewers read top to bottom and stop early

1. **One-sentence description** and a link to the live dashboard
2. **The point-in-time screenshot pair** — the same balance sheet queried as-of two different dates, showing a restatement. Put this near the top; it's your strongest single artifact.
3. Architecture diagram
4. Data model ERD
5. Control framework summary — the registry table, rendered
6. **"Problems I hit and how I solved them"** — subtotal rows breaking reconciliation, fiscal-year-end cohorts, subsidiary double-counting, the knowledge-time incremental. Write these as short honest paragraphs.
7. **Known limitations** — restatement history starts at first ingest; Dagster local vs. Actions scheduled; scope limited to six institutions.
8. Run instructions

The "problems" and "limitations" sections are what separate a portfolio project from a tutorial follow-along. Do not skip them to look flawless — bank interviewers are trained to probe for exactly this, and having it written down means you'll answer well.

---

## Phase 12 — Interview preparation (half a day)

Rehearse crisp answers to these. They will be asked.

1. *"Walk me through what happens when a bank restates a prior quarter."* — bitemporal snapshot, new version row, knowledge-time incremental picks it up, restatement event surfaces on the dashboard.
2. *"How do you know your numbers are right?"* — control framework, tied to a registry with severity and ownership, results persisted and trended, plus tie-out against published annual reports.
3. *"What breaks if the source changes?"* — pinned schema assertion in the extractor, `on_schema_change` config, freshness thresholds from the published calendar, CI catches it before prod.
4. *"What would you do differently at scale?"* — real orchestration platform, alerting to PagerDuty, data contracts enforced at ingestion, separate dev/staging/prod projects, cost monitoring.
5. *"What's the weakest part of this?"* — answer honestly: restatement history only from first ingest, single-source, no real access controls, one person's judgement on the line-item hierarchy.

Prepare a 90-second version and a 5-minute version. Practice both out loud.

---

## Suggested schedule

| Weekend | Phases | Deliverable |
|---|---|---|
| 1 | 0-2 | Repo up, source profiled, schema pinned |
| 2 | 3-5 | Extractor running daily, snapshot proven on a simulated restatement |
| 3 | 6 | Seeds complete, every line item joins |
| 4 | 7-8 | Marts built, controls firing, tied out to a published annual report |
| 5 | 9 | Scheduled run green, CI blocking bad PRs |
| 6 | 10-12 | Dashboards live, README done, answers rehearsed |

**Start the daily extractor at the end of weekend 2 and leave it running.** By the time you're interviewing, you'll have months of genuine knowledge-time history — and a restatement you can point to that actually happened, not one you simulated. That single detail will do more for you than anything else in the build.
