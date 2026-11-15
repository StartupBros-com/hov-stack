---
name: statusline-ad-stack
description: "Statusline chain: the local HUD of two or three rows, plus rows for PR links that wrap (prompt-cache TTL, quotas, route, privacy toggle) and the removed kickbacks/vibe-ads/onwatch and waitline ad injectors"
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

**Layout (2026-11-15).** Up to three rows, with PR-only rows appended when the
links need them. Claude Code passes the terminal size to the status line command
as `COLUMNS` and `LINES`, and cuts each row at `COLUMNS - 4` cells with `…`
(measured on 2.1.325). The renderer reads `COLUMNS` only, and rebuilds each row
to fit that budget, down to the floor described below. A `COLUMNS` that is
missing, or is not a whole number from 40 to 99999, falls back to a 108-cell
budget, so a terminal under 40 columns gets rows built for 108. Links wrap whole and never disappear at a drop level. One session at 132
columns, then at 60:

```
ctx █▉░░░░░░ 23% 230k/1M │ cache 48m→02:30 │ Fable 5.2 xhigh │ $12.34
reminder-diet cleanup │ hov-stack › wt statusline-refresh ±2 │ last session route ● max-acct-b (5h 33% 7d 58%, 4s ago)
5h  ███▎░░░░ 41%→03:52 │ 7d █████░░░ 63%→Tue 01:42 │ PR #625 ready │ 7f3a9c21

ctx █▉░░░░░░ 23% │ cache 48m→02:30 │ Fable 5.2 │ $12.34
reminder-diet cl… │ hov-stack › wt statusline-refresh ±2
5h  ███▎░░░░ 41% │ 7d █████░░░ 63% │ PR ✓#625
```

- **Rows.** Row 1 is context, prompt cache, model and cost. Row 2 is the
  session's name, where it is working and the last route. Row 3 is the two quota
  windows, the PR links and the session id. A row with nothing to show is not
  drawn. A session id with nothing beside it on row 3 moves to the end of the
  row above when it fits there, so a fresh session draws two rows.
- **What a row sheds, in order, until it fits.** Row 1: the reply's age, the
  miss cause, the token count, a cold cache's idle time, the `re-cache` word,
  the effort, a warm cache's expiry clock (on a cold cache, the separator
  before the estimate), the meter, the cost, `fast`. Row 2: the session
  name narrows first, to 24 cells; then `last session route` becomes
  `last route`; then the worktree name, the route's age, account windows past
  two, the path and a long account name (trimmed), the remaining windows, the
  name down to 10 cells, the route, the name down to 4 cells, the name. Row 3:
  PR state words become glyphs; then the session id, the reset clocks, the
  meters. A PR known only by its number keeps its review label beside linked
  PRs at every width, because it has no glyph to fall back to.
- **The floor.** A row that has shed everything is drawn as it stands, and
  Claude Code cuts it. Row 1 keeps context percent, cache state, model and a
  differing last reply at any width. In the suite's crowded fixture, which has a
  remapped reply with a long model name, that is 68 cells, so it is cut in a
  terminal under 72 columns. Row 2 keeps the trimmed path, a linked worktree's
  `wt` marker, the branch and the change count: the path trims to 24 cells but
  the branch is never shortened below its 40-cell cap, so a long path with a
  40-cell branch and a one-digit change count is 70 cells and is cut under 74
  columns (73 cells and 77 columns in a linked worktree). Rows 2 and 3 of the crowded fixture fit at 60.
- **Meters** are 8 cells filled in eighths (`▏▎▍▌▋▊▉█` over a `░` track), and any
  use above zero shows at least one eighth. The context meter is coloured by
  pressure, running green to orange to red, each cell by the level its position
  stands for. A quota meter is one quiet gray until its window
  reaches 60%. The track stays in the text, so a meter reads with colour
  stripped.
- **Colour depth.** When `COLORTERM` is `truecolor` or `24bit`, pressure
  colours blend in 24-bit colour between green at 0%, orange at 60%, red at 85%
  and a deeper red at 100%. Otherwise five 256-colour codes step at 45%, 60%,
  75% and 85%. The text is identical either way.
- **Session name.** `session_name` leads row 2 in bold accent colour. It is free
  text, so it is cleaned before it is drawn: a line break or tab becomes a
  space, control characters go, and only printable ASCII and Latin-script
  letters and symbols (U+00A1 to U+024F) stay, so a CJK or emoji title cannot
  take two cells. It is cut at 40 cells with `…`.

- **cache** reads Claude Code's own `prompt_cache` status-line field (originally
  inspected in 2.1.292; partial-usage behavior checked in 2.1.312). A build
  without the field renders no segment. In the inspected native implementation,
  the field covers the main conversation rather than subagent traffic. Warm
  shows the time left and absolute expiry when supplied, green until the last
  fifth of the native TTL and orange after; without expiry it displays `warm`.
  Cold shows idle time and the native re-cache estimate (`re-cache ~155k`) when
  available. It is blue, not red, because a cold cache is a cost, not an error.
  On warm frames, space permitting, a recognized non-idle miss cause appears in
  Claude Code's wording for up to ten minutes. The segment is absent when
  `prompt_cache` is missing or not an object, `caching_observed` is not true, or
  `warm` is not boolean. Absence alone does not prove that the provider disabled
  caching.
  **Unavailable usage (2026-10-27):** explicit numeric zero in all four
  `current_usage` counters, zero `total_input_tokens`, and no positive finite
  percentage render `ctx usage unavailable`. In that state, an otherwise
  eligible cold cache frame without a finite numeric expiry or positive finite
  re-cache estimate renders `cache unknown`. Independent warmth, expiry, and
  positive estimates retain their existing display; an old miss timestamp alone
  does not settle this attempt. Positive measurements and fresh/legacy payloads
  without a complete four-zero usage object are unchanged. Unknown is not proof
  of a provider miss, and unavailable does not mean generation is still running.
  No prior transcript counts are substituted; native TTL labels do not measure
  upstream retention.
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
- **PR states:** each known state has a colour, a word and a glyph, so it reads
  with colour stripped: purple `merged` `◆`, gray `closed` `×`, gray `draft` `◇`,
  green `ready` `✓` (checks passed with no blocking review decision), orange
  `waiting` `○` (pending or failing checks, or a blocking review). Unknown is
  neutral with neither. The word follows the link (`#625 ready`); when the row
  is too wide for words the glyph leads it instead (`✓#625`). Closed and draft
  share a colour and are told apart by word and glyph. A detached child makes one batched `gh api graphql`
  read against github.com; rendering never waits for that network request.
  It kills `gh` after 8 seconds, atomically stores results for two minutes, and
  deduplicates launches with a short-lived lock. Failed reads also get the
  two-minute cooldown. Partial GraphQL errors leave only affected PRs unknown;
  errors without an attributable alias leave all states unknown. Missing
  checks/auth/`gh`, corrupt data and expired cache stay unknown rather than
  fabricated green. A payload `review_state` of `pending` or
  `changes_requested` can mark only its exact current PR waiting, and only where
  the cache has no entry for it or the helper's own `unknown`; approval alone
  does not prove checks passed. A cached state this renderer
  does not know, such as one written by another version of the helper, draws as
  unknown.
  No other PR inherits it. `STATUSLINE_PR_REFRESH=0` disables background reads
  for offline use while retaining links and fresh cached states.
  `STATUSLINE_PR_CACHE_DIR` relocates the default `~/.cache/claude-statusline`
  directory. State files are disposable; association files preserve previously
  observed typed links that compaction might otherwise discard. No hook,
  daemon, timer, or plugin discovers or refreshes these links.
- **Screenshots:** `STATUSLINE_PRIVATE=1`, or `touch ~/.claude/statusline-private`,
  masks the account to its plan family (`max-•••`), or whole (`••••`) when the
  prefix is not a known plan family, and hides the session name and the session
  id. Repo, branch and PR number still render. Remove the file to undo. The flag is read on every render, so it takes effect
  within one refresh.
- Payload text (model name, cwd, branch, worktree name) has C0/C1 controls and
  bidi overrides stripped. Effort, PR review state and session id must match
  allowlists or they are dropped. No Nerd Font glyphs are used: every character
  is in a standard Unicode block. The set before 2026-11-15 was checked in a
  stock terminal font, Termius on iOS included. The meter eighths added then
  (`▎▍▌▋▊▉`; `▏` was already drawn) and the PR glyphs (`◆ ◇ ✓ ×`; `○` was
  already drawn) have not been checked there. Widths are counted one cell per character, which holds
  where the terminal draws East Asian ambiguous-width characters narrow (the
  default outside CJK locales); a terminal set to draw them wide gives several
  of these glyphs two cells, and rows run wider than counted.

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
