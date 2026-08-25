{{ config(materialized='table') }}

-- Not yet a true SCD2 dimension -- snap_institution_registry (the
-- institution-registry snapshot docs/PROJECT_STRUCTURE.md calls for)
-- hasn't been built. This is a straight pass-through of
-- seed_institution_master: one row per institution, no historical
-- versioning of name/status changes yet.

select
    institution_id,
    legal_name,
    short_name,
    schedule_type,
    fiscal_year_end_month,
    parent_institution_id,
    peer_group
from {{ ref('seed_institution_master') }}
