# ADR-0002: Variant ordering must use (return_title, label), and one
# institution-period is quarantined rather than resolved

**Status:** Accepted
**Date:** 2026-08-05
**Phase:** 2 (source profiling)
**Supersedes:** ADR-0001's ordering clause (`order by data_point_label_as_filed`)

---

## Context

ADR-0001 established `variant_seq` as `row_number() over (partition by
institution_id, return_code, reporting_period_end, line_item_code order by
data_point_label_as_filed) - 1`, on the assumption that the label always
differs between concurrent variants.

Drafting `seed_data_point_variants.csv` falsified that assumption. Of the 270
distinct `(return_code, line_item_code, reporting_period_end)` groups
carrying more than one variant:

- **162 groups have byte-identical label text** on both variants. `order by
  label` cannot break these ties by content, so it silently falls back to
  physical row order in the source file — an ordering ADR-0001 did not
  intend to rely on and did not claim was stable.

A full per-column diff of those 162 groups, and a check of which
institutions are involved in *any* duplicate group at all (not just the
identical-label ones), found the population splits cleanly in two:

| Population | Groups | Institutions involved | Disambiguating column |
|---|---|---|---|
| OSFI aggregate republication | 220 | Exclusively `Id 1000000` / `1000001` / `1000002` (Total All Banks / Total Domestic / Total Foreign Subsidiaries) | `Return Title` differs for 112 of these; the other 108 already have differing labels |
| Wholesale duplicate filing | 50 | Exclusively `Id 28017`, exclusively `2010 Q4-2010`, in P3 (41 codes) and E3 (9 codes) | **None.** Every column matches except the amount. |

**No real financial institution other than `Id 28017` is affected anywhere
in the dataset**, and `Id 28017` is affected at exactly one period. This
reframes the problem: it is not a general property of dual-basis filings, it
is (a) OSFI's own aggregate series being recomputed and republished under
revised return definitions over time, plus (b) one isolated institution's
Q4-2010 filing appearing twice in the static export.

### Proof that row order is not usable for `Id 28017`

`Id 28017`'s Q4-2010 E3 filing has every one of its 9 line items duplicated,
with no third, single-valued line item anywhere in that institution-period
to test against. But two of the duplicated codes are themselves parent/child
of each other, which lets the pairing be checked internally without an
external anchor:

```
3125 "...individual allowance"           rows: (row 118078, 46.0), (row 118079, 64.0)
3127 "...individual allowance"           rows: (row 118080, 101.0), (row 118081, 28.0)
3131 "total, individual allowance"       rows: (row 118082, 147.0), (row 118083, 92.0)

  same-physical-position pairing:
    row-position 0: 46 + 101 = 147  == 3131 position 0 (147)   MATCH
    row-position 1: 64 + 28  = 92   == 3131 position 1 (92)    MATCH

3133 "...recorded investment"            rows: (row 118084, 46.0),   (row 118085, 64.0)
3135 "...recorded investment"            rows: (row 118086, 746.0),  (row 118087, 1163.0)
3139 "total, recorded investment"        rows: (row 118088, 810.0),  (row 118089, 1209.0)

  same-physical-position pairing:
    row-position 0: 46 + 746   = 792   != 3139 position 0 (810)   FAILS
    row-position 1: 64 + 1163  = 1227  != 3139 position 1 (1209)  FAILS

  crossed-position pairing:
    3133 pos 0 (46) + 3135 pos 1 (1163) = 1209 == 3139 position 1 (1209)  MATCH
    3133 pos 1 (64) + 3135 pos 0 (746)  = 810  == 3139 position 0 (810)   MATCH
```

`3125`/`3127`/`3131` require **same-position** pairing to satisfy the
subtotal identity. `3133`/`3135`/`3139` require **crossed-position**
pairing to satisfy the identical kind of identity, in the same
institution-period, in the same file pull. There is no single row-order
rule that is correct for both. Row order does not track a consistent
"vintage" across codes here — it is not merely a risk of instability across
future republications, it is already incoherent within this one export.
This is not a case that curation, however careful, can resolve: the data
itself does not contain the information needed to pair the two vintages
correctly per code.

---

## Decision

### 1. Reorder `variant_seq` on `(return_title, label_as_filed)`, not label alone

```sql
variant_seq = row_number() over (
    partition by institution_id, return_code, reporting_period_end, line_item_code
    order by return_title, data_point_label_as_filed
) - 1
```

This resolves all 112 previously-tied aggregate groups where only
`Return Title` differed. Combined with the 108 groups that already had
differing labels, this disambiguates all **220 aggregate groups** by
content. It changes nothing for `Id 28017`'s 50 groups, where neither column
differs — those remain genuinely tied, which is expected and desired: a
content-based tiebreak should not invent a distinction that isn't there.

### 2. Quarantine `Id 28017` / 2010-12-31 instead of resolving it algorithmically

`seeds/seed_quarantine.csv` records two rows — one for P3, one for E3 — at
the institution-period level, not per line item. Any row in `stg_osfi__filings`
matching a quarantine entry is excluded from marts and flagged, not
silently included with an arbitrary variant pairing. This is intentionally
coarser than the variant machinery: the crossed-pairing proof means there is
no per-code fix available, only a per-institution-period one.

### 3. `seed_data_point_variants.csv` becomes an override table, not an exhaustive one

Default (no seed row): `is_primary_basis` is derived as the variant whose
`(return_title, label_as_filed)` matches the **most recently observed**
`(return_title, label_as_filed)` for that `(return_code, line_item_code)`
across the full history of the file — i.e., whichever wording OSFI was
using most recently for that code is treated as current. This requires no
manual curation for the well-behaved majority of the 220 aggregate groups.

The seed now holds only the cases where that automatic rule is not trusted:
the 24 label-ambiguous groups (where the label signals neither IAS 39 nor
IFRS 9 wording clearly) and any group where the derived answer looks wrong
on inspection. See the Phase-2 report for the full 220-row derived table and
the exception list.

### 4. Centralize `variant_seq` computation

`extract/keys.py` exposes a single `compute_variant_seq`. Both
`extract/generate_schema.py` and `extract/schema_assert.py` import it — no
copy-pasted logic. This also fixes the gap flagged during Phase 2:
`schema_assert.py`'s own natural-key uniqueness check previously assumed
every key column was a literal raw column, which broke as soon as
`variant_seq` (a derived column) entered the key.

### 5. `Return Title` becomes a consumed, contract-critical column

It is now load-bearing for key uniqueness across all three returns, not
merely informational. `schema.yml` is regenerated accordingly.

---

## Consequences

**Positive**

- The 220 aggregate groups get a fully automatic, self-maintaining
  `is_primary_basis` rule that does not require re-curation every time OSFI
  revises a return definition — the "most recent wording wins" rule
  adapts on its own.
- The one case that cannot be resolved is not silently mispaired; it is
  named, quarantined, and documented with the proof of why.
- `seed_data_point_variants.csv` stays small (exceptions only), which is
  what makes it maintainable long-term.

**Negative**

- `Id 28017`'s Q4-2010 P3 and E3 data is unavailable in the marts until
  someone with access to OSFI's original filings can determine the correct
  values by hand. This is a real, disclosed data gap, not a workaround.
- The "most recently observed" derivation rule assumes OSFI's most recent
  wording for a code is always the intended current basis. This is a
  reasonable default but is exactly the kind of assumption the 24
  label-ambiguous exceptions exist to catch.

**Rejected alternatives**

- *Curate `Id 28017`'s 50 rows manually, same as the aggregate groups* —
  rejected. The crossed-pairing proof shows the data does not contain the
  information needed to do this correctly; manual curation would be
  guessing dressed up as a decision.
- *Add `Return Title` to the base natural key instead of `variant_seq`* —
  rejected. It does not help `Id 28017` at all (identical `Return Title` on
  both rows), and would still need `variant_seq` for that population, so it
  does not remove complexity, only relocates it.
- *Keep ordering on label alone and accept the tie-break risk* — rejected.
  Falsified directly by the crossed-pairing evidence.

---

## Related profiling findings

- Full column diff on the 162 identical-label groups: `Industry Group` /
  `Groupe Sectoriel` never differs (0/162) — the hypothesis that aggregates
  are published under multiple industry groupings does not hold. `Return
  Title` differs in exactly the 112 groups belonging to `Id 1000000`; the
  remaining 50 (`Id 28017`) have no differing column at all besides the
  amount.
- See `docs/known_data_issues.md` for the quarantine entry and the
  crossed-pairing proof preserved verbatim.
