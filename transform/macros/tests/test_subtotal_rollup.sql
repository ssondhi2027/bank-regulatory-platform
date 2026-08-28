{% test subtotal_rollup(model, return_code, tolerance=1) %}

-- REC-002: child line items must sum to their declared parent subtotal,
-- within a materiality tolerance (CLAUDE.md rule 7 -- OSFI rounds to
-- thousands). Joins on (return_code, line_item_code), not line_item_code
-- alone -- the same numeric code is reused across M4/P3/E3 with unrelated
-- meanings, so a single-column join would silently cross-contaminate
-- parent/child pairs across return types.

with hierarchy as (

    select return_code, line_item_code, parent_line_item_code
    from {{ ref('seed_line_item_hierarchy') }}
    where parent_line_item_code is not null
      and return_code = '{{ return_code }}'

),

base as (

    select * from {{ model }}
    where return_code = '{{ return_code }}' and is_primary_basis

),

child_sums as (

    select
        b.institution_id,
        b.reporting_period_raw,
        h.parent_line_item_code,
        sum(b.amount_cad_000) as child_total
    from base b
    join hierarchy h on b.line_item_code = h.line_item_code
    group by 1, 2, 3

),

declared as (

    select
        institution_id,
        reporting_period_raw,
        line_item_code as parent_line_item_code,
        amount_cad_000 as declared_total
    from base

)

select
    c.institution_id,
    c.reporting_period_raw,
    c.parent_line_item_code,
    c.child_total,
    d.declared_total,
    c.child_total - d.declared_total as variance
from child_sums c
join declared d
  on  c.institution_id = d.institution_id
  and c.reporting_period_raw = d.reporting_period_raw
  and c.parent_line_item_code = d.parent_line_item_code
where abs(c.child_total - d.declared_total) > {{ tolerance }}

{% endtest %}
