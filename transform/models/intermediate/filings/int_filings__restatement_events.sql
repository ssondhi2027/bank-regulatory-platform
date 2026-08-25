{{ config(materialized='table') }}

-- A first-class output, not a byproduct -- restatement frequency by
-- institution is a dashboard tile (docs/PROJECT_STRUCTURE.md). Uses ALL
-- versions from the snapshot, not just the current one.

with versions as (

    select
        filing_line_key,
        institution_id,
        return_code,
        reporting_period_raw,
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
    return_code,
    reporting_period_raw,
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
    date_diff(cast(known_from_ts as date), cast(first_known_ts as date), day) as days_to_restatement
from versions
where version_no > 1
