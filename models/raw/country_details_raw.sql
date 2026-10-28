{{ config(
    materialized='table',
    database='GLUEDB',
    schema='RAW',
    pre_hook="COPY INTO GLUEDB.PUBLIC.COUNTRY_DETAILS_CP (DATA) FROM (SELECT $1 FROM @GLUEDB.PUBLIC.GLUE_S3_STAGE) PATTERN = '.*country_details[.]json$' FILE_FORMAT = (TYPE = JSON)"
) }}

WITH country_details_cp AS (
    SELECT
        x.value AS source_data,
        CURRENT_TIMESTAMP(6) AS insert_dts
    FROM {{ source('country', 'COUNTRY_DETAILS_CP') }} AS a,
         LATERAL FLATTEN(INPUT => a.data) AS x
)

SELECT
    CAST(source_data AS VARIANT) AS source_data,
    CAST(insert_dts AS TIMESTAMP(6)) AS insert_dts
FROM country_details_cp