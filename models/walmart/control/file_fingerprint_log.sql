{{ config(
    materialized = 'incremental',
    schema       = 'CONTROL',
    unique_key   = ['file_name', 'file_last_modified'],
    transient    = false
) }}

{#- Control table of file fingerprints: one row per file version.
    Each run hashes ONLY data files that are new or changed in S3
    (found through the stage's directory table, which opens no files).
    assert_raw_matches_s3 compares RAW with these stored fingerprints. -#}

{%- set new_files_sql -%}
    SELECT d.relative_path
    FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE) d
    WHERE REGEXP_LIKE(d.relative_path, '(stores|department|fact).*[.]csv')
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

{%- set feeds = {'stores': [], 'department': [], 'fact': []} -%}
{%- for f in new_files -%}
    {%- for feed in ['stores', 'department', 'fact'] -%}
        {%- if f.startswith(feed) -%}{%- do feeds[feed].append(f | replace('.', '[.]')) -%}{%- endif -%}
    {%- endfor -%}
{%- endfor %}

{%- set cols = {
    'stores':     '$1, $2, $3',
    'department': '$1, $2, $3, $4, $5',
    'fact':       '$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12'
} -%}

{%- if new_files | length == 0 %}

-- Nothing new to fingerprint: return no rows
SELECT
    CAST(NULL AS VARCHAR)       AS file_name,
    CAST(NULL AS TIMESTAMP_LTZ) AS file_last_modified,
    CAST(NULL AS VARCHAR)       AS file_type,
    CAST(NULL AS NUMBER)        AS s3_rows,
    CAST(NULL AS NUMBER)        AS s3_hash,
    CAST(NULL AS TIMESTAMP_LTZ) AS fingerprinted_at
WHERE FALSE

{%- else %}

WITH files AS (
    SELECT 'raw/' || relative_path AS file_name,
           last_modified           AS file_last_modified
    FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE)
    WHERE relative_path IN ({% for f in new_files %}'{{ f }}'{% if not loop.last %}, {% endif %}{% endfor %})
),

hashed AS (
    {%- set parts = [] -%}
    {%- for feed in ['stores', 'department', 'fact'] if feeds[feed] | length > 0 -%}
        {%- do parts.append(feed) -%}
    {%- endfor %}
    {%- for feed in parts %}
    SELECT metadata$filename AS file_name,
           '{{ feed }}'      AS file_type,
           COUNT(*)          AS s3_rows,
           HASH_AGG({{ cols[feed] }}) AS s3_hash
    FROM @WALMART.RAW.WALMART_S3_STAGE
        (file_format => 'WALMART.RAW.CSV_FORMAT',
         pattern     => '(.*/)?({{ feeds[feed] | join("|") }})')
    GROUP BY 1
    {% if not loop.last %}UNION ALL{% endif %}
    {%- endfor %}
)

SELECT
    f.file_name,
    f.file_last_modified,
    h.file_type,
    COALESCE(h.s3_rows, 0) AS s3_rows,
    h.s3_hash,
    CURRENT_TIMESTAMP()    AS fingerprinted_at
FROM files f
LEFT JOIN hashed h
       ON h.file_name = f.file_name

{%- endif %}