# Global Transactions

A dbt project that models transaction data for a global marketplace: staging and cleaning the raw sources, converting all amounts to GBP, applying contracted platform fee discounts, and producing monthly revenue recognition by client.

The original brief is in [task_instructions.md](task_instructions.md).

## Getting started

### Prerequisites

- Python 3.11
- **SQLite ≥ 3.48.** The intermediate layer uses the multi-argument `IF()` function, which was added in SQLite 3.48. `dbt-sqlite` uses the SQLite library that is bundled with your Python, not one installed via pip, so check it before running anything:

  ```bash
  python -c "import sqlite3; print(sqlite3.sqlite_version)"
  ```

  On an older version, `dbt build` still succeeds (SQLite does not validate functions when a view is created), but querying `int__transactions` fails with `no such function: IF`. Python installs managed by [uv](https://docs.astral.sh/uv/) ship a recent SQLite and are the simplest fix.

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
dbt build
```

The raw source tables live in the pre-built database at `target/global_transactions.db`, and models are written back to the same file.

> **Do not run `dbt clean`.** `target/` is listed in `clean-targets`, so it would delete the database along with the source data.

## Project structure

```
models/
├── raw/            sources.yml: the four pre-built raw tables
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
client_contracts ─────────┘
```

## Business logic and assumptions

### Transaction types

| Type | Revenue | Counts towards contract spend |
|---|---|---|
| `payment` | Positive | Yes |
| `refund` | Negative (amount is negated) | Yes, reduces spend |
| `fraud` | Excluded (zero) | No |
| `chargeback` | Positive, **only once resolved**; pending chargebacks contribute zero | Yes, from the resolution date |

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
