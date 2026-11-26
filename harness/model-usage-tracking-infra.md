---
name: model-usage-tracking-infra
description: "What can and cannot read model-credit usage: no ambient grok/minimax/openrouter credit reader exists; grok CLI has no headless balance; onwatch mechanics kept for whoever builds a reader"
metadata: 
  node_type: memory
  type: reference
  originSessionId: e906c482-5be7-47b1-9919-896b385a5df5
---

Verified 2026-06-26 while building token-eater.

> **No ambient reader for grok, minimax or openrouter credits exists on this box.** onwatch is
> not installed (see [[statusline-ad-stack]]): `:9211` is closed and `~/.onwatch/data/onwatch.db`
> does not exist, so everything onwatch-sourced below is unavailable. What does not depend on
> onwatch: the statusline's 5h/7d Anthropic quota (Claude Code puts
> `rate_limits.{five_hour,seven_day}` on stdin), the actually-served model badge
> (better-ccflare's localhost per-session endpoint). The onwatch mechanics below record
> how it read grok credits.

- **onwatch** (not installed; mechanics for a rebuild) (`localhost:9211`) tracked **grok, anthropic, codex** (and minimax, openrouter). The grok dashboard (`localhost:9211/?provider=grok`) shows real credits %util + weekly reset (e.g. 11% used, resets Jun 30 20:00 ET). **Caveat (2026-06-27): grok is AUTHED-ONLY** — the open Prometheus `/metrics` endpoint still exposes `onwatch_quota_utilization_percent`/`reset_timestamp` for **anthropic + codex only**; grok lives behind the dashboard and the `/api/*` JSON endpoints return **401**. To read grok balance programmatically (e.g. from token-eater) you must authenticate to onwatch's API or get grok added to open `/metrics`.
- **grok CLI** itself exposes **no headless balance**: no `grok usage`/`credits` subcommand (`grok models` is the only usage-ish one), `/usage` is TUI-only, real data behind `console.x.ai/team/default/rate-limits`. The CLI talks to `api.x.ai/v1` (API-key billing — a *different* pool than subscription credits) and `cli-chat-proxy.grok.com/v1` (session). So the balance source for grok is **onwatch** (authed), not the CLI; self-metering is the fallback.
- **HOW onwatch reads grok (reverse-engineered 2026-06-27):** it calls gRPC `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCredits` (`application/grpc-web+proto`, bearer = `~/.grok/auth.json` `.key`) and stores snapshots in `~/.onwatch/data/onwatch.db` → table **`grok_quota_values`** (`utilization`, `resets_at`, `status`). The DB is the easy read (no `sqlite3` CLI on this box — use `python3` sqlite, `mode=ro`). anthropic/codex util+reset are in the open `/metrics` (`onwatch_quota_utilization_percent{...quota_type="seven_day"}`). token-eater's `scripts/onwatch-usage.sh` consumes both; replicating the gRPC call directly (for no-onwatch members) is blocked on the request `.proto` (empty msg → grpc-status 12). See token-eater issue #9.
- **Codex transport uses the local ccflare pool.** The top-level
  `model_provider = "better_ccflare"` pin (dotfiles#1002) routes requests through the
  pool, which rotates across every ChatGPT account per request. The old
  `codex-quota-guard` preflight could rewrite or deny a call when its direct account
  was explicitly exhausted. It was retired in hov-stack#882.

**Historical audit (2026-07-02):** ALL Claude Code traffic rides ccflare too — `~/.claude/settings.json` sets `ANTHROPIC_BASE_URL=http://127.0.0.1:8788` globally. And both watchers are currently unsupervised: user unit `better-ccflare` crash-looping (~6k failures/day on port conflict) while an ORPHAN pair (better-ccflare :8789 + ccflare-guard.mjs :8788, node 24.12.0 vs the unit's pinned 24.13.1 — likely orphaned by a mise node upgrade ~Jul 1 04:15) serves all traffic; orphan death = total Claude outage until the flapping unit wins the port race. `onwatch.service` failed (start-limit-hit) since Jul 1 19:32 with an orphan `--debug` pid holding :9211; `onwatch-update`'s ExecStartPost uses `try-restart`, which never revives a failed unit. Fix (approval-gated, severs live sessions for seconds): kill orphans → `systemctl --user start better-ccflare onwatch` (units are enabled and will claim the freed ports) → health-check. Also 07-02: ccflare accounts 6/7 paused incl. acct-a (codex) since 06-30 → **codex delegation blocked** until unpaused; 24h flow ≈ 5.9k req / 978M tokens, nearly all through one Max account. grok-in-onwatch confirmed current (~288 snapshots/day since ~06-27).
