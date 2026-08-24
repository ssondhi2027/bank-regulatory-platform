{% snapshot snap_osfi_filings %}
{{
  config(
    target_schema='snapshots',
    unique_key='filing_line_key',
    strategy='check',
    check_cols=['measure_value_valeur_de_mesure'],
    invalidate_hard_deletes=True
  )
}}

with source as (

    select * from {{ source('osfi_raw', 'filings') }}

),

with_period as (

    select
        *,
        -- Raw, unambiguous period representation, not a resolved calendar
        -- date. M4's calendar_month_mois_civil is already a real date.
        -- P3/E3 only carry fiscal_year + fiscal_quarter as filed; turning
        -- that into a true reporting_period_end requires each
        -- institution's fiscal-year-end month (seed_institution_master,
        -- Phase 6) and is deliberately deferred to the intermediate layer
        -- -- see docs/known_data_issues.md. Keying the snapshot on the raw
        -- fields keeps this grain stable regardless of when that join
        -- lands; the snapshot must never be re-keyed once it's running.
        coalesce(
            calendar_month_mois_civil,
            fiscal_year_annee_fiscale || '-' || fiscal_quarter
        ) as reporting_period_raw
    from source

),

quarantined as (

    -- ADR-0002 addendum: quarantined institution-periods are excluded here,
    -- upstream of row_number(), not only in marts as originally scoped.
    -- Proven empirically that leaving them in lets BigQuery's row_number()
    -- assign a DIFFERENT tiebreak across separate executions of the exact
    -- same underlying data (no other column disambiguates these rows at
    -- all, so there is nothing for the ORDER BY to break the tie on) --
    -- the first two snapshot runs on unchanged Id 28017 data produced 46
    -- phantom restatements. Filtering in marts alone would not have
    -- prevented that, since the instability originates in this query.
    select return_code, institution_id, reporting_period_raw
    from {{ ref('seed_quarantine') }}

),

filtered as (

    select p.*
    from with_period p
    left join quarantined q
        on  p.source_return_code = q.return_code
        and p.id = cast(q.institution_id as string)
        and p.reporting_period_raw = q.reporting_period_raw
    where q.institution_id is null

),

with_variant as (

    select
        *,
        -- ADR-0002: order by (return_title, label), NOT label alone.
        -- Label alone ties whenever two concurrent variants share
        -- byte-identical text (162 of 270 duplicate groups profiled),
        -- silently falling back to physical row order -- proven
        -- internally inconsistent across line items for at least one
        -- institution-period (Id 28017, quarantined; see
        -- seeds/seed_quarantine.csv). This must be computed identically
        -- here and in extract/keys.py::compute_variant_seq -- there is no
        -- shared code path across the Python extractor and dbt, so any
        -- change to one must be mirrored in the other by hand.
        row_number() over (
            partition by
                id,
                source_return_code,
                reporting_period_raw,
                data_point_address_adresse_de_point_de_donnee
            order by
                return_title,
                data_point_address_label
        ) - 1 as variant_seq
    from filtered

)

select
    {{ dbt_utils.generate_surrogate_key([
        'id',
        'source_return_code',
        'reporting_period_raw',
        'data_point_address_adresse_de_point_de_donnee',
        'variant_seq'
    ]) }} as filing_line_key,
    *
from with_variant

{% endsnapshot %}
