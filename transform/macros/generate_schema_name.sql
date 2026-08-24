{#
    Standard dbt override: use the custom schema name as-is instead of
    concatenating it with the target's default schema (dbt's out-of-the-box
    behavior would otherwise produce e.g. "dbt_dev_snapshots" instead of the
    clean, dedicated BigQuery dataset "snapshots" that docs/PROJECT_STRUCTURE.md
    calls for -- snapshots, staging, core, finance, risk, controls, reference
    are each meant to be their own top-level dataset).
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
