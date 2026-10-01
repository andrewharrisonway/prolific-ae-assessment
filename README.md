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
├── raw/            sources.yml: declares the raw tables loaded from seeds/raw/
├── staging/        one model per source: typing, renaming, date fixes, tests
│   ├── currencies/
│   ├── customers/
│   └── transactions/
├── intermediate/   int__transactions: GBP conversion, contract discounts, revenue per transaction
└── marts/          monthly revenue by client (in progress)
```

| Layer | Materialisation | Purpose |
|---|---|---|
| staging | table | Clean and type each source; the bulk of data quality testing lives here |
| intermediate | view | Transaction-grain business logic |
| marts | table | Reporting outputs |

### Lineage

```
transactions ─────────────┐
transaction_resolutions ──┤
currency_rates ───────────┼──► int__transactions ──► (marts)
client_contracts ─────────┤
transaction_types (seed) ─┘
```

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

`int__transactions` keeps both the recorded amount (`gross_amount_*`, always positive) and the signed amount (`net_amount_*`). Revenue is `net_amount_gbp × applicable_fee_margin × is_revenue_recognised`.

With four types, a seed is more structure than strictly needed. It is used deliberately: the business rules sit in one reviewable file, the staging model validates transaction types against it, and adding or changing a type becomes a data change rather than a logic change.

All refunds link to a payment from the same client, in the same currency, for no more than the original amount. Chargebacks have no linked transaction and are treated as standalone events.

### Currency conversion

- All amounts are converted to GBP using the latest available rate **on or before** the transaction date.
- Exchange rates end on 2024-06-30 but transactions run into July 2024, so the last available rate is carried forward.

### Contract discounts

- Four clients (C001–C004) have contracts; the remaining clients pay the standard platform fee margin.
- A contract is active from `contract_start_date` (inclusive) for `contract_duration_months` (end date exclusive).
- Cumulative qualifying spend in GBP is tracked within the contract window, ordered by the date each transaction takes effect (resolution date for chargebacks). Fraud and pending chargebacks do not count.
- Once cumulative spend reaches `spend_threshold`, the discounted fee margin applies for the remainder of the contract term. The discount applies from the transaction that crosses the threshold.
- **Assumption:** `spend_threshold` is in GBP. The contracts table does not state a currency, and each client transacts in both GBP and USD.

### Data quality fixes

- `transaction_resolutions.resolution_date` arrives as `dd/mm/yyyy`; it is converted to an ISO date in staging.

## Known findings

- **No contracted client reaches its spend threshold** under the logic above, so the discounted margin is never applied in this dataset. The logic is implemented as I understand the business rules, rather than adjusted to make the discount trigger. A naive gross-GMV measure (all transaction types summed) does cross the threshold for C001 and C002; this will be exposed in the mart for comparison but is not the recommended definition.

## Testing

Tests are defined in each layer's `schema.yml` and run with `dbt build` or `dbt test`. Coverage includes:

- Uniqueness, not-null and ID format checks
- Relationships between transactions, refunds, resolutions and currencies
- Conditional rules, e.g. only refunds have a linked transaction, and only resolved chargebacks have a resolution date
- Hard and soft (warning) ranges on fee margins and exchange rates

SQL style is enforced with SQLFluff (`.sqlfluff`):

```bash
sqlfluff lint models
```

## Status

- [x] Staging models and tests
- [x] Intermediate transaction model
- [ ] Recognise chargeback revenue in the month of resolution
- [ ] Monthly revenue mart: revenue by client and month, GMV in GBP, spend threshold tracking, discount status
- [ ] Tests on the intermediate and mart layers
