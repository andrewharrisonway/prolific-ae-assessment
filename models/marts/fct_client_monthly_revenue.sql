WITH

/* IMPORTS */

transactions AS (
    SELECT
        client_id
        , transaction_date
        , resolution_status
        , resolution_date
        , recognition_date
        , spend_effective_date
        , amount_direction
        , gross_amount_gbp
        , net_amount_gbp
        , is_revenue_recognised
        , is_in_contract_period
        , contract_spend_gbp
        , is_discount_earned
        , revenue_gbp
    FROM
        {{ ref('fct_transactions') }}
)

, months AS (
    SELECT DISTINCT
        month_start_date
        , month_end_date
    FROM
        {{ ref('dim_dates') }}
)

, client_contracts AS (
    SELECT
        client_id
        , contract_start_date
        , contract_end_date
        , spend_threshold
    FROM
        {{ ref('int_client_contracts_windowed') }}
)

/* TRANSFORMATIONS */

/*
LOGIC/CHOICES:

One row per client per month, for every month the data covers (from the first
transaction to the last activity), so months without activity still appear and
running totals carry forward.

Two bases for the same recognised transactions:
- Recognised: revenue lands in the month it is recognised (resolution month
  for chargebacks). Closed months never change. This is the headline basis.
- Originated: revenue lands in the month the transaction happened, counting
  chargebacks resolved as of the latest data, so past months are restated as
  chargebacks resolve.
Both bases contain the same transactions, so their totals per client agree;
pending_chargebacks_gbp shows what is still outstanding at each month end.

NB: the source supplies no client master data, so the clients reported are
those that appear in the transactions.
*/

, data_coverage AS (
    SELECT
        MIN(transaction_date) AS data_start_date
        , MAX(
            MAX(transaction_date), MAX(COALESCE(resolution_date, ''))
        ) AS data_end_date
    FROM
        transactions
)

, reporting_months AS (
    -- NOTE: dim_dates is a fixed, wide spine; report only the months the data
    -- covers
    SELECT
        mth.month_start_date
        , mth.month_end_date
    FROM
        months AS mth
    INNER JOIN
        data_coverage AS dcv
        ON
            mth.month_start_date
            >= DATE(dcv.data_start_date, 'start of month')
            AND mth.month_start_date
            <= DATE(dcv.data_end_date, 'start of month')
)

, clients AS (
    SELECT DISTINCT client_id
    FROM
        transactions
)

, client_months AS (
    SELECT
        cln.client_id
        , rmo.month_start_date
        , rmo.month_end_date
    FROM
        clients AS cln
    CROSS JOIN
        reporting_months AS rmo
)

, recognised_by_month AS (
    SELECT
        client_id
        , DATE(recognition_date, 'start of month') AS month_start_date
        , SUM(
            CASE WHEN amount_direction = 1 THEN gross_amount_gbp ELSE 0 END
        ) AS recognised_gross_gmv_gbp
        , SUM(net_amount_gbp) AS recognised_net_gmv_gbp
        , SUM(revenue_gbp) AS recognised_revenue_gbp
        , COUNT(*) AS recognised_transaction_count
    FROM
        transactions
    WHERE
        is_revenue_recognised = 1
    GROUP BY
        client_id
        , DATE(recognition_date, 'start of month')
)

, originated_by_month AS (
    SELECT
        client_id
        , DATE(transaction_date, 'start of month') AS month_start_date
        , SUM(net_amount_gbp) AS originated_net_gmv_gbp
        , SUM(revenue_gbp) AS originated_revenue_gbp
    FROM
        transactions
    WHERE
        is_revenue_recognised = 1
    GROUP BY
        client_id
        , DATE(transaction_date, 'start of month')
)

, pending_at_month_end AS (
    -- NOTE: a transaction with a resolution status is one that requires
    -- resolution (a chargeback); it is pending at a month end if it happened
    -- by then but was not resolved by then
    SELECT
        cmo.client_id
        , cmo.month_start_date
        , SUM(txn.net_amount_gbp) AS pending_chargebacks_gbp
    FROM
        client_months AS cmo
    INNER JOIN
        transactions AS txn
        ON
            cmo.client_id = txn.client_id
            AND txn.resolution_status IS NOT NULL
            AND cmo.month_end_date >= txn.transaction_date
            AND (
                txn.resolution_date IS NULL
                OR cmo.month_end_date < txn.resolution_date
            )
    GROUP BY
        cmo.client_id
        , cmo.month_start_date
)

, contract_spend_by_month AS (
    SELECT
        client_id
        , DATE(spend_effective_date, 'start of month') AS month_start_date
        , SUM(contract_spend_gbp) AS monthly_contract_spend_gbp
    FROM
        transactions
    WHERE
        contract_spend_gbp IS NOT NULL
    GROUP BY
        client_id
        , DATE(spend_effective_date, 'start of month')
)

, naive_spend_by_month AS (
    -- NOTE: the naive measure: every transaction in the contract window at its
    -- gross amount, whatever its type. Kept for comparison only.
    SELECT
        client_id
        , DATE(transaction_date, 'start of month') AS month_start_date
        , SUM(gross_amount_gbp) AS monthly_naive_gross_spend_gbp
    FROM
        transactions
    WHERE
        is_in_contract_period = 1
    GROUP BY
        client_id
        , DATE(transaction_date, 'start of month')
)

, discount_earned AS (
    SELECT
        client_id
        , CAST(MIN(spend_effective_date) AS text) AS discount_earned_date
    FROM
        transactions
    WHERE
        is_discount_earned = 1
    GROUP BY
        client_id
)

, client_months_combined AS (
    SELECT
        cmo.client_id
        , cmo.month_start_date
        , cmo.month_end_date
        , cct.contract_start_date
        , cct.contract_end_date
        , cct.spend_threshold
        , dse.discount_earned_date
        , cmo.month_end_date > dcv.data_end_date AS is_partial_month
        , COALESCE(rbm.recognised_gross_gmv_gbp, 0) AS recognised_gross_gmv_gbp
        , COALESCE(rbm.recognised_net_gmv_gbp, 0) AS recognised_net_gmv_gbp
        , COALESCE(rbm.recognised_revenue_gbp, 0) AS recognised_revenue_gbp
        , COALESCE(
            rbm.recognised_transaction_count, 0
        ) AS recognised_transaction_count
        , COALESCE(obm.originated_net_gmv_gbp, 0) AS originated_net_gmv_gbp
        , COALESCE(obm.originated_revenue_gbp, 0) AS originated_revenue_gbp
        , COALESCE(pme.pending_chargebacks_gbp, 0) AS pending_chargebacks_gbp
        -- NOTE: contract measures are null for clients without a contract
        , CASE
            WHEN cct.client_id IS NOT NULL
                THEN COALESCE(csm.monthly_contract_spend_gbp, 0)
        END AS monthly_contract_spend_gbp
        , CASE
            WHEN cct.client_id IS NOT NULL
                THEN COALESCE(nsm.monthly_naive_gross_spend_gbp, 0)
        END AS monthly_naive_gross_spend_gbp
    FROM
        client_months AS cmo
    CROSS JOIN
        data_coverage AS dcv
    LEFT JOIN
        client_contracts AS cct
        ON cmo.client_id = cct.client_id
    LEFT JOIN
        discount_earned AS dse
        ON cmo.client_id = dse.client_id
    LEFT JOIN
        recognised_by_month AS rbm
        ON
            cmo.client_id = rbm.client_id
            AND cmo.month_start_date = rbm.month_start_date
    LEFT JOIN
        originated_by_month AS obm
        ON
            cmo.client_id = obm.client_id
            AND cmo.month_start_date = obm.month_start_date
    LEFT JOIN
        pending_at_month_end AS pme
        ON
            cmo.client_id = pme.client_id
            AND cmo.month_start_date = pme.month_start_date
    LEFT JOIN
        contract_spend_by_month AS csm
        ON
            cmo.client_id = csm.client_id
            AND cmo.month_start_date = csm.month_start_date
    LEFT JOIN
        naive_spend_by_month AS nsm
        ON
            cmo.client_id = nsm.client_id
            AND cmo.month_start_date = nsm.month_start_date
)

, client_months_cumulative AS (
    SELECT
        client_id
        , month_start_date
        , month_end_date
        , contract_start_date
        , contract_end_date
        , spend_threshold
        , discount_earned_date
        , is_partial_month
        , recognised_gross_gmv_gbp
        , recognised_net_gmv_gbp
        , recognised_revenue_gbp
        , recognised_transaction_count
        , originated_net_gmv_gbp
        , originated_revenue_gbp
        , pending_chargebacks_gbp
        , monthly_contract_spend_gbp
        , SUM(monthly_contract_spend_gbp) OVER (
            PARTITION BY client_id
            ORDER BY month_start_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_contract_spend_gbp
        , SUM(monthly_naive_gross_spend_gbp) OVER (
            PARTITION BY client_id
            ORDER BY month_start_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS naive_cumulative_gross_spend_gbp
    FROM
        client_months_combined
)

, client_months_status AS (
    -- NOTE: contract and discount status are as at the month end
    SELECT
        client_id
        , month_start_date
        , month_end_date
        , spend_threshold
        , is_partial_month
        , recognised_gross_gmv_gbp
        , recognised_net_gmv_gbp
        , recognised_revenue_gbp
        , recognised_transaction_count
        , originated_net_gmv_gbp
        , originated_revenue_gbp
        , pending_chargebacks_gbp
        , monthly_contract_spend_gbp
        , cumulative_contract_spend_gbp
        , naive_cumulative_gross_spend_gbp
        -- NOTE: only shown once the threshold has been reached by month end
        , CAST(
            CASE
                WHEN discount_earned_date <= month_end_date
                    THEN discount_earned_date
            END AS text
        ) AS discount_earned_date
        , CAST(
            CASE
                WHEN contract_start_date IS NULL THEN 'no contract'
                WHEN month_end_date < contract_start_date THEN 'not started'
                WHEN month_end_date >= contract_end_date THEN 'ended'
                ELSE 'active'
            END AS text
        ) AS contract_status
        -- NOTE: CAST avoids SQLite integer division when both values are whole
        , ROUND(
            CAST(cumulative_contract_spend_gbp AS real) / spend_threshold, 4
        ) AS pct_of_spend_threshold
        , CASE
            WHEN contract_start_date IS NULL THEN NULL
            WHEN
                month_end_date >= contract_start_date
                AND month_end_date < contract_end_date
                AND discount_earned_date <= month_end_date
                THEN 1
            ELSE 0
        END AS is_discount_active
        , CASE
            WHEN contract_start_date IS NULL THEN NULL
            WHEN naive_cumulative_gross_spend_gbp >= spend_threshold THEN 1
            ELSE 0
        END AS is_naive_threshold_reached
    FROM
        client_months_cumulative
)

, output_cte AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(
            ['client_id', 'month_start_date']
        ) }} AS client_month_id
        , client_id
        , month_start_date
        , month_end_date
        , is_partial_month
        , recognised_gross_gmv_gbp
        , recognised_net_gmv_gbp
        , recognised_revenue_gbp
        , recognised_transaction_count
        , originated_net_gmv_gbp
        , originated_revenue_gbp
        , pending_chargebacks_gbp
        , contract_status
        , spend_threshold
        , monthly_contract_spend_gbp
        , cumulative_contract_spend_gbp
        , pct_of_spend_threshold
        , discount_earned_date
        , is_discount_active
        , naive_cumulative_gross_spend_gbp
        , is_naive_threshold_reached
    FROM
        client_months_status
)

SELECT * FROM output_cte
