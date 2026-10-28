{% snapshot product_snapshot %}
{{
config
(
strategy = "check",
unique_key = "PRODUCT_ID",
check_cols = ["PRODUCT_NAME","PRODUCT_CATEGORY","PRODUCT_PRICE","PRODUCT_STOCK_QUANTITY","PRODUCT_SUPPLIER_NAME"],
schema = "SNAPSHOT"
)
}}
SELECT * FROM {{ ref('product_transformed') }}
{% endsnapshot %}