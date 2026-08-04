# Canadian Bank Regulatory Reporting Platform — dbt Project Structure

A bitemporal dbt Core project over OSFI bank financial filings and Bank of Canada rate data, with a formal data-control framework.

---

## 1. The one design decision everything else follows from

Regulatory filings get **restated**. An institution files Q1 in May, then refiles a corrected Q1 in November. This means every number has two time dimensions:

| Dimension | Column | Meaning |
|---|---|---|
| **Business / valid time** | `reporting_period_end` | *what period the number describes* |
| **System / knowledge time** | `dbt_valid_from` / `dbt_valid_to` | *when we learned the number* |

This is a **bitemporal** model. Getting it right lets you answer both:

- "What is Q1 total assets?" → latest known version
- "What did we report for Q1 as of June 30?" → point-in-time reconstruction

**The trap most people fall into:** building `fct_balance_sheet` as incremental filtered on `reporting_period_end > (select max(...) from this)`. That is *wrong here* — a restatement of a two-year-old period arrives today and will never be picked up. Your incremental filter must key off **knowledge time**, not business time. Call this out explicitly in your README; it's a strong interview signal.

---

## 2. Folder structure

```
bank_regulatory_platform/
├── dbt_project.yml
├── packages.yml
├── profiles.yml.example
├── README.md
│
├── seeds/
│   ├── seed_institution_master.csv
│   ├── seed_line_item_hierarchy.csv
│   ├── seed_peer_group.csv
│   ├── seed_control_registry.csv
│   └── seeds.yml
│
├── snapshots/
│   ├── snap_osfi_filings.yml
│   └── snap_institution_registry.yml
│
├── macros/
│   ├── generate_schema_name.sql
│   ├── audit_columns.sql
│   ├── log_dbt_results.sql
│   ├── period_end_helpers.sql
│   └── tests/
│       ├── test_subtotal_rollup.sql
│       ├── test_period_sequence_complete.sql
│       └── test_within_tolerance_of.sql
│
├── models/
│   ├── staging/
│   │   ├── osfi/
│   │   │   ├── _osfi__sources.yml
│   │   │   ├── _osfi__models.yml
│   │   │   ├── stg_osfi__filings.sql
│   │   │   └── stg_osfi__institutions.sql
│   │   ├── boc/
│   │   │   ├── _boc__sources.yml
│   │   │   ├── _boc__models.yml
│   │   │   └── stg_boc__rate_observations.sql
│   │   └── statcan/
│   │       ├── _statcan__sources.yml
│   │       └── stg_statcan__household_credit.sql
│   │
│   ├── intermediate/
│   │   ├── filings/
│   │   │   ├── int_filings__current_version.sql
│   │   │   ├── int_filings__restatement_events.sql
│   │   │   ├── int_filings__balance_sheet_pivoted.sql
│   │   │   └── int_filings__income_statement_pivoted.sql
│   │   └── rates/
│   │       ├── int_rates__period_aligned.sql
│   │       └── int_rates__yield_curve_daily.sql
│   │
│   └── marts/
│       ├── core/
│       │   ├── dim_institution.sql
│       │   ├── dim_line_item.sql
│       │   ├── dim_reporting_period.sql
│       │   ├── dim_date.sql
│       │   └── _core__models.yml
│       ├── finance/
│       │   ├── fct_balance_sheet.sql
│       │   ├── fct_income_statement.sql
│       │   ├── fct_financial_metrics.sql
│       │   ├── fct_peer_benchmark.sql
│       │   ├── fct_restatement_history.sql
│       │   └── _finance__models.yml
│       ├── risk/
│       │   ├── fct_rate_sensitivity.sql
│       │   └── _risk__models.yml
│       └── controls/
│           ├── fct_control_results.sql
│           ├── fct_pipeline_run_log.sql
│           ├── rpt_control_scorecard.sql
│           └── _controls__models.yml
│
└── tests/
    ├── rec_001_balance_sheet_balances.sql
    ├── rec_003_income_statement_rollforward.sql
    ├── rec_004_retained_earnings_continuity.sql
    ├── rec_005_cross_return_net_income_tieout.sql
    └── pla_003_no_duplicate_active_versions.sql
```

---

## 3. Layer by layer

### Sources

`models/staging/osfi/_osfi__sources.yml`

```yaml
version: 2

sources:
  - name: osfi_raw
    database: "{{ env_var('RAW_DATABASE') }}"
    schema: osfi_raw
    description: >
      Landed OSFI financial returns. Append-only. Each ingestion writes a new
      batch; restatements arrive as new rows, never updates in place.
    loaded_at_field: ingested_at
    freshness:
      warn_after: {count: 45, period: day}
      error_after: {count: 75, period: day}
    tables:
      - name: filings
        columns:
          - name: institution_id
          - name: report_type          # BS | IS | CAP
          - name: reporting_period_end
          - name: schedule_code
          - name: line_item_code
          - name: amount_cad_000
          - name: source_file_name
          - name: source_file_hash     # audit trail
          - name: source_published_at  # OSFI publication date
          - name: ingested_at
      - name: institutions

  - name: boc_raw
    schema: boc_raw
    loaded_at_field: ingested_at
    freshness:
      warn_after: {count: 2, period: day}
      error_after: {count: 5, period: day}
    tables:
      - name: valet_observations       # series_id, obs_date, value
```

**Ingestion contract (your Python extractor must guarantee this):** append-only, idempotent by `source_file_hash`, and it never overwrites a prior filing. dbt's job is to reason about versions, not to receive them pre-resolved.

---

### Snapshots — the restatement engine

`snapshots/snap_osfi_filings.yml` (dbt 1.9+ YAML snapshot syntax)

```yaml
snapshots:
  - name: snap_osfi_filings
    relation: source('osfi_raw', 'filings')
    config:
      schema: snapshots
      unique_key: filing_line_key
      strategy: check
      check_cols: ['amount_cad_000']
      hard_deletes: invalidate      # pre-1.9: invalidate_hard_deletes: true
```

If you need the surrogate key built before snapshotting, use the classic SQL form instead:

```sql
{% snapshot snap_osfi_filings %}
{{
  config(
    target_schema='snapshots',
    unique_key='filing_line_key',
    strategy='check',
    check_cols=['amount_cad_000'],
    invalidate_hard_deletes=True
  )
}}

select
    {{ dbt_utils.generate_surrogate_key([
        'institution_id', 'report_type',
        'reporting_period_end', 'line_item_code'
    ]) }}                              as filing_line_key,
    institution_id,
    report_type,
    reporting_period_end,
    schedule_code,
    line_item_code,
    amount_cad_000,
    source_file_hash,
    source_published_at
from {{ source('osfi_raw', 'filings') }}

{% endsnapshot %}
```

**Why `check` and not `timestamp`:** OSFI doesn't give you a reliable per-row updated-at. `check` on the amount column is what detects a restatement.

**Why `invalidate_hard_deletes`:** when a restated filing *drops* a line item that previously existed, that's a real change — it must be closed off, not silently left open.

**Two caveats to document (they show maturity):**
1. Snapshot resolution is bounded by run cadence. Snapshot daily and you can reconstruct daily knowledge; snapshot weekly and you can't. Say so in the README.
2. Snapshot the **raw/staging** grain, never the mart. Snapshotting a transformed model means a logic change looks like a data change.

Also snapshot the institution registry — banks merge, get acquired, change legal names, change status. That's genuine SCD2 on reference data:

```yaml
snapshots:
  - name: snap_institution_registry
    relation: source('osfi_raw', 'institutions')
    config:
      unique_key: institution_id
      strategy: check
      check_cols: ['legal_name', 'schedule_type', 'status', 'parent_institution_id']
```

---

### Staging

Thin: rename, cast, standardize. One model per source table, views.

`stg_osfi__filings.sql`

```sql
with source as (
    select * from {{ ref('snap_osfi_filings') }}
),

renamed as (
    select
        filing_line_key,
        institution_id,
        upper(trim(report_type))                    as report_type,
        cast(reporting_period_end as date)          as reporting_period_end,
        trim(schedule_code)                         as schedule_code,
        trim(line_item_code)                        as line_item_code,
        cast(amount_cad_000 as numeric(20, 3))      as amount_cad_000,
        source_file_hash,
        cast(source_published_at as date)           as source_published_at,

        -- knowledge-time window
        dbt_valid_from                              as known_from_ts,
        dbt_valid_to                                as known_to_ts,
        (dbt_valid_to is null)                      as is_current_version
    from source
)

select * from renamed
```

Note that staging reads from the **snapshot**, not the source. The snapshot is the system of record from here down.

---

### Intermediate

`int_filings__current_version.sql` — the "as we know it today" spine.

```sql
{{ config(materialized='ephemeral') }}

select
    filing_line_key,
    institution_id,
    report_type,
    reporting_period_end,
    schedule_code,
    line_item_code,
    amount_cad_000,
    known_from_ts,
    source_published_at
from {{ ref('stg_osfi__filings') }}
where is_current_version
```

`int_filings__restatement_events.sql` — a first-class output, not a byproduct. This becomes a dashboard tile.

```sql
with versions as (
    select
        filing_line_key,
        institution_id,
        report_type,
        reporting_period_end,
        line_item_code,
        amount_cad_000,
        known_from_ts,
        known_to_ts,
        row_number() over (
            partition by filing_line_key order by known_from_ts
        ) as version_no,
        lag(amount_cad_000) over (
            partition by filing_line_key order by known_from_ts
        ) as prior_amount_cad_000,
        min(known_from_ts) over (partition by filing_line_key) as first_known_ts
    from {{ ref('stg_osfi__filings') }}
)

select
    filing_line_key,
    institution_id,
    report_type,
    reporting_period_end,
    line_item_code,
    version_no                                          as restatement_seq,
    prior_amount_cad_000                                as original_amount_cad_000,
    amount_cad_000                                      as restated_amount_cad_000,
    amount_cad_000 - prior_amount_cad_000               as restatement_delta_cad_000,
    case
        when coalesce(prior_amount_cad_000, 0) = 0 then null
        else (amount_cad_000 - prior_amount_cad_000)
             / abs(prior_amount_cad_000)
    end                                                 as restatement_pct,
    first_known_ts                                      as originally_known_at,
    known_from_ts                                       as restated_known_at,
    date_diff('day', first_known_ts, known_from_ts)     as days_to_restatement
from versions
where version_no > 1
```

`int_filings__balance_sheet_pivoted.sql` — long-to-wide using the line-item hierarchy seed, producing named measures (`total_assets`, `total_deposits`, `gross_loans`, `allowance_for_credit_losses`, `total_liabilities`, `total_equity`, `retained_earnings`).

`int_rates__period_aligned.sql` — collapses daily BoC observations to period-end and period-average per reporting period, so rate joins to filings don't fan out.

---

### Marts

**Grain declarations (state these in YAML descriptions — reviewers look for it):**

| Model | Grain |
|---|---|
| `dim_institution` | one row per institution per SCD2 version |
| `dim_line_item` | one row per line item code |
| `dim_reporting_period` | one row per reporting period end |
| `fct_balance_sheet` | institution × reporting_period_end |
| `fct_income_statement` | institution × reporting_period_end |
| `fct_financial_metrics` | institution × reporting_period_end |
| `fct_peer_benchmark` | peer_group × reporting_period_end × metric |
| `fct_restatement_history` | filing_line_key × restatement_seq |
| `fct_control_results` | run_id × control_id × invocation |

`fct_balance_sheet.sql` — **restatement-aware incremental**:

```sql
{{
  config(
    materialized='incremental',
    unique_key=['institution_key', 'reporting_period_end'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    contract={'enforced': true}
  )
}}

with base as (
    select * from {{ ref('int_filings__balance_sheet_pivoted') }}

    {% if is_incremental() %}
    -- CRITICAL: filter on KNOWLEDGE time, not reporting period.
    -- A restatement of an old period arrives with a new known_from_ts and
    -- must be reprocessed. Filtering on reporting_period_end would drop it.
    where known_from_ts > (
        select coalesce(max(source_known_from_ts), '1900-01-01')
        from {{ this }}
    )
    {% endif %}
)

select
    {{ dbt_utils.generate_surrogate_key(['b.institution_id']) }} as institution_key,
    b.institution_id,
    b.reporting_period_end,
    b.total_assets_cad_000,
    b.total_liabilities_cad_000,
    b.total_equity_cad_000,
    b.total_deposits_cad_000,
    b.gross_loans_cad_000,
    b.allowance_for_credit_losses_cad_000,
    b.retained_earnings_cad_000,
    b.known_from_ts                                as source_known_from_ts,
    {{ audit_columns() }}
from base b
```

`fct_financial_metrics.sql` — derived ratios, each with a documented formula in YAML: net interest margin, return on assets, return on equity, efficiency ratio, deposit-to-loan ratio, allowance coverage ratio, tier 1 capital ratio (if you ingest the CAP return).

`fct_rate_sensitivity.sql` — joins `fct_financial_metrics` to `int_rates__period_aligned`; regresses NIM against policy rate / 2s10s spread per institution. This is your "so what" model.

---

## 4. The control framework

### Control registry seed

`seeds/seed_control_registry.csv`

```csv
control_id,control_name,category,severity,owner,description,regulatory_ref
REC-001,balance_sheet_balances,Reconciliation,error,Finance Data,Assets equal liabilities plus equity per institution per period,BCBS 239 P3 Accuracy
REC-002,subtotal_rollup_integrity,Reconciliation,error,Finance Data,Child line items sum to declared parent subtotal,BCBS 239 P3 Accuracy
REC-003,income_statement_rollforward,Reconciliation,error,Finance Data,Net income reconciles to revenue less expenses provisions and tax,BCBS 239 P3 Accuracy
REC-004,retained_earnings_continuity,Reconciliation,warn,Finance Data,Retained earnings roll forward across consecutive periods,BCBS 239 P3 Accuracy
REC-005,cross_return_net_income_tieout,Reconciliation,error,Finance Data,Net income agrees between income statement and equity section,BCBS 239 P3 Accuracy
REC-006,restated_filing_still_balances,Reconciliation,error,Finance Data,Restated versions satisfy the balance sheet identity,BCBS 239 P7 Accuracy
CMP-001,all_expected_institutions_filed,Completeness,error,Platform,Every active institution has a filing for the period,BCBS 239 P4 Completeness
CMP-002,no_reporting_period_gaps,Completeness,error,Platform,No missing periods in an institution filing sequence,BCBS 239 P4 Completeness
CMP-003,mandatory_line_items_present,Completeness,warn,Finance Data,All mandatory line items present in each return,BCBS 239 P4 Completeness
CMP-004,row_volume_within_expected_band,Completeness,warn,Platform,Ingested row count within tolerance of trailing average,BCBS 239 P4 Completeness
VAL-001,amounts_not_null_numeric,Validity,error,Platform,Amount values are populated and numeric,BCBS 239 P3 Accuracy
VAL-002,sign_convention_respected,Validity,warn,Finance Data,Line items follow expected sign conventions,BCBS 239 P3 Accuracy
VAL-003,institution_in_registry,Validity,error,Platform,Institution identifier exists in the registry,BCBS 239 P3 Integrity
VAL-004,period_end_is_valid_boundary,Validity,error,Platform,Reporting period end is a valid month or quarter end,BCBS 239 P3 Accuracy
VAL-005,units_and_currency_consistent,Validity,error,Platform,All amounts expressed in thousands of Canadian dollars,BCBS 239 P3 Accuracy
TML-001,osfi_source_freshness,Timeliness,warn,Platform,OSFI filings received within expected publication lag,BCBS 239 P5 Timeliness
TML-002,boc_business_day_coverage,Timeliness,error,Platform,Rate series has an observation for every business day,BCBS 239 P5 Timeliness
PLA-001,total_assets_change_plausible,Plausibility,warn,Finance Data,Period over period asset change within expected band,BCBS 239 P3 Accuracy
PLA-002,nim_within_plausible_range,Plausibility,warn,Finance Data,Net interest margin falls in a plausible range,BCBS 239 P3 Accuracy
PLA-003,no_duplicate_active_versions,Plausibility,error,Platform,Exactly one current version per filing line key,BCBS 239 P3 Integrity
```

### Naming convention that wires tests to controls

Name every test with its control ID. The control ID becomes the join key between dbt's run artifacts and your registry.

```yaml
models:
  - name: fct_balance_sheet
    tests:
      - dbt_utils.expression_is_true:
          name: rec_001_balance_sheet_balances
          expression: >
            abs(total_assets_cad_000
                - (total_liabilities_cad_000 + total_equity_cad_000)) <= 1
          config:
            severity: error
            store_failures: true
            store_failures_as: table
```

### Singular tests

`tests/rec_005_cross_return_net_income_tieout.sql`

```sql
with income_stmt as (
    select institution_id, reporting_period_end, net_income_cad_000
    from {{ ref('fct_income_statement') }}
),

balance_sheet as (
    select institution_id, reporting_period_end, net_income_in_equity_cad_000
    from {{ ref('fct_balance_sheet') }}
)

select
    i.institution_id,
    i.reporting_period_end,
    i.net_income_cad_000,
    b.net_income_in_equity_cad_000,
    i.net_income_cad_000 - b.net_income_in_equity_cad_000 as variance_cad_000
from income_stmt i
join balance_sheet b
  on  i.institution_id = b.institution_id
  and i.reporting_period_end = b.reporting_period_end
where abs(i.net_income_cad_000 - b.net_income_in_equity_cad_000) > 1
```

`tests/rec_004_retained_earnings_continuity.sql`

```sql
with rolled as (
    select
        bs.institution_id,
        bs.reporting_period_end,
        bs.retained_earnings_cad_000,
        lag(bs.retained_earnings_cad_000) over (
            partition by bs.institution_id order by bs.reporting_period_end
        ) as prior_retained_earnings_cad_000,
        is_.net_income_cad_000,
        is_.dividends_declared_cad_000
    from {{ ref('fct_balance_sheet') }} bs
    left join {{ ref('fct_income_statement') }} is_
      on  bs.institution_id = is_.institution_id
      and bs.reporting_period_end = is_.reporting_period_end
)

select *
from rolled
where prior_retained_earnings_cad_000 is not null
  and abs(
        retained_earnings_cad_000
        - (prior_retained_earnings_cad_000
           + coalesce(net_income_cad_000, 0)
           - coalesce(dividends_declared_cad_000, 0))
      ) > greatest(50, abs(retained_earnings_cad_000) * 0.001)
```

### Generic test macro — subtotal rollup

`macros/tests/test_subtotal_rollup.sql`

```sql
{% test subtotal_rollup(model, parent_code_column, child_code_column,
                        amount_column, tolerance=1) %}

with hierarchy as (
    select line_item_code, parent_line_item_code
    from {{ ref('seed_line_item_hierarchy') }}
    where parent_line_item_code is not null
),

child_sums as (
    select
        m.institution_id,
        m.reporting_period_end,
        h.parent_line_item_code,
        sum(m.{{ amount_column }}) as child_total
    from {{ model }} m
    join hierarchy h on m.{{ child_code_column }} = h.line_item_code
    group by 1, 2, 3
),

declared as (
    select
        institution_id,
        reporting_period_end,
        {{ parent_code_column }} as parent_line_item_code,
        {{ amount_column }}      as declared_total
    from {{ model }}
)

select
    c.institution_id,
    c.reporting_period_end,
    c.parent_line_item_code,
    c.child_total,
    d.declared_total,
    c.child_total - d.declared_total as variance
from child_sums c
join declared d
  on  c.institution_id = d.institution_id
  and c.reporting_period_end = d.reporting_period_end
  and c.parent_line_item_code = d.parent_line_item_code
where abs(c.child_total - d.declared_total) > {{ tolerance }}

{% endtest %}
```

### Capturing results into `fct_control_results`

`macros/log_dbt_results.sql` — an `on-run-end` hook that persists every test outcome.

```sql
{% macro log_dbt_results(results) %}
  {% if execute and results and target.name == 'prod' %}
    {% set rows = [] %}
    {% for res in results %}
      {% if res.node.resource_type == 'test' %}
        {% do rows.append(
          "('" ~ invocation_id ~ "','" ~ res.node.name ~ "','"
               ~ res.status ~ "'," ~ (res.failures | default(0)) ~ ","
               ~ (res.execution_time | round(3)) ~ ",current_timestamp)"
        ) %}
      {% endif %}
    {% endfor %}
    {% if rows | length > 0 %}
      insert into {{ target.schema }}_audit.dbt_test_log
        (invocation_id, test_name, status, failure_count, execution_seconds, logged_at)
      values {{ rows | join(', ') }}
    {% endif %}
  {% endif %}
{% endmacro %}
```

Wired in `dbt_project.yml`:

```yaml
on-run-end:
  - "{{ log_dbt_results(results) }}"
```

`models/marts/controls/fct_control_results.sql`

```sql
with log as (
    select * from {{ source('audit', 'dbt_test_log') }}
),

registry as (
    select * from {{ ref('seed_control_registry') }}
),

joined as (
    select
        l.invocation_id                                as run_id,
        upper(replace(split_part(l.test_name, '_', 1)
              || '-' || split_part(l.test_name, '_', 2), ' ', ''))  as control_id,
        l.test_name,
        l.status,
        l.failure_count,
        l.execution_seconds,
        l.logged_at
    from log l
)

select
    j.run_id,
    j.control_id,
    r.control_name,
    r.category,
    r.severity,
    r.owner,
    r.regulatory_ref,
    j.status,
    j.failure_count,
    case when j.status in ('pass', 'warn') then 1 else 0 end as is_passing,
    j.execution_seconds,
    j.logged_at
from joined j
left join registry r on j.control_id = r.control_id
```

`rpt_control_scorecard.sql` aggregates to run × category: pass rate, breach count, worst-severity breach, trailing 30-day pass rate. That is page two of your dashboard.

> **Shortcut option:** the `elementary-data` or `dbt_artifacts` package gives you run logging out of the box. Building the macro yourself demonstrates more, but mention in the README that you evaluated both and why you chose yours.

---

## 5. `dbt_project.yml`

```yaml
name: 'bank_regulatory_platform'
version: '1.0.0'
config-version: 2
profile: 'bank_regulatory_platform'

model-paths: ["models"]
seed-paths: ["seeds"]
test-paths: ["tests"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

vars:
  as_of_ts: null                 # override for point-in-time reconstruction
  materiality_threshold_cad_000: 1
  peer_group_default: 'BIG_SIX'

on-run-end:
  - "{{ log_dbt_results(results) }}"

models:
  bank_regulatory_platform:
    +persist_docs:
      relation: true
      columns: true
    staging:
      +materialized: view
      +schema: staging
    intermediate:
      +materialized: ephemeral
      +schema: intermediate
    marts:
      +materialized: table
      core:
        +schema: core
      finance:
        +schema: finance
        +contract:
          enforced: true
      risk:
        +schema: risk
      controls:
        +schema: controls

seeds:
  bank_regulatory_platform:
    +schema: reference
    seed_control_registry:
      +column_types:
        control_id: varchar(10)

snapshots:
  bank_regulatory_platform:
    +target_schema: snapshots

tests:
  +store_failures: true
  +schema: dq_failures
```

`packages.yml`

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
  - package: calogica/dbt_expectations
    version: [">=0.10.0", "<0.11.0"]
  - package: dbt-labs/codegen
    version: [">=0.12.0", "<0.13.0"]
```

---

## 6. Point-in-time reconstruction

The payoff model. Prove you can answer "what did we know on date X."

```sql
-- models/marts/finance/fct_balance_sheet_as_of.sql
{{ config(materialized='view') }}

{% set as_of = var('as_of_ts', None) %}

select
    institution_id,
    reporting_period_end,
    line_item_code,
    amount_cad_000,
    known_from_ts,
    known_to_ts
from {{ ref('stg_osfi__filings') }}
{% if as_of %}
where known_from_ts <= '{{ as_of }}'
  and (known_to_ts > '{{ as_of }}' or known_to_ts is null)
{% else %}
where is_current_version
{% endif %}
```

Run it two ways in your demo:

```bash
dbt build --select fct_balance_sheet_as_of
dbt build --select fct_balance_sheet_as_of --vars '{"as_of_ts": "2025-06-30 00:00:00"}'
```

Screenshot the diff. That single before/after is the most persuasive artifact in the whole project.

---

## 7. Exposures

`models/marts/_exposures.yml`

```yaml
version: 2

exposures:
  - name: peer_benchmarking_dashboard
    type: dashboard
    maturity: high
    url: https://your-dashboard-url
    owner:
      name: Simranvir
      email: your@email.com
    description: >
      Big Six peer benchmarking — asset growth, deposit mix, NIM vs policy rate.
    depends_on:
      - ref('fct_peer_benchmark')
      - ref('fct_financial_metrics')
      - ref('fct_rate_sensitivity')

  - name: data_control_scorecard
    type: dashboard
    maturity: high
    owner:
      name: Simranvir
      email: your@email.com
    description: >
      Control pass rate by category and severity, breach detail, freshness,
      and restatement frequency by institution.
    depends_on:
      - ref('rpt_control_scorecard')
      - ref('fct_control_results')
      - ref('fct_restatement_history')
```

---

## 8. Build order

```
seeds ──────────────────────────────┐
                                    │
sources ──> snapshots ──> staging ──┴──> intermediate ──> marts/core
                                                            │
                                                            ├──> marts/finance
                                                            ├──> marts/risk
                                                            └──> marts/controls
```

Commands worth putting in your README:

```bash
dbt deps && dbt seed
dbt snapshot
dbt build --select staging+ intermediate+
dbt build --select marts.finance marts.risk
dbt build --select marts.controls
dbt source freshness
dbt docs generate && dbt docs serve
```

CI slim run on pull requests:

```bash
dbt build --select state:modified+ --defer --state ./prod-manifest --target ci
```

---

## 9. Build sequence (suggested order of work)

1. Extractor + `snap_osfi_filings` + `stg_osfi__filings`. Prove restatement capture works by re-ingesting a corrected file.
2. Line-item hierarchy seed + pivoted intermediate models. This is the tedious part; budget for it.
3. `fct_balance_sheet` with the knowledge-time incremental. Write REC-001 and REC-002 immediately.
4. Income statement, then the cross-return tie-out (REC-005).
5. BoC rates, `fct_financial_metrics`, `fct_rate_sensitivity`.
6. Control registry, logging macro, `fct_control_results`, scorecard.
7. Orchestration + CI, then dashboards, then `dbt docs` on GitHub Pages.

Scope guard: six institutions, five years, three return types. Depth beats breadth for this audience.
