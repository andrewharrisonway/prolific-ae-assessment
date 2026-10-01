WITH RECURSIVE

/* TRANSFORMATIONS */

/*
LOGIC/CHOICES:

A fixed daily spine between the date_spine_start_date and date_spine_end_date
project vars (end exclusive). It does not depend on the data, so it covers any
period a model or MetricFlow needs, including comparisons across years; models
limit it to the period they report on.

NB: not dbt_utils.date_spine, which fails on SQLite: dbt-sqlite's dateadd macro
errors ("no such column: day") and its datediff macro is disabled.
*/

date_spine AS (
    SELECT DATE('{{ var("date_spine_start_date") }}') AS date_day

    UNION ALL

    SELECT DATE(date_day, '+1 day') AS date_day
    FROM
        date_spine
    WHERE
        date_day < DATE('{{ var("date_spine_end_date") }}', '-1 day')
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
