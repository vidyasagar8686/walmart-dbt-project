{% macro register_open_quarantine() %}
    {#- Adds every OPEN quarantine row that isn't in the triage table yet,
        so a steward only has to update its status. Never changes existing rows. -#}
    {% set sql %}
        INSERT INTO {{ source('walmart_control', 'quarantine_triage') }}
            (file_name, file_row_number, status)
        SELECT q.file_name, q.file_row_number, 'OPEN'
        FROM (
            SELECT file_name, file_row_number FROM {{ ref('quarantine_department') }} WHERE quarantine_status = 'OPEN'
            UNION
            SELECT file_name, file_row_number FROM {{ ref('quarantine_fact') }}       WHERE quarantine_status = 'OPEN'
        ) q
        WHERE NOT EXISTS (
            SELECT 1 FROM {{ source('walmart_control', 'quarantine_triage') }} t
            WHERE t.file_name = q.file_name
              AND t.file_row_number = q.file_row_number
        )
    {% endset %}
    {% do run_query(sql) %}
    {{ log("New OPEN quarantine rows registered in QUARANTINE_TRIAGE", info=True) }}
{% endmacro %}