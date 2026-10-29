-- Manifest gate (#5): the batch must be COMPLETE before anything is transformed.
-- The vendor uploads raw/manifest_<YYYYMMDD>_<n>.csv LAST, listing every data file
-- in the batch and its row count. Fails (0 rows = pass) when:
--   MISSING   : a listed file is not in RAW (late or lost file)
--   ROW COUNT : RAW has a different number of rows than the manifest (cut-off file)
--   UNLISTED  : a data file from the manifest era arrived without being listed
-- dbt reads the manifests first (small files) and passes them in as VALUES,
-- so the gate query itself never scans the S3 stage.

{%- set manifest_count_sql -%}
    SELECT COUNT(*) FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE)
    WHERE REGEXP_LIKE(relative_path, '(.*/)?manifest_[0-9]{8}_[0-9]+[.]csv')
{%- endset -%}

{%- set manifest_read_sql -%}
    SELECT metadata$filename, TRIM($1), TRY_TO_NUMBER($2)
    FROM @WALMART.RAW.WALMART_S3_STAGE
        (file_format => 'WALMART.RAW.CSV_FORMAT',
         pattern     => '.*manifest_[0-9]{8}_[0-9]+[.]csv')
{%- endset -%}

{%- set m_files = [] -%}
{%- set m_names = [] -%}
{%- set m_rows  = [] -%}
{%- if execute -%}
    {%- if run_query(manifest_count_sql).columns[0].values()[0] > 0 -%}
        {%- set res = run_query(manifest_read_sql) -%}
        {%- set m_files = res.columns[0].values() -%}
        {%- set m_names = res.columns[1].values() -%}
        {%- set m_rows  = res.columns[2].values() -%}
    {%- endif -%}
{%- endif %}

WITH manifest AS (
{%- if m_names | length > 0 %}
    SELECT column1 AS manifest_file,
           column2 AS file_name,
           TRY_TO_NUMBER(column3) AS expected_rows
    FROM VALUES
    {%- for i in range(m_names | length) %}
        ('{{ m_files[i] }}', '{{ m_names[i] }}', '{{ m_rows[i] if m_rows[i] is not none else "" }}'){% if not loop.last %},{% endif %}
    {%- endfor %}
{%- else %}
    SELECT CAST(NULL AS VARCHAR) AS manifest_file,
           CAST(NULL AS VARCHAR) AS file_name,
           CAST(NULL AS NUMBER)  AS expected_rows
    WHERE FALSE
{%- endif %}
),

raw_counts AS (
    SELECT file_name, COUNT(*) AS raw_rows FROM {{ source('walmart_raw', 'stores') }}     GROUP BY 1
    UNION ALL
    SELECT file_name, COUNT(*)             FROM {{ source('walmart_raw', 'department') }} GROUP BY 1
    UNION ALL
    SELECT file_name, COUNT(*)             FROM {{ source('walmart_raw', 'fact') }}       GROUP BY 1
),

listed AS (
    SELECT m.manifest_file,
           m.file_name,
           m.expected_rows,
           COALESCE(r.raw_rows, 0) AS raw_rows,
           CASE WHEN r.file_name IS NULL           THEN 'MISSING'
                WHEN m.expected_rows IS NULL
                  OR r.raw_rows <> m.expected_rows THEN 'ROW COUNT'
           END AS issue
    FROM manifest m
    LEFT JOIN raw_counts r
           ON r.file_name = m.file_name
),

unlisted AS (
    SELECT CAST(NULL AS VARCHAR) AS manifest_file,
           r.file_name,
           CAST(NULL AS NUMBER)  AS expected_rows,
           r.raw_rows,
           'UNLISTED'            AS issue
    FROM raw_counts r
    LEFT JOIN manifest m
           ON m.file_name = r.file_name
    WHERE m.file_name IS NULL
      AND TRY_TO_DATE(REGEXP_SUBSTR(r.file_name, '_([0-9]{8})_[0-9]+[.]csv$', 1, 1, 'e', 1), 'YYYYMMDD')
          >= '{{ var("manifest_start_date", "2026-10-28") }}'::DATE
)

SELECT manifest_file, file_name, expected_rows, raw_rows, issue
FROM listed
WHERE issue IS NOT NULL

UNION ALL

SELECT manifest_file, file_name, expected_rows, raw_rows, issue
FROM unlisted