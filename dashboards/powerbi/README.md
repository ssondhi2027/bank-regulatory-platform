# Power BI dashboard (BigQuery, Import + scheduled refresh, Publish to Web)

A publicly viewable version of the same two dashboards already built in
Evidence (`dashboards/evidence/pages/home.md`, `business.md`), connected
directly to BigQuery -- no exported files, no local setup for viewers.

**Mode chosen: Import + scheduled refresh, not DirectQuery.** DirectQuery
would run a real BigQuery query every time anyone opens the public link --
uncapped cost exposure on personal GCP billing with no viewer limit.
Import mode pulls a snapshot into Power BI on a schedule (e.g. every few
hours) instead, so BigQuery only gets queried on refresh, not per viewer.
Current within a few hours, not literally live, and safe to publish
fully public.

## 1. Install Power BI Desktop

Free, Windows only: https://www.microsoft.com/en-us/power-platform/products/power-bi/downloads

You'll also want a (free) Power BI account to publish later:
https://app.powerbi.com

## 2. Connect to BigQuery

1. **Get Data** > search **Google BigQuery** > **Connect**
2. Sign in with the Google account tied to `bank-regulatory-platform`
   (OAuth -- Power BI's BigQuery connector doesn't take a service-account
   JSON directly, it authenticates as you)
3. In the Navigator, you'll see the project's datasets/tables browsable
   directly -- but instead of picking tables and joining them in Power
   Query, use the **same 10 proven queries** already built and verified in
   the Evidence dashboards (below), pasted as native SQL. This reuses
   exact, already-correct logic rather than re-deriving it in Power
   Query's M language.

For each query below: **Get Data > Google BigQuery > Advanced options**,
paste the SQL into the **SQL statement** box, **OK**. Repeat once per
query -- each becomes its own Power BI table.

<details>
<summary><b>control_scorecard_summary</b> -- KPI tiles</summary>

```sql
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
</details>

<details>
<summary><b>pass_rate_trend</b> -- pass rate by category, trending</summary>

```sql
select run_logged_at, category, pass_rate
from controls.rpt_control_scorecard
order by run_logged_at
```
</details>

<details>
<summary><b>breach_detail</b> -- breach detail table (0 rows currently -- correct, means everything passes)</summary>

```sql
select
  control_id, control_name, category, severity, owner, status,
  failure_count, logged_at
from controls.fct_control_results
where category is not null and is_passing = 0
order by
  case severity when 'error' then 2 when 'warn' then 1 else 0 end desc,
  logged_at desc
```
</details>

<details>
<summary><b>source_freshness</b> -- source freshness vs. SLA</summary>

```sql
select source_return_code, last_ingested_at, days_since_ingested, freshness_status
from controls.rpt_source_freshness
order by days_since_ingested desc
```
</details>

<details>
<summary><b>restatements_by_institution</b> -- restatement frequency</summary>

```sql
select
  m.legal_name, m.short_name,
  count(*) as restatement_count,
  avg(r.days_to_restatement) as avg_days_to_restatement
from intermediate.int_filings__restatement_events r
join core.dim_institution m on r.institution_id = m.institution_id
group by 1, 2
order by restatement_count desc
```
</details>

<details>
<summary><b>indexed_assets</b> -- total assets, indexed</summary>

```sql
with bs as (
  select
    bs.institution_id, m.short_name, bs.reporting_period_end,
    bs.total_assets_cad_000,
    first_value(bs.total_assets_cad_000) over (
      partition by bs.institution_id order by bs.reporting_period_end
    ) as base_assets
  from finance.fct_balance_sheet bs
  join core.dim_institution m on bs.institution_id = m.institution_id
)
select short_name, reporting_period_end, total_assets_cad_000 / base_assets * 100 as indexed_assets
from bs
order by reporting_period_end
```
</details>

<details>
<summary><b>nim_vs_policy_rate</b> -- headline chart: NIM vs. BoC policy rate</summary>

```sql
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
</details>

<details>
<summary><b>deposit_and_loan_mix</b> -- deposit and loan mix across the Big Six</summary>

```sql
select
  m.short_name,
  bs.reporting_period_end,
  bs.total_deposits_cad_000,
  bs.gross_loans_cad_000
from finance.fct_balance_sheet bs
join core.dim_institution m on bs.institution_id = m.institution_id
order by bs.reporting_period_end
```
</details>

<details>
<summary><b>allowance_coverage</b> -- allowance coverage ratio trend</summary>

```sql
select m.short_name, fm.reporting_period_end, fm.allowance_coverage_ratio * 100 as allowance_coverage_pct
from finance.fct_financial_metrics fm
join core.dim_institution m on fm.institution_id = m.institution_id
where fm.allowance_coverage_ratio is not null
order by fm.reporting_period_end
```
</details>

<details>
<summary><b>peer_ranking</b> -- peer ranking, latest quarter, with QoQ movement</summary>

```sql
with ranked as (
  select
    m.short_name, bs.institution_id, bs.reporting_period_end,
    bs.total_assets_cad_000,
    rank() over (partition by bs.reporting_period_end order by bs.total_assets_cad_000 desc) as rnk
  from finance.fct_balance_sheet bs
  join core.dim_institution m on bs.institution_id = m.institution_id
),
with_prior as (
  select *, lag(rnk) over (partition by institution_id order by reporting_period_end) as prior_rnk
  from ranked
)
select
  short_name, reporting_period_end, total_assets_cad_000,
  rnk as rank, prior_rnk as prior_rank, prior_rnk - rnk as rank_change
from with_prior
where reporting_period_end = (select max(reporting_period_end) from finance.fct_balance_sheet)
order by rnk
```
</details>

After all 10 are connected, **Home > Close & Apply** to load them into the
model.

## 3. Build the visuals

Same 10 visuals as the Evidence/Tableau versions, same fields:

**Control Scorecard page**

| Table | Visual | Fields |
|---|---|---|
| `control_scorecard_summary` | 3x Card visual | `total_controls`, `total_passing`, `total_breaches` (one card each) |
| `pass_rate_trend` | Line chart | Axis: `run_logged_at`, Values: `pass_rate`, Legend: `category` |
| `breach_detail` | Table | all columns |
| `source_freshness` | Table | all columns (consider conditional formatting on `freshness_status`) |
| `restatements_by_institution` | Clustered bar chart | Axis: `short_name`, Values: `restatement_count` |

**Business Overview page**

| Table | Visual | Fields |
|---|---|---|
| `indexed_assets` | Line chart | Axis: `reporting_period_end`, Values: `indexed_assets`, Legend: `short_name` |
| `nim_vs_policy_rate` | Line chart, **secondary axis** | Axis: `reporting_period_end`, Values: `avg_nim_pct`; add `policy_rate_pct` and move it to the Secondary Values well |
| `deposit_and_loan_mix` | 2x Stacked area chart | Axis: `reporting_period_end`, Values: `total_deposits_cad_000` (chart 1) / `gross_loans_cad_000` (chart 2), Legend: `short_name` |
| `allowance_coverage` | Line chart | Axis: `reporting_period_end`, Values: `allowance_coverage_pct`, Legend: `short_name` |
| `peer_ranking` | Table | all columns (consider conditional formatting on `rank_change`) |

Use two Power BI **report pages** (bottom tabs), one per table above, to
mirror the two Evidence pages.

## 4. Publish

1. **Home > Publish**, sign in, pick a workspace (My workspace is fine for
   a personal project)
2. In the Power BI Service (app.powerbi.com), open the published report
3. **File > Publish to web** (NOT the regular "Share" button -- that
   requires viewers to have accounts). Confirm the public-embed warning --
   this makes the report fully public, no login, no access control.
   Appropriate here since everything derives from public OSFI/BoC data,
   not sensitive.
4. Copy the embed link/iframe it gives you and add it to `README.md`'s
   dashboard section.

## 5. Set up scheduled refresh

1. In the Power BI Service, go to the **dataset** (not the report) >
   **Settings** > **Scheduled refresh**
2. Turn it on, set a frequency (e.g. every 6-8 hours -- the free tier caps
   at 8 refreshes/day)
3. You'll need to enter BigQuery credentials once here so the cloud
   service can refresh without your local Power BI Desktop running --
   Power BI's BigQuery connector supports this directly since BigQuery is
   itself cloud-hosted (no on-premises gateway needed, unlike a local
   database)

That's it -- from here, the published link updates itself on schedule with
no manual re-export or re-publish step, unlike the Tableau Public path.
