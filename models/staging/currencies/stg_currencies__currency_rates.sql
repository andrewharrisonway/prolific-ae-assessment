WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(from=source('global_transactions', 'currency_rates')) }}
    FROM
        {{ source('global_transactions', 'currency_rates') }}
)

, typed AS (
    SELECT
        CAST(currency AS varchar(3)) AS currency
        , DATE(rate_date) AS rate_date
        , CAST(exchange_rate_to_gbp AS numeric(8, 4)) AS exchange_rate_to_gbp
    FROM raw_input
)

SELECT * FROM typed