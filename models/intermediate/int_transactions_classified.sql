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
        {{ ref('stg_global_transactions__transactions') }}
)

, transaction_resolutions AS (
    SELECT
        transaction_id
        , resolution_status
        , resolution_date
    FROM
        {{ ref('stg_global_transactions__transaction_resolutions') }}
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

Duplicate refunds: some payments are refunded in full more than once. Staging
flags every refund after the first (is_duplicate_refund); this model excludes
them from revenue and spend. The rows are kept so the exclusion is visible
downstream.

ASSUMPTION: Chargebacks happen instantaneously when a transaction occurs
*/

, transactions_joined AS (
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
        , txn.linked_transaction_id
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
        , resolution_status
        , resolution_date
        , linked_transaction_id
        , linked_payment_date
        , is_duplicate_refund
        -- NOTE: chargebacks count toward spend when they resolve, so they
        -- are ordered by resolution date rather than transaction date
        , CAST(
            COALESCE(resolution_date, transaction_date) AS text
        ) AS spend_effective_date
        , CASE
            WHEN is_duplicate_refund = 1 THEN 0
            ELSE recognises_revenue * is_settled
        END AS is_revenue_recognised
        , CASE
            WHEN is_duplicate_refund = 1 THEN 0
            ELSE counts_toward_spend * is_settled
        END AS is_spend_qualifying
    FROM
        transactions_joined
)

SELECT * FROM output_cte
