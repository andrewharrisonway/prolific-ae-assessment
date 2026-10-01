{#-
    Overrides dbt-sqlite's hash, which calls md5(). SQLite has no built-in hash
    function: md5() needs the sqlean crypto extension, a platform-specific binary
    every user would have to install and configure in their profile.

    On SQLite, the key is the concatenated input string itself, unhashed. It is
    still deterministic and unique per input, which is all a surrogate key needs,
    and it stays readable (e.g. 'GBP-2024-01-01').

    The sqlite__ prefix means this only applies on SQLite: on any other adapter,
    dbt_utils.generate_surrogate_key falls back to that adapter's real md5 hash.
-#}
{% macro sqlite__hash(field) -%}
    CAST({{ field }} AS {{ api.Column.translate_type('string') }})
{%- endmacro %}
