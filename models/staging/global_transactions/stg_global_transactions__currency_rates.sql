WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(
            from=source('global_transactions', 'currency_rates')
        ) }}
    FROM
        {{ source('global_transactions', 'currency_rates') }}
)

, typed AS (
    SELECT
        CAST(currency AS varchar(3)) AS currency
        , CAST(exchange_rate_to_gbp AS numeric(8, 4)) AS exchange_rate_to_gbp
        , CAST(DATE(rate_date) AS text) AS rate_date
    FROM raw_input
)

, keyed AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['currency', 'rate_date']) }}
            AS currency_rate_id
        , currency
        , rate_date
        , exchange_rate_to_gbp
    FROM typed
)

SELECT * FROM keyed
