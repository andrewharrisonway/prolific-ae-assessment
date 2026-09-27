WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(from=source('global_transactions', 'transactions')) }}
    FROM
        {{ source('global_transactions', 'transactions') }}
)

, typed AS (
    SELECT
        CAST(transaction_id AS varchar(10)) AS transaction_id
        , CAST(client_id AS varchar(7)) AS client_id
        , CAST(transaction_amount AS numeric(8, 2)) AS transaction_amount
        , CAST(transaction_type AS varchar(12)) AS transaction_type
        , CAST(platform_fee_margin AS numeric(1, 2)) AS platform_fee_margin
        , CAST(currency AS varchar(3)) AS transaction_currency
        , CAST(linked_transaction_id AS varchar(10)) AS linked_transaction_id
        , DATE(transaction_date) AS transaction_date
    FROM raw_input
)

SELECT * FROM typed
