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
Client identifier, formatted `C` followed by three digits. The source supplies no client master data, so client IDs are validated by format only. Contracts exist for some clients only.
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

{% docs resolution_status %}
Chargeback resolution status: `resolved` or `pending`.
{% enddocs %}

{% docs resolution_date %}
Date the chargeback was resolved. Null while pending.
{% enddocs %}

{% docs gross_amount_local %}
Amount as recorded, in the transaction's currency. Always positive.
{% enddocs %}

{% docs net_amount_local %}
Signed amount in the transaction's currency: `gross_amount_local * amount_direction`.
{% enddocs %}

{% docs gross_amount_gbp %}
Recorded amount converted to GBP at the latest rate on or before the transaction date. Always positive.
{% enddocs %}

{% docs net_amount_gbp %}
Signed amount in GBP: negative for refunds, positive otherwise.
{% enddocs %}

{% docs is_revenue_recognised %}
1 if this transaction generates revenue: the type recognises revenue, nothing is outstanding (chargebacks must be resolved), and it is not a duplicate refund. Otherwise 0.
{% enddocs %}

{% docs is_spend_qualifying %}
1 if this transaction's type and status count toward contract spend; duplicate refunds never count. Contract rules are applied separately (see `contract_spend_gbp`).
{% enddocs %}

{% docs applicable_fee_margin %}
Fee margin applied: the contracted discounted margin once the spend threshold is reached within the contract term, otherwise the platform fee margin.
{% enddocs %}

{% docs revenue_gbp %}
Platform revenue in GBP: `net_amount_gbp * applicable_fee_margin` when `is_revenue_recognised`, otherwise 0.
{% enddocs %}

{% docs recognition_date %}
Date revenue is recognised: the resolution date for chargebacks, the transaction date otherwise. Null for transactions that never generate revenue (fraud, pending chargebacks, duplicate refunds).
{% enddocs %}

{% docs spend_effective_date %}
Date the transaction counts toward contract spend: the resolution date for resolved chargebacks, the transaction date otherwise. Orders the running contract spend.
{% enddocs %}

{% docs is_in_contract_period %}
1 if the transaction date falls inside the client's contract window, 0 if outside it. Null for clients without a contract.
{% enddocs %}

{% docs contract_spend_gbp %}
This transaction's contribution to its client's contract spend, in GBP. The net amount if the transaction is inside the contract window and qualifies (see `is_spend_qualifying`); a refund only counts if the payment it reverses was also inside the window. Otherwise 0. Null for clients without a contract.
{% enddocs %}

{% docs is_discount_earned %}
1 once the client's cumulative contract spend has reached its threshold within the contract term. It stays 1 for the rest of the term, even if refunds later reduce spend. 0 before that or outside the term; null for clients without a contract.
{% enddocs %}

{% docs contract_start_date %}
Date the contract takes effect (inclusive).
{% enddocs %}

{% docs contract_duration_months %}
Length of the contract in months.
{% enddocs %}

{% docs spend_threshold %}
Cumulative spend a client must reach within the contract term for the discounted fee margin to apply. ASSUMPTION: in GBP. The contracts table does not state a currency, and every client transacts in both GBP and USD.
{% enddocs %}

{% docs discounted_fee_margin %}
Contracted fee margin that applies once the client reaches its spend threshold.
{% enddocs %}

{% docs month_start_date %}
First day of the month.
{% enddocs %}

{% docs month_end_date %}
Last day of the month.
{% enddocs %}
