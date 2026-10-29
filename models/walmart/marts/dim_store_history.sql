-- Store history (SCD Type 2), rebuilt from Bronze (RAW) on every run (#8).
-- valid_from = the extract date in the file name (when the vendor sent the change),
-- NOT the dbt run time, so late runs and back-dated corrections land on the right date.
-- The original full extract (stores.csv, no date in the name) is the starting version: 1900-01-01.
-- store_snapshot is kept separately as the audit trail of what dbt saw and when.

WITH raw_rows AS (
    SELECT
        TRY_TO_NUMBER(store) AS store_id,
        TRIM(type)           AS store_type,
        TRY_TO_NUMBER(size)  AS store_size,
        file_name,
        COALESCE(TRY_TO_DATE(REGEXP_SUBSTR(file_name, '_([0-9]{8})_[0-9]+[.]csv$', 1, 1, 'e', 1), 'YYYYMMDD'),
                 '1900-01-01'::DATE)                                                          AS effective_date,
        COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(file_name, '_[0-9]{8}_([0-9]+)[.]csv$', 1, 1, 'e', 1)), 0) AS file_seq,
        loaded_at
    FROM {{ source('walmart_raw', 'stores') }}
    WHERE TRY_TO_NUMBER(store) IS NOT NULL
),

one_per_day AS (
    -- several files on the same date: the highest sequence wins (same rule as newest_file_first)
    SELECT *
    FROM raw_rows
    QUALIFY ROW_NUMBER() OVER (PARTITION BY store_id, effective_date
                               ORDER BY file_seq DESC, file_name DESC, loaded_at DESC) = 1
),

compared AS (
    -- LAG: bring in the previous version's values for the same store
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY effective_date) AS row_seq,
           LAG(store_type) OVER (PARTITION BY store_id ORDER BY effective_date) AS prev_type,
           LAG(store_size) OVER (PARTITION BY store_id ORDER BY effective_date) AS prev_size
    FROM one_per_day
),

changes AS (
    -- keep only real changes (a re-sent identical row is not a new version)
    SELECT *
    FROM compared
    WHERE row_seq = 1
       OR store_type IS DISTINCT FROM prev_type
       OR store_size IS DISTINCT FROM prev_size
),

versions AS (
    -- LEAD: the next version's start date closes this version
    SELECT
        store_id,
        store_type,
        store_size,
        file_name                                                              AS source_file,
        effective_date                                                         AS valid_from_date,
        LEAD(effective_date) OVER (PARTITION BY store_id ORDER BY effective_date) AS next_valid_from,
        ROW_NUMBER()         OVER (PARTITION BY store_id ORDER BY effective_date) AS version_number
    FROM changes
)

SELECT
    MD5(store_id || '|' || TO_VARCHAR(valid_from_date))   AS store_version_key,
    store_id,
    version_number,
    store_type,
    store_size,
    CASE
        WHEN store_size IS NULL   THEN 'Unknown'
        WHEN store_size < 50000   THEN 'Small'
        WHEN store_size < 150000  THEN 'Medium'
        ELSE 'Large'
    END                                                    AS store_size_category,
    valid_from_date::TIMESTAMP                             AS valid_from,
    COALESCE(next_valid_from, '9999-12-31'::DATE)::TIMESTAMP AS valid_to,
    next_valid_from IS NULL                                AS is_current,
    source_file
FROM versions