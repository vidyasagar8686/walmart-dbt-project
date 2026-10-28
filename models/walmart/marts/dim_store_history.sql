-- Store history (SCD Type 2), one row per store version,
-- tidied from store_snapshot for point-in-time joins.
WITH versions AS (
    SELECT
        dbt_scd_id      AS store_version_key,
        store_id,
        store_type,
        store_size,
        dbt_valid_from,
        dbt_valid_to,
        ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY dbt_valid_from) AS version_number
    FROM {{ ref('store_snapshot') }}
)

SELECT
    store_version_key,
    store_id,
    version_number,
    store_type,
    store_size,
    CASE
        WHEN store_size IS NULL   THEN 'Unknown'
        WHEN store_size < 50000   THEN 'Small'
        WHEN store_size < 150000  THEN 'Medium'
        ELSE 'Large'
    END AS store_size_category,
    -- The first version covers all earlier sales (the snapshot only started in 2026)
    CASE WHEN version_number = 1
         THEN '1900-01-01'::TIMESTAMP
         ELSE dbt_valid_from
    END AS valid_from,
    COALESCE(dbt_valid_to, '9999-12-31'::TIMESTAMP) AS valid_to,
    dbt_valid_to IS NULL AS is_current
FROM versions