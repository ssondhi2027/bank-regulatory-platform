"""
Assert a downloaded OSFI file matches the pinned schema.

Called by extract/osfi_extract.py immediately after download, BEFORE the file
is landed. A silent upstream schema change becomes a loud failure here rather
than a wrong number in a mart three phases later.

Severity policy:
  ERROR (raises)  - a consumed column disappeared or was renamed
                  - the natural key is no longer unique
                  - a new non-numeric token appeared in the amount column
                  - row count fell below the floor (truncated download)
  WARN  (logs)    - a new column appeared
                  - a non-consumed column disappeared
                  - column order changed
                  - row count grew unusually fast
                  - a low-cardinality column gained a new value

Additive upstream change should not break the pipeline. Removal, rename, and
key-integrity failures must.
"""

from __future__ import annotations

import logging
from pathlib import Path

import pandas as pd
import yaml

from keys import compute_variant_seq

log = logging.getLogger(__name__)

SCHEMA_PATH = Path("extract/schema.yml")
ROW_GROWTH_WARN_RATIO = 1.25


class SchemaDriftError(Exception):
    """Raised when a change requires human review before ingestion proceeds."""


def load_schema(path: Path = SCHEMA_PATH) -> dict:
    if not path.exists():
        raise SchemaDriftError(
            f"{path} not found. Run extract/generate_schema.py first."
        )
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def assert_matches(df: pd.DataFrame, return_code: str,
                   schema: dict | None = None) -> list[str]:
    """Validate df against the pinned schema. Returns the warning list;
    raises SchemaDriftError on any error-severity finding."""
    schema = schema or load_schema()
    spec = schema["returns"].get(return_code)
    if spec is None:
        raise SchemaDriftError(f"No pinned schema for return {return_code}")

    errors: list[str] = []
    warnings: list[str] = []

    expected = {c["name"]: c for c in spec["columns"]}
    actual = list(df.columns)
    actual_set = set(actual)

    # --- columns -----------------------------------------------------------
    for name, col in expected.items():
        if col.get("derived"):
            continue  # e.g. variant_seq: never a literal header, checked separately below
        if name in actual_set:
            continue
        # A rename may just be an encoding wobble; match on the ASCII slug
        # before declaring the column gone.
        from generate_schema import normalize  # same normalization both sides
        slug_match = [a for a in actual if normalize(a) == col["normalized"]]
        if slug_match:
            warnings.append(
                f"column header changed: {name!r} -> {slug_match[0]!r} "
                f"(same normalized name, treating as match)"
            )
            continue
        msg = f"expected column missing: {name!r}"
        (errors if col["consumed"] else warnings).append(
            msg + ("  [CONSUMED]" if col["consumed"] else "  [informational]")
        )

    for name in actual_set - set(expected):
        warnings.append(f"new column appeared: {name!r} — review before consuming")

    if [c for c in actual if c in expected] != [
        c["name"] for c in spec["columns"] if c["name"] in actual_set
    ]:
        warnings.append("column order changed")

    # --- row count ---------------------------------------------------------
    n = len(df)
    if n < spec["row_count_floor"]:
        errors.append(
            f"row count {n:,} is below floor {spec['row_count_floor']:,} "
            f"(baseline {spec['row_count_baseline']:,}) — likely truncated download"
        )
    elif n > spec["row_count_baseline"] * ROW_GROWTH_WARN_RATIO:
        warnings.append(
            f"row count {n:,} is well above baseline "
            f"{spec['row_count_baseline']:,} — verify this is real growth"
        )

    # --- natural key -------------------------------------------------------
    # variant_seq (if present in the key) is derived, never a literal raw
    # column -- see extract/keys.py and docs/decisions/ADR-0001/0002. It
    # must be computed here the same way generate_schema.py computed it, or
    # the two would silently drift apart and this check would be checking
    # something other than what the snapshot actually keys on.
    key = spec["natural_key"]["columns"]
    has_variant_seq = "variant_seq" in key
    raw_key = [k for k in key if k != "variant_seq"]

    if all(k in actual_set for k in raw_key):
        if has_variant_seq:
            ordering = spec.get("variant_ordering")
            if not ordering:
                errors.append(
                    "natural key includes variant_seq but schema.yml has no "
                    "'variant_ordering' block to recompute it from -- re-run "
                    "generate_schema.py --update"
                )
                key_df = None
            else:
                key_df = df.assign(variant_seq=compute_variant_seq(
                    df, ordering["base_key"],
                    return_title_col=ordering["return_title_column"],
                    label_col=ordering["label_column"],
                ))
        else:
            key_df = df

        if key_df is not None:
            null_rows = int(key_df[raw_key].isna().any(axis=1).sum())
            if null_rows:
                errors.append(f"{null_rows:,} rows have a null natural-key component")
            dupes = key_df.groupby(key, dropna=False).size()
            n_dupes = int((dupes > 1).sum())
            if n_dupes:
                errors.append(
                    f"natural key no longer unique: {n_dupes:,} duplicate combinations. "
                    f"The dbt snapshot unique_key depends on this."
                )
    else:
        errors.append(f"natural key columns missing from file: {raw_key}")

    # --- amount column -----------------------------------------------------
    amt = spec.get("amount") or {}
    amt_col = amt.get("column")
    if amt_col and amt_col in actual_set:
        values = df[amt_col].dropna().astype(str).str.strip()
        bad = values[pd.to_numeric(values, errors="coerce").isna()]
        known = set(amt.get("known_non_numeric_tokens") or [])
        new_tokens = sorted(set(bad.unique()) - known)
        if new_tokens:
            errors.append(
                f"new non-numeric token(s) in {amt_col!r}: {new_tokens[:10]} — "
                f"these would silently become NULL. Classify them "
                f"(suppression? footnote?) and re-pin the schema."
            )

    # --- low-cardinality drift --------------------------------------------
    for name, col in expected.items():
        allowed = col.get("allowed_values")
        if not allowed or name not in actual_set:
            continue
        new_vals = sorted(set(df[name].dropna().astype(str)) - set(allowed))
        if new_vals:
            warnings.append(
                f"{name!r} gained value(s): {new_vals[:10]}"
            )

    for w in warnings:
        log.warning("[%s] %s", return_code, w)

    if errors:
        detail = "\n  - ".join(errors)
        raise SchemaDriftError(
            f"[{return_code}] schema assertion failed:\n  - {detail}\n\n"
            f"If this change is legitimate, re-run "
            f"`python extract/generate_schema.py --update` and review the diff."
        )

    log.info("[%s] schema OK (%d warnings)", return_code, len(warnings))
    return warnings
