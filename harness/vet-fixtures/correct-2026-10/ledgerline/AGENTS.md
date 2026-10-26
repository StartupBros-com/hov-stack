# ledgerline

Small invoicing service. Python 3, standard library only.

## Checks

Run `make check` before every commit. CI runs the same command.

## Rules

- Standard library only. No third-party packages.
- Name tests after the behaviour, not the function.
- Keep modules small and put new code next to the code it extends.
- No `print()` in `src/`; use `logging`. `scripts/check.py` fails the build on it.
- Reach storage only through `ledgerline.storage.repo`.
- Money is integer cents. No float arithmetic on amounts.
- A new invoice status goes in every status list (models, api, export).
