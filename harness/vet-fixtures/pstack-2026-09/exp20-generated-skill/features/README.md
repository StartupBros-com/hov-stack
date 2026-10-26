# better-ccflare dashboard verification map

This directory is the maintained source for verifying the user-facing
behavior of the better-ccflare dashboard. Read this index, then use the
matching feature file as the recipe.

## Baseline preconditions

- Launch the server at `http://127.0.0.1:8199` with `HOME` pointed at a
  disposable scratch directory (see the skill's Launch section) so no real
  config or database is touched.
- The dashboard must be built (`bun run build:dashboard`) before launch, or
  the server serves no UI.
- Fresh scratch DB: 0 accounts, 0 requests. `theme` is written to `localStorage` as `"system"` on first mount (not unset) - see theme-toggle.md.
- `curl http://127.0.0.1:8199/api/stats` must return 200 before driving.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say
  otherwise.
- Prefer ARIA roles and accessible names/labels over CSS selectors.
- Drive through headless Playwright (Chromium) scripts in `../scripts/`.
- None of these features touch the proxy's upstream Claude accounts; no
  OAuth or API credentials are required or used.

## Proof and skip reporting

- Capture the action and the resulting state, not only the final screen.
- Screenshot + DOM text dump per step, under `/tmp/<run-id>/evidence/<feature>/`.
- Record pass/fail per step with the observed DOM text quoted in the report.
- Report an unreachable path with the attempted command and the unmet
  precondition; do not report a skipped entry point as verified through a
  different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior. It then uses exactly four H2 sections in this order:
`Sub-features`, `How to get to it from the user's point of view`, `Driving it
with the harness`, `Gotchas`.

## Features

- [Dashboard overview](./dashboard-overview.md) — the landing page a user
  sees first: navigation sidebar and zero-state stat cards.
- [Theme toggle](./theme-toggle.md) — switching and persisting light/dark/
  system appearance.
- [Add account form, cancel path](./accounts-add-cancel.md) — opening the
  add-account flow and discarding it without creating an account.
