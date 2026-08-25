{{
  config(
    materialized='incremental',
    unique_key=['institution_key', 'reporting_period_end'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}

with base as (
    select * from {{ ref('int_filings__income_statement_pivoted') }}

    {% if is_incremental() %}
    -- Same knowledge-time rule as fct_balance_sheet -- see that model's
    -- comment and CLAUDE.md rule 4 for why this must never filter on
    -- reporting_period_end.
    where known_from_ts > (
        select coalesce(max(source_known_from_ts), timestamp('1900-01-01'))
        from {{ this }}
    )
    {% endif %}
),

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
    interest_income_total_cad_000,
    interest_expense_total_cad_000,
    net_interest_income_cad_000,
    net_interest_income_after_impairment_cad_000,
    non_interest_income_cad_000,
    non_interest_expense_cad_000,
    net_income_before_tax_cad_000,
    net_income_cad_000,
    known_from_ts as source_known_from_ts,
    current_timestamp() as dbt_loaded_at
from scoped
