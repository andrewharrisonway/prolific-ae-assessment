WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(
            from=source('global_transactions', 'client_contracts')
        ) }}
    FROM
        {{ source('global_transactions', 'client_contracts') }}
)

, typed AS (
    SELECT
        CAST(client_id AS varchar(7)) AS client_id
        , CAST(contract_duration_months AS integer) AS contract_duration_months
        , CAST(spend_threshold AS numeric(12, 2)) AS spend_threshold
        , CAST(discounted_fee_margin AS numeric(4, 3)) AS discounted_fee_margin
        , CAST(DATE(contract_start_date) AS text) AS contract_start_date
    FROM raw_input
)

SELECT * FROM typed
