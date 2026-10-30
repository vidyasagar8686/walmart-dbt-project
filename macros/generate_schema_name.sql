{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {#- Gold publish: in production (or a dev test run with --vars '{gold_build: true}'),
        Gold models are built in the build schema and published by publish_gold.
        Snapshots are excluded: store_snapshot keeps writing to the live schema. -#}
    {%- set gold_to_build = custom_schema_name is not none
                            and custom_schema_name | trim | upper == 'MART'
                            and node is not none and node.resource_type == 'model'
                            and (target.name == 'prod' or var('gold_build', false)) -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}

    {#- Production job (target name "prod"): use the real schema names -#}
    {%- elif target.name == 'prod' -%}
        {{ 'MART_BUILD' if gold_to_build else custom_schema_name | trim }}

    {#- Development (IDE): prefix with the developer's schema, e.g. DBT_DEV_MART -#}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}{{ '_BUILD' if gold_to_build else '' }}

    {%- endif -%}

{%- endmacro %}