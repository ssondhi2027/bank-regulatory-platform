{#
    Standard dbt override: use the custom schema name as-is instead of
    concatenating it with the target's default schema (dbt's out-of-the-box
    behavior would otherwise produce e.g. "dbt_dev_snapshots" instead of the
    clean, dedicated BigQuery dataset "snapshots" that docs/PROJECT_STRUCTURE.md
    calls for -- snapshots, staging, core, finance, risk, controls, reference
    are each meant to be their own top-level dataset).

    EXCEPT for target=ci: dev and prod deliberately share these bare-name
    datasets (solo-developer project, accepted tradeoff -- dev's
    work-in-progress state can leak into what prod's tables show, but
    nothing else consumes prod between runs). ci is categorically
    different: it runs against unreviewed PR branches, and letting a CI
    build write into the exact same tables the scheduled prod pipeline
    serves from -- before the PR is even merged -- is a real risk, not a
    tradeoff. Found in Phase 9 when bootstrapping the prod-manifest:
    `dbt build --target prod` silently reused dev's already-populated
    finance/core/snapshots tables (0 new snapshot rows, since dev had
    already captured everything). ci gets its own target-prefixed,
    disposable schemas instead.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if target.name == 'ci' -%}
        {%- if custom_schema_name is none -%}
            {{ default_schema }}
        {%- else -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- endif -%}
    {%- elif custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
