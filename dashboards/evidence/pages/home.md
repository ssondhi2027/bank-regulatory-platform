# Data Control Scorecard

Bank regulatory reporting platform — OSFI M4/P3/E3 filings, control results
from every `dbt build` run, queried live against BigQuery.

```sql latest_run
select
  run_id,
  run_logged_at,
  sum(control_count) as total_controls,
  sum(passing_count) as total_passing,
  sum(breach_count) as total_breaches
from controls.rpt_control_scorecard
where run_logged_at = (select max(run_logged_at) from controls.rpt_control_scorecard)
group by 1, 2
```

{% row %}
{% big_value data="latest_run" value="total_controls" title="Controls checked (latest run)" /%}
{% big_value data="latest_run" value="total_passing" title="Passing" /%}
{% big_value data="latest_run" value="total_breaches" title="Breaches" /%}
{% /row %}

## Control pass rate by category, trending

```sql pass_rate_trend
select
  run_logged_at,
  category,
  pass_rate
from controls.rpt_control_scorecard
order by run_logged_at
```

{% line_chart
  data="pass_rate_trend"
  x="run_logged_at"
  y="pass_rate"
  series="category"
  y_fmt="pct1"
  title="Pass rate by category over time"
  subtitle="One point per dbt build run"
/%}

## Breach detail

Every control result from the most recent run, worst severity first. Empty
when everything passes -- which it currently does.

```sql breach_detail
select
  control_id,
  control_name,
  category,
  severity,
  owner,
  status,
  failure_count,
  logged_at
from controls.fct_control_results
where category is not null
  and is_passing = 0
order by
  case severity when 'error' then 2 when 'warn' then 1 else 0 end desc,
  logged_at desc
```

{% table data="breach_detail" %}
{% /table %}

## Source freshness vs SLA

Warn at 45 days since last ingest, error at 75 -- same thresholds pinned in
`_osfi__sources.yml`.

```sql freshness
select
  source_return_code,
  last_ingested_at,
  days_since_ingested,
  freshness_status
from controls.rpt_source_freshness
order by days_since_ingested desc
```

{% table data="freshness" %}
{% /table %}

## Restatement frequency by institution

Every line item that was ever restated after first being filed -- this
chart exists in almost no comparable portfolio project. Counts distinct
restatement events, not distinct line items (an institution can restate
the same line item more than once).

```sql restatements_by_institution
select
  m.legal_name,
  m.short_name,
  count(*) as restatement_count,
  avg(r.days_to_restatement) as avg_days_to_restatement
from intermediate.int_filings__restatement_events r
join core.dim_institution m on r.institution_id = m.institution_id
group by 1, 2
order by restatement_count desc
```

{% bar_chart
  data="restatements_by_institution"
  x="short_name"
  y="restatement_count"
  title="Restatement events by institution"
  subtitle="Count of (institution, period, line item) restatements captured by the bitemporal snapshot"
/%}

{% table data="restatements_by_institution" %}
{% /table %}
