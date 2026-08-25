{#
    Convert an OSFI fiscal year + fiscal quarter number into the actual
    calendar-quarter-end date, given an institution's fiscal-year-end month.

    Model: fiscal year Y ends at month `fye_month` of calendar year Y (e.g.
    October-FYE fiscal year 2026 = November 2025 - October 2026). Quarter n
    (1-4) is the n-th 3-month block of that fiscal year.

    Verified empirically for fye_month = 10 (the only case in scope --
    seed_institution_master only has fiscal_year_end_month populated for
    the Big Six, all October FYE): confirmed the "fiscal_year label = the
    calendar year the fiscal year ENDS in" convention by checking RBC's
    most recent P3 data (Fiscal Year 2026, Q2) -- under the alternative
    "starting year" convention that quarter would not have occurred yet,
    which is impossible. Cross-checked against M4's real calendar dates
    (M4 for the same institution extends one month past P3's latest
    quarter-end, consistent with M4 being monthly and P3 quarterly).

    The month/year arithmetic below is the same logical model applied to
    any fye_month, but only fye_month = 10 has been checked against real
    data -- treat other values as unverified until an institution with a
    different fiscal year end is added to seed_institution_master and
    checked the same way. See docs/known_data_issues.md.
#}
{% macro fiscal_quarter_end_date(fiscal_year_col, quarter_num_expr, fye_month_col) %}
    last_day(date(
        {{ fiscal_year_col }} + div({{ fye_month_col }} + 3 * {{ quarter_num_expr }} - 1, 12) - 1,
        mod({{ fye_month_col }} + 3 * {{ quarter_num_expr }} - 1, 12) + 1,
        1
    ))
{% endmacro %}
