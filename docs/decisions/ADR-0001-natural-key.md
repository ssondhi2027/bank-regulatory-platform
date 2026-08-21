# ADR-0001: Natural key must accommodate dual-basis filings

**Status:** Accepted
**Date:** 2026-08-04
**Phase:** 2 (source profiling)

---

## Context

The design in `docs/PROJECT_STRUCTURE.md` assumed the natural key of an OSFI
filing line was:

```
(institution_id, return_code, reporting_period_end, line_item_code)
```

Profiling proved this is **not unique**:

| Return | Duplicate key combinations | Total rows | Periods affected |
|---|---|---|---|
| M4 | 230 | 1,555,044 | 2017 only |
| P3 | 123 | 352,564 | 2007-2010, 2014-2015, 2017 |
| E3 | 58 | 143,354 | 2010, 2017-2018 |

The duplicates are **not a data error**. They are the same institution, period,
and data point address reported on **two different accounting bases**, with
different amounts. The clearest case: 210 of the 230 M4 duplicates are a single
line item filed once under IAS 39 wording ("less allowance for impairment") and
once under IFRS 9 wording ("less allowance for expected credit losses"), all in
2017 — the IFRS 9 adoption transition for Canadian banks.

During a standards transition, institutions legitimately report the same period
on both the outgoing and incoming basis. OSFI reuses the data point address
across the revision rather than issuing a new code.

**No single existing column disambiguates them universally.** In M4 the
duplicate rows share an identical `Return Title` and differ only in
`Data Point Address Label`. In P3 the `Return Title` does differ. A tiebreaker
that works for one return fails for another.

### Why we cannot simply hash the label into the key

`Data Point Address Label` is not stable. M4 has 290 distinct codes but 338
distinct labels, so labels are revised over time for benign reasons too. If the
label were part of the snapshot key, a cosmetic relabel would change the key for
every historical row of that series at once. The dbt snapshot would interpret it
as the entire series being deleted and a new series inserted — destroying
restatement history for that measure.

The key must therefore be stable against *benign relabeling* while still
separating *genuinely concurrent* measures.

---

## Decision

### 1. Add a deterministic `variant_seq` to the natural key

```
(institution_id, return_code, reporting_period_end, line_item_code, variant_seq)
```

where, within each base four-column group:

```sql
variant_seq = row_number() over (
    partition by institution_id, return_code, reporting_period_end, line_item_code
    order by data_point_label_as_filed
) - 1
```

Properties:

- **`variant_seq` is 0 for approximately 99.98% of rows.** Only the ~411
  dual-basis combinations across all three returns ever produce a 1.
- **Benign relabeling does not change the key.** A code with a single label per
  period stays at `variant_seq = 0` no matter how the label text is edited, so
  the snapshot correctly records a value change rather than a delete-and-insert.
  This is the property that hashing the label directly would have lost.
- **Genuinely concurrent measures stay separate**, so the pre-transition value
  is preserved rather than discarded.

Accepted residual risk: if a label edit reorders two concurrent variants within
the same period, variant identity swaps. All affected periods are frozen
historical periods that will not be refiled, so the risk is negligible. It is
guarded by control `PLA-004` below.

### 2. Curate a variant seed rather than inferring the reporting basis

`seeds/seed_data_point_variants.csv`:

```csv
return_code,line_item_code,reporting_period_end,variant_seq,label_as_filed,accounting_basis,is_primary_basis,note
M4,<code>,2017-01-31,0,...less allowance for impairment...,IAS_39,false,Superseded basis retained for transition comparability
M4,<code>,2017-01-31,1,...less allowance for expected credit losses...,IFRS_9,true,Adopted basis
```

The distinct code count needing curation is small — the 411 duplicate rows
collapse to a few dozen distinct codes.

Default behaviour for any key not in the seed: `variant_seq = 0`,
`is_primary_basis = true`.

### 3. Marts filter to the primary basis; staging and snapshot keep both

`fct_balance_sheet` and `fct_income_statement` select only
`is_primary_basis = true`.

**This is not optional.** Summing both variants for a 2017 period would
double-count the affected line items and break `REC-001` for reasons that look
like a reconciliation failure but are actually a grain failure.

The snapshot and staging layers retain both variants, so the dual-basis history
remains queryable and auditable.

### 4. New controls

| ID | Category | Severity | Test |
|---|---|---|---|
| PLA-004 | Plausibility | error | Exactly one `is_primary_basis = true` row per (institution, return, period, code) |
| PLA-005 | Plausibility | warn | The set of (return, code, period) combinations carrying more than one variant does not change between runs |
| CMP-005 | Completeness | error | Every duplicate key combination present in staging is represented in `seed_data_point_variants` |

`CMP-005` matters most: it means a *future* accounting transition that
introduces new dual-basis filings fails the build loudly instead of silently
double-counting.

---

## Consequences

**Positive**

- Zero data loss; both accounting bases preserved.
- Snapshot key is stable against label revision, preserving restatement history.
- The IFRS 9 transition becomes a documented, explainable feature of the
  platform rather than an unexplained anomaly.
- `CMP-005` converts an unknown future risk into a build failure.

**Negative**

- Requires a curated seed and periodic maintenance.
- `variant_seq` must be computed identically in the extractor/staging layer and
  in the snapshot, or keys diverge. Compute it once, in `stg_osfi__filings`,
  and have the snapshot read from there.

**Rejected alternatives**

- *Hash the label into the key* — fragile against benign relabeling; would
  destroy restatement history on cosmetic edits.
- *Pick one vintage and drop the other* — loses the pre-transition value.
  Unacceptable for a platform whose stated purpose is faithful regulatory
  reproduction.
- *Use `Return Title` as tiebreaker* — proven not to work for M4.

---

## Related profiling findings

- **Code namespace:** `Data Point Address` codes do not overlap between M4, P3
  and E3 (zero shared codes). The compound key `(return_code, line_item_code)`
  is nonetheless adopted defensively, and it makes the variant seed
  unambiguous.
- **Aggregate reconciliation:** at 2025-10-31, Total All Banks
  (9,519,056,765) exceeds Total Domestic (9,299,488,650) plus Total Foreign
  Bank Subsidiaries (31,867,830) by 187,700,285 thousand CAD. Consistent with
  foreign bank branches, which are a separate OSFI population in a separate
  dataset. `REC-007` therefore requires ingesting dataset
  `c6879faf-2bc7-4c84-999c-0626ae33ec84`.
- **Nulls:** P3 has 12,892 null amounts (3.66%). These are blanks, not
  suppression markers. They must not be coalesced to zero — a null is
  "not reported", which is materially different from a reported zero.
- **Partial periods:** the latest period in M4 (32.3% of median row volume) and
  E3 (39.8%) is incomplete. `period_status` should be derived from **distinct
  filing institution count** against the trailing median, not row count, which
  is a weaker proxy.
- **History depth:** all three returns span 1996 to mid-2026. Land the full
  history; scope to 6 institutions and 5 years with a dbt `var` in staging so
  scope is configuration, not data loss.
