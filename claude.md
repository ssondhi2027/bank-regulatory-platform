## Project

A Canadian bank regulatory reporting data platform. Ingests OSFI bank
financial returns and Bank of Canada rate data, models them with dbt Core
into a finance/risk mart with a formal data-control framework, and serves
two dashboards. Portfolio project targeting Canadian bank data roles.

**Read `docs/PROJECT_STRUCTURE.md` and `docs/BUILD_GUIDE.md` before
proposing any implementation.** They contain the model layout, control
registry, and phased build order. Follow them unless you have a specific
reason not to — and say so if you do.

## Stack

- Python 3.11, requests + pandas (extraction)
- BigQuery (warehouse), dbt-core + dbt-bigquery
- Dagster (asset definitions), GitHub Actions (scheduled runs + CI)
- Evidence.dev + Power BI (dashboards)

## Non-negotiable rules

1. **Never invent a data schema.** The OSFI CSV column names are not known
   yet. Do not write parsing, staging, or model SQL that references a column
   until it has been confirmed by running the profiler and I have seen the
   output. If you need a column name, stop and ask.

2. **Never commit credentials.** No service account JSON, no `.env`, no
   tokens in code or in test fixtures. `.gitignore` must cover them before
   any auth code is written.

3. **Never hardcode Open Government download URLs** in production code.
   Resolve them at runtime from the CKAN endpoint:
   `https://open.canada.ca/data/api/action/package_show?id=91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de`

4. **Incremental models filter on knowledge time, never business time.**
   Regulatory filings get restated. `fct_*` incremental logic must filter on
   `known_from_ts` (derived from snapshot `dbt_valid_from`), never on
   `reporting_period_end`. Filtering on the reporting period silently and
   permanently drops restatements. Add a code comment explaining this
   wherever it appears.

5. **Exclude subtotal rows before aggregating.** Raw OSFI returns interleave
   detail lines and subtotal/total lines. Any aggregation must filter on the
   `is_subtotal` flag from `seed_line_item_hierarchy` or it double-counts.

6. **The extraction landing zone is append-only and content-addressed.**
   Files are written to a path derived from their SHA-256 hash. Never
   overwrite or delete a landed file.

7. **Reconciliation controls use a materiality tolerance**, not exact
   equality — OSFI reports in thousands and rounds.

## Working style

- Work one phase at a time. Do not jump ahead to later phases.
- Before writing code for a phase, tell me your plan in 5 lines or fewer and
  wait for confirmation.
- After each phase, run the checkpoint from `docs/BUILD_GUIDE.md` and show me
  the actual output. Do not report a checkpoint as passed without running it.
- If something is ambiguous, ask rather than assume. A wrong assumption here
  costs a day.
- Prefer small commits with clear messages. Commit at each checkpoint.

## Commands

```bash
source .venv/bin/activate
python extract/osfi_extract.py       # ingest OSFI returns
python extract/boc_extract.py        # ingest Bank of Canada rates
python extract/load_bigquery.py      # load landing zone to raw
cd transform && dbt snapshot && dbt build
cd transform && dbt test --select fct_balance_sheet
dagster dev                          # asset graph at localhost:3000
```

## Current phase

Phase 10 in progress: control scorecard dashboard done
(dashboards/evidence, pages/home.md -- pass rate trend, breach detail,
source freshness vs SLA, restatement frequency by institution, all
verified against real BigQuery data).

BoC rates + fct_financial_metrics now built (previously deferred from
Phase 7): extract/load_boc_bigquery.py loads Valet observations into
boc_raw; stg_boc__rate_observations -> int_rates__period_aligned
(period-end + trailing 3-month average per series); a new
int_filings__income_statement_quarterly de-cumulates P3's YTD figures into
true single-quarter figures (see docs/known_data_issues.md); NIM/ROA/ROE/
efficiency ratio/deposit-to-loan/allowance coverage all in
fct_financial_metrics, verified against RBC's actual disclosures. No CAP
return ingested, so no tier 1 capital ratio.

Business dashboard itself (the NIM-vs-policy-rate chart, peer rankings)
not yet built in dashboards/evidence -- the data is ready but the page
isn't written. Power BI version not started -- needs manual GUI work in
Power BI Desktop, not automatable from here.
(Update this line as you go. It's how Claude Code knows where we are.)

Read CLAUDE.md, docs/PROJECT_STRUCTURE.md, and docs/BUILD_GUIDE.md.

Then do Phase 1 only (repo scaffolding and environment):
- Create the directory structure and a .gitignore that covers .env,
  service account JSON, .venv, target/, dbt_packages/, logs/, data/raw/
- Create requirements.txt with the packages listed in the build guide
- Create .env.example with the variable names needed (no values)
- Set up the Python venv and install dependencies
- Verify with `dbt --version`

Stop after Phase 1. Show me the tree and confirm the checkpoint passed.
Do not write any extraction or dbt code yet.

Phase 2: profile the OSFI source data.

Write extract/profile_source.py per the build guide. Run it against the M4,
P3, and E3 CSVs and show me the FULL output — shape, dtypes, head, and
per-column cardinality with sample values for low-cardinality columns.

Then answer these six questions from the actual output, not from assumption:
1. Is each file long or wide?
2. What identifies an institution?
3. How is the reporting period expressed?
4. Is there a line-item code, or only a description?
5. Are amounts in thousands, and is there a units/currency column?
6. Are subtotal/total rows interleaved with detail rows? How can we tell
   them apart programmatically?

Do not write extract/schema.yml until I've reviewed your answers.

Phase 3: build the extractor.

Write extract/osfi_extract.py per the build guide:
- Resolve resource URLs from the CKAN package_show endpoint (never hardcode)
- SHA-256 content addressing; skip write if the hash already exists
- Sidecar .meta.json per landed file with hash, URL, CKAN last_modified,
  ingested_at, size
- Assert the downloaded schema matches extract/schema.yml and fail loudly
  if it doesn't

Then extract/boc_extract.py for the Bank of Canada Valet API. First call
https://www.bankofcanada.ca/valet/lists/series to confirm the exact series
names for the policy rate, 2Y and 10Y GoC yields, and CAD/USD — do not
guess them.

Checkpoint: run osfi_extract.py twice. The second run must print "unchanged"
for every return and create no new files. Show me both runs.

Phase 4: load the landing zone into BigQuery raw.

Write extract/load_bigquery.py per the build guide. Raw must land as-is
(all columns as strings) plus audit columns: source_file_name,
source_file_hash, source_return_code, ckan_last_modified, ingested_at.

No cleaning, no renaming, no type casting — that all belongs in dbt.

Checkpoint: show row counts grouped by source_return_code.

Phase 5: dbt init, sources, and the restatement snapshot.

1. dbt init in transform/, configure profiles for BigQuery dev and prod
   targets, dbt debug must pass
2. packages.yml with dbt_utils and dbt_expectations, dbt deps
3. _osfi__sources.yml with freshness thresholds: warn 45 days, error 75 days
   (OSFI publishes monthly returns around the 15th of the following month)
4. snapshots/snap_osfi_filings — strategy check on the amount column,
   unique_key a surrogate of institution + return code + reporting period +
   line item, hard deletes invalidated
5. stg_osfi__filings reading FROM THE SNAPSHOT, exposing known_from_ts,
   known_to_ts, is_current_version

Then prove the snapshot works: after the first dbt snapshot, manually modify
one amount in one landed CSV, reload, and re-snapshot. Show me the query
proving two version rows exist for that key, one closed and one open.

Do not proceed to Phase 6 until you've shown me those two rows.

Phase 6: seeds.

Start with seed_institution_master.csv only. Download the "Who we regulate"
dataset (b27ec3ef-7338-4e76-a6fd-128339a92df5) and the List of Bank
Subsidiaries XLSX from the Banks dataset, and build a CSV with:
institution_id, legal_name, short_name, schedule_type,
fiscal_year_end_month, parent_institution_id, peer_group.

Scope to the Big Six plus any of their subsidiaries that appear in the
filings, peer_group = BIG_SIX.

For seed_line_item_hierarchy.csv: parse the OSFI Data Dictionary XLSX and
propose a draft, but flag every line item where the parent or the
is_subtotal flag is uncertain. I will review before we commit it.

Do not generate seed_control_registry.csv — I'll supply it from
docs/PROJECT_STRUCTURE.md.

Checkpoint: the anti-join query in the build guide returns zero rows.

Phase 7: intermediate models and marts, in the order given in
docs/PROJECT_STRUCTURE.md.

Reminder: fct_balance_sheet's incremental filter uses known_from_ts, not
reporting_period_end. Include the explanatory comment.

Then test it: restate an old period in the source, run an incremental (not
full-refresh) build, and show me that the old period's value updated.

Checkpoint: one row per institution per period, and total assets for RBC's
most recent quarter within rounding error of their published statements —
show me both numbers side by side.

Phase 8: control framework.

Implement the controls from seed_control_registry.csv in the order given in
the build guide. Use materiality tolerances, not exact equality.

Include REC-007 (industry total ties to published) — this needs the foreign
bank branches dataset and must exclude bank subsidiaries of banks to avoid
double-counting.

Include CMP-001 with fiscal-year-end cohort logic: October FYE and December
FYE filers publish on different dates, so a naive "did everyone file?" check
false-alarms.

Then the on-run-end logging macro, fct_control_results, and
rpt_control_scorecard.

Expect failures on the first run. For each one, tell me whether it's our bug
or a real data characteristic, and log the real ones to
docs/known_data_issues.md with the decision made.

Phase 9: orchestration and CI.

1. .github/workflows/daily_pipeline.yml — cron at 11:00 UTC, GCP auth via
   the GCP_SA_KEY secret, extract then load then source freshness
   (continue-on-error) then snapshot then dbt build, upload target/ as an
   artifact on always()
2. .github/workflows/ci.yml — on pull_request, slim CI:
   dbt build --select state:modified+ --defer --state ./prod-manifest
   --target ci. Explain how I should store and refresh prod-manifest.
3. orchestration/definitions.py — Dagster assets wrapping the extract and
   load steps plus @dbt_assets over the dbt project, with a daily schedule.

Then tell me exactly which GitHub secrets I need to create and how to
generate the service account with least-privilege roles.

Checkpoint: I'll open a PR that breaks a control and confirm CI fails.

