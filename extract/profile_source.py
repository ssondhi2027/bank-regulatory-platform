"""
Profiling script — not the production extractor. Run manually to inspect
raw OSFI CSV structure and validate assumptions before writing any parsing,
staging, or schema-pinning code. See docs/build_guide.md Phase 2.

Caches the downloaded CSVs under data/raw/<CODE>/<CODE>.csv (gitignored) so
repeated runs don't re-fetch ~1M+ rows over the network. Delete that folder
to force a fresh pull.
"""

from pathlib import Path

import pandas as pd
import requests

URLS = {
    "M4": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/d0f6040e-671c-4301-a235-e9e7ba164604/download/banks_monthly_m4.csv",
    "P3": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/027ee7f8-4b87-45cd-a10f-f95d3a5d4e09/download/banks_quarterly_p3.csv",
    "E3": "https://open.canada.ca/data/dataset/91ed76b4-a1a2-4f87-9c4c-59cd64f7a9de/resource/1f86e088-7d29-49c2-94de-ddbfe6559725/download/banks_quarterly_e3.csv",
}

RAW = Path("data/raw")
NATURAL_KEYS = {
    "M4": ["Id", "Calendar Year", "Calendar Month", "Data Point Address"],
    "P3": ["Id", "Fiscal Year", "Fiscal Quarter", "Data Point Address"],
    "E3": ["Id", "Fiscal Year", "Fiscal Quarter", "Data Point Address"],
}


def by_prefix(df: pd.DataFrame, english_prefix: str) -> str:
    """Resolve a bilingual 'English/Français' header by its English half, so
    this script never has to hardcode accented characters."""
    matches = [c for c in df.columns if c.split("/")[0].strip() == english_prefix]
    if not matches:
        raise KeyError(f"no column starting with {english_prefix!r} in {list(df.columns)}")
    return matches[0]


def load_cached(code: str) -> pd.DataFrame:
    dest = RAW / code / f"{code}.csv"
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        body = requests.get(URLS[code], timeout=600).content
        dest.write_bytes(body)
        print(f"[{code}] downloaded {len(body)/1e6:.1f} MB -> {dest}")
    else:
        print(f"[{code}] using cache at {dest}")
    return pd.read_csv(dest, dtype=str, low_memory=False, encoding="utf-8")


def resolve_key(df: pd.DataFrame, code: str) -> list[str]:
    prefixes = NATURAL_KEYS[code]
    return ["Id" if p == "Id" else by_prefix(df, p) for p in prefixes]


# ---------------------------------------------------------------------------
# Basic shape / dtype / cardinality profile (numeric columns kept as string
# here deliberately -- dtype inference happens in extract/generate_schema.py,
# this script is for human inspection only).
# ---------------------------------------------------------------------------

def basic_profile(code: str, df_typed: pd.DataFrame) -> None:
    print(f"\n{'='*70}\n{code}  shape={df_typed.shape}")
    print(df_typed.dtypes)
    print(df_typed.head(10).to_string())
    for col in df_typed.columns:
        n = df_typed[col].nunique(dropna=True)
        print(f"  {col:45s} distinct={n:>8,}  nulls={df_typed[col].isna().sum():>8,}")
        if n <= 25:
            print(f"      values: {sorted(df_typed[col].dropna().unique().tolist())[:25]}")


# ---------------------------------------------------------------------------
# Due-diligence checks required before pinning schema.yml
# ---------------------------------------------------------------------------

def check_natural_key(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: NATURAL KEY UNIQUENESS\n{'='*70}")
    for code, df in dfs.items():
        key = resolve_key(df, code)
        dupes = df.groupby(key, dropna=False).size()
        dupes = dupes[dupes > 1]
        print(f"\n[{code}] key={key}")
        print(f"  duplicate key combinations: {len(dupes):,} (of {len(df):,} rows)")
        if not len(dupes):
            continue
        label_col = "Data Point Address Label"
        impairment_vs_ecl = 0
        for k in dupes.index:
            vals = k if isinstance(k, tuple) else (k,)
            mask = pd.Series(True, index=df.index)
            for col, val in zip(key, vals):
                mask &= df[col].eq(val)
            labels = df.loc[mask, label_col].str.lower()
            if labels.str.contains("impairment").any() and labels.str.contains("expected credit losses").any():
                impairment_vs_ecl += 1
        print(f"  of these, {impairment_vs_ecl} are an 'impairment' (IAS 39) vs "
              f"'expected credit losses' (IFRS 9) label pair for the same code")
        period_col = key[1]
        periods = sorted({(k if isinstance(k, tuple) else (k,))[1] for k in dupes.index})
        print(f"  duplicate rows fall in these {period_col} values: {periods}")


def check_bilingual_row_duplication(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: BILINGUAL DUPLICATION IS COLUMN-LEVEL, NOT ROW-LEVEL\n{'='*70}")
    for code, df in dfs.items():
        key = resolve_key(df, code)
        distinct_combos = df[key].drop_duplicates().shape[0]
        print(f"[{code}] total rows: {len(df):,}   distinct key combos: {distinct_combos:,}   "
              f"gap: {len(df) - distinct_combos:,} (should equal the duplicate-key count above)")


def check_code_namespace(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: DATA POINT ADDRESS NAMESPACE OVERLAP ACROSS RETURNS\n{'='*70}")
    code_sets = {c: set(df[by_prefix(df, "Data Point Address")].dropna().unique()) for c, df in dfs.items()}
    codes = list(code_sets)
    for i, a in enumerate(codes):
        for b in codes[i + 1:]:
            overlap = code_sets[a] & code_sets[b]
            print(f"{a} & {b}: {len(overlap)} shared codes")


def check_aggregate_reconciliation(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: Id 1000000 (Total All Banks) vs 1000001 + 1000002\n{'='*70}")
    df = dfs["M4"]
    period_col = by_prefix(df, "Calendar Month")
    code_col = by_prefix(df, "Data Point Address")
    label_col = "Data Point Address Label"
    totals = df[df["Id"] == "1000000"]
    complete_period = totals.groupby(period_col).size().idxmax()
    total_assets_code = df.loc[
        (df["Id"] == "1000000") & (df[period_col] == complete_period)
        & (df[label_col] == "Consolidated monthly balance sheet: assets, total assets, total"),
        code_col,
    ].iloc[0]

    def val(inst_id: str) -> float:
        row = df[(df["Id"] == inst_id) & (df[period_col] == complete_period) & (df[code_col] == total_assets_code)]
        return float(row["Measure Value/Valeur de mesure"].iloc[0])

    v_all, v_dom, v_for = val("1000000"), val("1000001"), val("1000002")
    print(f"period used: {complete_period}")
    print(f"Total All Banks (1000000):              {v_all:>18,.0f}")
    print(f"Total Domestic Banks (1000001):          {v_dom:>18,.0f}")
    print(f"Total Foreign Bank Subsidiaries (1000002): {v_for:>16,.0f}")
    print(f"dom + for subsidiaries:                  {v_dom + v_for:>18,.0f}")
    print(f"residual (all - (dom+for)):              {v_all - (v_dom + v_for):>18,.0f}")
    print("Residual is consistent with foreign bank BRANCHES (a separate OSFI "
          "population from foreign bank subsidiaries) not being included in "
          "Id 1000001/1000002. Needed for REC-007 in Phase 8.")


def check_non_numeric_amounts(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: NON-NUMERIC / NULL VALUES IN THE AMOUNT COLUMN\n{'='*70}")
    for code, df in dfs.items():
        amt_col = by_prefix(df, "Measure Value")
        vals = df[amt_col].dropna().astype(str).str.strip()
        bad = vals[pd.to_numeric(vals, errors="coerce").isna()]
        null_count = df[amt_col].isna().sum()
        print(f"[{code}] non-numeric tokens: {sorted(bad.unique().tolist())[:30]}  "
              f"({len(bad):,} rows) | null rows: {null_count:,} ({null_count/len(df):.2%})")


def check_history_depth(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: HISTORY DEPTH\n{'='*70}")
    m4 = dfs["M4"]
    m4_period = by_prefix(m4, "Calendar Month")
    print(f"[M4] {m4[m4_period].min()} .. {m4[m4_period].max()}")
    for code in ["P3", "E3"]:
        df = dfs[code]
        fy = df[by_prefix(df, "Fiscal Year")].astype(int)
        print(f"[{code}] FY {fy.min()} .. FY {fy.max()}")


def check_partial_latest_period(dfs: dict[str, pd.DataFrame]) -> None:
    print(f"\n{'='*70}\nCHECK: IS THE LATEST PERIOD PARTIAL? (row count vs recent-period median)\n{'='*70}")
    for code in ["M4", "P3", "E3"]:
        df = dfs[code]
        if code == "M4":
            period_cols = [by_prefix(df, "Calendar Month")]
        else:
            period_cols = [by_prefix(df, "Fiscal Year"), "Fiscal Quarter"]
        counts = df.groupby(period_cols).size().sort_index()
        median = counts.median()
        latest_count = counts.iloc[-1]
        print(f"[{code}] latest period row count: {latest_count:,}  |  "
              f"all-time median: {median:,.0f}  |  "
              f"ratio: {latest_count/median:.1%}")


def main() -> None:
    dfs = {code: load_cached(code) for code in URLS}

    for code, df in dfs.items():
        basic_profile(code, df)

    check_natural_key(dfs)
    check_bilingual_row_duplication(dfs)
    check_code_namespace(dfs)
    check_aggregate_reconciliation(dfs)
    check_non_numeric_amounts(dfs)
    check_history_depth(dfs)
    check_partial_latest_period(dfs)


if __name__ == "__main__":
    main()
