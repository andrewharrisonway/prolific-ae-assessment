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
        , linked_payment_date
        , is_duplicate_refund
        , spend_effective_date
        , is_revenue_recognised
        , is_spend_qualifying
    FROM
        {{ ref('int_transactions_converted_to_gbp') }}
)

, client_contracts AS (
    SELECT
        client_id
        , contract_start_date
        , contract_end_date
        , spend_threshold
        , discounted_fee_margin
    FROM
        {{ ref('int_client_contracts_windowed') }}
)

/* TRANSFORMATIONS */

/*
LOGIC/CHOICES:

For contract discount rates, a client must achieve a high watermark of the
target within the duration of their contract term, at which point the discount
rate will apply for the remainder of the term.

A refund only reduces contract spend if the payment it reverses counted toward
that spend, i.e. the payment fell inside the contract window. Otherwise a
refund of a pre-contract payment would reduce spend that was never added.

Chargebacks follow the same rule: one only reduces contract spend if the
transaction it reverses (recorded on its transaction_date, see
int_transactions_classified) fell inside the contract window, and it takes
effect (on its resolution date) inside the window too.
*/

, transactions_with_contracts AS (
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
        , txn.gross_amount_gbp
        , txn.net_amount_gbp
        , txn.resolution_status
        , txn.resolution_date
        , txn.linked_transaction_id
        , txn.is_duplicate_refund
        , txn.spend_effective_date
        , txn.is_revenue_recognised
        , txn.is_spend_qualifying
        , cct.spend_threshold
        , cct.discounted_fee_margin
        , (
            txn.transaction_date >= cct.contract_start_date
            AND txn.transaction_date < cct.contract_end_date
        ) AS is_in_contract_period
        -- NOTE: differs from is_in_contract_period only for chargebacks,
        -- which take effect on their resolution date
        , (
            txn.spend_effective_date >= cct.contract_start_date
            AND txn.spend_effective_date < cct.contract_end_date
        ) AS is_effective_in_contract_period
        -- NOTE: null unless this is a refund of a contracted client;
        -- contract_spend_gbp treats null as qualifying
        , (
            txn.linked_payment_date >= cct.contract_start_date
            AND txn.linked_payment_date < cct.contract_end_date
        ) AS is_linked_payment_in_contract_period
    FROM
        transactions AS txn
    LEFT JOIN
        client_contracts AS cct
        ON txn.client_id = cct.client_id
)

/*
Each transaction's contribution to its client's contract spend, so the running
total below (and the monthly mart) sum the same values.
*/

, transactions_contract_spend AS (
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
        , spend_threshold
        , discounted_fee_margin
        , is_in_contract_period
        , CASE
            -- non-contract clients have no contract spend
            WHEN is_in_contract_period IS NULL THEN NULL
            -- reversals only reduce spend if what they reverse counted
            -- toward it, and they take effect inside the window
            WHEN
                is_in_contract_period = 1
                AND is_effective_in_contract_period = 1
                AND is_spend_qualifying = 1
                AND COALESCE(is_linked_payment_in_contract_period, 1) = 1
                THEN net_amount_gbp
            ELSE 0
        END AS contract_spend_gbp
    FROM
        transactions_with_contracts
)

, transactions_running_spend AS (
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
        , spend_threshold
        , discounted_fee_margin
        , is_in_contract_period
        , contract_spend_gbp
        , SUM(contract_spend_gbp) OVER (
            PARTITION BY client_id
            -- NOTE: transaction_id keeps the sort deterministic
            ORDER BY spend_effective_date, transaction_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_contract_spend_gbp
    FROM
        transactions_contract_spend
)

, output_cte AS (
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
        , running_contract_spend_gbp
        , CASE
            -- contract expired: force off
            WHEN is_in_contract_period = 0 THEN 0
            -- no contract at all: no discount concept applies
            WHEN is_in_contract_period IS NULL THEN NULL
            ELSE MAX(running_contract_spend_gbp >= spend_threshold) OVER (
                PARTITION BY client_id
                ORDER BY spend_effective_date, transaction_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        END AS is_discount_earned
    FROM
        transactions_running_spend
)

SELECT * FROM output_cte
