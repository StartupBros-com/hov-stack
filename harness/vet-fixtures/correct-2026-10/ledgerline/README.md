# ledgerline

Small invoicing service: invoices, line items, totals, CSV export.
Standard library only; runs offline.

## Layout

- `src/ledgerline/models.py` invoice and line item types
- `src/ledgerline/api.py` request handlers
- `src/ledgerline/pricing.py` subtotals, tax and discounts
- `src/ledgerline/export.py` CSV and summary reports
- `src/ledgerline/storage/` in-memory persistence, used through `repo`

## Checks

Run `make check` for the unit tests and the static checks. CI runs the same
command on every push and pull request.
