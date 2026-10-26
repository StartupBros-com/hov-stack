---
name: model-usage-tracking-infra
description: "What can/can't read model-credit usage: onwatch RETIRED 2026-08-06 leaving no grok/minimax/openrouter reader; grok CLI has no headless balance; historical onwatch mechanics kept for whoever rebuilds it"
metadata: 
  node_type: memory
  type: reference
  originSessionId: e906c482-5be7-47b1-9919-896b385a5df5
---

Verified 2026-06-26 while building token-eater.

> **RETIRED 2026-08-06 — everything onwatch-sourced below is now UNAVAILABLE.** onwatch was
> removed (see [[statusline-ad-stack]]); `:9211` is closed and `~/.onwatch/data/onwatch.db`
> is gone. Net capability loss: **no ambient reader for grok, minimax or openrouter credits
> remains on this box.** What did NOT depend on onwatch and still works: the statusline's
> 5h/7d Anthropic quota (Claude Code puts `rate_limits.{five_hour,seven_day}` on stdin),
> the actually-served model badge (better-ccflare's localhost per-session endpoint), and
> the direct-Codex explicit-state preflight in `hooks/PreToolUse/codex-quota-guard.js`.
> The mechanics below are kept deliberately — they are the reverse-engineering anyone
> rebuilding a grok credit reader would otherwise redo.

- **onwatch** *[RETIRED — historical]* (`localhost:9211`) tracked **grok, anthropic, codex** (and minimax, openrouter) — updated since 2026-06-26. The grok dashboard (`localhost:9211/?provider=grok`) shows real credits %util + weekly reset (e.g. 11% used, resets Jun 30 20:00 ET). **Caveat (2026-06-27): grok is AUTHED-ONLY** — the open Prometheus `/metrics` endpoint still exposes `onwatch_quota_utilization_percent`/`reset_timestamp` for **anthropic + codex only**; grok lives behind the dashboard and the `/api/*` JSON endpoints return **401**. To read grok balance programmatically (e.g. from token-eater) you must authenticate to onwatch's API or get grok added to open `/metrics`.
- **grok CLI** itself exposes **no headless balance**: no `grok usage`/`credits` subcommand (`grok models` is the only usage-ish one), `/usage` is TUI-only, real data behind `console.x.ai/team/default/rate-limits`. The CLI talks to `api.x.ai/v1` (API-key billing — a *different* pool than subscription credits) and `cli-chat-proxy.grok.com/v1` (session). So the balance source for grok is **onwatch** (authed), not the CLI; self-metering is the fallback.
- **HOW onwatch reads grok (reverse-engineered 2026-06-27):** it calls gRPC `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCredits` (`application/grpc-web+proto`, bearer = `~/.grok/auth.json` `.key`) and stores snapshots in `~/.onwatch/data/onwatch.db` → table **`grok_quota_values`** (`utilization`, `resets_at`, `status`). The DB is the easy read (no `sqlite3` CLI on this box — use `python3` sqlite, `mode=ro`). anthropic/codex util+reset are in the open `/metrics` (`onwatch_quota_utilization_percent{...quota_type="seven_day"}`). token-eater's `scripts/onwatch-usage.sh` consumes both; replicating the gRPC call directly (for no-onwatch members) is blocked on the request `.proto` (empty msg → grpc-status 12). See token-eater issue #9.
- **codex routes through ccflare** *[SUPERSEDED 2026-07-03: codex transport is now DIRECT; `model_provider = "better_ccflare"` is commented out of `~/.codex/config.toml`, so a ccflare outage no longer blocks codex delegation. See [[codex-delegation-setup]]. Historical detail below applied 06-26 to 07-02.]*: `~/.codex/config.toml` has `base_url = "http://127.0.0.1:8788/v1"`, `wire_api = "responses"`. So a ccflare outage hits codex too — not just Claude. When ccflare returns `503 Service Unavailable: All accounts are temporarily unavailable`, **`codex exec` delegation is fully blocked** (5 reconnects then fails). Recover by fixing/restarting ccflare or freeing the pooled accounts — retrying alone does not help. This can happen even when onwatch shows real usage low, so it's a proxy/account-auth issue, not true saturation. Corrects the older "better-ccflare is Anthropic-side only" note in [[codex-delegation-setup]] — codex is behind it too.

**2026-07-02 audit:** ALL Claude Code traffic rides ccflare too — `~/.claude/settings.json` sets `ANTHROPIC_BASE_URL=http://127.0.0.1:8788` globally. And both watchers are currently unsupervised: user unit `better-ccflare` crash-looping (~6k failures/day on port conflict) while an ORPHAN pair (better-ccflare :8789 + ccflare-guard.mjs :8788, node 24.12.0 vs the unit's pinned 24.13.1 — likely orphaned by a mise node upgrade ~Jul 1 04:15) serves all traffic; orphan death = total Claude outage until the flapping unit wins the port race. `onwatch.service` failed (start-limit-hit) since Jul 1 19:32 with an orphan `--debug` pid holding :9211; `onwatch-update`'s ExecStartPost uses `try-restart`, which never revives a failed unit. Fix (approval-gated, severs live sessions for seconds): kill orphans → `systemctl --user start better-ccflare onwatch` (units are enabled and will claim the freed ports) → health-check. Also 07-02: ccflare accounts 6/7 paused incl. acct-a (codex) since 06-30 → **codex delegation blocked** until unpaused; 24h flow ≈ 5.9k req / 978M tokens, nearly all through one Max account. grok-in-onwatch confirmed current (~288 snapshots/day since ~06-27).
