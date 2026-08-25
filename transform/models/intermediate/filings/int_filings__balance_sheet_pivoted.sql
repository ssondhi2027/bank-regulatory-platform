{{ config(materialized='table') }}

-- Named measures sourced from OSFI's own M4 validation-rule formulas
-- (IR002, IR004), not invented: total_assets = code 1045 (direct);
-- total_liabilities / total_equity split from IR004's 35-code list (29
-- liability codes + 6 equity codes); total_deposits = the 12 deposit codes
-- within that same list; net_loans = the loan subset of IR002; retained
-- earnings = code 2225 (direct). See docs/decisions/ and the Phase 7
-- code-mapping discussion for the full derivation.
--
-- M4 reports loans NET of allowance (every loan line item's label says
-- "less allowance for expected credit losses" -- there is no separate
-- gross figure in M4 at all). gross_loans and allowance_for_credit_losses
-- are recovered by joining E3 (the allowances return) and adding its total
-- back: gross = M4 net loans + E3 total allowance.

with m4 as (

    select * from {{ ref('int_filings__current_version') }}
    where return_code = 'M4' and is_primary_basis

),

m4_pivoted as (

    select
        institution_id,
        cast(reporting_period_raw as date) as reporting_period_end,

        max(case when line_item_code = '1045' then amount_cad_000 end) as total_assets_cad_000,

        -- IR004's 29 liability codes (deposits, cheques, advances,
        -- acceptances, other liabilities, subordinated debt)
        sum(case when line_item_code in (
            '0873','0874','0875','0876','0877','0878',
            '0880','0881','2202','0616','0618','2339',
            '2267','1059','2345',
            '0620','0624','0883','2255','0626','0628','0630','0632','0634','0636','2000','2367','2026',
            '1065'
        ) then amount_cad_000 else 0 end) as total_liabilities_cad_000,

        -- IR004's 6 equity codes: preferred shares, common shares,
        -- contributed surplus, retained earnings, non-controlling
        -- interests, accumulated other comprehensive income
        sum(case when line_item_code in ('2355','2357','0503','2225','1202','2604')
            then amount_cad_000 else 0 end) as total_equity_cad_000,

        -- IR004's first 12 codes: demand/notice deposits + fixed-term deposits
        sum(case when line_item_code in (
            '0873','0874','0875','0876','0877','0878',
            '0880','0881','2202','0616','0618','2339'
        ) then amount_cad_000 else 0 end) as total_deposits_cad_000,

        max(case when line_item_code = '2225' then amount_cad_000 end) as retained_earnings_cad_000,

        -- IR002's loan subset: 8 non-mortgage + 4 mortgage leaf codes
        sum(case when line_item_code in (
            '2310','2057','0524','0526','2067','0534','0666','0572',
            '0540','0542','0608','2117'
        ) then amount_cad_000 else 0 end) as net_loans_cad_000,

        max(known_from_ts) as m4_known_from_ts
    from m4
    group by 1, 2

),

institution_fye as (

    select institution_id, fiscal_year_end_month
    from {{ ref('seed_institution_master') }}
    where fiscal_year_end_month is not null

),

e3_with_calendar_date as (

    -- Inner join: only institutions with a known fiscal-year-end month can
    -- have their fiscal quarter mapped to a real calendar date (currently
    -- the Big Six only -- subsidiaries have no confirmed FYE, see
    -- seed_institution_master.csv). Those institutions simply get no
    -- allowance/gross_loans figure, which is honest: we don't know which
    -- calendar quarter their E3 filing corresponds to, so we don't guess.
    select
        e3.institution_id,
        {{ fiscal_quarter_end_date(
            "cast(regexp_extract(e3.reporting_period_raw, r'^(\\d{4})') as int64)",
            "cast(regexp_extract(e3.reporting_period_raw, r'Q(\\d)') as int64)",
            "fye.fiscal_year_end_month"
        ) }} as reporting_period_end,
        e3.amount_cad_000,
        e3.known_from_ts
    from {{ ref('int_filings__current_version') }} e3
    inner join institution_fye fye on e3.institution_id = fye.institution_id
    where e3.return_code = 'E3'
      and e3.is_primary_basis
      -- Total, Stage I/II/III Expected Credit Losses -- summed because E3
      -- has no single combined "all stages" code (confirmed: checked the
      -- full Sample Return layout, stages are only ever reported in
      -- parallel, never pre-summed).
      and e3.line_item_code in ('3019', '3038', '3057')

),

e3_pivoted as (

    select
        institution_id,
        reporting_period_end,
        sum(amount_cad_000) as allowance_for_credit_losses_cad_000,
        max(known_from_ts) as e3_known_from_ts
    from e3_with_calendar_date
    group by 1, 2

)

select
    m4.institution_id,
    m4.reporting_period_end,
    m4.total_assets_cad_000,
    m4.total_liabilities_cad_000,
    m4.total_equity_cad_000,
    m4.total_deposits_cad_000,
    m4.retained_earnings_cad_000,
    m4.net_loans_cad_000,
    e3.allowance_for_credit_losses_cad_000,
    -- Null, not zero, when E3 couldn't be matched (unknown FYE or no
    -- filing for that exact quarter) -- "we don't know" is not "zero".
    case when e3.allowance_for_credit_losses_cad_000 is not null
        then m4.net_loans_cad_000 + e3.allowance_for_credit_losses_cad_000
    end as gross_loans_cad_000,
    greatest(m4.m4_known_from_ts, coalesce(e3.e3_known_from_ts, m4.m4_known_from_ts)) as known_from_ts
from m4_pivoted m4
left join e3_pivoted e3
    on  m4.institution_id = e3.institution_id
    and m4.reporting_period_end = e3.reporting_period_end
