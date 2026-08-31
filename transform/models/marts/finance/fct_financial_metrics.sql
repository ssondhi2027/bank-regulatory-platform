{{ config(materialized='table') }}

-- Grain: institution x reporting_period_end (quarterly -- matches
-- int_filings__income_statement_quarterly, since every ratio here needs
-- an income-statement flow figure, and P3 only files quarterly).
--
-- NIM/ROA/ROE annualize the single-quarter flow figure (x4) before
-- dividing by an average balance -- the standard banking convention (bank
-- disclosures always report "annualized" quarterly ROE/ROA/NIM, not the
-- raw quarterly ratio), and what makes these directly comparable to an
-- annual-terms series like the BoC policy rate on the "so what" chart.
--
-- Average balance = (period-end balance + PRIOR period-end balance) / 2.
-- Null for an institution's first period in scope (no prior balance to
-- average against) -- correct, not a bug: a real bank's first-ever
-- reporting period has the same limitation.
--
-- Tier 1 capital ratio is NOT included -- would require the CAP return,
-- which has never been ingested (see docs/PROJECT_STRUCTURE.md: "if you
-- ingest the CAP return"). Not invented here.

with income_q as (

    select * from {{ ref('int_filings__income_statement_quarterly') }}

),

-- fct_balance_sheet is MONTHLY grain (M4 files every month); income_q is
-- QUARTERLY (P3 files once a quarter). Filtering to only the periods that
-- also have a quarterly income-statement filing BEFORE computing lag() is
-- what makes "prior" mean prior QUARTER, not prior calendar month -- doing
-- lag() over the full monthly table first (an earlier version of this
-- model did that) silently averages against last month's balance instead.
quarterly_balance_sheet as (

    select bs.*
    from {{ ref('fct_balance_sheet') }} bs
    where exists (
        select 1 from income_q i
        where i.institution_id = bs.institution_id
          and i.reporting_period_end = bs.reporting_period_end
    )

),

balance_sheet as (

    select
        *,
        lag(total_assets_cad_000) over (
            partition by institution_id order by reporting_period_end
        ) as prior_total_assets_cad_000,
        lag(total_equity_cad_000) over (
            partition by institution_id order by reporting_period_end
        ) as prior_total_equity_cad_000
    from quarterly_balance_sheet

),

joined as (

    select
        i.institution_key,
        i.institution_id,
        i.reporting_period_end,

        i.net_interest_income_q_cad_000,
        i.net_income_q_cad_000,
        i.non_interest_income_q_cad_000,
        i.non_interest_expense_q_cad_000,

        b.total_assets_cad_000,
        b.prior_total_assets_cad_000,
        b.total_equity_cad_000,
        b.prior_total_equity_cad_000,
        b.total_deposits_cad_000,
        b.gross_loans_cad_000,
        b.allowance_for_credit_losses_cad_000

    from income_q i
    join balance_sheet b
        on  i.institution_id = b.institution_id
        and i.reporting_period_end = b.reporting_period_end

)

select
    institution_key,
    institution_id,
    reporting_period_end,

    safe_divide(
        net_interest_income_q_cad_000 * 4,
        (total_assets_cad_000 + prior_total_assets_cad_000) / 2
    ) as net_interest_margin,

    safe_divide(
        net_income_q_cad_000 * 4,
        (total_assets_cad_000 + prior_total_assets_cad_000) / 2
    ) as return_on_assets,

    safe_divide(
        net_income_q_cad_000 * 4,
        (total_equity_cad_000 + prior_total_equity_cad_000) / 2
    ) as return_on_equity,

    safe_divide(
        non_interest_expense_q_cad_000,
        net_interest_income_q_cad_000 + non_interest_income_q_cad_000
    ) as efficiency_ratio,

    safe_divide(total_deposits_cad_000, gross_loans_cad_000) as deposit_to_loan_ratio,

    safe_divide(allowance_for_credit_losses_cad_000, gross_loans_cad_000) as allowance_coverage_ratio

from joined
