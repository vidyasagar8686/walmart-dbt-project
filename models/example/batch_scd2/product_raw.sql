{{
config
(
materialized = "incremental",
incremental_strategy = "append",
pre_hook = "{{ copy_into_snowflake('PRODUCT_CP') }}",
schema = "RAW"
)
}}

WITH product_cp AS
(
SELECT 
SOURCE_DATA:product_id AS PRODUCT_ID,
SOURCE_DATA AS SOURCE_DATA,
SOURCE_FILENAME AS SOURCE_FILENAME,
CURRENT_TIMESTAMP(6) AS INSERT_DTS
FROM {{source('product','PRODUCT_CP')}}

{% if is_incremental() %}
WHERE INSERT_DTS > (SELECT MAX(INSERT_DTS) FROM {{this}})
{% endif %}
)
SELECT
CAST(PRODUCT_ID AS INT) AS PRODUCT_ID,
CAST(SOURCE_DATA AS VARIANT) AS SOURCE_DATA,
CAST(SOURCE_FILENAME AS STRING) AS SOURCE_FILENAME,
CAST(INSERT_DTS AS TIMESTAMP(6)) AS INSERT_DTS
FROM product_cp