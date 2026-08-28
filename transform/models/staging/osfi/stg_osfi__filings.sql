{{ config(materialized='view') }}

-- Reads from the SNAPSHOT, not the source. From here down, the snapshot is
-- the system of record: it is where restatement (knowledge-time) history
-- lives. Thin layer: renaming to expose the snapshot's own bookkeeping
-- columns under clearer names, and casting the one column that needs it
-- (amount_cad_000, string -> numeric, so downstream models can do
-- arithmetic).
--
-- One filter does happen here, deliberately: a trailing scope_years window
-- on reporting_period_raw's leading 4-digit year. Both M4's "YYYY-MM-DD"
-- and P3/E3's "YYYY-Qn - YYYY" period representations start with the
-- calendar/fiscal year, so this one regex works for all three returns.
-- This is a scope decision, not a data-loss one: the landing zone and
-- snapshot both retain full history; widening scope later only requires
-- bumping the var, never re-extracting. See docs/known_data_issues.md for
-- why staying inside this window matters (OSFI line-item code churn).

with source as (

    select * from {{ ref('snap_osfi_filings') }}
    where cast(regexp_extract(reporting_period_raw, r'^(\d{4})') as int64)
          >= extract(year from current_date) - {{ var('scope_years') }}

)

select
    filing_line_key,
    id as institution_id,
    source_return_code as return_code,
    reporting_period_raw,
    data_point_address_adresse_de_point_de_donnee as line_item_code,
    variant_seq,
    data_point_address_label as line_item_label,
    return_title,
    -- BigQuery does not allow a parameterized precision/scale inside a CAST
    -- expression (confirmed: "Parameterized types are not allowed in CAST
    -- expressions" on first attempt with numeric(20,3)) -- plain NUMERIC only.
    cast(measure_value_valeur_de_mesure as numeric) as amount_cad_000,
    source_file_name,
    source_file_hash,
    ckan_last_modified,
    ingested_at as source_ingested_at,

    -- knowledge-time window (bitemporal: this is system/knowledge time,
    -- distinct from reporting_period_raw's business time)
    dbt_valid_from as known_from_ts,
    dbt_valid_to as known_to_ts,
    (dbt_valid_to is null) as is_current_version

from source
