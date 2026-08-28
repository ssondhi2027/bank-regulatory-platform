"""
Generate extract/schema.yml from the landed OSFI CSVs.

Run this once to pin the schema, review the output, commit it. Re-run with
--update only when you have deliberately accepted an upstream change; the
git diff on schema.yml is then your change log.

Refuses to emit if the declared natural key is not unique — a non-unique key
would silently break the dbt snapshot's version tracking.

Usage:
    python extract/generate_schema.py
    python extract/generate_schema.py --update
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
import unicodedata
from pathlib import Path

import pandas as pd
import yaml

from keys import compute_variant_seq

RAW = Path("data/raw")
SCHEMA_PATH = Path("extract/schema.yml")

# ---------------------------------------------------------------------------
# FILL THIS IN from your Phase 2 profiler output, using the EXACT raw header
# strings as they appear in the file. This is the only hand-maintained part.
#
# natural_key  -> columns that together identify one row. This is the key the
#                 dbt snapshot will hash. It MUST be unique.
# amount       -> the numeric measure column.
# label        -> the line-item description (for drift detection only; never a
#                 join key, since labels get revised).
# ---------------------------------------------------------------------------
#
# natural_key ends in "variant_seq" for all three returns per
# docs/decisions/ADR-0001-natural-key.md: profiling found the base four
# columns are NOT unique (230/123/58 duplicate combinations in M4/P3/E3),
# always a line item reported under two return definitions/accounting bases
# during a standards or return-title revision (e.g. IAS 39 "impairment" vs
# IFRS 9 "expected credit losses" wording in 2017). variant_seq is not a raw
# column -- it is computed by extract/keys.py::compute_variant_seq, ordered
# by (return_title, label) per ADR-0002 (not label alone -- ADR-0001's
# original clause ties whenever two variants share identical label text,
# which is the common case), and must be computed identically downstream in
# stg_osfi__filings via the same shared function.
#
# return_title is now itself a consumed, contract-critical column per
# ADR-0002: it is load-bearing for variant_seq's ordering, not merely
# informational.
COLUMN_ROLES: dict[str, dict] = {
    "M4": {
        "natural_key": ["Id", "Calendar Year/Année civile", "Calendar Month/Mois civil",
                        "Data Point Address/Adresse de point de donnée", "variant_seq"],
        "amount": "Measure Value/Valeur de mesure",
        "label": "Data Point Address Label",
        "return_title": "Return Title",
    },
    "P3": {
        "natural_key": ["Id", "Fiscal Year/Année fiscale", "Fiscal Quarter",
                        "Data Point Address/Adresse de point de donnée", "variant_seq"],
        "amount": "Measure Value/Valeur de mesure",
        "label": "Data Point Address Label",
        "return_title": "Return Title",
    },
    "E3": {
        "natural_key": ["Id", "Fiscal Year/Année fiscale", "Fiscal Quarter",
                        "Data Point Address/Adresse de point de donnée", "variant_seq"],
        "amount": "Measure Value/Valeur de mesure",
        "label": "Data Point Address Label",
        "return_title": "Return Title",
    },
    # Foreign bank branches -- a separate OSFI-published population (REC-007
    # only; see docs/known_data_issues.md). Same load-bearing column names
    # as M4 (Id, dates, Data Point Address, Measure Value all match
    # byte-for-byte); only the "Total All Banks..." label column's wording
    # differs, and that column is non-consumed. A distinct return_code
    # because it is a different filer population with its own row-count
    # baseline, not a duplicate of domestic M4.
    "M4_FBB": {
        "natural_key": ["Id", "Calendar Year/Année civile", "Calendar Month/Mois civil",
                        "Data Point Address/Adresse de point de donnée", "variant_seq"],
        "amount": "Measure Value/Valeur de mesure",
        "label": "Data Point Address Label",
        "return_title": "Return Title",
    },
}

# Row-count floor tolerance: fail if a future file has fewer rows than
# (baseline * this). Guards against a truncated or partial download.
ROW_FLOOR_RATIO = 0.95

MAX_SAMPLE_VALUES = 25
LOW_CARDINALITY = 25


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalize(name: str) -> str:
    """ASCII snake_case slug. Accented French headers are fragile to match on
    directly, so every column carries a stable normalized alias."""
    decomposed = unicodedata.normalize("NFKD", name)
    ascii_only = decomposed.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^0-9a-zA-Z]+", "_", ascii_only).strip("_").lower()
    return re.sub(r"_+", "_", slug)


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
INT_RE = re.compile(r"^-?\d+$")


def infer_dtype(series: pd.Series) -> str:
    """Everything lands as string; this records what it SHOULD cast to, so a
    future file that stops casting cleanly fails loudly."""
    values = series.dropna().astype(str).str.strip()
    values = values[values != ""]
    if values.empty:
        return "string"
    if values.str.match(INT_RE).all():
        return "integer"
    if values.str.match(DATE_RE).all():
        return "date"
    try:
        pd.to_numeric(values)
        return "numeric"
    except (ValueError, TypeError):
        return "string"


def non_numeric_tokens(series: pd.Series) -> list[str]:
    """Suppression markers, footnote flags, blanks — anything in the amount
    column that will not cast. Pinning the known set means a NEW marker
    appearing is caught instead of silently becoming NULL."""
    values = series.dropna().astype(str).str.strip()
    bad = values[pd.to_numeric(values, errors="coerce").isna()]
    return sorted(bad.unique().tolist())[:MAX_SAMPLE_VALUES]


def latest_file(return_code: str) -> Path:
    candidates = sorted(
        (RAW / return_code).rglob("*.csv"), key=lambda p: p.stat().st_mtime
    )
    if not candidates:
        raise FileNotFoundError(f"No landed CSV found for {return_code} under {RAW}")
    return candidates[-1]


# ---------------------------------------------------------------------------
# Profiling
# ---------------------------------------------------------------------------

def check_natural_key(df: pd.DataFrame, key: list[str], return_code: str) -> dict:
    missing = [c for c in key if c not in df.columns]
    if missing:
        raise SystemExit(
            f"\n[{return_code}] natural_key references columns not in the file: "
            f"{missing}\nAvailable columns:\n  " + "\n  ".join(df.columns)
        )

    null_rows = int(df[key].isna().any(axis=1).sum())
    dupes = df.groupby(key, dropna=False).size()
    dupes = dupes[dupes > 1]

    if len(dupes) or null_rows:
        print(f"\n{'!' * 70}")
        print(f"[{return_code}] NATURAL KEY IS NOT VALID")
        print(f"  duplicate key combinations : {len(dupes):,}")
        print(f"  rows with a null key part  : {null_rows:,}")
        if len(dupes):
            print("\n  Worst offenders:")
            print(dupes.sort_values(ascending=False).head(10).to_string())
            sample = dupes.sort_values(ascending=False).index[0]
            mask = pd.Series(True, index=df.index)
            for col, val in zip(key, sample if isinstance(sample, tuple) else (sample,)):
                mask &= df[col].eq(val)
            print("\n  Full rows for the worst offender — look for the column")
            print("  that actually distinguishes them, and add it to the key:")
            print(df[mask].to_string())
        print(f"{'!' * 70}\n")
        raise SystemExit(
            f"Refusing to write schema.yml. The dbt snapshot unique_key depends "
            f"on this being unique; fix COLUMN_ROLES['{return_code}']['natural_key'] "
            f"first."
        )

    return {"columns": key, "verified_unique": True, "null_key_rows": 0}


def profile_return(return_code: str, roles: dict) -> dict:
    path = latest_file(return_code)
    df = pd.read_csv(path, dtype=str, encoding="utf-8", low_memory=False)
    raw_columns = list(df.columns)  # the file's actual columns, for drift detection below

    print(f"\n[{return_code}] {path.name}  rows={len(df):,}  cols={len(df.columns)}")

    key = roles["natural_key"]
    has_variant_seq = "variant_seq" in key
    if has_variant_seq:
        base_key = [c for c in key if c != "variant_seq"]
        # Computed on a copy: variant_seq must NOT appear in the raw-column
        # drift list below, since a freshly downloaded file will never
        # literally contain it -- schema_assert.py would then flag every
        # future run as missing a "consumed" column that was never real.
        key_df = df.assign(variant_seq=compute_variant_seq(
            df, base_key, return_title_col=roles["return_title"], label_col=roles["label"]))
    else:
        key_df = df

    key_info = check_natural_key(key_df, key, return_code)

    consumed = (set(c for c in key if c != "variant_seq")
                | {roles["amount"], roles.get("label"), roles.get("return_title")})
    consumed.discard(None)

    columns = []
    for pos, col in enumerate(raw_columns):
        series = df[col]
        distinct = int(series.nunique(dropna=True))
        entry = {
            "name": col,
            "normalized": normalize(col),
            "position": pos,
            "dtype": infer_dtype(series),
            "nullable": bool(series.isna().any()),
            "distinct_count": distinct,
            # Consumed columns are contract-critical: their disappearance or
            # rename must fail the pipeline. The rest are informational.
            "consumed": col in consumed,
        }
        if distinct <= LOW_CARDINALITY:
            entry["allowed_values"] = sorted(
                series.dropna().astype(str).unique().tolist()
            )[:MAX_SAMPLE_VALUES]
        columns.append(entry)

    if has_variant_seq:
        # Documented for humans reading schema.yml, but deliberately marked
        # consumed=False and derived=True: it is never a literal header in a
        # downloaded file, so schema_assert.py's raw-column drift check must
        # not expect to find it there. Its uniqueness is still enforced --
        # see natural_key below -- computed identically here and in
        # stg_osfi__filings via extract/keys.py::compute_variant_seq
        # (ADR-0001, ordering revised by ADR-0002).
        columns.append({
            "name": "variant_seq",
            "normalized": "variant_seq",
            "position": None,
            "dtype": "integer",
            "nullable": False,
            "distinct_count": None,
            "consumed": False,
            "derived": True,
            "derivation": (
                "row_number() over (partition by institution_id, return_code, "
                "reporting_period_end, line_item_code order by "
                "return_title, data_point_label_as_filed) - 1"
            ),
        })

    amount_col = roles["amount"]
    amount_info = {}
    if amount_col in df.columns:
        tokens = non_numeric_tokens(df[amount_col])
        numeric = pd.to_numeric(df[amount_col], errors="coerce")
        amount_info = {
            "column": amount_col,
            "units": "thousands_cad",
            "implicit_units": True,  # no units column exists in the source
            "known_non_numeric_tokens": tokens,
            "null_rate": round(float(numeric.isna().mean()), 6),
            "min": None if numeric.dropna().empty else float(numeric.min()),
            "max": None if numeric.dropna().empty else float(numeric.max()),
            "has_negatives": bool((numeric < 0).any()),
        }
        if tokens:
            print(f"  non-numeric tokens in {amount_col}: {tokens}")

    result = {
        "source_file": path.name,
        "encoding": "utf-8",
        "row_count_baseline": len(df),
        "row_count_floor": int(len(df) * ROW_FLOOR_RATIO),
        "column_count": len(df.columns),
        "natural_key": key_info,
        "amount": amount_info,
        "columns": columns,
    }
    if has_variant_seq:
        # Explicit, not reverse-engineered from natural_key column order or
        # the derivation string: schema_assert.py needs these two exact
        # column names to recompute variant_seq via the same shared
        # extract/keys.py::compute_variant_seq before it can check
        # uniqueness on a freshly downloaded file.
        result["variant_ordering"] = {
            "base_key": base_key,
            "return_title_column": roles["return_title"],
            "label_column": roles["label"],
        }
    return result


# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true",
                        help="Overwrite an existing schema.yml (review the git diff).")
    args = parser.parse_args()

    unfilled = [
        rc for rc, r in COLUMN_ROLES.items()
        if str(r.get("amount", "")).startswith("<")
    ]
    if unfilled:
        raise SystemExit(
            f"Fill in the amount column header for: {unfilled}\n"
            f"Use the exact raw header string from your profiler output."
        )

    if SCHEMA_PATH.exists() and not args.update:
        raise SystemExit(
            f"{SCHEMA_PATH} already exists. Re-run with --update if you have "
            f"deliberately accepted an upstream change, then review the git diff."
        )

    schema = {
        "version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "notes": [
            "Consumed columns are contract-critical: a rename or removal is a "
            "hard failure. Non-consumed columns (including French-language "
            "duplicates) drift with a warning only.",
            "Amount units are thousands of CAD and are IMPLICIT — the source "
            "carries no units column. Do not remove this note.",
            "Subtotal identification is NOT derivable from this file. It comes "
            "from the OSFI Data Dictionary hierarchy seed, keyed on the "
            "line-item code. See docs/known_data_issues.md.",
            "The natural key includes a derived variant_seq column (not a raw "
            "source column -- see the 'derived' entry under each return's "
            "columns list), computed by extract/keys.py::compute_variant_seq "
            "and ordered by (return_title, label_as_filed) per ADR-0002 -- "
            "NOT by label alone (ADR-0001's original clause). It "
            "disambiguates the same line item reported under two return "
            "definitions/accounting bases (e.g. IAS 39 vs IFRS 9 wording). "
            "Must be computed identically in stg_osfi__filings via the same "
            "shared function. See docs/decisions/ADR-0001-natural-key.md, "
            "docs/decisions/ADR-0002-variant-ordering-and-quarantine.md, and "
            "seeds/seed_data_point_variants.csv.",
            "seeds/seed_quarantine.csv excludes Id 28017 at 2010-12-31 (P3 "
            "and E3) entirely -- every line item in that institution-period "
            "is duplicated with no distinguishing column, and row order was "
            "proven internally inconsistent across codes. No variant_seq "
            "pairing is trustworthy there. See "
            "docs/decisions/ADR-0002-variant-ordering-and-quarantine.md.",
        ],
        "returns": {
            rc: profile_return(rc, roles) for rc, roles in COLUMN_ROLES.items()
        },
    }

    SCHEMA_PATH.parent.mkdir(parents=True, exist_ok=True)
    with SCHEMA_PATH.open("w", encoding="utf-8") as fh:
        yaml.safe_dump(schema, fh, sort_keys=False, allow_unicode=True, width=100)

    print(f"\nWrote {SCHEMA_PATH}")
    print("Review it, then commit. The git diff on this file is your change log.")


if __name__ == "__main__":
    sys.exit(main())
