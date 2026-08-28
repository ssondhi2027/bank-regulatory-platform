-- REC-007: OSFI's published "Total All Banks" (Id 1000000) must equal
-- Total Domestic (1000001) + Total Foreign Bank Subsidiaries (1000002)
-- + Total Foreign Bank Branches, lending + full service (1000006/1000007
-- from the separate Foreign Bank Branches dataset). Tolerance-based per
-- CLAUDE.md rule 7. See int_filings__industry_totals.sql and
-- docs/known_data_issues.md ("REC-007 needs a fourth dataset") for the
-- full derivation.

select
    reporting_period_raw,
    total_all_banks_cad_000,
    total_domestic_banks_cad_000
        + total_foreign_bank_subsidiaries_cad_000
        + coalesce(total_foreign_bank_branches_lending_cad_000, 0)
        + coalesce(total_foreign_bank_branches_full_service_cad_000, 0)
        as computed_total_cad_000,
    total_all_banks_cad_000 - (
        total_domestic_banks_cad_000
        + total_foreign_bank_subsidiaries_cad_000
        + coalesce(total_foreign_bank_branches_lending_cad_000, 0)
        + coalesce(total_foreign_bank_branches_full_service_cad_000, 0)
    ) as variance_cad_000
from {{ ref('int_filings__industry_totals') }}
where abs(
    total_all_banks_cad_000 - (
        total_domestic_banks_cad_000
        + total_foreign_bank_subsidiaries_cad_000
        + coalesce(total_foreign_bank_branches_lending_cad_000, 0)
        + coalesce(total_foreign_bank_branches_full_service_cad_000, 0)
    )
) > {{ var('materiality_threshold_cad_000') }}
