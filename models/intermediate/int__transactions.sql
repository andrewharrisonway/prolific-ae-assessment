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
    FROM
        {{ref('stg_transactions__transactions')}}
),

currency_rates AS (
    SELECT
        currency
        , rate_date
        , exchange_rate_to_gbp
    FROM
        {{ref('stg_currencies__currency_rates')}}
),

client_contracts AS (
    SELECT
        client_id
        , contract_start_date
        , contract_duration_months
        , spend_threshold
        , discounted_fee_margin
    FROM
        {{ref('stg_customers__client_contracts')}}
),

transaction_resolutions AS (
    SELECT
        transaction_id
        , resolution_status
        , resolution_date
    FROM
        {{ref('stg_transactions__transaction_resolutions')}}
),

/* TRANSFORMATIONS */

/*
LOGIC/CHOICES:

Refunds get negated.  Their revenue will be negative.

For contract discount rates, a client must achieve a high watermark of the target
within the duration of their contract term, at which point the discount rate will
apply for the remainder of the term.

Regular transactions apply positively.
Refunds apply negatively.
Fraud does not apply.
Chargebacks do apply but only after they have been resolved.

ASSUMPTION: Chargebacks happen instantaneously when a transaction occurs
*/

transactions_negated_enriched AS (
    -- note 1: I'm opting to negate refund values for ease of aggregation
    SELECT
        txn.transaction_id
        , txn.transaction_date
        , txn.client_id
        , txn.transaction_type
        , IF(txn.transaction_type = 'refund', txn.transaction_amount_local*-1, txn.transaction_amount_local) transaction_amount_local
        , txn.transaction_currency
        , txn.platform_fee_margin
        , trl.transaction_id IS NOT NULL AS is_chargeback_triggered
        , trl.resolution_status
        , trl.resolution_date
    FROM
        transactions txn
    LEFT JOIN
        transaction_resolutions trl
            ON txn.transaction_id = trl.transaction_id
),

transactions_converted_and_contracts AS (
    SELECT
        tne.*
        , ROUND(tne.transaction_amount_local*crt.exchange_rate_to_gbp,2) AS transaction_amount_gbp
        , cct.spend_threshold
        , cct.discounted_fee_margin
        , cct.contract_start_date
        , date(cct.contract_start_date, '+'||cct.contract_duration_months||' months') AS contract_end_date
        , tne.transaction_date >= cct.contract_start_date 
            AND tne.transaction_date < date(cct.contract_start_date, '+'||cct.contract_duration_months||' months')
            AS is_in_contract_period
    FROM
        transactions_negated_enriched tne
    LEFT JOIN
        currency_rates crt
            ON crt.currency = tne.transaction_currency
            AND crt.rate_date = (                               -- NOTE: I am normally not fond of subqueries but this one
                SELECT MAX(cr2.rate_date)                       -- is useful for filling in conversion rate gaps at the end
                FROM currency_rates cr2                         -- of the period.
                WHERE cr2.currency = tne.transaction_currency
                  AND cr2.rate_date <= tne.transaction_date
            )
    LEFT JOIN
        client_contracts cct on tne.client_id = cct.client_id
),

transactions_cumulative AS (
    SELECT
        *
        , SUM(
            IF(
                is_in_contract_period IS NULL, NULL,    -- filters out non-contract customers
                is_in_contract_period = 0, 0,           -- only applies when transactions are in window
                transaction_type = 'fraud', 0,          -- fraud does not count toward cumulative spend
                resolution_status = 'pending', 0,       -- unresolved chargebacks do not count toward cumulative spend
                transaction_amount_gbp
            )
        ) OVER (
            PARTITION BY client_id
            ORDER BY COALESCE(resolution_date, transaction_date), transaction_id -- coalesce dates to ensure chargebacks are considered when they occur, transaction_id keeps deterministic sorting
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) cumulative_spend_gbp
    FROM
        transactions_converted_and_contracts
)
, transactions_discount_status AS (
    SELECT
        *
        , CASE
            WHEN is_in_contract_period = 0 THEN 0        -- contract expired: force off
            WHEN is_in_contract_period IS NULL THEN NULL -- no contract at all: no discount concept applies
            ELSE MAX(
                (cumulative_spend_gbp >= spend_threshold)
            ) OVER (
                PARTITION BY client_id
                ORDER BY COALESCE(resolution_date, transaction_date), transaction_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
          END AS is_discount_earned
    FROM
        transactions_cumulative
)
, output_cte AS (
    SELECT
        transaction_id
        , transaction_date
        , client_id
        , transaction_type
        , transaction_amount_local
        , transaction_currency
        , transaction_amount_gbp
        , IF(transaction_type = 'fraud',0,
            transaction_type = 'chargeback' AND resolution_status IS NOT 'resolved', 0,
            is_in_contract_period = 1 AND is_discount_earned = 1, transaction_amount_gbp * discounted_fee_margin,
            transaction_amount_gbp * platform_fee_margin
        ) revenue_gbp
    FROM
        transactions_discount_status
)

SELECT * FROM output_cte