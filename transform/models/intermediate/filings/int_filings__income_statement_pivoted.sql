{{ config(materialized='table') }}

-- Named measures sourced directly from P3's own validation-rule formulas
-- (IR146, IR154, IR155, IR156, IR162, IR166, IR167, IR199), not invented.
-- All P3 figures are YEAR-TO-DATE cumulative as filed (every P3 label ends
-- "...(year to date)") -- Q2 is not "Q2 alone," it is Q1+Q2 combined. Any
-- consumer wanting a single-quarter figure must difference consecutive
-- quarters within the same fiscal year, not use this table's rows as-is.

with p3 as (

    select * from {{ ref('int_filings__current_version') }}
    where return_code = 'P3' and is_primary_basis

),

institution_fye as (

    select institution_id, fiscal_year_end_month
    from {{ ref('seed_institution_master') }}
    where fiscal_year_end_month is not null

),

p3_with_calendar_date as (

    -- Same FYE-dependent quarter mapping as the balance sheet pivot --
    -- see macros/period_end_helpers.sql and int_filings__balance_sheet_pivoted.sql
    -- for why this is an inner join (Big Six only, currently).
    select
        p3.institution_id,
        {{ fiscal_quarter_end_date(
            "cast(regexp_extract(p3.reporting_period_raw, r'^(\\d{4})') as int64)",
            "cast(regexp_extract(p3.reporting_period_raw, r'Q(\\d)') as int64)",
            "fye.fiscal_year_end_month"
        ) }} as reporting_period_end,
        p3.line_item_code,
        p3.amount_cad_000,
        p3.known_from_ts
    from p3
    inner join institution_fye fye on p3.institution_id = fye.institution_id

)

select
    institution_id,
    reporting_period_end,

    max(case when line_item_code = '8252' then amount_cad_000 end) as interest_income_total_cad_000,
    max(case when line_item_code = '8407' then amount_cad_000 end) as interest_expense_total_cad_000,
    max(case when line_item_code = '8408' then amount_cad_000 end) as net_interest_income_cad_000,
    max(case when line_item_code = '8464' then amount_cad_000 end) as net_interest_income_after_impairment_cad_000,
    max(case when line_item_code = '2084' then amount_cad_000 end) as non_interest_income_cad_000,
    max(case when line_item_code = '1284' then amount_cad_000 end) as non_interest_expense_cad_000,
    max(case when line_item_code = '1285' then amount_cad_000 end) as net_income_before_tax_cad_000,
    max(case when line_item_code = '1109' then amount_cad_000 end) as net_income_cad_000,

    max(known_from_ts) as known_from_ts
from p3_with_calendar_date
group by 1, 2
