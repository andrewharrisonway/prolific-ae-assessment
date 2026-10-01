# Global Transactions

A dbt project that models transaction data for a global marketplace: staging and cleaning the raw sources, converting all amounts to GBP, applying contracted platform fee discounts, and producing monthly revenue recognition by client.

The original brief is in [task_instructions.md](task_instructions.md).

## Getting started

### Prerequisites

- Python 3.11

### Setup

```bash
uv venv dbt-env --python 3.11
source dbt-env/bin/activate
uv pip install -r requirements.txt
dbt deps
```

`profiles.yml` is included in the project root, so no changes to `~/.dbt` are needed.

### Running

```bash
dbt seed
dbt build
```

Everything is written to a SQLite database at `target/global_transactions.db`, which is created on the first run. The database is disposable: `dbt clean` deletes it (along with installed packages), and `dbt deps` followed by `dbt seed` rebuilds it.

Run `dbt seed` before `dbt build`. Models read the raw tables through `source()`, which creates no dependency on the seeds in dbt's graph, so on a fresh database `dbt build` alone runs the staging models before the raw tables exist, and they fail.

### Why the raw data is loaded as seeds

The brief supplies the raw data as dbt seeds. Seeds are intended for small, static reference data, and in production raw data would arrive through an extract-and-load tool rather than dbt. To keep the models production-shaped:

- `seeds/raw/` stands in for that load step: `dbt seed` lands the four raw tables in the warehouse, with column types pinned so they match the data as delivered.
- Models only read raw data through `source()` (declared in `models/raw/sources.yml`), never `ref()`. Swapping the seeds for a real loader would need no model changes.
- `seeds/reference/` holds genuine seed data: the `transaction_types` business rules.

## Project structure

```
seeds/
├── raw/            the four raw data files, loaded by dbt seed (stand-in for extract-and-load)
└── reference/      transaction_types.csv: business rules per transaction type (see below)
macros/
└── sqlite__hash.sql   makes surrogate keys work on SQLite, which has no md5()
models/
├── docs/           shared column descriptions (dbt doc blocks), used across the yml files
├── raw/            sources.yml: declares the raw tables loaded from seeds/raw/
├── staging/        one model per source: typing, renaming, date fixes, tests
│   ├── currencies/
│   ├── clients/
│   └── transactions/
├── intermediate/   int__client_contracts: contract windows
│                   int__transactions: GBP conversion, contract discounts, revenue per transaction
└── marts/          dim_dates, fct_transactions, fct_client_monthly_revenue, semantic layer
tests/              singular tests: daily exchange rates, monthly mart reconciliation
```

| Layer | Materialisation | Purpose |
|---|---|---|
| staging | table | Clean and type each source; the bulk of data quality testing lives here |
| intermediate | view | Transaction-grain business logic |
| marts | table | Reporting outputs: facts (`fct_`) and dimensions (`dim_`) |

### Lineage

```
transactions ─────────────┐
transaction_resolutions ──┤
currency_rates ───────────┼──► int__transactions ──► fct_transactions ──► fct_client_monthly_revenue
transaction_types (seed) ─┘          ▲                                     ▲  ▲
client_contracts ──► int__client_contracts ────────────────────────────────┘  │
                                     int__transactions ──► dim_dates ─────────┘
```

## Marts

| Model | Grain | Purpose |
|---|---|---|
| `fct_client_monthly_revenue` | client × month | The deliverable: monthly revenue recognition, GMV in GBP, spend threshold tracking and discount status |
| `fct_transactions` | transaction | Transaction-level fact behind the monthly mart and the semantic layer |
| `dim_dates` | day | Date spine generated from the data: the month spine for the mart and the MetricFlow time spine |

**Every client appears in every month** (January to July 2024), so months without activity still show, and running totals carry forward. July is flagged `is_partial_month`: the data ends on 6 July, and the month contains only refunds and chargeback resolutions.

**Revenue is reported on two bases**, over the same recognised transactions:

- **Recognised** (`recognised_*`), the headline: revenue lands in the month it is recognised, which for chargebacks is the month they resolve. A closed month never changes.
- **Originated** (`originated_*`): revenue lands in the month the transaction happened, counting chargebacks resolved as of the latest data, so past months are restated as chargebacks resolve.
- `pending_chargebacks_gbp` shows chargebacks still unresolved at each month end. Per client, the two bases total to the same figures; a singular test checks this against `fct_transactions`.

**GMV** is reported gross (money in: payments and resolved chargebacks) and net (after refunds). Fraud, pending chargebacks and duplicate refunds are excluded from both.

**Spend threshold tracking and discount status** are as at each month end: contract status (`no contract`, `not started`, `active`, `ended`), contract spend for the month and to date, progress towards the threshold, the date the threshold was reached, and whether the discount is active.

### Semantic layer

`models/marts/semantic_models.yml` defines MetricFlow measures and metrics on `fct_transactions`: revenue, net and gross GMV, take rate and transaction count, by recognition or transaction date, sliceable by client, type and currency. This shows how the additive measures would be defined once, so any slice can be queried without a new mart. MetricFlow cannot query SQLite, so the definitions are validated by `dbt parse` but cannot be run here. Stateful measures (contract spend against threshold, discount status, pending chargebacks at month end) are not simple aggregates, so they live in `fct_client_monthly_revenue`.

## Business logic and assumptions

### Transaction types

How each transaction type behaves is defined as data in the [`transaction_types`](seeds/reference/transaction_types.csv) seed, not in model logic:

| Type | `amount_direction` | `recognises_revenue` | `counts_toward_spend` | `requires_resolution` |
|---|---|---|---|---|
| `payment` | 1 | 1 | 1 | 0 |
| `refund` | -1 | 1 | 1 | 0 |
| `chargeback` | 1 | 1 | 1 | 1 |
| `fraud` | 1 | 0 | 0 | 0 |

- Refunds are negated, so they reduce both revenue and contract spend.
- Fraud contributes nothing to revenue or spend.
- Chargebacks count only once resolved, and towards spend from their resolution date. Pending chargebacks contribute zero.

`int__transactions` keeps both the recorded amount (`gross_amount_*`, always positive) and the signed amount (`net_amount_*`). Revenue is `net_amount_gbp × applicable_fee_margin` for recognised transactions, and 0 otherwise.

With four types, a seed is more structure than strictly needed. It is used deliberately: the business rules sit in one reviewable file, the staging model validates transaction types against it, and adding or changing a type becomes a data change rather than a logic change.

Every refund links to a payment from the same client, in the same currency, for exactly the full payment amount. Chargebacks have no linked transaction and are treated as standalone events.

### Duplicate refunds

Six payments are refunded more than once (one of them three times): 7 refunds in total, worth £175,166 of GMV and £35,033 of revenue. Because every refund is for the full payment amount, a second refund of the same payment cannot be genuine, so:

- Only the first refund of each payment (by date, then transaction ID) counts.
- Later refunds are flagged `is_duplicate_refund` in staging (`stg_transactions__transactions`), which describes the source data without filtering it. `int__transactions` then excludes flagged refunds from revenue and contract spend. The rows are kept, so the exclusion is visible and can be reported.
- A `unique` test on `linked_transaction_id` in staging catches payments refunded more than once. It is set to warn, because the raw data does contain these duplicates.

### Currency conversion

- All amounts are converted to GBP using the latest available rate **on or before** the transaction date.
- Exchange rates end on 2024-06-30 but transactions run into July 2024, so the last available rate is carried forward.
- Chargebacks are converted at the rate on their transaction date, even when their revenue is recognised later, in the month they resolve.
- Refunds are converted at the rate on the refund date, not the original payment's rate. The client is refunded the full amount in the currency they paid, so the GBP cost of the refund is whatever that amount is worth on the day. Any difference from exchange-rate movement between payment and refund is treated as a cost of doing business, not something to pass on to the client. In this data, USD payment and refund pairs leave a net +£1,486 of GMV (+£297 revenue) from rate movement.

### Contract discounts

- Four clients (C001–C004) have contracts; the remaining clients pay the standard platform fee margin.
- A contract is active from `contract_start_date` (inclusive) for `contract_duration_months` (end date exclusive).
- Cumulative qualifying spend in GBP is tracked within the contract window, ordered by the date each transaction takes effect (resolution date for chargebacks). Fraud and pending chargebacks do not count.
- A refund only reduces contract spend if the payment it reverses counted toward it, i.e. the payment fell inside the contract window. For example, C004's contract starts on 2024-03-01, and a refund on that day of a February payment (£64,580) does not reduce C004's spend, because the payment was never added to it.
- Once cumulative spend reaches `spend_threshold`, the discounted fee margin applies for the remainder of the contract term. The discount applies from the transaction that crosses the threshold.
- **Assumption:** `spend_threshold` is in GBP. The contracts table does not state a currency, and each client transacts in both GBP and USD.

### Data quality fixes

- `transaction_resolutions.resolution_date` arrives as `dd/mm/yyyy`; it is converted to an ISO date in staging.
- Duplicate refunds are flagged and excluded (see above).

## Known findings

- **Duplicate refunds:** 6 payments were refunded more than once; the 7 extra refunds are excluded (see Duplicate refunds above). `dbt build` reports this as one expected warning.
- **No client or currency reference data.** The source supplies no client master data and no currency list. Client IDs can only be validated by format, not checked against a list of real clients, and currencies are checked against those that have exchange rates. This is treated as a data quality gap in what was supplied: a client dimension is deliberately not deduced from transaction data, because a list built from the transactions would always agree with them and so could never catch an unknown client.
- **No discount triggers during the period of observation.** No contracted client reaches its spend threshold within the data provided, so the discounted margin is never applied. The logic is implemented as I understand the business rules, rather than adjusted to make the discount trigger. Because that seemed odd, I also tried a more naive calculation: every transaction in the contract window at its gross amount, whatever its type. It does reach the threshold, for C001 and C002 in June 2024, and it is exposed in `fct_client_monthly_revenue` (`naive_cumulative_gross_spend_gbp`, `is_naive_threshold_reached`) for comparison. It works, but I don't defend it from a business standpoint: it counts fraud and refunds as spend.

## Testing

Tests are defined in each layer's `schema.yml` and run with `dbt build` or `dbt test`. Coverage includes:

- Uniqueness, not-null and ID format checks
- Relationships between transactions, refunds, resolutions and currencies
- Conditional rules, e.g. only refunds have a linked transaction, and only resolved chargebacks have a resolution date
- Hard and soft (warning) ranges on fee margins and exchange rates
- Unit tests (`unit_tests.yml` in `intermediate/` and `marts/`) on small hand-built fixtures, for logic the real data never exercises: the discount crossing the threshold and expiring, refunds of pre-contract payments, chargebacks moving between months, and contract and discount status by month
- Singular tests in `tests/`: exchange rates are daily with no gaps, and the monthly mart reconciles to `fct_transactions`

SQL style is enforced with SQLFluff (`.sqlfluff`):

```bash
sqlfluff lint models
```

## Status

- [x] Staging models and tests
- [x] Intermediate transaction model
- [x] Recognise chargeback revenue in the month of resolution
- [x] Monthly revenue mart: revenue by client and month, GMV in GBP, spend threshold tracking, discount status
- [x] Tests on the intermediate and mart layers
- [x] Semantic layer definitions
