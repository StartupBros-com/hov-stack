---
name: verify-better-ccflare
description: "Drive the real better-ccflare dashboard (web UI, Bun server) end to end and capture proof: launch the server against a disposable SQLite DB, doctor it, drive a feature from features/, capture screenshots and DOM snapshots, tear down without deleting evidence. Use for /verify-better-ccflare or when asked to prove a dashboard feature works against the live app rather than unit tests."
disable-model-invocation: true
---

# Verify better-ccflare

better-ccflare is a Bun/TypeScript load-balancing proxy for Claude Code with a
React dashboard served by the Bun server
(`apps/server/src/server.ts`). This skill drives the real dashboard with a
headless Playwright harness and proves behavior with screenshots and DOM
dumps. No Claude/OAuth accounts are required for the features in the map:
they exercise dashboard chrome, not the proxy's upstream calls.

## Launch

The server reads its config/DB location from `homedir()`-derived paths
(`~/.config/better-ccflare` on Linux, or `$XDG_CONFIG_HOME`). Always run it
with an isolated `HOME` so verification never touches the real developer
machine's config or database:

```bash
cd <repo-root>
mkdir -p /tmp/<run-id>/scratch-home/.config
export HOME=/tmp/<run-id>/scratch-home
export XDG_CONFIG_HOME=/tmp/<run-id>/scratch-home/.config
export PORT=8199
nohup bun run apps/server/src/server.ts > /tmp/<run-id>/server.log 2>&1 &
echo $! > /tmp/<run-id>/server.pid
```

First-run-only fix: `packages/database/src/inline-{vacuum,incremental-vacuum,integrity-check}-worker.ts`
are gitignored, build-generated files. Running the server from source
without building the CLI first throws `Cannot find module
'./inline-integrity-check-worker'`. Create the same empty-string placeholders
the project's own `apps/cli` build step creates when the file is absent:

```ts
// packages/database/src/inline-integrity-check-worker.ts (and the other two)
export const EMBEDDED_INTEGRITY_CHECK_WORKER_CODE = "";
```

The dashboard also needs a one-time build or the server logs "Dashboard
assets not found" and serves no UI:

```bash
bun run build:dashboard   # build the dashboard workspace
```

Readiness: the log line `📊 Dashboard: http://localhost:<port>` (not
"Dashboard: unavailable"), and `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:<port>/`
returns `200`.

Teardown: `kill "$(cat /tmp/<run-id>/server.pid)"`; verify with `kill -0` and
escalate to `-9` only if it doesn't exit within a couple seconds. Never `pkill
-f server.ts` — that would kill any other developer's instance too.

## Doctor

Before driving anything, or after anything looked wrong:

```bash
curl -s http://127.0.0.1:<port>/api/stats
```

Require: HTTP 200, valid JSON with a `totalRequests` field. This also proves
the DB migrations ran (the server logs `[DatabaseMigrations] All database
migrations completed successfully` on first boot against a fresh DB) and that
we're talking to an instance we started, on the port we started it on — not a
developer's real dashboard on a well-known port.

## Drive

Harness: headless Playwright (Chromium), installed locally in this repo
(`pnpm add -D playwright`, `npx playwright install chromium`) — not
`wsl-cdp`, which drives the operator's real browser. A driver script per
feature under `.claude/skills/verify-better-ccflare/scripts/` launches
Chromium, navigates to `http://127.0.0.1:<port>`, and drives the exact
selectors named in the matching `features/*.md` file. Prefer role/label
selectors (`page.getByRole('link', { name: 'Accounts' })`,
`page.getByLabel('Account Name')`) over CSS or DOM position, matching the
selectors named in each feature file.

## Evidence

Per feature step: one screenshot (`page.screenshot({ path })`) and one DOM
text dump (`page.locator('body').innerText()` written to a `.txt` file, or an
ARIA snapshot) under `/tmp/<run-id>/evidence/<feature>/`. Name files by step
so order is traceable (`01-loaded.png`, `01-loaded.dom.txt`, ...). Capture the
action's result, not just the final screen — e.g. for the theme toggle,
capture the `<html>` class both before and after the click, plus after a
reload, to prove persistence rather than a transient class change.

## Cleanup

```bash
kill "$(cat /tmp/<run-id>/server.pid)"
```

Only the server process and its scratch `HOME` (config + SQLite DB) are
disposable. Evidence under `/tmp/<run-id>/evidence/` is never touched by
cleanup — list it after teardown to prove it survived
(`find /tmp/<run-id>/evidence -type f`). A cleanup step that deletes or
truncates the evidence directory fails this skill's own standard.

## Helpers

- `scripts/dashboard-overview.mjs` — drives the `dashboard-overview` feature.
- `scripts/theme-toggle.mjs` — drives the `theme-toggle` feature.
- `scripts/accounts-add-cancel.mjs` — drives the `accounts-add-cancel` feature.

Each is invoked as `node <script> <base-url> <evidence-dir>` and is
self-contained (imports `playwright`, no shared driver module to
reverse-engineer).

## Feature map

See `features/README.md` for the index. Three features are mapped so far;
the map is the maintained source — use `/maintain-verification-skill` to keep
it honest as the dashboard changes.
