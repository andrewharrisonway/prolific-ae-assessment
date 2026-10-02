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
        , linked_transaction_id
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

/*
LOGIC/CHOICES:

A refund reverses revenue at the margin its original payment was charged at,
not the margin in effect on the refund date. Otherwise a payment charged the
platform margin, then refunded after the client earned the discount (or the
reverse), would not net to zero revenue.
*/

, transactions_own_margin AS (
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
        , linked_transaction_id
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
        END AS own_fee_margin
    FROM
        transactions
)

, transactions_fee_margin AS (
    -- NOTE: only refunds have a linked transaction (tested in staging)
    SELECT
        tom.transaction_id
        , tom.transaction_date
        , tom.client_id
        , tom.transaction_type
        , tom.transaction_currency
        , tom.amount_direction
        , tom.gross_amount_local
        , tom.net_amount_local
        , tom.gross_amount_gbp
        , tom.net_amount_gbp
        , tom.is_duplicate_refund
        , tom.is_revenue_recognised
        , tom.is_spend_qualifying
        , tom.resolution_status
        , tom.resolution_date
        , tom.spend_effective_date
        , tom.contract_spend_gbp
        , tom.is_in_contract_period
        , tom.is_discount_earned
        , tom.recognition_date
        , COALESCE(
            pmt.own_fee_margin, tom.own_fee_margin
        ) AS applicable_fee_margin
    FROM
        transactions_own_margin AS tom
    LEFT JOIN
        transactions_own_margin AS pmt
        ON tom.linked_transaction_id = pmt.transaction_id
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
