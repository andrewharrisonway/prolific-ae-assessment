WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(
            from=source('global_transactions', 'transaction_resolutions')
        ) }}
    FROM
        {{ source('global_transactions', 'transaction_resolutions') }}
)

, typed AS (
    SELECT
        CAST(transaction_id AS varchar(10)) AS transaction_id
        , CAST(resolution_status AS varchar(10)) AS resolution_status
        -- NOTE: date reformatted from dd/mm/yyyy to ISO date
        , CAST(
            CASE
                WHEN NULLIF(resolution_date, '') IS NULL THEN NULL
                ELSE DATE(
                    SUBSTR(resolution_date, 7, 4)
                    || '-' || SUBSTR(resolution_date, 4, 2)
                    || '-' || SUBSTR(resolution_date, 1, 2)
                )
            END AS text
        ) AS resolution_date
    FROM raw_input
)

SELECT * FROM typed
