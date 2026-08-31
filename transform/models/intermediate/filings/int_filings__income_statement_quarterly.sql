{{ config(materialized='table') }}

-- Converts fct_income_statement's year-to-date cumulative figures (P3's
-- own convention -- see int_filings__income_statement_pivoted.sql) into
-- true single-quarter figures, by differencing consecutive quarters
-- within the same fiscal year. Needed for fct_financial_metrics: a ratio
-- like NIM computed directly from YTD figures would blend earlier
-- quarters into every later quarter of the same fiscal year, which is not
-- how NIM/ROA/ROE are normally presented and would look like a data
-- quality issue on a trend chart.
--
-- fiscal_year_label buckets each reporting_period_end into the fiscal
-- year it belongs to (calendar months <= fiscal_year_end_month belong to
-- the fiscal year named after that calendar year; later months belong to
-- the NEXT fiscal year's label) -- e.g. for October FYE, Jan/Apr/Jul/Oct
-- 2026 are all fiscal year 2026 (FY2026 = Nov 2025 - Oct 2026). Within
-- that group, quarter_seq orders the 4 filings; Q1's YTD figure already
-- IS the single-quarter figure (nothing to subtract), Q2-Q4 subtract the
-- immediately prior quarter's YTD.

with income_statement as (

    select f.*, m.fiscal_year_end_month
    from {{ ref('fct_income_statement') }} f
    join {{ ref('seed_institution_master') }} m on f.institution_id = m.institution_id
    where m.fiscal_year_end_month is not null

),

with_fiscal_year as (

    select
        *,
        extract(year from reporting_period_end)
            + case when extract(month from reporting_period_end) <= fiscal_year_end_month then 0 else 1 end
            as fiscal_year_label
    from income_statement

),

with_quarter_seq as (

    select
        *,
        row_number() over (
            partition by institution_id, fiscal_year_label
            order by reporting_period_end
        ) as quarter_seq
    from with_fiscal_year

)

select
    institution_key,
    institution_id,
    reporting_period_end,
    fiscal_year_label,
    quarter_seq,

    interest_income_total_cad_000
        - coalesce(lag(interest_income_total_cad_000) over (w), 0) as interest_income_total_q_cad_000,
    interest_expense_total_cad_000
        - coalesce(lag(interest_expense_total_cad_000) over (w), 0) as interest_expense_total_q_cad_000,
    net_interest_income_cad_000
        - coalesce(lag(net_interest_income_cad_000) over (w), 0) as net_interest_income_q_cad_000,
    net_interest_income_after_impairment_cad_000
        - coalesce(lag(net_interest_income_after_impairment_cad_000) over (w), 0) as net_interest_income_after_impairment_q_cad_000,
    non_interest_income_cad_000
        - coalesce(lag(non_interest_income_cad_000) over (w), 0) as non_interest_income_q_cad_000,
    non_interest_expense_cad_000
        - coalesce(lag(non_interest_expense_cad_000) over (w), 0) as non_interest_expense_q_cad_000,
    net_income_before_tax_cad_000
        - coalesce(lag(net_income_before_tax_cad_000) over (w), 0) as net_income_before_tax_q_cad_000,
    net_income_cad_000
        - coalesce(lag(net_income_cad_000) over (w), 0) as net_income_q_cad_000,

    source_known_from_ts
from with_quarter_seq
window w as (partition by institution_id, fiscal_year_label order by reporting_period_end)
