---
name: claude-code-opus48-overload
description: "Constant Claude Code \"rate limited / not your usage limit\" errors are Opus 4.8 global server overload amplified by ~6 concurrent sessions on one account — NOT a usage cap, auth, or retry problem. Mitigated: session model pinned to Fable + all traffic on better-ccflare :8788 failover."
metadata:
  node_type: memory
  type: project
  originSessionId: 6f32c66d-738b-439e-aa6f-3171ffb1e5c3
---

## Diagnosis (the durable point)

The recurring Claude Code error **"Server is temporarily limiting requests (not your usage limit) · Rate limited"** is **server-side overload of `claude-opus-4-8` specifically** — NOT a subscription usage cap, auth, or retry problem. Evidence (June 2026):

- 176/185 recent API errors (95%) were HTTP 429 `overloaded_error`; **174/176 (99%) on `claude-opus-4-8`** (Sonnet/Haiku ~0). Zero subscription-cap events.
- Usage at the time was **5h 14% / 7d 64%** — nowhere near the cap — with **~6 concurrent Claude Code CLI sessions on one account**. With no default model configured, sessions defaulted to Opus 4.8, the one model Anthropic was overloading.

## Ruled out — do not re-try these

`forceLoginMethod: claudeai`; `CLAUDE_CODE_MAX_RETRIES=20` (transcript still capped at 10 — retries can't fix a vendor capacity shortage); sequential account rotation (every Max account hits the same overloaded Opus fleet). The leaked private evals repository `ANTHROPIC_API_KEY` in env is **NOT the cause** and is harmless (the proxy ignores client auth) — this doc's old filename ("…-credential-leak") was a disproven early hypothesis.

## Live mitigation (current state)

- **Model pin:** `~/.claude/settings.json` sets `"model": "fable"` (verified 2026-07-03) → sessions no longer default to Opus 4.8, neutralizing the main trigger.
- **better-ccflare failover proxy on :8788** carries ALL Claude traffic via `env.ANTHROPIC_BASE_URL=http://localhost:8788`. Two Max accounts (`acct-c`, `acct-g`) added by OAuth on the **`session` strategy** (auto-drains both weekly caps; the ban-prone round-robin/least-requests strategies were removed upstream). Client needs only `ANTHROPIC_BASE_URL` (no `ANTHROPIC_AUTH_TOKEN`); `forceLoginMethod: claudeai` is compatible.
- **Persistence** = a self-healing idempotent `~/.bashrc` guard (starts the proxy on :8788 if `ss` shows nothing listening), NOT systemd — WSL does not run the user systemd manager. Monitor: `http://localhost:8788/dashboard` or `better-ccflare --stats`. Rollback: remove `ANTHROPIC_BASE_URL` from settings.json + remove the `.bashrc` block + kill the PID. *[SUPERSEDED 2026-09-28: persistence is the system unit `/etc/systemd/system/ccflare-stack.service` (`Restart=always`, runner restarts its children); the `.bashrc` guard and the "WSL does not run the user systemd manager" claim are both stale (the user manager runs; see `codex-delegation-setup.md`). Owner line: `HARNESS.md` → "ccflare gateway".]*
- **ToS:** relay-proxying OAuth tokens carries residual (undocumented-for-personal-use) ban risk; mitigated by the session strategy + two separate-payment subscriptions. `claude-swap` is the fallback if spoofing ever breaks.
- **Higher-leverage levers if caps still bite:** split concurrent load across the 2nd Max account (done, via ccflare), stagger concurrent review launches, `/model` during bursts, and fail heavy batches to Codex (gpt-5.5, already in the workflow).

## Operational gotchas (learned the hard way)

- **Never `pkill -f <pattern>` where the pattern could appear in your own command line** — `-f` matches the full command line, so the invoking shell self-matches and dies (exit 144; hit with `pkill -f 'better-ccflare …'`). Identify the real listener with `ss -ltnp` / `lsof` and kill that PID instead.
- `settings.json` is rewritten sub-second by live sessions and the ad stack, so the Edit-tool stale-state guard trips — modify it with an **atomic python read-modify-write** (`os.replace`), not the Edit tool.
- Port **8788 is deliberate**: 8080 was owned by another enabled local service (later freed, but ccflare was left on 8788 — re-porting is churn that already broke settings.json once).

Related: [[model-usage-tracking-infra]] (ccflare routing; onwatch usage tracking retired 2026-08-06), [[codex-delegation-setup]] (Codex-side failover). Committed API keys in a private repository's `.mcp.json` stay unless the repository's trust boundary changes.
