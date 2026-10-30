-- Fails if any data file differs between S3 and RAW, in row count or in content.
-- S3 side: stored fingerprints from file_fingerprint_log (only new or changed files
-- are hashed each run). RAW side: computed from the RAW tables on every run.
WITH current_files AS (
    -- the current version of every data file in S3 (directory table: opens no files)
    SELECT 'raw/' || relative_path AS file_name,
           last_modified           AS file_last_modified
    FROM DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE)
    WHERE REGEXP_LIKE(relative_path, '(stores|department|fact).*[.]csv')
),

s3_files AS (
    SELECT c.file_name, l.s3_rows, l.s3_hash
    FROM current_files c
    LEFT JOIN {{ ref('file_fingerprint_log') }} l
           ON l.file_name          = c.file_name
          AND l.file_last_modified = c.file_last_modified
),

raw_files AS (
    SELECT file_name, COUNT(*) AS raw_rows,
           HASH_AGG(store, type, size) AS raw_hash
    FROM {{ source('walmart_raw', 'stores') }}
    GROUP BY 1

    UNION ALL
    SELECT file_name, COUNT(*),
           HASH_AGG(store, dept, date, weekly_sales, isholiday)
    FROM {{ source('walmart_raw', 'department') }}
    GROUP BY 1

    UNION ALL
    SELECT file_name, COUNT(*),
           HASH_AGG(store, date, temperature, fuel_price, markdown1, markdown2,
                    markdown3, markdown4, markdown5, cpi, unemployment, isholiday)
    FROM {{ source('walmart_raw', 'fact') }}
    GROUP BY 1
)

SELECT COALESCE(s.file_name, r.file_name) AS file_name,
       COALESCE(s.s3_rows, 0)  AS s3_rows,
       COALESCE(r.raw_rows, 0) AS raw_rows,
       CASE WHEN COALESCE(s.s3_rows, 0) <> COALESCE(r.raw_rows, 0) THEN 'ROW COUNT'
            ELSE 'CONTENT' END AS mismatch_type
FROM s3_files s
FULL OUTER JOIN raw_files r
       ON s.file_name = r.file_name
WHERE COALESCE(s.s3_rows, 0) <> COALESCE(r.raw_rows, 0)
   OR s.s3_hash IS DISTINCT FROM r.raw_hash