{% docs __overview__ %}
# Global Transactions

Monthly revenue recognition for a global marketplace: raw transactions are cleaned, converted to GBP, priced with each client's contracted fee margin, and reported by client and month.

## Start here

| Model | Grain | What it answers |
|---|---|---|
| `fct_client_monthly_revenue` | client × month | Revenue and GMV in GBP by client and month, chargebacks pending at month end, and contract spend against each client's discount threshold |
| `fct_transactions` | transaction | Every transaction with its GBP amounts, fee margin, revenue and recognition date; the basis of the semantic layer metrics |
| `dim_dates` | day | Fixed calendar from 2020 to 2030 |

## How the data flows

1. **Sources:** four raw tables (transactions, chargeback resolutions, daily exchange rates, client contracts), loaded by `dbt seed` as a stand-in for an extract-and-load tool.
2. **Staging** (`stg_global_transactions__*`): one model per raw table; typing, renaming, date fixes and most data quality tests.
3. **Intermediate** (`int_<entity>_<verb>`): the business logic, one step per model: contract windows, classifying transactions, GBP conversion, contract spend and discounts, then revenue.
4. **Marts** (`fct_*`, `dim_*`): the tables to query.

How each transaction type behaves (sign, revenue, spend, resolution) is defined in the `transaction_types` seed.

## Key rules

- **Revenue is recognised** in the month it takes effect: the resolution month for chargebacks, the transaction month otherwise. The `originated_*` columns show the same transactions by the month they happened.
- **Refunds** reverse revenue (at the margin the original payment was charged at) and spend. **Resolved chargebacks** also reverse revenue, GMV and spend, in the month they resolve. **Fraud** and **pending chargebacks** count toward neither.
- **GBP conversion** uses the latest rate on or before the transaction date.
- **Contract discounts** apply once a client's spend within the contract term reaches its threshold, for the rest of the term. A refund or chargeback only reduces contract spend if what it reverses counted toward it.

## Known findings

- **No discount triggers during the period of observation:** no contracted client reaches its threshold. A naive measure would cross it for C001 and C002; it is kept for comparison only, as the `naive_threshold_comparison` analysis, not in any model.
- **Duplicate refunds:** 6 payments were refunded more than once; the 7 extra refunds are flagged (`is_duplicate_refund`) and excluded.
- **No client or currency reference data** is supplied, so client IDs are validated by format only.
- **July 2024 is a partial month** (`is_partial_month`): the data ends on 6 July.

## Reading these docs

- Columns tagged `meta.additivity: semi_additive` are positions at month end: sum them across clients, never across months. `non_additive` columns should never be summed.
- Each column is tested once, in the layer where it is created or changed.

The full write-up, including assumptions and setup, is in the [project README](https://github.com/andrewharrisonway/prolific-ae-assessment#readme).
{% enddocs %}
