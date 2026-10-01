{#
    Column descriptions for the raw tables, shared by models/raw/sources.yml
    and seeds/raw/_raw_seeds.yml, which describe the same tables. They describe
    the data as delivered; staging cleans, types and renames it.
#}

{% docs raw__transaction_id %}
Transaction identifier, formatted `T` followed by six digits (`T000001`). IDs are allocated in blocks by transaction type, not in time order.
{% enddocs %}

{% docs raw__client_id %}
Client identifier, formatted `C` followed by three digits (`C001`).
{% enddocs %}

{% docs raw__transaction_amount %}
Amount in the transaction's original currency (see `currency`). Always positive, including for refunds; the transaction type gives the direction.
{% enddocs %}

{% docs raw__transaction_type %}
One of `payment`, `refund`, `chargeback` or `fraud`.
{% enddocs %}

{% docs raw__transaction_date %}
Date the transaction occurred, as `YYYY-MM-DD` text.
{% enddocs %}

{% docs raw__platform_fee_margin %}
Standard platform fee margin recorded on the transaction. 0.2 on every row; contract discounts are not reflected here.
{% enddocs %}

{% docs raw__currency %}
ISO currency code: `GBP` or `USD`.
{% enddocs %}

{% docs raw__linked_transaction_id %}
For refunds, the `transaction_id` of the payment being refunded. Null for all other transaction types.
{% enddocs %}

{% docs raw__contract_start_date %}
Date the contract takes effect, as `YYYY-MM-DD` text.
{% enddocs %}

{% docs raw__contract_duration_months %}
Length of the contract in whole months.
{% enddocs %}

{% docs raw__spend_threshold %}
Cumulative spend the client must reach within the contract term for the discounted margin to apply. No currency is stated; the project assumes GBP.
{% enddocs %}

{% docs raw__discounted_fee_margin %}
Fee margin that applies once the spend threshold is reached.
{% enddocs %}

{% docs raw__rate_date %}
Date the exchange rate applies to, as `YYYY-MM-DD` text. Daily from 2024-01-01 to 2024-06-30.
{% enddocs %}

{% docs raw__exchange_rate_to_gbp %}
GBP value of one unit of `currency` on `rate_date`. Always 1 for GBP.
{% enddocs %}

{% docs raw__resolution_transaction_id %}
The `transaction_id` of the chargeback this resolution applies to.
{% enddocs %}

{% docs raw__resolution_status %}
`resolved` or `pending`.
{% enddocs %}

{% docs raw__resolution_date %}
Date the chargeback was resolved, as `dd/mm/yyyy` text (unlike every other date in the data). Null while pending.
{% enddocs %}
