WITH

/* IMPORTS */

monthly AS (
    SELECT
        client_id
        , month_start_date
        , spend_threshold
        , cumulative_contract_spend_gbp
    FROM
        {{ ref('fct_client_monthly_revenue') }}
    WHERE
        contract_status != 'no contract'
)

, transactions AS (
    SELECT
        client_id
        , transaction_date
        , gross_amount_gbp
    FROM
        {{ ref('fct_transactions') }}
    WHERE
        is_in_contract_period = 1
)

/* TRANSFORMATIONS */

, naive_spend_by_month AS (
    -- NOTE: every transaction in the contract window at its gross amount,
    -- whatever its type
    SELECT
        client_id
        , DATE(transaction_date, 'start of month') AS month_start_date
        , SUM(gross_amount_gbp) AS monthly_naive_gross_spend_gbp
    FROM
        transactions
    GROUP BY
        client_id
        , DATE(transaction_date, 'start of month')
)

, monthly_with_naive_spend AS (
    SELECT
        mly.client_id
        , mly.month_start_date
        , mly.spend_threshold
        , mly.cumulative_contract_spend_gbp
        , COALESCE(
            nsm.monthly_naive_gross_spend_gbp, 0
        ) AS monthly_naive_gross_spend_gbp
    FROM
        monthly AS mly
    LEFT JOIN
        naive_spend_by_month AS nsm
        ON
            mly.client_id = nsm.client_id
            AND mly.month_start_date = nsm.month_start_date
)

, monthly_cumulative AS (
    SELECT
        client_id
        , month_start_date
        , spend_threshold
        , cumulative_contract_spend_gbp
        , SUM(monthly_naive_gross_spend_gbp) OVER (
            PARTITION BY client_id
            ORDER BY month_start_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS naive_cumulative_gross_spend_gbp
    FROM
        monthly_with_naive_spend
)

, output_cte AS (
    SELECT
        client_id
        , month_start_date
        , spend_threshold
        , cumulative_contract_spend_gbp
        , naive_cumulative_gross_spend_gbp
        , CASE
            WHEN cumulative_contract_spend_gbp >= spend_threshold THEN 1
            ELSE 0
        END AS is_threshold_reached
        , CASE
            WHEN naive_cumulative_gross_spend_gbp >= spend_threshold THEN 1
            ELSE 0
        END AS is_naive_threshold_reached
    FROM
        monthly_cumulative
)

SELECT * FROM output_cte
