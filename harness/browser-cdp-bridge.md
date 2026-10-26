---
name: browser-cdp-bridge
description: "wsl-cdp: agent access to the real Windows browser over CDP from WSL2 — architecture, security posture, troubleshooting"
metadata:
  node_type: memory
  type: project
---

# browser-cdp-bridge — real-browser agent access from WSL2

`wsl-cdp` gives any agent — session, subagent, cron, script — a real,
persistently-logged-in Windows browser session over the Chrome DevTools Protocol.
It is a standalone tool + Claude Code plugin, published at
[StartupBros-com/wsl-cdp](https://github.com/StartupBros-com/wsl-cdp) (MIT) and on
the hov marketplace (`claude plugin install wsl-cdp@hov`). On this box it lives at
`~/.local/share/wsl-cdp/` (PATH via `~/.local/bin/wsl-cdp`) and the plugin cache
under `~/.claude/plugins/cache/hov/wsl-cdp/`. Origin + threat model verified
2026-08-08 (30 claims checked, 0 refuted); hardened to v0.3.0 the same day (19
defect fixes + a behavioral test suite; wsl-cdp#6).

> **Retired 2026-08-08:** the dotfiles-vendored duplicate `brave-cdp`
> (`bin/brave-cdp*`) was removed in favor of dogfooding the published
> plugin — one source of truth instead of a diverged, less-hardened copy. A
> transitional standalone fallback remains at `~/.local/share/brave-cdp/`
> (`~/.local/bin/brave-cdp`) until `wsl-cdp` is proven on its own logged-in
> profile; delete it once that happens. The Windows login profile
> `C:\Users\<you>\.brave-cdp\profile` is independent and survives regardless.
> Full history: memory `[[brave-cdp-real-browser-bridge]]`.

## Why not the Claude-in-Chrome extension

The extension's transport is a **native messaging host**: Windows Brave spawns the
CLI as a child process over stdio/named pipe. A process on Windows cannot spawn one
inside the WSL VM, and Claude Code additionally hard-gates the feature (`isWSL`
check — the minified branch `case"wsl":default:return null` is visible in
anthropics/claude-code#14507's stack trace; docs state "Chrome integration isn't
supported in WSL"). The community native-messaging bridge (#41625,
`CLAUDE_CODE_ENABLE_CFC=1` + registry key + `wsl.exe` stdio hop) was closed
not-planned — usable but self-maintained; we chose raw CDP instead, which is what
every verified working WSL2 setup uses. The officially supported alternative is
running Claude Code natively on Windows (`winget install Anthropic.ClaudeCode`) —
legitimate for browser-heavy one-offs, but it forks off this WSL harness (hooks,
guards, memory), so it is not the daily driver.

## Architecture

```
WSL 127.0.0.1:9223 ──wsl-cdp-forward.py──► WIN_IP:9224 ──netsh portproxy──► 127.0.0.1:9223 browser
    (per-connection TCP relay)             (one-time elevated setup)        (dedicated agent profile)
```

Every constant is load-bearing:

- **9223/9224, never 9222** — the pro-gate oracle bridge's Chrome owns
  `127.0.0.1:9222` inside WSL (Xvfb + ChatGPT profile). `wsl-cdp up` refuses any
  port that has a foreign listener rather than fighting it. (`WSL_CDP_PORT` /
  `WSL_CDP_PROXY_PORT` override, but the defaults exist for this reason.)
- **WSL listen port == browser's debug port** — DevTools echoes the request Host
  header into `webSocketDebuggerUrl`, so clients are handed
  `ws://127.0.0.1:9223/...`; that URL only resolves from WSL because the local
  relay listens on the same port. This is why the forwarder exists at all (and why
  it relays raw bytes: WebSocket upgrades and multi-MB screenshot frames pass
  through unparsed, with an asyncio half-close guard so a client half-close never
  truncates a large reverse stream).
- **portproxy listens on 9224 ≠ 9223** — a portproxy rule on the browser's own port
  can grab `127.0.0.1:9223` before the browser binds it, pushing it to `[::1]` and
  self-looping IPv4 traffic (the classic stale-rule failure). Distinct ports make
  that race structurally impossible; `setup-windows` also sweeps stale rules on
  both ports, and `doctor` warns if one reappears.
- **Dedicated profile `C:\Users\<you>\.wsl-cdp\profile`** — Chromium 136+ silently
  ignores `--remote-debugging-port` on the default profile
  (developer.chrome.com/blog/remote-debugging-port), and the agent profile is the
  security boundary: log it into exactly what agents need, never the primary
  profile (prompt-injection → authenticated-session exfiltration is the live
  threat model; see the July 2026 Claude-for-Chrome disclosure).
  `--remote-allow-origins=*` is required for cross-host WebSocket handshakes.
- **Nothing is LAN-exposed** — the browser binds loopback only (Chromium removed
  `--remote-debugging-address`); the portproxy's 0.0.0.0 listen (IP-churn-proof
  across reboots) is closed down by a firewall rule scoped to the WSL NAT range.

## Operating it

- `wsl-cdp up` / `down` — `up` is self-healing and idempotent: it short-circuits
  when the port already answers, else refuses foreign listeners, checks the
  portproxy, launches the browser if needed, and (re)starts the forwarder with a
  fresh `WIN_IP` (it changes across reboots; `up` re-resolves every time). `down`
  tears the forwarder back down.
- `wsl-cdp status` / `doctor` (`--json`) — one line per chain link, exit code = first
  broken link, remediation attached. The Windows side is probed directly so a live
  forwarder can never mask a dead bridge. Exit codes: `0` ok · `1` chain/forwarder
  down · `2` usage/invalid argument · `3` end-to-end fail.
- `wsl-cdp setup-windows` — the ONE human step, once: triggers UAC and installs the
  portproxy + firewall rules. TOCTOU-free (the PowerShell body is passed inline via
  `-EncodedCommand`, no swappable on-disk artifact). Idempotent (delete-then-add;
  run twice ⇒ still one rule).
- Agent verbs: `tabs` · `open URL` · `close ID` · `eval JS [TAB]` · `text [TAB]` ·
  `screenshot [FILE] [TAB]` (the last three need node ≥22 — built-in WebSocket; the
  driver rejects pending calls on `ws.onclose` so a dropped socket can't hang, and
  strips C0/DEL control bytes out of untrusted page `innerText`). `print-launch`
  shows the exact browser command line; `url` prints the CDP WebSocket URL.
- `wsl-cdp mcp-add` — writes a per-repo `.mcp.json` entry for
  `chrome-devtools-mcp --browserUrl=http://127.0.0.1:9223` in the CWD. Per-repo by
  policy: stdio MCP servers multiply per-session RAM across ~20 concurrent
  sessions and harness-doctor check 3 warns on new global stdio
  ([[cc-mcp-architecture]]). The CLI is the default agent surface (CLI-over-MCP
  doctrine); reach for the MCP server for long autonomous browse loops in a
  specific repo. `--browserUrl` chosen over playwright-mcp's `--cdp-endpoint`
  because the URL survives browser restarts.
- Env: `WSL_CDP_PORT` `WSL_CDP_PROXY_PORT` `WSL_CDP_WINUSER` `WSL_CDP_BROWSER`
  `WSL_CDP_USERS_ROOT` (autodetects Windows user + Chrome→Edge→Brave since
  v0.3.1 — Brave demoted because its updater can't swap the shared versioned
  install while a daily-driver `brave.exe` runs, relaunch-looping the agent
  instance. Once launched, the profile's recorded browser
  (`%USERPROFILE%\.wsl-cdp\browser`) outranks autodetect, so the vendor never
  silently changes under a logged-in profile; override only when detection is
  wrong).

## Layered browser stack (which tool when)

1. **In-WSL Playwright, no bridge** — dev loops: tests, screenshots of local apps,
   front-end verification. `~/.cache/ms-playwright` Chromium is already installed;
   `npx playwright ...` headless works without WSLg.
2. **wsl-cdp** (this doc) — anything needing the operator's real logged-in
   sessions: SaaS consoles, dashboards, authenticated reads.
3. **browser-console-setup skill** — unchanged: Google OAuth / 2FA / CAPTCHA walls
   stay human-in-the-loop. Verified industry consensus: no stealth or cloud
   product clears Google's "browser may not be secure" either; session
   capture/reuse or a human is the answer.
4. **Cloud/stealth browsers (Browserbase, Kernel, browser-use.com, …)** — NOT
   adopted (2026-08 decision): they solve unattended/serverless execution, >~10
   concurrent sessions, and anonymous multi-tenant browsing — none of which this
   harness has. Revisit trigger: a workload that must browse while no WSL box is
   running, or sustained scraping against active bot walls. Kernel had the
   cleanest Claude Code path at evaluation time if that day comes.
5. **ChatGPT Pro's chat pool (not a browser tool, but shares this territory)** —
   two separate lanes, neither part of the stack above: pro-gate's oracle
   bridge owns its own Xvfb Chrome on `127.0.0.1:9222` (never wsl-cdp's
   9223/9224), and async research fleet-style GitHub-connector threads need no CDP
   bridge at all. Which lane takes which task is routed in [[pro-capacity-lanes]],
   not here.

## Security posture

The agent profile is deliberately narrow: treat everything it is logged into as
reachable by any agent driving the bridge, and treat page content as untrusted
input (the gate in `CLAUDE.md`, Harness section). Do not log the profile into
banking or anything with irreversible sends. The bridge itself adds no remote
exposure: WSL-subnet-scoped firewall, loopback-bound browser, no public listener.

**Co-resident distros share one loopback namespace.** All WSL2 distros on a host
share `127.0.0.1`, and the relay has no auth — so any other distro can reach the
bridge on `9223`. `doctor` WARNs when a second distro is present; **this box runs
a second WSL distro alongside, so the bridge is live-exposed to it.** Relay
auth is deferred (wsl-cdp#7). Keep the agent profile scoped accordingly.

## Troubleshooting (verified failure modes)

| Symptom | Cause | Fix |
|---|---|---|
| `up` fails: port taken by google-chrome | you set `WSL_CDP_PORT=9222` (oracle bridge) | unset it; 9223 is the default for this reason |
| Brave (pinned via `WSL_CDP_BROWSER`) relaunch-loops on a fresh profile | daily Brave holds the shared install; the staged update swap can't complete, each agent launch re-detects "update pending" | close EVERY `brave.exe`, launch Brave once so the update finishes, then `up` — or drop the pin and let autodetect pick Chrome/Edge (different install, no contention) |
| browser runs, `/json/version` empty on Windows | debug flag ignored: default profile, or stale portproxy rule grabbed 9223 first | dedicated `--user-data-dir` (`print-launch` shows it); `setup-windows` sweeps stale rules |
| `winside` unreachable, portproxy rule present | firewall rule missing/mis-scoped, or browser not running | rerun `setup-windows`; `doctor` separates the two |
| worked yesterday, dead today | Windows reboot changed `WIN_IP`; forwarder targets the old one | `wsl-cdp up` (kills + restarts the forwarder with a fresh IP) |
| WebSocket connects then drops instantly | missing `--remote-allow-origins` on the browser's command line | it's in `launch_argv`; if the browser was started by hand, restart via `wsl-cdp up` |
| mirrored networking curiosity | `networkingMode=mirrored` can reach Windows loopback at `localhost` directly, no portproxy | untested here (NAT assumed); microsoft/WSL#40343 documents flaky mirrored loopback — the portproxy path is the reliability choice |
