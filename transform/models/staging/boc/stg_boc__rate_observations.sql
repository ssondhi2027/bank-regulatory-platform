{{ config(materialized='view') }}

-- Thin layer: cast + a friendly name for the raw Valet series code. No
-- restatement concept here (unlike OSFI filings) -- BoC does not
-- retroactively revise a published daily observation, so this reads
-- directly from the source, not a snapshot.

select
    series_id,
    case series_id
        when 'V39079' then 'policy_rate'
        when 'BD.CDN.2YR.DQ.YLD' then 'goc_2y_yield'
        when 'BD.CDN.10YR.DQ.YLD' then 'goc_10y_yield'
        when 'FXCADUSD' then 'cad_usd'
    end as series_name,
    cast(obs_date as date) as obs_date,
    cast(value as numeric) as value,
    source_file_hash,
    ingested_at as source_ingested_at
from {{ source('boc_raw', 'valet_observations') }}
