WITH

/* IMPORTS */

transactions AS (
    SELECT
        transaction_id
        , transaction_date
        , client_id
        , transaction_amount AS transaction_amount_local
        , transaction_currency
        , transaction_type
        , platform_fee_margin
        , linked_transaction_id
        , is_duplicate_refund
    FROM
        {{ ref('stg_transactions__transactions') }}
)

, currency_rates AS (
    SELECT
        currency
        , rate_date
        , exchange_rate_to_gbp
    FROM
        {{ ref('stg_currencies__currency_rates') }}
)

, client_contracts AS (
    SELECT
        client_id
        , contract_start_date
        , contract_duration_months
        , spend_threshold
        , discounted_fee_margin
    FROM
        {{ ref('stg_customers__client_contracts') }}
)

, transaction_resolutions AS (
    SELECT
        transaction_id
        , resolution_status
        , resolution_date
    FROM
        {{ ref('stg_transactions__transaction_resolutions') }}
)

, transaction_types AS (
    SELECT
        transaction_type
        , amount_direction
        , recognises_revenue
        , counts_toward_spend
        , requires_resolution
    FROM
        {{ ref('transaction_types') }}
)

/* TRANSFORMATIONS */

/*
LOGIC/CHOICES:

How each transaction type behaves is defined in the `transaction_types` seed,
not in this model:
- amount_direction: refunds are -1, so net amounts aggregate correctly.
- recognises_revenue / counts_toward_spend: fraud counts toward neither.
- requires_resolution: chargebacks only count once resolved.

Each transaction keeps its recorded (gross) amount alongside the signed (net)
amount, so neither meaning is lost.

For contract discount rates, a client must achieve a high watermark of the
target within the duration of their contract term, at which point the discount
rate will apply for the remainder of the term.

A refund only reduces contract spend if the payment it reverses counted toward
that spend, i.e. the payment fell inside the contract window. Otherwise a
refund of a pre-contract payment would reduce spend that was never added.

Duplicate refunds: some payments are refunded in full more than once. Staging
flags every refund after the first (is_duplicate_refund); this model excludes
them from revenue and spend. The rows are kept so the exclusion is visible
downstream.

ASSUMPTION: Chargebacks happen instantaneously when a transaction occurs
*/

, transactions_classified AS (
    SELECT
        txn.transaction_id
        , txn.transaction_date
        , txn.client_id
        , txn.transaction_type
        , txn.transaction_currency
        , txn.platform_fee_margin
        , txn.transaction_amount_local AS gross_amount_local
        , trl.resolution_status
        , trl.resolution_date
        , lnk.transaction_date AS linked_payment_date
        , tty.amount_direction
        , tty.recognises_revenue
        , tty.counts_toward_spend
        , txn.is_duplicate_refund
        , (
            txn.transaction_amount_local * tty.amount_direction
        ) AS net_amount_local
        -- NOTE: settled means nothing is outstanding: either the type needs no
        -- resolution, or it has been resolved
        , CASE
            WHEN tty.requires_resolution = 0 THEN 1
            WHEN trl.resolution_status = 'resolved' THEN 1
            ELSE 0
        END AS is_settled
    FROM
        transactions AS txn
    LEFT JOIN
        transaction_types AS tty
        ON txn.transaction_type = tty.transaction_type
    LEFT JOIN
        transaction_resolutions AS trl
        ON txn.transaction_id = trl.transaction_id
    LEFT JOIN
        transactions AS lnk
        ON txn.linked_transaction_id = lnk.transaction_id
)

, client_contract_windows AS (
    SELECT
        client_id
        , spend_threshold
        , discounted_fee_margin
        , contract_start_date
        , DATE(
            contract_start_date
            , '+' || contract_duration_months || ' months'
        ) AS contract_end_date
    FROM
        client_contracts
)

, transactions_converted_and_contracts AS (
    SELECT
        tcl.transaction_id
        , tcl.transaction_date
        , tcl.client_id
        , tcl.transaction_type
        , tcl.transaction_currency
        , tcl.platform_fee_margin
        , tcl.amount_direction
        , tcl.gross_amount_local
        , tcl.net_amount_local
        , ccw.spend_threshold
        , ccw.discounted_fee_margin
        , ccw.contract_start_date
        , ccw.contract_end_date
        , tcl.is_duplicate_refund
        , CASE
            WHEN tcl.is_duplicate_refund = 1 THEN 0
            ELSE tcl.recognises_revenue * tcl.is_settled
        END AS is_revenue_recognised
        , CASE
            WHEN tcl.is_duplicate_refund = 1 THEN 0
            ELSE tcl.counts_toward_spend * tcl.is_settled
        END AS is_spend_qualifying
        -- NOTE: chargebacks count toward spend when they resolve, so they
        -- are ordered by resolution date rather than transaction date
        , COALESCE(
            tcl.resolution_date, tcl.transaction_date
        ) AS spend_effective_date
        , ROUND(
            tcl.gross_amount_local * crt.exchange_rate_to_gbp, 2
        ) AS gross_amount_gbp
        , ROUND(
            tcl.net_amount_local * crt.exchange_rate_to_gbp, 2
        ) AS net_amount_gbp
        , (
            tcl.transaction_date >= ccw.contract_start_date
            AND tcl.transaction_date < ccw.contract_end_date
        ) AS is_in_contract_period
        -- NOTE: null unless this is a refund of a contracted client
        , (
            tcl.linked_payment_date >= ccw.contract_start_date
            AND tcl.linked_payment_date < ccw.contract_end_date
        ) AS is_linked_payment_in_contract_period
    FROM
        transactions_classified AS tcl
    LEFT JOIN
        currency_rates AS crt
        ON
            tcl.transaction_currency = crt.currency
            -- NOTE: I am normally not fond of subqueries, but this one fills
            -- conversion rate gaps at the end of the period. In production,
            -- this should be addressed upstream to determine the source of
            -- the gaps.
            AND crt.rate_date = (
                SELECT MAX(cr2.rate_date)
                FROM currency_rates AS cr2
                WHERE
                    cr2.currency = tcl.transaction_currency
                    AND cr2.rate_date <= tcl.transaction_date
            )
    LEFT JOIN
        client_contract_windows AS ccw
        ON tcl.client_id = ccw.client_id
)

, transactions_cumulative AS (
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
        , platform_fee_margin
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , spend_effective_date
        , spend_threshold
        , discounted_fee_margin
        , is_in_contract_period
        , SUM(
            CASE
                -- non-contract clients have no cumulative spend
                WHEN is_in_contract_period IS NULL THEN NULL
                -- refunds only reduce spend if their payment counted toward it
                WHEN
                    is_in_contract_period = 1
                    AND is_spend_qualifying = 1
                    AND COALESCE(is_linked_payment_in_contract_period, 1) = 1
                    THEN net_amount_gbp
                ELSE 0
            END
        ) OVER (
            PARTITION BY client_id
            -- NOTE: transaction_id keeps the sort deterministic
            ORDER BY spend_effective_date, transaction_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_spend_gbp
    FROM
        transactions_converted_and_contracts
)

, transactions_discount_status AS (
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
        , platform_fee_margin
        , is_duplicate_refund
        , is_revenue_recognised
        , is_spend_qualifying
        , discounted_fee_margin
        , is_in_contract_period
        , CASE
            -- contract expired: force off
            WHEN is_in_contract_period = 0 THEN 0
            -- no contract at all: no discount concept applies
            WHEN is_in_contract_period IS NULL THEN NULL
            ELSE MAX(cumulative_spend_gbp >= spend_threshold) OVER (
                PARTITION BY client_id
                ORDER BY spend_effective_date, transaction_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        END AS is_discount_earned
    FROM
        transactions_cumulative
)

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
        , CASE
            WHEN
                is_in_contract_period = 1 AND is_discount_earned = 1
                THEN discounted_fee_margin
            ELSE platform_fee_margin
        END AS applicable_fee_margin
    FROM
        transactions_discount_status
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
        , CASE
            WHEN is_revenue_recognised = 0 THEN 0
            ELSE net_amount_gbp * applicable_fee_margin
        END AS revenue_gbp
    FROM
        transactions_fee_margin
)

SELECT * FROM output_cte
