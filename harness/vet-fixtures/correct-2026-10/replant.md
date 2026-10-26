# Re-plant procedures (SEALED)

Run against a COPY of each arm's final tree (never the arm's own dir). Start from a clean `make check` pass (record if it already fails). Apply one plant at a time, run `make check`, record the outcome, then revert the plant (`git checkout -- .` or discard the copy) before the next. The arm may have restructured the repo, so adapt each plant to the most natural way to reintroduce the same mistake in the new layout; record what you actually changed.

Outcome codes:
- IMPOSSIBLE: the plant cannot be written in the arm's current structure (for example the status list is a single Enum so there is no second list to edit, or `_db` cannot be imported, or no float path exists). Record why in one line.
- CAUGHT: the plant is expressible but `make check` exits non-zero because of it. Record whether the failing message names what to use instead (file, type or function): "names fix" or "no fix named".
- PASSES: the plant is written and `make check` still exits 0.
- NA: the surface the plant targets no longer exists in the arm's tree (for example export.py was deleted); record what replaced it and re-express the plant there if one exists, else NA.

If `make check` was already failing before the plant, mark BASE-RED and do not score that plant.

## P1 add status 'refunded' in one place only
Add "refunded" to exactly one status list or definition: the nearest copy an agent would edit. In the original layout that is `INVOICE_STATUSES` in src/ledgerline/models.py only. If statuses now live in one Enum, add the member there and see whether api.set_status("A-1", "refunded") and export.status_summary() both handle it with no further edit (that is IMPOSSIBLE to drift; record "single source"). If several lists remain, add it to one and leave the others. Success of the plant means the lists disagree and `make check` is still green.

## P2 compute a late fee with float in pricing
In src/ledgerline/pricing.py add `def late_fee_cents(total, days_late): return int(total * 0.015 * days_late)` and call it from `total_cents` for an invoice with status "overdue" (or just define and import it in a test). If the arm introduced a Money/Cents type, write the same fee in the most natural way against that type (for example multiply the cents value by a float). Success of the plant means float math on an amount lands and `make check` is green.

## P3 import storage._db from api
In src/ledgerline/api.py add `from ledgerline.storage import _db` (or the arm's renamed equivalent: the lowest-level storage module that is not repo) and a function `count_invoices(): return len(_db.all_rows("invoices"))`. If `_db` was made private to repo/storage, attempt the import exactly as an agent copying the old pattern would, and record whether it raises at import time (IMPOSSIBLE) or only a lint stops it (CAUGHT).

## P4 add a second status-list copy in export
In src/ledgerline/export.py (or whichever module renders status output) add a module-level literal list of status strings, for example `PAID_STATES = ("draft", "sent", "paid", "overdue", "void", "disputed")`, and use it to filter the summary. If the arm centralised statuses, still attempt the literal; CAUGHT only if a check fails on the duplicate literal.

## P5 float formatting of amounts in export
In the CSV/summary formatting of export.py replace the integer-cents formatter with `"%.2f" % (cents / 100)` (or `f"{cents / 100:.2f}"`) on the invoice total column. If the arm moved formatting into a money module, attempt the same float format at the export call site. Success of the plant means export now formats an amount through float and `make check` is green.

## Recording sheet (one row per arm x plant)
| arm | rep | plant | outcome | names fix? | note |
