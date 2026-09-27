WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(from=source('global_transactions', 'transaction_resolutions')) }}
    FROM
        {{ source('global_transactions', 'transaction_resolutions') }}
)

, typed AS (
    SELECT
        CAST(transaction_id AS varchar(10)) AS transaction_id
        , CAST(resolution_status AS varchar(10)) AS resolution_status
        , CASE
            WHEN NULLIF(resolution_date, '') IS NULL THEN NULL
            ELSE DATE(
                substr(resolution_date, 7, 4) || '-' || substr(resolution_date, 4, 2) || '-' || substr(resolution_date, 1, 2)
            )
          END AS resolution_date -- date reformatted from dd/mm/yyyy to ISO date
    FROM raw_input
)

SELECT * FROM typed