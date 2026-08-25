{{ config(materialized='view') }}

-- Reads from the SNAPSHOT, not the source. From here down, the snapshot is
-- the system of record: it is where restatement (knowledge-time) history
-- lives. Thin layer: renaming to expose the snapshot's own bookkeeping
-- columns under clearer names, and casting the one column that needs it
-- (amount_cad_000, string -> numeric, so downstream models can do
-- arithmetic) -- no filtering, no business logic.

with source as (

    select * from {{ ref('snap_osfi_filings') }}

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
