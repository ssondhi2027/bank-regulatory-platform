{{ config(materialized='ephemeral') }}

-- The "as we know it today" spine. Quarantined institution-periods (ADR-0002)
-- are already excluded upstream in snap_osfi_filings, so nothing further to
-- filter for that here.

with source as (

    select * from {{ ref('stg_osfi__filings') }}
    where is_current_version

),

-- seed_data_point_variants.csv's "reporting_period_end" column, despite the
-- name, holds the same raw period representation stg_osfi__filings uses
-- (e.g. "2017-11-30" or "2010-Q4 - 2010"), not a resolved calendar date --
-- see docs/decisions/ADR-0002-variant-ordering-and-quarantine.md.
variant_override as (

    select
        return_code,
        line_item_code,
        reporting_period_end as reporting_period_raw,
        -- variant_seq is INT64 in the snapshot (native row_number() output)
        -- but arrives as text from the seed CSV -- cast to match, not the
        -- other way around.
        cast(variant_seq as int64) as variant_seq,
        case is_primary_basis
            when 'true' then true
            when 'false' then false
            else null  -- 28 groups where even the override table has no answer (ADR-0002 addendum)
        end as is_primary_basis_override
    from {{ ref('seed_data_point_variants') }}

)

select
    s.*,
    -- Default: variant_seq = 0 is primary. This is a real simplification --
    -- it is only correct-by-construction for single-variant codes (the
    -- overwhelming majority). For the minority of codes that ever had a
    -- genuine dual-basis duplicate, EVERY such case traces to either the
    -- OSFI aggregate pseudo-institutions (Id 1000000/1000001/1000002) or
    -- the quarantined Id 28017 (never a real institution) -- confirmed in
    -- ADR-0002. fct_balance_sheet inner-joins to seed_institution_master,
    -- which has no pseudo-ids, so this default never actually reaches a
    -- mart row today. Revisit with the full "most-recently-observed-
    -- wording" logic if aggregate-row marts (e.g. REC-007) are built.
    coalesce(vo.is_primary_basis_override, s.variant_seq = 0) as is_primary_basis
from source s
left join variant_override vo
    on  s.return_code = vo.return_code
    and s.line_item_code = vo.line_item_code
    and s.reporting_period_raw = vo.reporting_period_raw
    and s.variant_seq = vo.variant_seq
