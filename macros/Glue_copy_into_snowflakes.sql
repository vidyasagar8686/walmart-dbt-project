{%  macro copy_json(table_nm) %}

-- delete the data from the copy table before running the copy command
DELETE FROM {{ var('target_db') }}.{{ var('target_schema') }}.{{ table_nm }};

-- copy the data from snowflake external stage to snowflake table

COPY INTO {{ var('target_db') }}.{{ var('target_schema') }}.{{ table_nm }} (DATA)
FROM (SELECT $1 FROM @{{ var('stage_name') }})
FILE_FORMAT = (TYPE = JSON)
FORCE = TRUE

{% endmacro %}

