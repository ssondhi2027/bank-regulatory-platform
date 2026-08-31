# Big Six Business Dashboard

Peer benchmarking across the Big Six -- OSFI M4/P3/E3 filings joined to
Bank of Canada rate data, queried live against BigQuery.

## Total assets, indexed to first period

```sql indexed_assets
with bs as (
  select
    bs.institution_id,
    m.short_name,
    bs.reporting_period_end,
    bs.total_assets_cad_000,
    first_value(bs.total_assets_cad_000) over (
      partition by bs.institution_id order by bs.reporting_period_end
    ) as base_assets
  from finance.fct_balance_sheet bs
  join core.dim_institution m on bs.institution_id = m.institution_id
)
select
  short_name,
  reporting_period_end,
  total_assets_cad_000 / base_assets * 100 as indexed_assets
from bs
order by reporting_period_end
```

{% line_chart
  data="indexed_assets"
  x="reporting_period_end"
  y="indexed_assets"
  series="short_name"
  title="Total assets, indexed (first period in scope = 100)"
  subtitle="Monthly, from M4"
/%}

## Net interest margin vs. Bank of Canada policy rate

The headline chart -- Big-Six-average NIM (annualized, single-quarter
figures, not P3's raw year-to-date) against the policy rate over the same
periods.

```sql nim_vs_rate
select
  fm.reporting_period_end,
  avg(fm.net_interest_margin) * 100 as avg_nim_pct,
  avg(r.policy_rate_period_end) as policy_rate_pct
from finance.fct_financial_metrics fm
join intermediate.int_rates__period_aligned r on fm.reporting_period_end = r.reporting_period_end
where fm.net_interest_margin is not null
group by 1
order by 1
```

{% combo_chart
  data="nim_vs_rate"
  x="reporting_period_end"
  y_fmt="num1"
  y2_fmt="num1"
  title="Big-Six average NIM vs. BoC policy rate"
  subtitle="Left axis: NIM %. Right axis: policy rate %."
%}
{% line y="avg_nim_pct" /%}
{% line y="policy_rate_pct" axis="y2" /%}
{% /combo_chart %}

## Deposit and loan mix across the Big Six

Each institution's share of combined Big-Six deposits and gross loans --
the "mix" available at this grain (no per-product breakdown is modeled).

```sql deposit_mix
select m.short_name, bs.reporting_period_end, bs.total_deposits_cad_000
from finance.fct_balance_sheet bs
join core.dim_institution m on bs.institution_id = m.institution_id
order by bs.reporting_period_end
```

{% area_chart
  data="deposit_mix"
  x="reporting_period_end"
  y="total_deposits_cad_000"
  series="short_name"
  title="Total deposits by institution"
  subtitle="Stacked -- monthly, from M4"
/%}

```sql loan_mix
select m.short_name, bs.reporting_period_end, bs.gross_loans_cad_000
from finance.fct_balance_sheet bs
join core.dim_institution m on bs.institution_id = m.institution_id
where bs.gross_loans_cad_000 is not null
order by bs.reporting_period_end
```

{% area_chart
  data="loan_mix"
  x="reporting_period_end"
  y="gross_loans_cad_000"
  series="short_name"
  title="Gross loans by institution"
  subtitle="Stacked -- only populated at true quarter-ends (needs E3's allowance figure to back out gross from M4's net-of-allowance loan lines)"
/%}

## Allowance coverage ratio trend

From E3 (allowances for expected credit losses) -- the credit risk angle.

```sql allowance_coverage
select m.short_name, fm.reporting_period_end, fm.allowance_coverage_ratio * 100 as allowance_coverage_pct
from finance.fct_financial_metrics fm
join core.dim_institution m on fm.institution_id = m.institution_id
where fm.allowance_coverage_ratio is not null
order by fm.reporting_period_end
```

{% line_chart
  data="allowance_coverage"
  x="reporting_period_end"
  y="allowance_coverage_pct"
  series="short_name"
  title="Allowance coverage ratio"
  subtitle="Allowance for credit losses / gross loans"
/%}

## Peer ranking, latest quarter

Ranked by total assets, with the rank change since the prior period shown
in the table below.

```sql peer_ranking
with ranked as (
  select
    m.short_name,
    bs.institution_id,
    bs.reporting_period_end,
    bs.total_assets_cad_000,
    rank() over (partition by bs.reporting_period_end order by bs.total_assets_cad_000 desc) as rnk
  from finance.fct_balance_sheet bs
  join core.dim_institution m on bs.institution_id = m.institution_id
),
with_prior as (
  select
    *,
    lag(rnk) over (partition by institution_id order by reporting_period_end) as prior_rnk
  from ranked
)
select
  short_name,
  reporting_period_end,
  total_assets_cad_000,
  rnk as rank,
  prior_rnk as prior_rank,
  prior_rnk - rnk as rank_change
from with_prior
where reporting_period_end = (select max(reporting_period_end) from finance.fct_balance_sheet)
order by rnk
```

{% table data="peer_ranking" %}
{% /table %}
