{{
  config(
    materialized='incremental',
    unique_key=['institution_key', 'reporting_period_end'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}

with base as (
    select * from {{ ref('int_filings__balance_sheet_pivoted') }}

    {% if is_incremental() %}
    -- CRITICAL: filter on KNOWLEDGE time, not reporting period. Regulatory
    -- filings get restated -- a restatement of a two-year-old period
    -- arrives today with a NEW known_from_ts but an OLD reporting_period_end.
    -- Filtering on reporting_period_end (e.g. "only load periods after the
    -- max period already loaded") would silently and permanently drop that
    -- restatement, since its business-time date is old even though we only
    -- just learned about it. See CLAUDE.md rule 4 and
    -- docs/PROJECT_STRUCTURE.md section 1.
    where known_from_ts > (
        select coalesce(max(source_known_from_ts), timestamp('1900-01-01'))
        from {{ this }}
    )
    {% endif %}
),

-- Scope to the Big Six + their in-scope subsidiaries. int_filings__balance_
-- sheet_pivoted itself covers every institution in the raw M4 data (all
-- ~150 banks), not just our seed_institution_master scope -- the inner
-- join here is what actually limits fct_balance_sheet's grain.
scoped as (
    select b.*
    from base b
    inner join {{ ref('seed_institution_master') }} m
        on b.institution_id = m.institution_id
)

select
    {{ dbt_utils.generate_surrogate_key(['institution_id']) }} as institution_key,
    institution_id,
    reporting_period_end,
    total_assets_cad_000,
    total_liabilities_cad_000,
    total_equity_cad_000,
    total_deposits_cad_000,
    gross_loans_cad_000,
    allowance_for_credit_losses_cad_000,
    retained_earnings_cad_000,
    known_from_ts as source_known_from_ts,
    current_timestamp() as dbt_loaded_at
from scoped
