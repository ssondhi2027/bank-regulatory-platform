# Known data issues

Real characteristics of the OSFI source data, discovered during profiling,
and the decision made for each. See `docs/decisions/` for issues significant
enough to warrant a full ADR.

---

## Dual-basis filings during accounting standard transitions

**Found:** Phase 2 profiling. See `docs/decisions/ADR-0001-natural-key.md`.

**Issue:** The base natural key `(institution_id, return_code,
reporting_period_end, line_item_code)` is not unique. 230 (M4) / 123 (P3) /
58 (E3) key combinations report the same line item twice, on two different
accounting bases (e.g. IAS 39 "impairment" wording vs IFRS 9 "expected
credit losses" wording), with different amounts.

**Decision:** Add a deterministic `variant_seq` to the natural key.
`seeds/seed_data_point_variants.csv` curates which variant is the primary
basis. Marts filter to `is_primary_basis = true`; staging and the snapshot
retain both. See ADR-0001 for full rationale and rejected alternatives.

**Superseded in part by ADR-0002** — see the next entry. The ordering clause
(`order by data_point_label_as_filed`) assumed labels always differ between
variants; that assumption was falsified, and the fix changes both the
ordering key and how `seed_data_point_variants.csv` is built.

---

## Variant ordering must include Return Title, and one institution-period is quarantined

**Found:** Drafting `seed_data_point_variants.csv` (Phase 2). See
`docs/decisions/ADR-0002-variant-ordering-and-quarantine.md`, which
supersedes ADR-0001's ordering clause.

**Issue:** 162 of the 270 duplicate `(return_code, line_item_code,
reporting_period_end)` groups have byte-identical label text on both
variants, so `order by label` silently fell back to physical row order — an
ordering never claimed to be stable. A full column diff plus an audit of
every institution ID involved in *any* duplicate group (not just the
identical-label ones) found the population splits cleanly in two:

- **220 groups**, exclusively OSFI's own aggregate rows (`Id 1000000` /
  `1000001` / `1000002`, i.e. Total All Banks / Total Domestic / Total
  Foreign Bank Subsidiaries) — no real financial institution is affected by
  this population at all. `Return Title` differs for 112 of these; the
  other 108 already had differing labels.
- **50 groups**, exclusively `Id 28017` (a small institution that has
  carried several legal names over time — Hollis Canadian Bank / Dundee
  Wealth Bank / ADS Canadian Bank / Dundee Bank of Canada), exclusively at
  **2010-12-31**, in P3 (41 codes) and E3 (9 codes). Every single line item
  OSFI has for this institution at this period is duplicated — the entire
  filing appears twice — with **no column at all** distinguishing the two
  rows besides the amount.

For the 50 `Id 28017` groups, the following proof (preserved verbatim from
the investigation, since it is the direct justification for quarantining
rather than resolving this population) shows physical row order is not
merely unstable across future republications — it is already internally
inconsistent within a single file pull:

> `Id 28017`'s Q4-2010 E3 filing has every one of its 9 line items
> duplicated, with no third, single-valued line item anywhere in that
> institution-period to test against. But two of the duplicated codes are
> themselves parent/child of each other, which lets the pairing be checked
> internally without an external anchor:
>
> ```
> 3125 "...individual allowance"           rows: (row 118078, 46.0), (row 118079, 64.0)
> 3127 "...individual allowance"           rows: (row 118080, 101.0), (row 118081, 28.0)
> 3131 "total, individual allowance"       rows: (row 118082, 147.0), (row 118083, 92.0)
>
>   same-physical-position pairing:
>     row-position 0: 46 + 101 = 147  == 3131 position 0 (147)   MATCH
>     row-position 1: 64 + 28  = 92   == 3131 position 1 (92)    MATCH
>
> 3133 "...recorded investment"            rows: (row 118084, 46.0),   (row 118085, 64.0)
> 3135 "...recorded investment"            rows: (row 118086, 746.0),  (row 118087, 1163.0)
> 3139 "total, recorded investment"        rows: (row 118088, 810.0),  (row 118089, 1209.0)
>
>   same-physical-position pairing:
>     row-position 0: 46 + 746   = 792   != 3139 position 0 (810)   FAILS
>     row-position 1: 64 + 1163  = 1227  != 3139 position 1 (1209)  FAILS
>
>   crossed-position pairing:
>     3133 pos 0 (46) + 3135 pos 1 (1163) = 1209 == 3139 position 1 (1209)  MATCH
>     3133 pos 1 (64) + 3135 pos 0 (746)  = 810  == 3139 position 0 (810)   MATCH
> ```
>
> `3125`/`3127`/`3131` require **same-position** pairing to satisfy the
> subtotal identity. `3133`/`3135`/`3139` require **crossed-position**
> pairing to satisfy the identical kind of identity, in the same
> institution-period, in the same file pull. There is no single row-order
> rule that is correct for both. Row order does not track a consistent
> "vintage" across codes here — it is not merely a risk of instability
> across future republications, it is already incoherent within this one
> export.

**Decision:**

1. `variant_seq` is now ordered by `(return_title, label_as_filed)`, not
   label alone. This resolves all 220 aggregate groups by content; verified
   zero ties remain among them, max `variant_seq` is still 1, and the 50
   `Id 28017` groups are the only remaining tied population (expected — no
   column distinguishes them, so a content-based tiebreak correctly finds
   nothing to break the tie on).
2. `seeds/seed_quarantine.csv` excludes `Id 28017` at `2010-12-31` (P3 and
   E3) entirely, at the institution-period level, pending manual
   reconciliation against OSFI's original filing. No algorithmic pairing is
   attempted — the proof above shows the data does not contain the
   information needed to do it correctly.
   **Amended in Phase 5** (see the ADR-0002 addendum): originally scoped as
   "excluded from marts," this proved insufficient — building
   `snap_osfi_filings` showed BigQuery's `row_number()` has no stable
   tiebreak at all for `Id 28017`'s rows (every column but the amount is
   identical), so leaving them in the snapshot's source query produced 46
   phantom restatement rows across two runs on *unchanged* data. The
   exclusion now happens in the snapshot itself, upstream of
   `row_number()`, not only in marts.
3. `seeds/seed_data_point_variants.csv` is now an **override table**.
   Default (no seed row): `is_primary_basis` is derived automatically as
   the variant whose `(return_title, label_as_filed)` matches the
   most-recently-observed `(return_title, label_as_filed)` for that
   `(return_code, line_item_code)` across the full history of the file.
   This required no manual curation for 174 of the 220 aggregate groups.
   The seed holds only the 46 exceptions: 28 groups where the automatic
   rule fails outright (`Return Title` has **three or more** distinct
   historical values for that code, and the specific pair being evaluated
   contains neither the first nor the truly-latest wording — e.g. P3 code
   `0791`'s title went `"P3 - Consolidated Statement Of Income"` →
   `"P3 - Consolid Statement Of Income, Retained Earnings & AOCI"` →
   `"P3 - Consolidated Statement Of Income, Retained Earnings & AOCI"`, and
   the 2007 duplicate pair contains only the first two), plus the 24
   originally label-ambiguous groups (kept as review exceptions per policy
   regardless of whether auto-derivation happens to succeed for them — 6 of
   the 24 overlap with the 28 broken ones).
4. `extract/keys.py` centralizes `compute_variant_seq`; both
   `extract/generate_schema.py` and `extract/schema_assert.py` import it.
   `schema_assert.py`'s own natural-key uniqueness check previously assumed
   every key column was a literal raw column — a gap flagged but not fixed
   during the original Phase 2 review — and now recomputes `variant_seq`
   from the schema's `variant_ordering` block before checking.
5. `Return Title` is now a consumed, contract-critical column in
   `schema.yml` for all three returns — it is load-bearing for key
   uniqueness, not merely informational.

See `docs/decisions/ADR-0002-variant-ordering-and-quarantine.md` for the
full decision record, consequences, and rejected alternatives.

---

## P3 null amounts are "not reported," not zero

**Found:** Phase 2 profiling. 12,892 rows (3.66% of P3) have a null
`Measure Value`. M4 and E3 have zero nulls in the amount column, and none of
the three files contain suppression markers or footnote tokens — the amount
column is either a clean number or genuinely blank.

**Decision:** Never `coalesce(amount, 0)` on this column. A null means the
institution did not report that line item for that period, which is a
materially different fact from a reported value of zero (e.g. "no data" vs
"we had none of this"). Any aggregation or control that sums this column
must decide explicitly how to handle nulls, not silently zero-fill them.

---

## The latest period in a landed file is frequently incomplete

**Found:** Phase 2 profiling. At the time of profiling, M4's most recent
month had 32.3% of the historical median row volume, and E3's most recent
quarter had 39.8%. Not every institution has filed yet when a period first
appears in the file — `MAX(period)` in a raw pull is not evidence that the
period is complete.

**Decision:** Derive `period_status` (complete vs. partial) from the
**distinct filing-institution count** for that period against its trailing
median, not from row count. Row count is a weaker proxy — a single
institution filing many line items can look superficially "full" while
whole institutions are still missing.

---

## Land full history; scope via config, not extraction

**Found:** Phase 2 profiling. All three returns span 1996 through mid-2026
(30 years) — far more than the 6-institution / 5-year target scope for this
project.

**Decision:** The extractor lands the full available history for all three
returns. Scope (6 institutions, 5 years) is applied as a `dbt var` filter in
staging, not by restricting what gets extracted or loaded. This keeps scope
a reversible configuration choice rather than a data-loss decision baked
into ingestion — widening scope later never requires re-extracting history
we already had.

---

## REC-007 needs a fourth dataset: foreign bank branches

**Found:** Phase 2 profiling, aggregate reconciliation check. At period
2025-10-31, `Total All Banks` (Id 1000000) = 9,519,056,765 (thousands CAD),
while `Total Domestic Banks` (1000001) + `Total Foreign Bank Subsidiaries`
(1000002) = 9,331,356,480 — a residual of **187,700,285 thousand CAD
(~$187.7B)**.

**Decision:** The residual is foreign bank **branches**, a population OSFI
tracks separately from foreign bank subsidiaries and which does not appear
in the M4/P3/E3 institution rows at all. `REC-007` (industry total ties to
published) requires ingesting the foreign bank branches dataset
(`c6879faf-2bc7-4c84-999c-0626ae33ec84`) in addition to the Banks dataset,
and must exclude bank subsidiaries of banks already counted elsewhere to
avoid double-counting when reconciling to the published industry total.

**Resolved in Phase 8.** The branches dataset (CKAN `c6879faf-...`)
publishes its own M4 file with the same schema shape as the main Banks
dataset (same load-bearing columns; only a non-consumed label column's
wording differs), plus two more OSFI aggregate pseudo-institutions:
`1000006` ("Total Foreign Bank Branches - Lending") and `1000007` ("Total
Foreign Bank Branches - Full Service"). The package's own published notes
confirm OSFI's totals already exclude subsidiary-of-subsidiary double-
counting ("Industry Totals do not include data reported by Banks that are
subsidiaries of other Banks, since this data is already accounted for in
the consolidated data reported by the parent banks"), so no separate
exclusion logic was needed -- using OSFI's own published aggregates
directly inherits it. Landed as return_code `M4_FBB` (`extract/
osfi_extract.py`, `extract/schema.yml` -- its own row-count baseline,
verified natural-key-unique, profiled the same way the original three
returns were in Phase 2), flowing through the existing snapshot/staging
pipeline unmodified (partition keys already include `source_return_code`,
so it doesn't collide with domestic M4). `int_filings__industry_totals.sql`
pivots the five aggregate rows; `tests/
rec_007_industry_total_ties_to_published.sql` checks
`1000000 = 1000001 + 1000002 + 1000006 + 1000007` within materiality
tolerance. Verified: exact zero variance across all 67 scoped periods,
including the most recent (partial) month -- OSFI's own totals are
internally consistent regardless of period completeness.

---

## P3 line item 1109 ("Net income") does not exist before 2011

**Found:** Phase 8, first `dbt test` run against `fct_income_statement`.
`not_null` on `net_income_cad_000` failed with exactly 360 rows — every
single Big-Six row from 1996-01-31 through 2010-12-31 (24 rows/year x 15
years), zero failures from 2011-01-31 onward.

**Investigated as a possible bug first:** checked whether the `is_primary_basis`
variant filter was dropping a real row (it wasn't — every raw
`(institution_id, reporting_period_raw)` group for code `1109` has exactly
one primary-marked row, zero orphaned non-primary groups), and whether the
FYE-based calendar-date join was silently excluding pre-2011 rows for this
code only (it wasn't — `net_income_before_tax_cad_000` (code `1285`) and
`interest_income_total_cad_000` (code `8252`) are both populated for the
identical 1996-2010 rows, proving the pivot mechanics and FYE mapping work
correctly for that era; only code `1109` itself is absent from the raw P3
data before 2011-01-31).

**Decision:** This is a real characteristic of the P3 return, not a pipeline
bug — OSFI introduced a distinct "Net income" line item (code `1109`) into
P3 starting in fiscal 2011; before that, only `1285` ("net income before
tax") was reported at this granularity. The `not_null` test on
`net_income_cad_000` in `_finance__models.yml` is scoped with
`where: "reporting_period_end >= '2011-01-01'"` rather than dropped, so it
still catches a genuine future regression within the era the code exists.

---

## M4 line-item codes changed around 2008-2009; scope narrowed to a 5-year window

**Found:** Phase 8, REC-001 (balance sheet identity) first run. 1,712 of
3,533 rows failed, with variances up to ~$214B on a single institution-
period, concentrated entirely in 1996-2008 and shrinking to near-zero by
2011-2012.

**Investigated as a possible bug first:** confirmed OSFI's own direct
combined total (code `2230`, "total liabilities and shareholders' equity")
is complete across the full 30-year history and always equals total assets
(code `1045`) exactly — so the pivot mechanics and FYE mapping are correct.
The gap traced to 8 of the 12 deposit codes (`0873`-`0881` etc.) our
liability rollup sums having **zero rows** in the raw data before ~2009 —
OSFI restructured M4's deposit detail codes around that time, the same
pattern later confirmed for P3's `1109` code (see previous entry).

**Decision:** Rather than chase down 15-20-year-old retired code numbers
(open-ended, possibly unrecoverable), applied the scope this project was
always meant to have: `docs/project_structure.md`'s "Land full history;
scope via config, not extraction" entry already specified a trailing-window
dbt var filter in staging, which had never actually been wired up.
`vars.scope_years` (default 5) now filters `stg_osfi__filings` on the
shared leading-year prefix in both M4's and P3/E3's period representations.
Landing zone and snapshot are unaffected — full history stays there;
widening scope later is a var change, not a re-extraction. All incremental
mart tables (`fct_balance_sheet`, `fct_income_statement`) required one
`--full-refresh` to purge now-out-of-scope rows, since narrowing a staging
filter does not retroactively remove rows from an already-populated
incremental table.

---

## P3/E3 granular detail-line codes are essentially unfiled in current-era data

**Found:** Phase 8, REC-002 (subtotal rollup) first run against P3 and E3.
5,731 P3 failures, 3,778 E3 failures.

**Investigated as a possible hierarchy-seed bug first:** cross-checked every
failing parent code's declared children in `seed_line_item_hierarchy.csv`
against OSFI's own Validation Rules XLSX (`P3_validation_rules.xlsx`,
`E3_validation_rules.xlsx`) for M4, P3, and E3. M4's hierarchy matched
exactly and passes cleanly. Most of P3/E3's declared child-code lists also
matched the authoritative formulas exactly (e.g. E3's `IR30`:
`3302 = 3303 + 3304 + 3306 + 3309`) — so the codes themselves were not
wrong. Direct query confirmed the real cause: most of those declared child
codes have **zero rows anywhere** in the loaded data (e.g. P3 code `8407`'s
6 declared children — only `8402` and the `8407` total itself are ever
filed; E3 code `3302`'s 4 declared children — only `3303`, credit cards,
is ever filed). Modern OSFI filers report the summary rollup directly and
do not populate the granular detail breakdown OSFI's schema still
nominally supports.

**Decision:** REC-002 is scoped to M4 only (`_filings__models.yml`), where
it is fully meaningful and passes cleanly. Not extended to P3/E3 — a
"require every declared child present" variant was considered and rejected,
since it would evaluate ~0 real groups for most P3/E3 parents and create an
illusion of coverage that isn't real.

## REC-004 and REC-005 cannot be implemented against current-era data

**Found:** Phase 8, building REC-004 (retained earnings continuity) and
REC-005 (cross-return net income tie-out).

**Investigated:** REC-004 needs dividends-declared figures (P3 codes `1495`
preferred, `1496` common, per validation rule `IR195`). REC-005's most
direct real analog is validation rule `P3M402`, which ties P3's own
retained-earnings-end-of-period (`1498`) to M4's retained earnings (`2225`)
for the same period -- there is no "net income" line item inside M4's
equity section at all (confirmed during the Phase 7 code-mapping work), so
a literal reading of REC-005's description has no real M4 counterpart to
check against regardless. Direct query confirmed P3's entire Section III
(codes `1493`-`1498`, everything `IR195`/`P3M402` need) has **zero rows
anywhere** in the loaded, scoped data -- not a mapping gap, not a stale
flag like the earlier P3/E3 findings, genuinely never filed by any
institution in scope. A broader search for any populated "dividend"-labeled
code across all three returns found only interest/dividend *income received*
on securities held (an asset-side revenue line), never dividends *declared*
to shareholders.

**Decision:** Not implemented. An approximation was considered --
`retained_earnings(t) ≈ retained_earnings(t-1) + net_income(t)`, dropping
the dividends term -- and rejected: every real, profitable, dividend-paying
institution (i.e. every Big Six bank, every quarter) would systematically
overshoot this identity by roughly its dividend payment, producing constant
false failures that are a modeling gap, not a real reconciliation break. A
control that reliably cries wolf is worse than no control -- it trains
whoever reviews `rpt_control_scorecard` to ignore it. REC-003 (income
statement rollforward) ships instead, fully viable since all four inputs it
needs are populated across every scoped row. REC-004/REC-005 remain in
`seed_control_registry.csv` (registered) but have no corresponding test --
`fct_control_results` will show them absent from a given run's results
rather than fabricating a pass or fail with no real check behind it.

---

**Separately, a genuine hierarchy bug was found and fixed** along the way:
codes `1109` (net income) and `1168` (comprehensive income) were double-
counted, because OSFI validates each of them via **two independent,
already-complete partitions** (`1109`: `IR202` = before-discontinued +
discontinued, *and* `IR203` = non-controlling + equity-holders; `1168`:
`IR197` = net income + OCI, *and* `IR200` = equity-holders + non-controlling),
and the seed had flattened both partitions into one child list per parent —
summing all of them double-counts the true total exactly 2x. Fixed by
keeping only one canonical partition as the declared children (`1109`:
`1197` + `1292` per `IR203`; `1168`: `1158` + `1167` per `IR197`) and
re-parenting the dropped codes (`1111`, `1112`, `1288`, `8652`) to no
parent, with a note explaining why, so they remain in the hierarchy seed
(satisfying the Phase 6 anti-join checkpoint) without being double-counted.
