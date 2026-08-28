{{ config(materialized='table') }}

-- OSFI's own published aggregate pseudo-institutions, pivoted for REC-007
-- (industry total ties to published). Id 1000000/1000001/1000002 come from
-- the main Banks dataset (M4); Id 1000006/1000007 come from the separate
-- Foreign Bank Branches dataset (M4_FBB) -- see docs/known_data_issues.md,
-- "REC-007 needs a fourth dataset". Both populations flow through the same
-- snapshot/staging pipeline already, distinguished by return_code.
--
-- Per the CKAN package's own published notes: "Industry Totals... do not
-- include data reported by Banks that are subsidiaries of other Banks,
-- since this data is already accounted for in the consolidated data
-- reported by the parent banks." These are OSFI's own pre-deduplicated
-- aggregates, so no separate subsidiary-exclusion logic is needed here --
-- using OSFI's published totals directly inherits their own exclusion.

with aggregates as (

    select institution_id, return_code, reporting_period_raw, amount_cad_000
    from {{ ref('int_filings__current_version') }}
    where line_item_code = '1045'  -- total assets, direct
      and is_primary_basis
      and institution_id in ('1000000', '1000001', '1000002', '1000006', '1000007')

)

select
    reporting_period_raw,

    max(case when institution_id = '1000000' then amount_cad_000 end) as total_all_banks_cad_000,
    max(case when institution_id = '1000001' then amount_cad_000 end) as total_domestic_banks_cad_000,
    max(case when institution_id = '1000002' then amount_cad_000 end) as total_foreign_bank_subsidiaries_cad_000,
    max(case when institution_id = '1000006' then amount_cad_000 end) as total_foreign_bank_branches_lending_cad_000,
    max(case when institution_id = '1000007' then amount_cad_000 end) as total_foreign_bank_branches_full_service_cad_000

from aggregates
group by 1
