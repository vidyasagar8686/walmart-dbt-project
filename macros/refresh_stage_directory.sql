{% macro refresh_stage_directory() %}
    {#- Refresh the S3 stage's directory table so new, changed and
        deleted files are visible before the header check runs. -#}
    {% do run_query("ALTER STAGE WALMART.RAW.WALMART_S3_STAGE REFRESH") %}
    {{ log("Directory table refreshed for WALMART.RAW.WALMART_S3_STAGE", info=True) }}
{% endmacro %}