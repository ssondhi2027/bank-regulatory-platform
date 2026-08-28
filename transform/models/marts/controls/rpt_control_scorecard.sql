{{ config(materialized='table') }}

-- Page two of the dashboard: pass rate by run x category, breach count,
-- worst-severity breach in that run, and a trailing 30-day pass rate for
-- context. Only rows that matched a real registry control_id are included
-- (category is not null) -- generic dbt hygiene tests (not_null, etc.)
-- aren't controls and would otherwise dilute the category breakdown.

with base as (

    select * from {{ ref('fct_control_results') }}
    where category is not null

),

per_run_category as (

    select
        run_id,
        category,
        max(logged_at) as run_logged_at,
        count(*) as control_count,
        sum(is_passing) as passing_count,
        round(sum(is_passing) / count(*), 4) as pass_rate,
        countif(is_passing = 0) as breach_count,
        max(case when is_passing = 0 then
            case severity when 'error' then 2 when 'warn' then 1 else 0 end
        end) as worst_breach_severity_rank
    from base
    group by 1, 2

),

with_severity_label as (

    select
        *,
        case worst_breach_severity_rank
            when 2 then 'error'
            when 1 then 'warn'
            else null
        end as worst_severity_breach
    from per_run_category

)

select
    p.run_id,
    p.category,
    p.run_logged_at,
    p.control_count,
    p.passing_count,
    p.pass_rate,
    p.breach_count,
    p.worst_severity_breach,
    (
        select round(avg(b2.is_passing), 4)
        from base b2
        where b2.category = p.category
          and b2.logged_at between timestamp_sub(p.run_logged_at, interval 30 day) and p.run_logged_at
    ) as trailing_30_day_pass_rate
from with_severity_label p
order by p.run_logged_at desc, p.category
