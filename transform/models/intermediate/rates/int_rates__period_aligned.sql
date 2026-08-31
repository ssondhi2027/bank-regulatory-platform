{{ config(materialized='table') }}

-- Collapses daily BoC observations to period-end and period-average per
-- reporting period, so rate joins to filings don't fan out (one row per
-- period, not one row per day).
--
-- Period-end: the most recent observation ON OR BEFORE the period end
-- (market/rate data doesn't necessarily land exactly on a quarter-end
-- calendar date -- e.g. a Sunday).
--
-- Period-average: trailing 3 calendar months up to and including the
-- period end. This is exact for P3's quarterly periods (which is what
-- fct_financial_metrics actually joins against) and a documented
-- simplification for any monthly-only period dim_reporting_period also
-- carries (M4-only periods with no P3 counterpart) -- those would show a
-- rolling 3-month average rather than a true 1-month average, but nothing
-- currently joins rates to those periods, so this never surfaces as a
-- wrong number today.

with periods as (

    select reporting_period_end from {{ ref('dim_reporting_period') }}

),

rates as (

    select series_name, obs_date, value
    from {{ ref('stg_boc__rate_observations') }}

),

period_end_values as (

    select
        p.reporting_period_end,
        r.series_name,
        r.value,
        row_number() over (
            partition by p.reporting_period_end, r.series_name
            order by r.obs_date desc
        ) as rn
    from periods p
    join rates r
        on r.obs_date <= p.reporting_period_end
       and r.obs_date > date_sub(p.reporting_period_end, interval 14 day)

),

period_avg_values as (

    select
        p.reporting_period_end,
        r.series_name,
        avg(r.value) as avg_value
    from periods p
    join rates r
        on r.obs_date <= p.reporting_period_end
       and r.obs_date > date_sub(p.reporting_period_end, interval 3 month)
    group by 1, 2

)

select
    e.reporting_period_end,

    max(case when e.series_name = 'policy_rate' and e.rn = 1 then e.value end) as policy_rate_period_end,
    max(case when e.series_name = 'goc_2y_yield' and e.rn = 1 then e.value end) as goc_2y_yield_period_end,
    max(case when e.series_name = 'goc_10y_yield' and e.rn = 1 then e.value end) as goc_10y_yield_period_end,
    max(case when e.series_name = 'cad_usd' and e.rn = 1 then e.value end) as cad_usd_period_end,

    max(case when a.series_name = 'policy_rate' then a.avg_value end) as policy_rate_avg_3m,
    max(case when a.series_name = 'goc_2y_yield' then a.avg_value end) as goc_2y_yield_avg_3m,
    max(case when a.series_name = 'goc_10y_yield' then a.avg_value end) as goc_10y_yield_avg_3m,
    max(case when a.series_name = 'cad_usd' then a.avg_value end) as cad_usd_avg_3m

from period_end_values e
left join period_avg_values a
    on  e.reporting_period_end = a.reporting_period_end
    and e.series_name = a.series_name
group by 1
