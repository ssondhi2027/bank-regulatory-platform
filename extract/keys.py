"""
Single source of truth for the OSFI filing natural key logic. Imported by
both generate_schema.py (pins the schema) and schema_assert.py (asserts a
freshly downloaded file still matches it) so the two can never drift apart.

See docs/decisions/ADR-0001-natural-key.md and
docs/decisions/ADR-0002-variant-ordering-and-quarantine.md.
"""

from __future__ import annotations

import pandas as pd

RETURN_TITLE_COL = "Return Title"
LABEL_COL = "Data Point Address Label"


def compute_variant_seq(df: pd.DataFrame, base_key: list[str],
                         return_title_col: str = RETURN_TITLE_COL,
                         label_col: str = LABEL_COL) -> pd.Series:
    """Deterministic ordinal within the base four-column group.

    Ordered by (return_title, label_as_filed) per ADR-0002 -- NOT by label
    alone (ADR-0001's original clause). Label alone ties whenever two
    concurrent variants share identical label text, which is the common
    case (162 of 270 duplicate groups profiled), and falls back silently to
    physical row order, which was proven internally inconsistent across
    line items for at least one institution-period (see
    docs/known_data_issues.md). Ordering on the pair resolves every
    duplicate group caused by OSFI's own aggregate-row republication (220
    of 270); the remainder (50, all Id 28017 at 2010-12-31) is quarantined
    in seeds/seed_quarantine.csv rather than resolved here, because no
    column in the source distinguishes them at all.

    0 for the overwhelming majority of rows; only genuinely concurrent
    variants ever reach 1.
    """
    sort_cols = base_key + [return_title_col, label_col]
    sorted_index = df.sort_values(sort_cols, kind="stable").index
    seq = pd.Series(index=df.index, dtype="int64")
    seq.loc[sorted_index] = df.loc[sorted_index].groupby(base_key, dropna=False).cumcount().values
    return seq.astype(str)
