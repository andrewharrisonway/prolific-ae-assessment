WITH RECURSIVE

/* IMPORTS */

transactions AS (
    SELECT
        transaction_date
        , resolution_date
    FROM
        {{ ref('int__transactions') }}
)

/* TRANSFORMATIONS */

, date_bounds AS (
    -- NOTE: whole months, from the first month with a transaction to the last
    -- month with any activity (transactions or chargeback resolutions)
    SELECT
        DATE(MIN(transaction_date), 'start of month') AS first_date
        , DATE(
            MAX(MAX(transaction_date), MAX(COALESCE(resolution_date, '')))
            , 'start of month'
            , '+1 month'
            , '-1 day'
        ) AS last_date
    FROM
        transactions
)

, date_spine AS (
    SELECT first_date AS date_day
    FROM date_bounds

    UNION ALL

    SELECT DATE(dsp.date_day, '+1 day') AS date_day
    FROM
        date_spine AS dsp
    INNER JOIN
        date_bounds AS dbd
        ON dsp.date_day < dbd.last_date
)

, output_cte AS (
    SELECT
        CAST(date_day AS text) AS date_day
        , CAST(DATE(date_day, 'start of month') AS text) AS month_start_date
        , CAST(
            DATE(date_day, 'start of month', '+1 month', '-1 day') AS text
        ) AS month_end_date
    FROM
        date_spine
)

SELECT * FROM output_cte
