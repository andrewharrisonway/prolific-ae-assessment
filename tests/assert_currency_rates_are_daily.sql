WITH

/* IMPORTS */

currency_rates AS (
    SELECT
        currency
        , rate_date
    FROM
        {{ ref('stg_global_transactions__currency_rates') }}
)

/* TRANSFORMATIONS */

, rates_with_previous_date AS (
    SELECT
        currency
        , rate_date
        , LAG(rate_date) OVER (
            PARTITION BY currency
            ORDER BY rate_date
        ) AS previous_rate_date
    FROM
        currency_rates
)

, output_cte AS (
    SELECT
        currency
        , rate_date
        , previous_rate_date
    FROM
        rates_with_previous_date
    WHERE
        previous_rate_date IS NOT NULL
        AND rate_date != DATE(previous_rate_date, '+1 day')
)

SELECT * FROM output_cte
