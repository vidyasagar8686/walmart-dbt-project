{{

config

({

"materialized":'table',
"database": 'GLUEDB',
"schema": 'MART'

})

}}

 

WITH country_details_asia AS

(

SELECT

*

FROM

{{ ref('country_details_transform') }}

WHERE UPPER(COUNTRY_CONTINENT_NAME) = 'ASIA'

)

 

SELECT

*

FROM country_details_asia