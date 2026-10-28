{{ config(
    materialized = 'incremental',
    schema       = 'CONTROL',
    unique_key   = ['file_name', 'file_last_modified'],
    transient    = false
) }}

-- depends_on: {{ ref('file_header_contract') }}

{#- Control table of checked files: one row per file version.
    Each run opens ONLY files that are new or changed since they were checked.
    The file list comes from the stage's directory table, which opens no files. -#}

{%- set new_files_sql -%}
    SELECT d.relative_path
    FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE) d
    WHERE d.relative_path ILIKE '%.csv'
    {%- if is_incremental() %}
      AND NOT EXISTS (
          SELECT 1 FROM {{ this }} l
          WHERE l.file_name          = 'raw/' || d.relative_path
            AND l.file_last_modified = d.last_modified
      )
    {%- endif %}
{%- endset -%}

{%- set new_files = [] -%}
{%- if execute -%}
    {%- set new_files = run_query(new_files_sql).columns[0].values() -%}
{%- endif -%}

{%- if new_files | length == 0 %}

-- Nothing new to check: return no rows
SELECT
    CAST(NULL AS VARCHAR)       AS file_name,
    CAST(NULL AS TIMESTAMP_LTZ) AS file_last_modified,
    CAST(NULL AS VARCHAR)       AS file_type,
    CAST(NULL AS VARCHAR)       AS actual_header,
    CAST(NULL AS NUMBER)        AS contract_version,
    CAST(NULL AS VARCHAR)       AS expected_header,
    CAST(NULL AS BOOLEAN)       AS header_ok,
    CAST(NULL AS TIMESTAMP_LTZ) AS checked_at
WHERE FALSE

{%- else %}

{%- set escaped = [] -%}
{%- for f in new_files -%}
    {%- do escaped.append(f | replace('.', '[.]')) -%}
{%- endfor %}

WITH files AS (
    -- the new or changed files, with their S3 time (from the directory table)
    SELECT 'raw/' || relative_path AS file_name,
           last_modified           AS file_last_modified
    FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE)
    WHERE relative_path IN ({% for f in new_files %}'{{ f }}'{% if not loop.last %}, {% endif %}{% endfor %})
),

actual AS (
    -- open ONLY those files and read their first line
    SELECT metadata$filename AS file_name,
           TRIM($1)          AS actual_header
    FROM @WALMART.RAW.WALMART_S3_STAGE
        (file_format => 'WALMART.RAW.LINE_FORMAT',
         pattern     => '(.*/)?({{ escaped | join("|") }})')
    WHERE metadata$file_row_number = 1
),

checked AS (
    SELECT
        f.file_name,
        f.file_last_modified,
        REGEXP_SUBSTR(SPLIT_PART(f.file_name, '/', -1), '^[a-z]+') AS file_type,
        a.actual_header,
        c.contract_version,
        c.expected_header
    FROM files f
    LEFT JOIN actual a
           ON a.file_name = f.file_name
    LEFT JOIN {{ ref('file_header_contract') }} c
           ON c.file_type = REGEXP_SUBSTR(SPLIT_PART(f.file_name, '/', -1), '^[a-z]+')
          AND f.file_last_modified::DATE >= TRY_TO_DATE(TO_VARCHAR(c.valid_from))
          AND (c.valid_to IS NULL
               OR f.file_last_modified::DATE < TRY_TO_DATE(TO_VARCHAR(c.valid_to)))
)

SELECT
    file_name,
    file_last_modified,
    file_type,
    actual_header,
    contract_version,
    expected_header,
    COALESCE(UPPER(REPLACE(actual_header, ' ', ''))
           = UPPER(REPLACE(expected_header, ' ', '')), FALSE) AS header_ok,
    CURRENT_TIMESTAMP() AS checked_at
FROM checked

{%- endif %}