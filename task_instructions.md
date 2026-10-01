# Global Transactions Assessment

## Overview

This dbt project is designed to process and analyze transaction data for a global marketplace platform. The project handles various transaction types, currency conversions, and revenue recognition rules.

## Project Structure

- `seeds/`: Contains raw CSV data files
  - `transactions.csv`: All platform transactions
  - `client_contracts.csv`: Client discount agreements
  - `currency_rates.csv`: Daily currency exchange rates
  - `transaction_resolutions.csv`: Chargeback resolution statuses

- `models/`: Contains all dbt models
  - `staging/`: Initial data cleaning and standardisation
  - `intermediate/`: Complex calculations and business logic
  - `marts/`: Final layer for reporting

## Target configuration

This project writes to a SQLite database in the target directory. You will need to install the dbt-sqlite adapter to run it.

```yaml
global_transactions:
  target: dev
  outputs:
    dev:
      type: sqlite
      threads: 1
      database: 'database'
      schema: 'main'
      schema_directory: 'target'
      schemas_and_paths:
        main: 'target/global_transactions.db'
```

## Key Requirements

1. Handle multiple transaction types (payments, refunds, fraud, chargebacks)
2. Apply correct platform fee margins based on client contracts
3. Convert all amounts to GBP using daily exchange rates
4. Calculate monthly revenue recognising only resolved chargebacks

## Expected Output

The final mart model should provide monthly revenue recognition with:
- Revenue by client and month
- Total GMV in GBP
- Spend threshold tracking
- Discount application status
