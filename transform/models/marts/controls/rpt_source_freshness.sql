{{ config(materialized='table') }}

-- `dbt source freshness` computes this on every run but only ever writes
-- it to target/sources.json (a run artifact, not a queryable table) --
-- there was nothing to build a "freshness vs SLA" dashboard tile from.
-- This recomputes the same thing directly from osfi_raw.filings, using the
-- identical thresholds already pinned in _osfi__sources.yml (warn 45 days,
-- error 75 days) rather than inventing new ones.

with latest_per_return as (

    select
        source_return_code,
        -- raw lands ingested_at as a STRING (all raw columns do); cast
        -- through TIMESTAMP before date arithmetic, not straight to DATE
        -- (a bare string-to-DATE cast can't parse the ISO datetime+offset
        -- format extract/load_bigquery.py writes, e.g.
        -- "2026-08-25T20:42:34.552764+00:00").
        max(cast(ingested_at as timestamp)) as last_ingested_at
    from {{ source('osfi_raw', 'filings') }}
    group by 1

)

select
    source_return_code,
    last_ingested_at,
    date_diff(current_date(), date(last_ingested_at), day) as days_since_ingested,
    case
        when date_diff(current_date(), date(last_ingested_at), day) > 75 then 'error'
        when date_diff(current_date(), date(last_ingested_at), day) > 45 then 'warn'
        else 'pass'
    end as freshness_status
from latest_per_return
