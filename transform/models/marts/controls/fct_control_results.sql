{{ config(materialized='table') }}

-- One invocation's lag, by construction: this model runs during the main
-- DAG phase, before macros/log_dbt_results.sql's on-run-end hook inserts
-- THAT SAME invocation's own results into dbt_test_log. So a build never
-- sees its own results here -- only every prior invocation's. Confirmed
-- empirically: a `dbt build` logged 26 new rows via its hook, but
-- rebuilding this model in that same invocation still only reflected the
-- prior invocation's rows; a second, separate `dbt build --select
-- fct_control_results rpt_control_scorecard` picked them up. Acceptable
-- for a daily scheduled pipeline (today's results surface in the next
-- run), but worth knowing before assuming a scorecard is stale or broken.
--
-- One row per control test per dbt invocation, joined to the control
-- registry for severity/owner/regulatory context. control_id is derived
-- from the test name, not stored separately -- every control test in this
-- project is named <category>_<number>_description (e.g.
-- rec_001_balance_sheet_balances, cmp_001_all_expected_institutions_filed),
-- so the first two underscore-delimited tokens reconstruct the registry's
-- control_id (REC-001, CMP-001). Generic dbt tests (not_null_..., etc.)
-- don't match any registry row and correctly left-join to nulls -- they
-- aren't controls, they're schema hygiene.

with log as (

    select * from {{ source('audit', 'dbt_test_log') }}

),

registry as (

    select * from {{ ref('seed_control_registry') }}

),

joined as (

    select
        l.invocation_id as run_id,
        -- BigQuery has no split_part(); split() returns an array instead.
        upper(
            split(l.test_name, '_')[safe_offset(0)] || '-' ||
            split(l.test_name, '_')[safe_offset(1)]
        ) as control_id,
        l.test_name,
        l.status,
        l.failure_count,
        l.execution_seconds,
        l.logged_at
    from log l

)

select
    j.run_id,
    j.control_id,
    r.control_name,
    r.category,
    r.severity,
    r.owner,
    r.regulatory_ref,
    j.status,
    j.failure_count,
    case when j.status in ('pass', 'warn') then 1 else 0 end as is_passing,
    j.execution_seconds,
    j.logged_at
from joined j
left join registry r on j.control_id = r.control_id
