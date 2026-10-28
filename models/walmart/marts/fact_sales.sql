{{ config(
    materialized          = 'incremental',
    incremental_strategy  = 'merge',
    unique_key            = ['store_id', 'dep_id', 'sales_date'],
    merge_exclude_columns = ['insert_date'],
    on_schema_change      = 'append_new_columns'
) }}

SELECT
    sales.store_id,
    sales.dep_id,
    sales.sales_date,
    hist.store_version_key,          -- the store version valid on the sale date (as-was)
    sales.weekly_sales,
    CASE WHEN sales.weekly_sales > 0 THEN sales.weekly_sales ELSE 0 END AS positive_sales,
    CASE WHEN sales.weekly_sales < 0 THEN -sales.weekly_sales ELSE 0 END AS net_return_amount,
    sales.is_holiday,
    features.temperature,
    features.fuel_price,
    features.markdown1,
    features.markdown2,
    features.markdown3,
    features.markdown4,
    features.markdown5,
    features.cpi,
    features.unemployment,
    -- when this row's data last arrived (newest of the sales row and its economic row)
    GREATEST(sales.loaded_at, COALESCE(features.loaded_at, sales.loaded_at)) AS source_loaded_at,
    current_timestamp() AS insert_date,
    current_timestamp() AS update_date
FROM {{ ref('stg_department') }} sales
LEFT JOIN {{ ref('stg_fact') }} features
       ON sales.store_id   = features.store_id
      AND sales.sales_date = features.sales_date
-- Point-in-time join: the store version that was valid on the sale date
LEFT JOIN {{ ref('dim_store_history') }} hist
       ON sales.store_id    = hist.store_id
      AND sales.sales_date >= hist.valid_from
      AND sales.sales_date <  hist.valid_to
WHERE sales.store_id IS NOT NULL
  AND sales.dep_id IS NOT NULL
  AND sales.sales_date IS NOT NULL

{% if is_incremental() %}
    {%- set existing_cols = adapter.get_columns_in_relation(this) | map(attribute='name') | map('lower') | list -%}
    {%- if 'source_loaded_at' in existing_cols %}
    -- Load-time watermark: re-process rows LOADED within N days of the newest load
    -- already in this table. A wrong date inside a row can't move this window.
    AND GREATEST(sales.loaded_at, COALESCE(features.loaded_at, sales.loaded_at)) >= (
        SELECT DATEADD(day, -{{ var('fact_lookback_days', 21) }},
                       COALESCE(MAX(source_loaded_at), '1900-01-01'::TIMESTAMP_LTZ))
        FROM {{ this }}
    )
    {%- endif %}
{% endif %}