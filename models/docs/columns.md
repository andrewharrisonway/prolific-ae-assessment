{#
    Shared column descriptions for the modelled layers (staging, intermediate,
    marts and reference seeds). A column described in more than one place gets
    a block here; models reference it with doc() and append any model-specific
    context inline. Raw-layer descriptions live in raw_columns.md.
#}

{% docs transaction_id %}
Unique transaction identifier, formatted `T` followed by six digits.
{% enddocs %}

{% docs client_id %}
Client identifier, formatted `C` followed by three digits. There is no client dimension table; contracts exist for some clients only.
{% enddocs %}

{% docs transaction_type %}
Type of transaction: `payment`, `refund`, `chargeback` or `fraud`. How each type behaves (direction, revenue, spend, resolution) is defined in the `transaction_types` seed.
{% enddocs %}

{% docs transaction_date %}
Date the transaction occurred.
{% enddocs %}

{% docs transaction_currency %}
ISO currency code of the transaction's amounts: `GBP` or `USD`.
{% enddocs %}

{% docs amount_direction %}
Sign applied to the recorded amount: 1 for money in, -1 for money returned (refunds). Fraud is 1, but fraud is excluded from revenue and spend by its flags.
{% enddocs %}

{% docs is_duplicate_refund %}
1 for a refund of a payment that has already been refunded, otherwise 0. Every refund is for the full payment amount, so only the first refund of a payment (by date, then `transaction_id`) is genuine. Flagged rather than filtered; `int__transactions` excludes flagged refunds from revenue and spend.
{% enddocs %}
