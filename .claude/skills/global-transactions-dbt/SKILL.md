---
name: global-transactions-dbt
description: SQL structure, naming, testing and workflow conventions for the global_transactions dbt project (SQLite). Use this skill whenever writing, editing, reviewing or debugging any model, properties yml file, source, test or docs page in this repo, including staging, intermediate and mart models, ad-hoc analysis queries against target/global_transactions.db, or questions about how revenue, GBP conversion, chargebacks or contract discounts are calculated, even if the user doesn't mention conventions or style.
---

# Global Transactions dbt conventions

This project models marketplace transactions in dbt on SQLite: raw sources → staging → intermediate → marts. The goal is SQL that a reviewer can read top to bottom and trust: every model follows the same shape, every business decision is visible in the code, and every assumption is tested or written down.

The business rules themselves live in `README.md` (section "Business logic and assumptions"). Read it before changing any revenue, spend or discount logic, and update it in the same change if a rule changes. This skill covers how the code is written; the README covers what it computes.

## Model structure

Every model follows the same four-part shape: **imports (with filters) → processing CTEs → `output_cte` → `SELECT * FROM output_cte`**.

```sql
WITH

/* IMPORTS */

transactions AS (
    SELECT
        transaction_id
        , client_id
        , transaction_amount AS transaction_amount_local
        , transaction_currency
        , transaction_date
    FROM
        {{ ref('stg_global_transactions__transactions') }}
    WHERE
        transaction_type = 'chargeback'
)

, transaction_resolutions AS (
    SELECT
        transaction_id
        , resolution_date
    FROM
        {{ ref('stg_global_transactions__transaction_resolutions') }}
    WHERE
        resolution_status = 'resolved'
)

/* TRANSFORMATIONS */

, resolved_chargebacks AS (
    -- one logical step per CTE, named for what it produces
    SELECT
        txn.transaction_id
        , txn.client_id
        , txn.transaction_amount_local
        , txn.transaction_currency
        , trl.resolution_date
    FROM
        transactions AS txn
    INNER JOIN
        transaction_resolutions AS trl
        ON txn.transaction_id = trl.transaction_id
)

, output_cte AS (
    SELECT
        transaction_id
        , client_id
        , transaction_amount_local
        , transaction_currency
        , resolution_date
    FROM
        resolved_chargebacks
)

SELECT * FROM output_cte
```

Why each part matters:

- **Import CTEs first, one per upstream model, with explicit columns.** The top of the file then documents exactly which columns the model depends on, and renames (e.g. `transaction_amount AS transaction_amount_local`) happen once, at the boundary. Never `ref()` or `source()` anywhere except an import CTE.
- **Filter in the import CTE.** If a model only ever needs a subset of an upstream model (resolved chargebacks, a single currency, in-contract clients), apply that `WHERE` in the import, not in a later step. The scope of the model is then visible at the top of the file, and every downstream CTE works on the smaller set. Filters that depend on a join or a calculated column belong in the processing CTE where that column first exists.
- **One processing step per CTE, named descriptively** (`transactions_negated_enriched`, `transactions_cumulative`). A reviewer can follow the logic by reading CTE names alone, and each step can be inspected with `dbt show`.
- **End with `output_cte` and `SELECT * FROM output_cte`.** The final CTE lists the output columns explicitly, so the model's contract is in one place. `SELECT *` is only acceptable in that final line, or in a staging `raw_input` CTE.
- **Put a `/* LOGIC/CHOICES */` block comment above complex transformations** stating the business rules being applied, in plain English.

### Staging models

Staging models are the only place raw data is cleaned. Start with these two CTEs:

```sql
WITH

raw_input AS (
    SELECT
        {{ dbt_utils.star(from=source('global_transactions', 'currency_rates')) }}
    FROM
        {{ source('global_transactions', 'currency_rates') }}
)

, typed AS (
    SELECT
        CAST(currency AS varchar(3)) AS currency
        , DATE(rate_date) AS rate_date
        , CAST(exchange_rate_to_gbp AS numeric(8, 4)) AS exchange_rate_to_gbp
    FROM raw_input
)

SELECT * FROM typed
```

If the source has no single-column primary key, add a third CTE, `keyed`, after `typed`: it generates a surrogate key with `dbt_utils.generate_surrogate_key` from the typed columns, named `<entity>_id` and placed first (see `stg_global_transactions__currency_rates`). The key is the model's primary key and gets `unique` + `not_null` tests.

In `typed`: cast every column, rename to project naming, fix formats (e.g. `dd/mm/yyyy` → ISO date). No joins, filters or business logic: staging should be a faithful, typed copy of the source, so problems in the data surface as test failures rather than being silently filtered out.

**Data quality flags belong in staging, as their own CTE after `typed` (e.g. `flagged`).** A flag that describes the source rows themselves, derived from that one source table without joins, is additive: it adds a column but never filters rows or changes the grain. For example, `is_duplicate_refund` in `stg_global_transactions__transactions` marks every refund after the first for the same payment. Staging only labels the row; deciding what a flag means for revenue, spend or anything else belongs in intermediate. Test the flag in staging, next to the column tests that rest on the same assumption.

## Formatting

These match `.sqlfluff`; run the linter rather than relying on memory.

- **Uppercase** keywords, functions and literals: `SELECT`, `LEFT JOIN`, `COALESCE`, `DATE()`, `NULL`, `TRUE`.
- **Leading commas**, both for columns and between CTEs (`, next_cte AS (`). Adding or removing a line then touches only that line.
- **4-space indentation.** Clause bodies go on their own line, indented under `SELECT`, `FROM`, `JOIN`. `ON` aligns with the joined table; when a join has several conditions, put `ON` on its own line and indent the conditions beneath it.
- **Always use `AS`** for column and table aliases.
- **Table aliases** follow the rules in the next section.
- **Jinja with inner spaces:** `{{ ref('model_name') }}`, not `{{ref('model_name')}}`.
- **Lines are at most 80 characters** (SQLFluff default). Break long function calls, `CASE` and window expressions across lines, and put explanatory comments on their own line above the code rather than trailing it.

### Table aliases

Whether a query (or CTE) has a join decides everything:

- **No join: no aliases.** Reference columns bare (`transaction_id`, not `txn.transaction_id`). An alias in a single-table query is noise.
- **Any join: every table gets an alias, and every column is qualified with it,** including in `SELECT`, `ON`, `WHERE`, `GROUP BY` and window clauses. Then a reader never has to work out which side a column comes from.
- **Aliases are at least 3 characters,** lowercase.
- **An alias must not be a substring of the table or CTE it refers to, or of a common word in the project.** A substring reads as a truncated word rather than a deliberate abbreviation, and it collides easily as more tables are added. Build the alias from consonants or initials instead.

| Table / CTE | Good | Bad (and why) |
|---|---|---|
| `transactions` | `txn` | `tra`, `trans` (substrings of `transactions`) |
| `transaction_resolutions` | `trl` | `res` (substring; also of `resolution`) |
| `currency_rates` | `crt` | `cur`, `rat` (substrings) |
| `client_contracts` | `cct` | `cli`, `con` (substrings; `con` is also in `contract`) |
| `transactions_negated_enriched` | `tne` | `neg` (substring) |

Common project words to check against include: transaction, client, contract, currency, rate, resolution, revenue, payment, refund, chargeback, fraud, spend, threshold, discount, margin, amount, date. So `rev`, `pay` and `ref` are out, because each is a substring of one of these words. `amt` is fine: it abbreviates `amount` but is not a substring of it.

The same rules apply to subqueries: give an inner reference its own alias, distinct from the outer one (e.g. an inner `currency_rates` as `cr2` when the outer one is `crt`). Avoid correlated subqueries for "latest value as of a date" lookups altogether (see SQLite specifics).

Column aliases (`AS transaction_amount_gbp`) are a separate thing: always use `AS` for them, regardless of joins.

## Naming

| Thing | Convention | Example |
|---|---|---|
| Staging model | `stg_<source>__<table>`, where `<source>` is the source system's name | `stg_global_transactions__transaction_resolutions` |
| Intermediate model | `int_<entity>_<verb>`: one step of business logic per model, named for what it does | `int_transactions_converted_to_gbp` |
| Mart fact | `fct_<grain>`: events or measures at a stated grain | `fct_client_monthly_revenue`, `fct_transactions` |
| Mart dimension | `dim_<entity>`: one row per entity, descriptive attributes | `dim_dates` |
| Staging folder | one per source system, holding its staging models, `_<source>__sources.yml` and `_<source>__models.yml` | `models/staging/global_transactions/` |
| Money columns | suffix with currency basis | `transaction_amount_local`, `revenue_gbp` |
| Booleans | `is_` / `has_` prefix | `is_in_contract_period`, `is_discount_earned` |
| Dates | `_date` suffix | `transaction_date`, `resolution_date` |
| Keys | `_id` suffix | `client_id`, `linked_transaction_id` |

**Keep intermediate models narrow.** Each does one step and is named for it (`classified`, `converted_to_gbp`, `with_contract_spend`, `with_revenue`), so each step's logic can be tested on its own. Put a unit test on the model that owns the logic, with its direct parents as inputs. Check new joins with `dbt_utils.equal_rowcount` against the model they extend.

Use `fct_`/`dim_` only in marts. Staging and intermediate keep `stg_`/`int_`: they hold source cleaning and reusable logic, not reporting outputs.

Use the business's vocabulary: these are **clients**, not customers.

## SQLite specifics

The warehouse is SQLite, which shapes several choices:

- **Use `CASE WHEN` for conditional logic.** It is portable across warehouses and SQLite versions.
- **No correlated subqueries for "latest value as of a date" lookups.** Give each value a validity period with `LEAD(...) OVER (PARTITION BY ... ORDER BY ...)` and join on the range instead (see `currency_rate_periods` in `int_transactions_converted_to_gbp`). Through views, a correlated subquery re-evaluates the view for every row: the rate lookup took the build from about 2 seconds to 79.
- **Views are not validated when created.** `dbt build` will succeed even if a view references a function that doesn't exist. After changing any view (staging and intermediate are views), run a query against it:
  ```bash
  dbt show --inline "select count(*) from {{ ref('int_transactions_with_revenue') }}"
  ```
- **No date_trunc or regex.** Use `DATE(d, 'start of month')` for month buckets, `DATE(d, '+N months')` for offsets, and `GLOB` patterns for format tests.
- **Types are affinities.** `CAST(x AS numeric(8, 2))` doesn't enforce precision; keep the precision anyway as documentation, but make it valid (precision ≥ scale) so it ports to another warehouse.
- **No hash functions.** SQLite has no `md5()`, so `macros/sqlite__hash.sql` overrides the adapter's hash: on SQLite, surrogate keys are the readable input string (e.g. `GBP-2024-01-01`), and other adapters still use md5. Always generate keys with `dbt_utils.generate_surrogate_key`, never by concatenating columns by hand, so they stay portable.
- **Give every text column a declared type.** Any text column produced by an expression (`CASE`, `COALESCE`, `MIN`, `DATE()`) has no declared type unless wrapped in `CAST(... AS text)`, and dbt unit-test fixtures then cast its values numerically (dates become `2024`, `'active'` becomes `0`). Numeric expressions are fine untyped.
- **Beware integer division.** `600 / 500` is `1` in SQLite; `CAST(x AS real)` one side when dividing columns that could both be whole.
- **Unit test expected rows must all list the same columns**, since dbt combines them with `UNION ALL`; use `null` where a value is not asserted. Expected values that are whole numbers lose their `.0`, so prefer non-whole fixture amounts.
- **Cast dates to text: `CAST(DATE(x) AS text)`.** SQLite stores dates as ISO text. A bare `DATE(x)` column has no declared type, so dbt unit-test fixtures cast it as `UNKNOWN` and SQLite turns `'2024-01-01'` into the number `2024`. Never `CAST(x AS date)` either: that has numeric affinity and does the same.
- **dbt_utils date macros don't work on SQLite.** dbt-sqlite's `dateadd` macro errors ("no such column: day") and its `datediff` is disabled, so `dbt_utils.date_spine` fails, and `dbt_utils.sequential_values` can never fail (its `CAST(... AS timestamp)` reduces dates to their year). Build date logic with SQLite's own `DATE()` modifiers (e.g. the recursive CTE in `dim_dates`), and confirm a new generic test can actually fail before relying on it.
- **No schemas.** Everything lands in `main`; layers are separated by folder and name prefix only.

## Documenting decisions in code

Use these comment prefixes so decisions are searchable:

- `-- ASSUMPTION:` something taken as true without evidence in the data (e.g. spend thresholds are in GBP).
- `-- NB:` a known limitation or a compromise forced by the setup or the data (e.g. a check limited by a data quality gap in what the source supplies).
- `-- NOTE:` an explanation of a non-obvious implementation choice.

Any `ASSUMPTION:` that affects outputs also belongs in the README.

## Testing

Every model has an entry in its folder's `_<directory>__models.yml` (e.g. `_marts__models.yml`; staging folders use the source name, `_global_transactions__models.yml`) with a model description and a description for every column. Generic tests go under `data_tests:`, not the older `tests:`, so they read differently from unit tests. Describe singular tests in `tests/_singular_tests.yml` (a `data_tests:` entry with a `description`), not in a comment at the top of the SQL.

**Mark columns that can't be summed freely** with `config: meta: additivity:`. Use `semi_additive` for positions at a point in time, which can be summed across entities but not across time (e.g. `cumulative_contract_spend_gbp`), and `non_additive` for ratios and thresholds that should never be summed. Say what the tags mean in the model description.

**The docs site home page is `models/docs/overview.md`** (`{% docs __overview__ %}`). Update it when models, key rules or known findings change.

**Write a shared description once, as a doc block.** When a column is described in more than one place, its description lives in `models/docs/columns.md` (modelled layers) or `models/docs/raw_columns.md` (raw data as delivered), and each yml references it with `doc()`. Add model-specific context after the block, e.g. `"{{ doc('transaction_id') }} Primary key of this model."` or `"{{ doc('discounted_fee_margin') }} Null for clients without a contract."`. Don't add lineage notes such as "Passed through from staging, where it is tested": they repeat on every column and say nothing about what the column means. A description used in one place only stays inline. Copies of the same description drift apart over time; a doc block can't.

**Wrap long descriptions.** A `description:` that would run past 80 characters on one line is written as a folded block scalar (`description: >-`), with the text wrapped at 80 characters and indented two spaces under the key. It loads as the same single-line string. Short descriptions stay as quoted one-liners.

- **Primary key:** `unique` + `not_null`, on every model, in every layer, always. This is the one exception to the pass-through rule below.
- **Foreign keys:** `relationships` tests. Where the source supplies no reference data to test against (e.g. no client master data), don't deduce a stand-in from the data being tested, since it would always agree with it; use the strongest check available and add an `NB:` comment naming it as a data quality gap.
- **Conditional rules** use `config: where:`, e.g. `linked_transaction_id` is `not_null` only where `transaction_type = 'refund'`.
- **Ranges:** use a hard bound at `error` severity for impossible values, and a soft bound at `severity: warn` for unusual but possible values.
- **Known data quality issues:** don't leave a test permanently warning, as people learn to ignore warnings. Accept the known count with `warn_if` / `error_if` (e.g. `"> 6"`) so any new case fails, add `store_failures: true` so the known rows stay queryable, and document the issue in the README.
- **Generic test arguments go under `arguments:`** (dbt ≥ 1.10 syntax), matching existing tests:
  ```yaml
  - dbt_utils.accepted_range:
      arguments:
        min_value: 0
        inclusive: false
      config:
        severity: warn
  ```
- **Test a column once, where it is created or changed.** A column passed through unchanged from a lower layer, where it is already tested, is not tested again downstream; renaming it doesn't count as a change. Retest it only if the model processes it: casting, calculating, aggregating, or deriving it through a join, such as a lookup or a conversion. Repeating upstream tests adds run time and noise without catching anything new, and it hides which tests guard which logic. Still give passed-through columns a description: the doc block alone is enough.
  - *Example:* `transaction_type` is tested in staging and passed through the intermediate models unchanged, so it isn't retested there. `net_amount_gbp` is calculated in `int_transactions_converted_to_gbp`, so it is tested there.
  - *Exception, primary keys:* always test a model's primary key for `unique` and `not_null`, even when it is passed through unchanged. The primary key defines the model's grain, and every model must prove its own grain: joins can fan out rows, and filters or unions can introduce gaps, so neither property is inherited from the layer below.
- **Intermediate and mart models need tests on what they create:** `unique` and `not_null` on the primary key, not-null on calculated measures (e.g. `net_amount_gbp`), and row-count or reconciliation checks against the upstream model. Logic with thresholds or windows (cumulative spend, discount trigger) should get dbt unit tests with small hand-built fixtures.

## Workflow

Use the project venv (`source dbt-env/bin/activate`; setup is in the README). After any change:

1. `dbt build --select <model>+` builds and tests the model and everything downstream.
2. `dbt show` against any changed view (see SQLite specifics above).
3. `sqlfluff lint <path>` on changed files.
4. If a business rule changed, update `README.md`.
5. CI (`.github/workflows/dbt_ci.yml`) repeats the README setup, `dbt seed`, `dbt build` and `sqlfluff lint models tests analyses` on every push and pull request.
6. Exploratory or comparison-only queries (e.g. `naive_threshold_comparison`) go in `analyses/`, described in `analyses/_analyses.yml`: dbt compiles them against the models but never builds them, so nothing can report or depend on them. Keep it in step with the README's setup and run commands.

**Raw data comes from `seeds/raw/`, but models read it through `source()`, never `ref()`.** Those seeds stand in for an extract-and-load tool. Genuine reference data (e.g. `transaction_types`) lives in `seeds/reference/` and is read with `ref()`. On a fresh database, run `dbt seed` before `dbt build`, because sources create no dependency on the seeds. `target/global_transactions.db` is disposable: `dbt clean` deletes it (and installed packages); `dbt deps` then `dbt seed` rebuilds it.

Layer materialisations are set in `dbt_project.yml` (staging: view, intermediate: view, marts: table), following dbt's recommendation. Don't override them per model without a stated reason.
