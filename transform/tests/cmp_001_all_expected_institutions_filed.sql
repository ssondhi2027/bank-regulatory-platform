-- CMP-001: every active institution has a filing for the period --
-- evaluated per FISCAL-YEAR-END COHORT, not calendar-naively. October FYE
-- and December FYE filers report on different fiscal calendars, so
-- comparing "did everyone file for period X" across ALL institutions at
-- once false-alarms whenever cohorts don't share a period (CLAUDE.md's own
-- example: "false alarms every February"). Instead, an institution is only
-- ever compared against periods actually observed within its OWN cohort
-- (same fiscal_year_end_month).
--
-- Scoped to institutions with a KNOWN fiscal_year_end_month -- currently
-- the 6 Big Six only; the 7 subsidiaries in seed_institution_master have
-- unconfirmed FYE (see int_filings__balance_sheet_pivoted.sql) and are
-- correctly excluded here rather than guessed at, same as everywhere else
-- FYE-dependent calendar mapping is used.
--
-- Simplification: "active" is not cross-checked against
-- fi_inactive_date_date_d_inactivite_iff (present in raw filings, not yet
-- carried into the marts) -- all 6 in-scope Big Six institutions are live,
-- major, currently-operating banks, so this never changes the result
-- today. Flagged here rather than silently assumed.

with cohorts as (

    select institution_id, fiscal_year_end_month
    from {{ ref('seed_institution_master') }}
    where fiscal_year_end_month is not null

),

periods_per_cohort as (

    select distinct c.fiscal_year_end_month, f.reporting_period_end
    from {{ ref('fct_income_statement') }} f
    join cohorts c on f.institution_id = c.institution_id

),

expected as (

    select c.institution_id, p.reporting_period_end
    from cohorts c
    join periods_per_cohort p on c.fiscal_year_end_month = p.fiscal_year_end_month

)

select
    e.institution_id,
    e.reporting_period_end
from expected e
left join {{ ref('fct_income_statement') }} f
    on  e.institution_id = f.institution_id
    and e.reporting_period_end = f.reporting_period_end
where f.institution_id is null
