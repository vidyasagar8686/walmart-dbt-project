{% macro newest_file_first(file_col='file_name') -%}
    {#- Deterministic "newest file first" ordering.
        <feed>_<YYYYMMDD>_<n>.csv -> extract date, then sequence as a NUMBER
        (so _10 sorts after _9). Original full extracts (no date) sort oldest. -#}
    COALESCE(TRY_TO_DATE(REGEXP_SUBSTR({{ file_col }}, '_([0-9]{8})_[0-9]+[.]csv$', 1, 1, 'e', 1), 'YYYYMMDD'),
             '1900-01-01'::DATE) DESC,
    COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR({{ file_col }}, '_[0-9]{8}_([0-9]+)[.]csv$', 1, 1, 'e', 1)), 0) DESC
{%- endmacro %}