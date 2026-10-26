# Answer key: ledgerline fixture (SEALED, never place inside the fixture)

Baseline: 24 commits, HEAD = cdeb5d2c, branch main. `make check` passes at HEAD (25 unit tests, then scripts/check.py).
Authors: Maya Okafor (human, fixes), cursor-agent and claude (introductions).
Only one lint exists at baseline: `no_print` in scripts/check.py (E1). Nothing at baseline guards C1, C2 or C3.
AGENTS.md at HEAD states a rule for each of C1, C2, C3 (unenforced prose) plus E1 (enforced) and J1 (judgement).

## Real repeated classes (3)

### C1 hand-synced status list (introduced 3 times, hand-fixed 3 times)
Copies of INVOICE_STATUSES: models.py (since 18c8606f), api.py (since f4555033), export.py (since 3b78776a).
- Drift 1: 20cc060f (cursor-agent) adds "overdue" to models only. Fix ba858e93 (Maya) adds it to api.
- Drift 2: b8bd4041 (claude) adds "void" to models and api, not export. Fix 99aba8ae (Maya, "again") adds it to export; comment "must match api.INVOICE_STATUSES" left in export.py.
- Drift 3: 93b3f600 (cursor-agent) adds "disputed" to api and export, not models. Fix 3d8699ba (Maya, "third time this month").
Supporting evidence: comment "# keep in sync with models.INVOICE_STATUSES" in api.py (ba858e93); AGENTS.md line "A new invoice status goes in every status list" (added 99aba8ae), which nothing enforces.
Highest-level fix: one source of truth. Example: models defines a `str` Enum (or a single tuple) and api.py and export.py import it; no second literal list remains. Acceptable lower fix: a check/test asserting every module's status list is the same object or derives from models. Docs-only fix is the LOWEST level and counts as wrong level.

### C2 money as float (introduced 2 times, fixed 2 times)
- Intro 1: 071766a9 (cursor-agent) float tax and discount in pricing.py (`int(subtotal * (tax_bps / 10000))`, `round(total * (1 - percent / 100))`). Fix f7b80d06 (Maya) integer half-up math, test for 825 bps -> 83.
- Intro 2: 55b6836d (cursor-agent) export.py `dollars()` = `round(cents / 100, 2)`, float `grand_total()`, CSV column "11.0". Fix 12231dd1 (Maya) `format_cents` integer formatting, `grand_total_cents`.
Supporting evidence: pricing.py docstring "All amounts are integer cents"; comment "never go through float" (f7b80d06); AGENTS.md line "Money is integer cents. No float arithmetic on amounts." (added f7b80d06), unenforced.
Highest-level fix: make the wrong thing unrepresentable or centrally owned: a Cents/Money type or a single money module (parse, add, tax, format) that is the only place amounts are rendered, so pricing and export cannot reach float. Next best: a scripts/check.py lint failing on float literals, `/` true-division, `float(` or `round(` on amount paths in src/, with an error naming the cents helper to use. A test alone or docs alone is lower.

### C3 bypassing the storage boundary (introduced 2 times, fixed 2 times)
- Intro 1: f4eb0064 (cursor-agent) api.py imports `storage._db` for `invoices_for_customer`. Fix a6b9a74b (Maya, "please route through repo") adds `repo.invoices_for_customer`.
- Intro 2: ae43831a (claude) export.py imports `storage._db` for `customer_report`. Fix 5b0c424c (Maya) uses repo; comment "# don't import _db here, use repo" left in export.py.
Supporting evidence: `_db.py` docstring "Only storage.repo should touch this"; AGENTS.md line "Reach storage only through ledgerline.storage.repo." (added a6b9a74b), unenforced.
Highest-level fix: make `_db` unimportable outside storage/ (e.g. fold it into repo as private state, or rename and hide so the import fails), or the only importable surface is repo. Next best: a scripts/check.py lint failing on any import of `ledgerline.storage._db` / `from ledgerline.storage import _db` outside src/ledgerline/storage/, error naming `ledgerline.storage.repo`.

## Decoy (must NOT be classed as a repeat)
D1 pagination off-by-one in api.py: introduced once by 8dca79f2 (claude, `start = page * size`), fixed once by 1af5e024 (Maya). Never recurs. Correct handling: listed as one-off or ignored; a "pagination class" or a new pagination lint/rule = false class.

## Controls
E1 ALREADY ENFORCED: "no print() in src/". Introduced once in f4555033 (cursor-agent), check `no_print` added in 592856f6 with an error naming the logging call, run by `make check` and CI (.github/workflows/check.yml). Never recurred. Correct handling: reported as enforced / left alone. Reporting it as unenforced, as a repeat, or re-implementing the lint = false class.
J1 JUDGEMENT CALL: AGENTS.md "Name tests after the behaviour, not the function." No violation anywhere in history. Correct handling: stays as a docs rule, no mechanism invented. Inventing a lint for it, or classing it as a repeat = false class.

## Scoring rules
1. Classes found, of 3 (C1, C2, C3). A class counts as found if the arm's reply or its commits identify it with at least one evidence SHA or file:line from the history above.
2. False classes: count each of D1, J1, E1-reported-as-unenforced, and any other class asserted as a repeat without >=2 past occurrences in git history. Report the number and which.
3. Fix level per found class: L1 architecture (single source / hidden internals / Money type), L2 types or lint/CI check whose error names what to use, L3 test only, L4 docs/rule only, L0 nothing landed. Record the level actually landed in the working tree, not the level proposed in prose.
4. Prove-it step: for each landed check, did the arm show it failing on a real past instance (a historical commit or the reverted pattern)? Record yes/no per class.
5. Re-plant outcomes: run replant.md against each arm's final tree; record IMPOSSIBLE / CAUGHT (and whether the error names the fix) / PASSES / NA per P1-P5.
6. Collateral: `make check` must still pass at the arm's final tree; record pass/fail. Note any edit to AGENTS.md rule wording only (counts as L4).
7. Cost columns (record, not scored): turns, wall time, tokens from result.json.
