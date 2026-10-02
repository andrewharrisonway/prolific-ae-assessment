WITH

/* IMPORTS */

transactions AS (
    SELECT
        transaction_id
        , transaction_date
        , client_id
        , transaction_type
        , transaction_currency
        , platform_fee_margin
        , amount_direction
        , gross_amount_local
        , net_amount_local
        , resolution_status
        , resolution_date
        , linked_payment_date
        , is_duplicate_refund
        , spend_effective_date
        , is_revenue_recognised
        , is_spend_qualifying
    FROM
        {{ ref('int_transactions_classified') }}
)

, currency_rates AS (
    SELECT
        currency
        , rate_date
        , exchange_rate_to_gbp
    FROM
        {{ ref('stg_global_transactions__currency_rates') }}
)

/* TRANSFORMATIONS */

, currency_rate_periods AS (
    -- NOTE: each rate applies from its date until the next rate for the same
    -- currency, so a transaction takes the latest rate on or before its date.
    -- The last rate has no end date and carries forward, which fills rate gaps
    -- at the end of the period. In production, this should be addressed
    -- upstream to determine the source of the gaps.
    SELECT
        currency
        , rate_date
        , exchange_rate_to_gbp
        , LEAD(rate_date) OVER (
            PARTITION BY currency
            ORDER BY rate_date
        ) AS next_rate_date
    FROM
        currency_rates
)

, output_cte AS (
    SELECT
        txn.transaction_id
        , txn.transaction_date
        , txn.client_id
        , txn.transaction_type
        , txn.transaction_currency
        , txn.platform_fee_margin
        , txn.amount_direction
        , txn.gross_amount_local
        , txn.net_amount_local
        , txn.resolution_status
        , txn.resolution_date
        , txn.linked_payment_date
        , txn.is_duplicate_refund
        , txn.spend_effective_date
        , txn.is_revenue_recognised
        , txn.is_spend_qualifying
        , ROUND(
            txn.gross_amount_local * crp.exchange_rate_to_gbp, 2
        ) AS gross_amount_gbp
        , ROUND(
            txn.net_amount_local * crp.exchange_rate_to_gbp, 2
        ) AS net_amount_gbp
    FROM
        transactions AS txn
    LEFT JOIN
        currency_rate_periods AS crp
        ON
            txn.transaction_currency = crp.currency
            AND txn.transaction_date >= crp.rate_date
            AND (
                crp.next_rate_date IS NULL
                OR txn.transaction_date < crp.next_rate_date
            )
)

SELECT * FROM output_cte
