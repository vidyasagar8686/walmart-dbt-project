{#-
  Gold publish: build Gold in a clone, publish with one atomic schema swap.
    prepare_gold_build : clone the live Gold schema into the build schema, log BUILDING
    publish_gold       : guard, grant readers on the build schema, SWAP, revoke, log PUBLISHED, post-check
    rollback_gold      : swap back to the previously published Gold (owner's decision)
  Production : live WALMART.MART,          build WALMART.MART_BUILD
  Dev test   : live WALMART.<dev>_MART,    build WALMART.<dev>_MART_BUILD  (run with --vars '{gold_build: true}')
  Readers (REPORTER / TABLEAU_SVC) only ever query the live schema.
-#}

{% macro gold_schemas() %}
    {%- if target.name == 'prod' -%}
        {{ return({'live': 'WALMART.MART', 'build': 'WALMART.MART_BUILD'}) }}
    {%- else -%}
        {{ return({'live': 'WALMART.' ~ target.schema ~ '_MART', 'build': 'WALMART.' ~ target.schema ~ '_MART_BUILD'}) }}
    {%- endif -%}
{% endmacro %}

{% macro _gold_log() %}WALMART.CONTROL.GOLD_PUBLISH_LOG{% endmacro %}

{% macro _latest_published() %}
    {%- set r = run_query("SELECT MAX_BY(publish_id, published_at) FROM " ~ _gold_log()
                          ~ " WHERE target_name = '" ~ target.name ~ "' AND status = 'PUBLISHED'") -%}
    {{ return(r.rows[0][0]) }}
{% endmacro %}


{% macro prepare_gold_build() %}
    {%- set s = gold_schemas() -%}
    {%- set publish_id = env_var('DBT_CLOUD_RUN_ID', 'dev-' ~ invocation_id) -%}

    {% do run_query("CREATE TABLE IF NOT EXISTS " ~ _gold_log() ~ " (
        publish_id        STRING,
        target_name       STRING,
        base_publish_id   STRING,          -- the published version this build was cloned from
        status            STRING,          -- BUILDING / PUBLISHED / FAILED / ROLLED_BACK
        fact_rows         NUMBER,
        fact_sales_total  NUMBER(38,2),
        build_started_at  TIMESTAMP_TZ,
        published_at      TIMESTAMP_TZ,
        rolled_back_at    TIMESTAMP_TZ,
        note              STRING)") %}

    {#- A build that never reached publish failed (the job stopped before the swap) -#}
    {% do run_query("UPDATE " ~ _gold_log() ~ " SET status = 'FAILED', note = 'job stopped before publish'
                     WHERE target_name = '" ~ target.name ~ "' AND status = 'BUILDING'") %}

    {% do run_query("CREATE SCHEMA IF NOT EXISTS " ~ s.live) %}
    {#- Zero-copy clone: the incremental fact table starts from the published history -#}
    {% do run_query("CREATE OR REPLACE SCHEMA " ~ s.build ~ " CLONE " ~ s.live) %}

    {%- set base = _latest_published() -%}
    {% do run_query("INSERT INTO " ~ _gold_log() ~ " (publish_id, target_name, base_publish_id, status, build_started_at)
                     SELECT '" ~ publish_id ~ "', '" ~ target.name ~ "', "
                     ~ ("'" ~ base ~ "'" if base else "NULL") ~ ", 'BUILDING', CURRENT_TIMESTAMP()") %}

    {{ log("prepare_gold_build: " ~ s.build ~ " cloned from " ~ s.live ~ " (publish_id " ~ publish_id ~ ")", info=True) }}
{% endmacro %}


{% macro publish_gold() %}
    {%- set s = gold_schemas() -%}

    {%- set b = run_query("SELECT publish_id, base_publish_id FROM " ~ _gold_log()
                          ~ " WHERE target_name = '" ~ target.name ~ "' AND status = 'BUILDING'
                              ORDER BY build_started_at DESC LIMIT 1") -%}
    {%- if b.rows | length == 0 -%}
        {{ exceptions.raise_compiler_error("publish_gold: no BUILDING row, run prepare_gold_build first") }}
    {%- endif -%}
    {%- set publish_id = b.rows[0][0] -%}
    {%- set base = b.rows[0][1] -%}

    {#- Guard: never publish a build cloned from an older version than what is live now -#}
    {%- set latest = _latest_published() -%}
    {%- if (base or '') != (latest or '') -%}
        {{ exceptions.raise_compiler_error("publish_gold: stale build (based on " ~ base ~ ", live is " ~ latest ~ ")") }}
    {%- endif -%}

    {%- set st = run_query("SELECT COUNT(*), SUM(weekly_sales) FROM " ~ s.build ~ ".FACT_SALES").rows[0] -%}

    {#- Readers get the new schema BEFORE the swap, so access never drops -#}
    {%- if target.name == 'prod' -%}
        {% do run_query("GRANT USAGE ON SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
        {% do run_query("GRANT SELECT ON ALL TABLES IN SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
        {% do run_query("GRANT SELECT ON ALL VIEWS IN SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
    {%- endif -%}

    {#- The single atomic step: every Gold table switches at once -#}
    {% do run_query("ALTER SCHEMA " ~ s.live ~ " SWAP WITH " ~ s.build) %}

    {#- The previous version now sits in the build schema: keep it for rollback, but hide it from readers -#}
    {%- if target.name == 'prod' -%}
        {% do run_query("REVOKE USAGE ON SCHEMA " ~ s.build ~ " FROM ROLE REPORTER") %}
    {%- endif -%}

    {% do run_query("UPDATE " ~ _gold_log() ~ " SET status = 'PUBLISHED', published_at = CURRENT_TIMESTAMP(),
                     fact_rows = " ~ st[0] ~ ", fact_sales_total = " ~ (st[1] if st[1] is not none else 'NULL') ~ "
                     WHERE publish_id = '" ~ publish_id ~ "' AND target_name = '" ~ target.name ~ "' AND status = 'BUILDING'") %}

    {#- Post-check: the live schema now holds exactly what was validated -#}
    {%- set live_rows = run_query("SELECT COUNT(*) FROM " ~ s.live ~ ".FACT_SALES").rows[0][0] -%}
    {%- if live_rows != st[0] -%}
        {{ exceptions.raise_compiler_error("publish_gold: post-check failed (live " ~ live_rows ~ " rows, validated " ~ st[0] ~ ")") }}
    {%- endif -%}

    {{ log("publish_gold: " ~ s.live ~ " now serves publish_id " ~ publish_id ~ " (" ~ st[0] ~ " fact rows)", info=True) }}
{% endmacro %}


{% macro rollback_gold() %}
    {%- set s = gold_schemas() -%}

    {#- Only valid right after a publish: then the build schema still holds the previous version -#}
    {%- set last = run_query("SELECT publish_id, status FROM " ~ _gold_log()
                             ~ " WHERE target_name = '" ~ target.name ~ "'
                                 ORDER BY build_started_at DESC LIMIT 1").rows -%}
    {%- if last | length == 0 or last[0][1] != 'PUBLISHED' -%}
        {{ exceptions.raise_compiler_error("rollback_gold: the latest build is not PUBLISHED, so the build schema doesn't hold the previous version") }}
    {%- endif -%}

    {%- if target.name == 'prod' -%}
        {% do run_query("GRANT USAGE ON SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
        {% do run_query("GRANT SELECT ON ALL TABLES IN SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
        {% do run_query("GRANT SELECT ON ALL VIEWS IN SCHEMA " ~ s.build ~ " TO ROLE REPORTER") %}
    {%- endif -%}
    {% do run_query("ALTER SCHEMA " ~ s.live ~ " SWAP WITH " ~ s.build) %}
    {%- if target.name == 'prod' -%}
        {% do run_query("REVOKE USAGE ON SCHEMA " ~ s.build ~ " FROM ROLE REPORTER") %}
    {%- endif -%}

    {% do run_query("UPDATE " ~ _gold_log() ~ " SET status = 'ROLLED_BACK', rolled_back_at = CURRENT_TIMESTAMP()
                     WHERE publish_id = '" ~ last[0][0] ~ "' AND target_name = '" ~ target.name ~ "'") %}
    {{ log("rollback_gold: " ~ s.live ~ " restored to the previous version (" ~ last[0][0] ~ " rolled back)", info=True) }}
{% endmacro %}