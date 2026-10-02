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
        , CAST(DATE(transaction_date) AS text) AS transaction_date
    FROM raw_input
)

, flagged AS (
    -- NOTE: refunds are always for the full payment amount, so any refund
    -- after the first for the same payment is a duplicate. Flagged, not
    -- filtered: what to do about duplicates is decided in
    -- int_transactions_classified.
    SELECT
        transaction_id
        , client_id
        , transaction_amount
        , transaction_type
        , platform_fee_margin
        , transaction_currency
        , linked_transaction_id
        , transaction_date
        , CASE
            WHEN
                transaction_type = 'refund'
                AND ROW_NUMBER() OVER (
                    PARTITION BY transaction_type, linked_transaction_id
                    ORDER BY transaction_date, transaction_id
                ) > 1
                THEN 1
            ELSE 0
        END AS is_duplicate_refund
    FROM typed
)

SELECT * FROM flagged
