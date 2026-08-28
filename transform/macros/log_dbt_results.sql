{% macro log_dbt_results(results) %}
  {#-
    on-run-end hook: persists every test outcome so fct_control_results can
    join it back to seed_control_registry. dbt executes whatever SQL this
    macro renders to -- it must not also call run_query() itself, or the
    insert would fire twice.

    Deliberately NOT gated on target.name == 'prod' (the usual pattern for
    this kind of macro): this is a single-developer portfolio project with
    no separate prod BigQuery workload actually running yet, and CLAUDE.md's
    own working style requires showing real checkpoint output for every
    phase, which a prod-only gate would make impossible to verify against
    dev. Logs on every target. Revisit if a real scheduled prod run is ever
    wired up (Phase 9) and dev-run noise becomes a problem.

    The destination table ({{ target.schema }}_audit.dbt_test_log) is
    created out-of-band, not by dbt -- a raw INSERT cannot create its own
    table. See the Phase 8 checkpoint notes for the one-off DDL.

    Only fires on `dbt run`/`dbt build` (project hooks are tied to the run
    task) -- `dbt test` alone never invokes on-run-end hooks, confirmed via
    --debug: no "on-run-end" hook node appears in a test-only invocation's
    log at all. Also: dbt's partial-parse cache did not pick up this hook
    being added to dbt_project.yml on the first post-change run ("Nothing
    changed, skipping partial parsing" even though dbt_project.yml had just
    been edited) -- delete target/partial_parse.msgpack (or pass
    --no-partial-parse) once after adding or editing this hook.
  -#}
  {% if execute and results %}
    {% set rows = [] %}
    {% for res in results %}
      {% if res.node.resource_type == 'test' %}
        {#- SKIPPED tests (e.g. downstream of an upstream failure/error in
            the same invocation) have failures=None and execution_time=None
            -- `| default(0)` on failures already guarded that, but
            execution_time had no such guard, so `None | round(3)` rendered
            the bare word None into the SQL literal, breaking the insert
            for the whole invocation (BigQuery: "Unrecognized name: None").
            Found via a full `dbt build`, not caught by scoped --select
            runs where nothing upstream had failed yet to produce a SKIP. -#}
        {% do rows.append(
          "('" ~ invocation_id ~ "','" ~ res.node.name ~ "','"
               ~ res.status ~ "'," ~ (res.failures | default(0)) ~ ","
               ~ (res.execution_time | default(0) | round(3)) ~ ",current_timestamp())"
        ) %}
      {% endif %}
    {% endfor %}
    {% if rows | length > 0 %}
insert into `{{ target.project }}`.`{{ target.schema }}_audit`.`dbt_test_log`
  (invocation_id, test_name, status, failure_count, execution_seconds, logged_at)
values {{ rows | join(', ') }}
    {% else %}
select 1  {#- no tests ran this invocation -- harmless no-op, not an empty query -#}
    {% endif %}
  {% else %}
select 1
  {% endif %}
{% endmacro %}
