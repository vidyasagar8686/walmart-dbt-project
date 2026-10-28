{% macro copy_into_snowflake(table_nm) %}
--Delete the data from the copy table before running the copy command
delete from {{var ('target_db') }}.{{var ('target_schema')}}.{{ table_nm }};
--Copy the data from the snowflake external stage to snowflake table
COPY INTO {{var ('target_db') }}.{{var ('target_schema')}}.{{ table_nm }}
FROM
(
SELECT
$1 AS SOURCE_DATA,
METADATA$FILENAME AS SOURCE_FILENAME,
CURRENT_TIMESTAMP AS INSERT_DTS
FROM @{{ var('stage_name') }}/data/product
)
FILE_FORMAT = (TYPE = PARQUET);
{% endmacro %}