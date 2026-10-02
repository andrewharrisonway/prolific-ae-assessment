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
        , gross_amount_gbp
        , net_amount_gbp
        , resolution_status
        , resolution_date
        , is_duplicate_refund
        , spend_effective_date
        , is_revenue_recognised
        , is_spend_qualifying
        , discounted_fee_margin
        , is_in_contract_period
        , contract_spend_gbp
        , is_discount_earned
    FROM
        {{ ref('int_transactions_with_contract_spend') }}
)

/* TRANSFORMATIONS */

, transactions_fee_margin AS (
    SELECT
        transaction_id
        , transaction_date
        , client_id
        , transaction_type
        , transaction_currency
        , amount_direction
        , gross_amount_local
        , net_amount_local
        , gross_amount_gbp
        , net_amount_gbp
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , resolution_status
        , resolution_date
        , spend_effective_date
        , contract_spend_gbp
        , is_in_contract_period
        , is_discount_earned
        -- NOTE: revenue is recognised when it takes effect: resolution date for
        -- chargebacks, transaction date otherwise; never for unrecognised rows
        , CAST(
            CASE WHEN is_revenue_recognised = 1 THEN spend_effective_date END
            AS text
        ) AS recognition_date
        , CASE
            WHEN
                is_in_contract_period = 1 AND is_discount_earned = 1
                THEN discounted_fee_margin
            ELSE platform_fee_margin
        END AS applicable_fee_margin
    FROM
        transactions
)

, output_cte AS (
    SELECT
        transaction_id
        , transaction_date
        , client_id
        , transaction_type
        , transaction_currency
        , amount_direction
        , gross_amount_local
        , net_amount_local
        , gross_amount_gbp
        , net_amount_gbp
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , applicable_fee_margin
        , resolution_status
        , resolution_date
        , recognition_date
        , spend_effective_date
        , is_in_contract_period
        , contract_spend_gbp
        , is_discount_earned
        , CASE
            WHEN is_revenue_recognised = 0 THEN 0
            ELSE net_amount_gbp * applicable_fee_margin
        END AS revenue_gbp
    FROM
        transactions_fee_margin
)

SELECT * FROM output_cte
