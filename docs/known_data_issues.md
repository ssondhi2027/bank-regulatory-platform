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
   E3) entirely, at the institution-period level. Excluded from marts,
   pending manual reconciliation against OSFI's original filing. No
   algorithmic pairing is attempted — the proof above shows the data does
   not contain the information needed to do it correctly.
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
