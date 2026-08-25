{{ config(materialized='table') }}

with periods as (
    select reporting_period_end from {{ ref('int_filings__balance_sheet_pivoted') }}
    union distinct
    select reporting_period_end from {{ ref('int_filings__income_statement_pivoted') }}
)

select
    reporting_period_end,
    extract(year from reporting_period_end) as calendar_year,
    extract(quarter from reporting_period_end) as calendar_quarter,
    extract(month from reporting_period_end) as calendar_month
from periods
where reporting_period_end is not null
