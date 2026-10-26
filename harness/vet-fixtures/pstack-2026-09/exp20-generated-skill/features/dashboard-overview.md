# Dashboard overview

The overview page is the dashboard's landing route (`/`). It shows the left
navigation sidebar (app identity, nav links to every tab) and a grid of
zero-state stat cards summarizing proxy activity.

## Sub-features

- `overview-load` loads the landing route and renders the sidebar and stat
  cards without error.
- `overview-nav-links` exposes a nav link for every tab (Overview, Analytics,
  Insights, Requests, Accounts, Usage History, Window Value, Agents, API
  Keys, Logs, Settings).
- `overview-zero-state` shows zeroed stat cards (`Total Requests`, `Success
  Rate`, `Avg Response Time`, `Plan Value`, `API Cost`, `Output Speed`) on a
  fresh database with no accounts and no requests.

## How to get to it from the user's point of view

- Open the dashboard root URL in a browser; it is the default route.
- Click the "better-ccflare" logo/title in the sidebar from any other tab.

## Driving it with the harness

Preconditions:

- Server is healthy at `http://127.0.0.1:8199` (`GET /api/stats` returns
  200).
- Fresh scratch DB: `GET /api/accounts` returns `[]` and `GET /api/stats`
  reports `totalRequests: 0`.

- **Load the page.** Navigate to `http://127.0.0.1:8199/`. Wait for the
  heading `Overview` (`h2`, exact text) to be visible.
- **Nav links.** Assert the sidebar (`nav`) contains links named `Overview`,
  `Analytics`, `Insights`, `Requests`, `Accounts`, `Usage History`, `Window
  Value`, `Agents`, `API Keys`, `Logs`, `Settings` (a `Combos` link may also
  be present depending on config).
- **Zero-state cards.** Assert the page contains stat card titles `Total
  Requests`, `Success Rate`, `Avg Response Time`, `Plan Value`, `API Cost`,
  `Output Speed`.
- **Proof.** Screenshot the full page and dump `body.innerText()` to
  `evidence/dashboard-overview/01-loaded.png` /
  `01-loaded.dom.txt`.

## Gotchas

- The dashboard is a client-rendered React app (Vite/Bun bundle); wait for
  the `Overview` heading rather than just `domcontentloaded`, or the page
  will read as blank.
- If the server logs "Dashboard assets not found - dashboard will be
  disabled" at boot, `bun run build:dashboard` was not run before launch;
  the root route serves a 404/API response instead of the UI.
- Stat card values are formatted (e.g. `$0.00`, `0%`) — assert on the card
  title text, not a parsed numeric value, to avoid brittle formatting
  coupling.
