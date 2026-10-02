WITH

/* IMPORTS */

client_contracts AS (
    SELECT
        client_id
        , contract_start_date
        , contract_duration_months
        , spend_threshold
        , discounted_fee_margin
    FROM
        {{ ref('stg_global_transactions__client_contracts') }}
)

/* TRANSFORMATIONS */

, output_cte AS (
    -- NOTE: a contract runs from its start date (inclusive) for its duration
    -- in months; the end date is exclusive
    SELECT
        client_id
        , contract_start_date
        , contract_duration_months
        , spend_threshold
        , discounted_fee_margin
        , CAST(
            DATE(
                contract_start_date
                , '+' || contract_duration_months || ' months'
            ) AS text
        ) AS contract_end_date
    FROM
        client_contracts
)

SELECT * FROM output_cte
