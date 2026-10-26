---
name: statusline-ad-stack
description: "Statusline chain: the local three-line HUD (prompt-cache TTL, quotas, route, privacy toggle) and the removed kickbacks/vibe-ads/onwatch and waitline ad injectors"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 6b7c256f-0e7d-46be-b770-a3e1500d8d90
---

Will's Claude Code status line WAS a chain of ad-injector products. Both are now gone;
what remains is a single dependency-free local renderer.

**Current chain (updated 2026-09-29):** `settings.json` `statusLine` =
`sh ~/.config/statusline-stack/stack.sh` → `stack.sh` reads the command out of
`~/.config/statusline-stack/original-statusline.json` →
`node ~/.config/statusline-stack/local-statusline.mjs`. That is the whole chain.
The renderer gets context %, prompt-cache state, requested model, effort, cost,
Claude Code's 5h/7d quota and the session's PR from stdin. It adds two
independent historical observations:

- **last reply:** the physical model on the last non-sidechain assistant record
  in the transcript, displayed when it differs from the requested model. Its age
  comes from that record's timestamp. A new user turn does not make it current.
- **last session route:** the account most recently associated with the session
  when better-ccflare recorded response forwarding (normally at entry into
  `forwardToClient`, also on direct terminal forwarding). This is neither
  dispatch-start nor proof of successful stream completion. Subagents share the
  session ID, so this account need not correspond to the last main-chain reply.
  Quota percentages retain the endpoint's account-window meanings. The route's
  age comes only from the endpoint's numeric epoch-ms `data.account.recordedAt`.

Missing, invalid or future timestamps read **age unknown**. An older gateway
without `recordedAt` still renders the account and quota. The five-second cache
only reduces HTTP reads; its fetch timestamp never supplies an observation age.
The endpoint follows `ANTHROPIC_BASE_URL` when set, otherwise probes local port
8788. Fetches are 250ms-bounded (`LOCAL_STATUSLINE_PROVENANCE_TIMEOUT_MS`
overrides it, 1-10000 ms), displayed metadata is sanitized, and failures
leave the rest of the HUD intact. These labels repair the misleading old arrow
and unqualified account badge; they do not add in-flight progress telemetry.

**Layout (2026-10-07).** Three lines when the PR links fit, with compact PR-only
rows appended when needed. The renderer is never told the terminal width, so
each line fits a 108-column budget; links wrap whole, never disappear at a drop level:

```
ctx ▕██░░░░░░░░▏ 15% 152k/1M │ cache 48m→15:10 │ Opus 5.5 xhigh │ $18.42
dotfiles › wt statusline-hud ±1 │ last session route ● acct-c 5h 24% 7d 83% (7s ago)
5h  ▕██░░░░░░░░▏ 23%→15:52 │ 7d ▕████░░░░░░▏ 41%→Sun 14:22 │ PR #1673 #1682 │ a6eda6ea
```

- **cache** reads Claude Code's own `prompt_cache` status-line field (read from
  the 2.1.292 bundle; a build without the field renders no segment). It covers
  the main conversation only, so subagent traffic cannot move it. Warm shows the time left on the TTL and its absolute expiry, green
  until the last fifth of the TTL and orange after. Cold shows the idle time and
  the tokens the next turn writes again (`re-cache ~155k`). It is blue, not red,
  because a cold cache is a cost, not an error. For ten minutes after a miss
  that idle time did not cause, the segment names the cause in Claude Code's
  wording. The segment is absent before the first request and when the API
  reports no caching.
- `statusLine.refreshInterval: 30` re-renders every 30 seconds so the countdown
  moves while the session is idle. `sync.sh` never writes `statusLine`:
  settings.json is volatile and `check` excludes the key. The tracked value only
  seeds a new host, so the live `~/.claude/settings.json` needs the same key set
  by hand.
- **PR links:** `pr-links.mjs` unions the payload PR with native job `children`
  of kind `pr`, accepting a job only when `sessionId` or `resumeSessionId` matches
  this session. `CLAUDE_JOB_DIR` is preferred; resumed-job discovery checks at
  most 256 directory entries/25ms in `~/.claude/jobs`, with bounded metadata
  reads. Typed, same-session transcript `pr-link` events also contribute;
  arbitrary URLs in messages never do. Transcript reads advance at most 1 MiB
  per render and retain earlier associations across transcript replacement or
  compaction in a separate cache. A large cold interactive transcript can take
  several refreshes to catch up. Native job children avoid the transcript
  replay's last-wins loss; links already lost before this cache existed cannot
  be recovered from a compacted interactive transcript alone.
  Targets must be canonical `https://github.com/owner/repo/pull/number` URLs,
  without credentials, query, fragment or terminal controls. Identities dedup
  case-insensitively by repository and number. The payload's repository uses
  `#N`; others use `repo#N`, or `owner/repo#N` when repository names collide.
  Exceptionally long labels abbreviate with their list position and PR number;
  their full hyperlink targets remain intact. OSC8 links work through piped
  stdout; `FORCE_HYPERLINK=0` keeps the same plain labels. Both OSC8 and SGR
  escapes are excluded from width calculations. Older number-only payloads
  retain their existing unlinked review label.
- **PR colors:** purple = merged, gray = draft/closed, green = checks passed
  with no blocking review decision, yellow = pending/failing checks or blocking
  review, neutral = unknown. A detached child makes one batched `gh api graphql`
  read against github.com; rendering never waits for that network request.
  It kills `gh` after 8 seconds, atomically stores results for two minutes, and
  deduplicates launches with a short-lived lock. Failed reads also get the
  two-minute cooldown. Partial GraphQL errors leave only affected PRs unknown;
  errors without an attributable alias leave all states unknown. Missing
  checks/auth/`gh`, corrupt data and expired cache stay unknown rather than
  fabricated green. Payload `review_state` can mark
  only its exact current PR waiting; approval alone does not prove checks passed.
  No other PR inherits it. `STATUSLINE_PR_REFRESH=0` disables background reads
  for offline use while retaining links and fresh cached states.
  `STATUSLINE_PR_CACHE_DIR` relocates the default `~/.cache/claude-statusline`
  directory. State files are disposable; association files preserve previously
  observed typed links that compaction might otherwise discard. No hook,
  daemon, timer, or plugin discovers or refreshes these links.
- **Screenshots:** `STATUSLINE_PRIVATE=1`, or `touch ~/.claude/statusline-private`,
  masks the account to its plan family (`max-•••`), or whole (`••••`) when the
  prefix is not a known plan family, and hides the session id. Repo, branch and
  PR number still render. Remove the file to undo. The flag is read on every render, so it takes effect
  within one refresh.
- Payload text (model name, cwd, branch, worktree name) has C0/C1 controls and
  bidi overrides stripped. Effort, PR review state and session id must match
  allowlists or they are dropped. No Nerd Font glyphs are used, so the HUD
  renders in a stock terminal font, Termius on iOS included.

**onwatch / Kickbacks.ai / vibe-ads — RETIRED 2026-08-06** (one product, three names).
Backend was `https://kickbacks-public-*.run.app`; daemon `~/.onwatch/bin/onwatch` rotated
ad creatives into `cli-ad.json` (the "ad·" line) and into `settings.json` `spinnerVerbs`,
rewriting settings.json live — which is why that file churned and drifted from this repo.

By the time it was removed it was doing none of that: `~/.vibe-ads/` was already gone,
`spinnerVerbs` was already absent, and the ad line rendered zero times. What survived was
a zombie — a system unit at `/etc/systemd/system/onwatch.service` with `Restart=always`
(NOT the disabled user unit of the same name, which misled the first removal attempt),
plus a `--debug` log with no rotation. Two separate copies of its capture wrapper also sat
in the render chain, in `settings.json` and in `original-statusline.json`, each writing the
session JSON to `~/.onwatch/data/` on EVERY render. **Nothing ever read either copy back.**
Removing both changed the rendered output by 0 bytes, verified against a captured session.

Removal: `sudo systemctl disable --now onwatch.service` (system scope — the user-scope unit
was a disabled decoy), `systemctl --user disable --now onwatch-update.timer` (else it fails
daily), strip the capture wrapper from both chain sites, then delete `~/.onwatch`.

**WaitLine** (getwaitline.com) was a SEPARATE competing ad product. Removed 2026-06-29: it
rendered via a hardcoded glob in `stack.sh` into
`~/.claude/plugins/cache/waitline-marketplace/.../waitline.min.js` that bypassed the plugin
enable/disable system — which is why removing it from `enabledPlugins` didn't stop it.
Fix = delete the WaitLine block in `stack.sh` + deregister from
`installed_plugins.json`/`known_marketplaces.json` (had `autoUpdate:true`) + `rm` the three
plugin dirs (cache/marketplaces/data). Backups: `*.bak.20260629-165103`.

The recurring lesson across both removals: **an ad injector's uninstall path is not its
install path.** WaitLine survived `enabledPlugins` removal via a hardcoded glob; onwatch
survived `systemctl --user disable` because the live unit was system-scope. Verify by
process and cgroup (`/proc/<pid>/cgroup`), not by the config you think owns it —
`scripts/agent-write-guard.py` now checks exactly that. See [[worktree-fleet-hygiene]]
for other env setup.
