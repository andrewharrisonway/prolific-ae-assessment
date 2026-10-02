WITH

/* IMPORTS */

monthly AS (
    SELECT
        client_id
        , month_start_date
        , recognised_revenue_gbp
        , originated_revenue_gbp
        , recognised_net_gmv_gbp
        , originated_net_gmv_gbp
        , cumulative_contract_spend_gbp
    FROM
        {{ ref('fct_client_monthly_revenue') }}
)

, transactions AS (
    SELECT
        client_id
        , is_revenue_recognised
        , net_amount_gbp
        , revenue_gbp
        , contract_spend_gbp
    FROM
        {{ ref('fct_transactions') }}
)

/* TRANSFORMATIONS */

, monthly_totals AS (
    SELECT
        client_id
        , SUM(recognised_revenue_gbp) AS recognised_revenue_gbp
        , SUM(originated_revenue_gbp) AS originated_revenue_gbp
        , SUM(recognised_net_gmv_gbp) AS recognised_net_gmv_gbp
        , SUM(originated_net_gmv_gbp) AS originated_net_gmv_gbp
    FROM
        monthly
    GROUP BY
        client_id
)

, last_month AS (
    SELECT MAX(month_start_date) AS month_start_date
    FROM
        monthly
)

, monthly_final_spend AS (
    SELECT
        mly.client_id
        , mly.cumulative_contract_spend_gbp
    FROM
        monthly AS mly
    INNER JOIN
        last_month AS lmo
        ON mly.month_start_date = lmo.month_start_date
)

, transaction_totals AS (
    SELECT
        client_id
        , SUM(revenue_gbp) AS revenue_gbp
        , SUM(
            CASE WHEN is_revenue_recognised = 1 THEN net_amount_gbp ELSE 0 END
        ) AS net_gmv_gbp
        , SUM(contract_spend_gbp) AS contract_spend_gbp
    FROM
        transactions
    GROUP BY
        client_id
)

, output_cte AS (
    SELECT
        mtt.client_id
        , mtt.recognised_revenue_gbp
        , mtt.originated_revenue_gbp
        , ttt.revenue_gbp
        , mtt.recognised_net_gmv_gbp
        , mtt.originated_net_gmv_gbp
        , ttt.net_gmv_gbp
        , mfs.cumulative_contract_spend_gbp
        , ttt.contract_spend_gbp
    FROM
        monthly_totals AS mtt
    INNER JOIN
        transaction_totals AS ttt
        ON mtt.client_id = ttt.client_id
    INNER JOIN
        monthly_final_spend AS mfs
        ON mtt.client_id = mfs.client_id
    WHERE
        ABS(mtt.recognised_revenue_gbp - ttt.revenue_gbp) > 0.001
        OR ABS(mtt.originated_revenue_gbp - ttt.revenue_gbp) > 0.001
        OR ABS(mtt.recognised_net_gmv_gbp - ttt.net_gmv_gbp) > 0.001
        OR ABS(mtt.originated_net_gmv_gbp - ttt.net_gmv_gbp) > 0.001
        OR ABS(
            COALESCE(mfs.cumulative_contract_spend_gbp, 0)
            - COALESCE(ttt.contract_spend_gbp, 0)
        ) > 0.001
)

SELECT * FROM output_cte
