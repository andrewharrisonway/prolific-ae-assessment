WITH

/* IMPORTS */

transactions AS (
    SELECT
        transaction_id
        , client_id
        , transaction_type
        , transaction_currency
        , transaction_date
        , resolution_status
        , resolution_date
        , recognition_date
        , spend_effective_date
        , amount_direction
        , gross_amount_local
        , net_amount_local
        , gross_amount_gbp
        , net_amount_gbp
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , is_in_contract_period
        , contract_spend_gbp
        , is_discount_earned
        , applicable_fee_margin
        , revenue_gbp
    FROM
        {{ ref('int_transactions_with_revenue') }}
)

/* TRANSFORMATIONS */

, output_cte AS (
    SELECT
        transaction_id
        , client_id
        , transaction_type
        , transaction_currency
        , transaction_date
        , resolution_status
        , resolution_date
        , recognition_date
        , spend_effective_date
        , amount_direction
        , gross_amount_local
        , net_amount_local
        , gross_amount_gbp
        , net_amount_gbp
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , is_in_contract_period
        , contract_spend_gbp
        , is_discount_earned
        , applicable_fee_margin
        , revenue_gbp
    FROM
        transactions
)

SELECT * FROM output_cte
