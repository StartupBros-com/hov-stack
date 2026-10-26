# Claude Code mod ideas: ranked backlog

Generated 2026-10-01 from a six-lens ideation workflow (78 raw ideas, 48 after merge, 41 survived a three-lens adversarial judge: API feasibility against the 2.1.287 types, value and durability, shareability and differentiation). Scores are 1-5 per lens: f = feasible on the real API, v = value, s = shareable. Total weights f 1.2, v 1.3, s 1.0.

Built first (2026-10-01): loop-breaker (M12), secret-stop (M39), install-preflight (M45). See the sibling folders. secret-stop was retired on 2026-10-03 after real use (see its build spec below). install-preflight was unwired from global settings on 2026-10-04 (no runs; agents call `claude plugin validate` directly) and is kept for the marketplace. The vendored community mods next-steps and where-am-i were deleted on 2026-10-06 and 2026-10-07 on the operator's verdicts (see rows 2b and 2 below).

Operator rule from that verdict: no mod that blocks or asks on a guess. A guard earns a place only by removing friction for long-running agents, never by adding a stop to their work.

Built 2026-10-03: read-ceiling-pager (M04), picked from the ranked QoL shortlist for
long-running agents; its README carries the measured defect it answers.

Built 2026-10-04: reminder-diet (M33), narrowed from "learns which reminders are noise" to
the measured case, exact repeats of the engine's task reminder; its README carries the numbers.

The original scores below are build-idea rankings, not adoption approvals. See
[community mod evaluations](#community-mod-evaluations-2026-10-03) for later
published implementations, coverage gaps and bounded trial decisions.

Consumer: whoever picks the next mod to build here or to graduate to the House of Vibe marketplace. Delete this file when the surviving rows have become GitHub issues on their plugin repositories, or when a later ideation pass replaces it.

## Survivors

| id | total | f | v | s | size | audience | name | what it does |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| M12 | 15 | 4 | 4 | 5 | xs | both | loop-breaker | Detects Claude repeating the same failing call, shows a worsening face, injects a hint with the passing alternative, and offers a one-tap Stop and Rethink. |
| M30 | 14 | 4 | 4 | 4 | m | both | secret-scrub | Redacts API keys and tokens from rows before they are stored and from tool output, with a reversible local map and a count band. |
| M19 | 13.8 | 3 | 4 | 5 | l | both | mod-gatekeeper | A personal seatbelt for installing mods: shows a plain-language 'what this can touch' card, refuses risky capabilities by your rules, and re-asks when an update adds powers. |
| M39 | 13 | 4 | 4 | 3 | xs | both | secret-stop | Before git commit or push, scans the staged diff for API keys and .env files and stops you with plain advice. |
| M08 | 12.8 | 3 | 4 | 4 | m | both | precompact-lifeboat | Writes a verified handoff note before compaction, optionally defers needless compactions, re-injects the note afterward and checks key facts survived. |
| M44 | 12.8 | 3 | 4 | 4 | m | both | mod-ledger | Logs every file read, process, network call and model spend by other mods (and Claude's own egress) per mod, with first-seen host flags and per-mod token budgets. |
| M22 | 12.7 | 4 | 3 | 4 | m | both | lesson-harvest | Spots your corrections ('no, use pnpm') and offers to save the rule as a memory in one keypress, after you approve or edit it. |
| M45 | 12.7 | 4 | 3 | 4 | s | both | install-preflight | /preflight <plugin-dir-or-repo> runs claude plugin validate and explains hooks and calls in plain language before you install. |
| M05 | 12 | 4 | 4 | 2 | m | will-personal | bg-job-board | A live pane of every background job, subagent and worktree session with what each is doing right now. |
| M01 | 11.7 | 4 | 3 | 3 | s | both | guard-ledger | A live pane and status count of every guard refusal and tool failure this session, with one-key friction logging to papercut. |
| M09 | 11.7 | 4 | 3 | 3 | m | will-personal | quota-governor | Uses live 5h and 7d plan limits to progressively downshift subagent model/effort, pause fan-out, then ask before the wall. |
| M20 | 11.7 | 4 | 3 | 3 | l | will-personal | session-wall | A live wall and triage inbox of every parallel Claude session: state, branch, cost, last action, filtered peer chatter, with reply from one pane. |
| M29 | 11.7 | 4 | 3 | 3 | l | both | pr-shepherd | A bounded PR babysitter: watches CI and review comments after a push, fixes what it can in capped rounds, then stops for you. |
| M40 | 11.7 | 4 | 3 | 3 | s | both | spend-guard | A per-session token budget: at the limit Claude Code asks whether to continue, switch to a cheaper model, or stop. |
| M41 | 11.7 | 4 | 3 | 3 | s | both | welcome-back-recap | Return after a break and get a three-line recap of done and next, before your first prompt is sent. |
| M28 | 11.5 | 3 | 3 | 4 | l | both | staging-area | Rehearsal mode: Claude's edits are staged in a review pane and land on disk only when you press Apply. |
| M35 | 11.5 | 3 | 3 | 4 | xs | both | turn-bell | Speaks a one-sentence summary aloud when a long turn finishes so you can walk away. |
| M38 | 11.5 | 3 | 3 | 4 | s | hov-builders | plain-english-tools | Rewrites cryptic tool lines into one plain sentence, with raw toggle, a 'What is this?' button, and a plain explanation of red errors with safe options. |
| M27 | 11.4 | 4 | 2 | 4 | m | hov-builders | design-rails-live | Flags off-brand CSS/Tailwind edits as Claude writes them, in a band and in the diff, with a fix button and self-correction. |
| M07 | 10.8 | 3 | 4 | 2 | s | will-personal | fanout-admission-ask | Replaces blind fanout and heavy-job refusals with a budgeted ask showing current load and a one-key override. |
| M04 | 10.7 | 4 | 3 | 2 | xs | both | read-ceiling-pager | Turns 'file exceeds max tokens' Read failures into automatic offset/limit chunked reads. Implemented 2026-10-03 (see `read-ceiling-pager/`): clamps an explicit window to the lines that fit and names the continuation; the engine already paginates whole-file reads. |
| M26 | 10.7 | 4 | 3 | 2 | m | hov-builders | skill-scorecard | Tracks whether each skill actually helped: loaded, corrections, aborts, cost, and ranks them so you can tune the weak ones. |
| M06 | 10.5 | 3 | 3 | 3 | m | will-personal | worktree-holders | Shows which live sessions hold which worktrees and warns before two sessions edit the same one. |
| M18 | 10.5 | 3 | 3 | 3 | m | both | paste-to-mod | Describe the mod you want in one line; it drafts a plugin directory, validates it, and hot-loads it after you press Install. |
| M14 | 10.4 | 4 | 2 | 3 | s | both | turn-postcard | After each long turn, a postcard under the answer: what changed, what was verified, what is still unproven. |
| M25 | 10.4 | 4 | 2 | 3 | m | both | hook-port | Reads your old settings.json hooks and drafts the equivalent typed, tested mod for you to review. |
| M33 | 10.4 | 4 | 2 | 3 | xs | both | reminder-diet | Learns which of Claude Code's injected reminders and system-prompt sections are noise for you, then trims them. Implemented 2026-10-04 (see `reminder-diet/`), narrowed to exact repeats of the task reminder, the only high-volume repeat a 14-day measurement found. |
| M42 | 10.4 | 4 | 2 | 3 | m | both | hov-launcher | /hov opens a pane of House of Vibe plugins with install state, plain description and a one-key install. |
| M46 | 10.4 | 4 | 2 | 3 | xs | both | config-confirmer | Asks for confirmation when Claude edits settings.json, .mcp.json, hooks or shell rc, showing exactly what changes. |
| M47 | 10.4 | 4 | 2 | 3 | xs | both | tripwire-files | Plants decoy secrets (fake ~/.aws/credentials) and alerts loudly if any mod or tool reads them. |
| M32 | 9.7 | 4 | 3 | 1 | xs | both | subagent-switchboard | Picks the model for each subagent by task type and hides subagent types you never want offered. |
| M34 | 9.5 | 3 | 3 | 2 | s | will-personal | friction-preempt | Turns your friction log into system-prompt rules and tool descriptions so Claude stops hitting the same guard refusals. |
| M10 | 9.4 | 4 | 2 | 2 | l | both | review-ladder-conductor | A pane tracking the review ladder per PR (adversarial, ce-code-review, pro-gate round) with next-rung buttons and a live pro-gate status. |
| M11 | 9.4 | 4 | 2 | 2 | l | both | usage-ledger | A mod-native ccusage and viberank plus live flight deck: every model request by agent and model, burn sparkline, ETA to quota, opt-in leaderboard submit. |
| M16 | 9.4 | 4 | 2 | 2 | m | both | cartoon-tool-use | Replaces noisy ToolUse rows with compact glyph-and-verb lines like 'Reading 3 files' and 'Running tests', grouped per step, with hover detail. |
| M24 | 9.4 | 4 | 2 | 2 | xs | will-personal | disk-watchdog | Quietly checks free disk and orphaned processes in the background and warns before a build or install fills the disk. |
| M31 | 9.4 | 4 | 2 | 2 | m | both | step-economist | Reroutes each model request: cheap model and low effort for mechanical post-tool steps, full effort for planning and final answers. |
| M23 | 9.2 | 3 | 2 | 3 | xs | both | honest-attribution | Rewrites the commit/PR attribution footer into a verifiable receipt: models used, turns, whether tests ran, what you reviewed. |
| M43 | 8.2 | 3 | 2 | 2 | l | hov-builders | hov-control-room | One pane for all your HoV plugins: papercut snags, review status, credits, drift and memory ideas, live. |
| M13 | 8.1 | 4 | 1 | 2 | s | both | pixel-pet | A tiny pixel pet in the band that reacts to tool outcomes: cheers on green tests, flinches on failures, sleeps when idle. |
| M21 | 8.1 | 4 | 1 | 2 | xs | hov-builders | commit-confetti | When a push or PR succeeds, a short confetti burst and a 'shipped' card appear with the PR link and live CI status. |

## Killed by the judges

- **readonly-bash-approver** (M03): Overriding a guard's block in tool.check is a trust problem. The same effect is a 20-line allowlist tweak in the readonly-bash hook itself (506 refusals). A mod that auto-approves is also a poor OSS or HoV pitch. Moot since #1874 (2026-10-17) retired the readonly-bash hook itself.
- **scope-leash** (M48): Will already has the worktree route guard, dcg and git-guard. Its top papercuts are guard refusals ('too complex to verify it stays inside the worktree', 35/553), so another path guard adds friction. Bash path parsing is unreliable, and asks will nag.
- **ask-cards** (M15): AskUserQuestion render props are only {tool, questions, metadataSource} (line 9082), and Button.action is only an engine keybinding action (line 926). A replacement card has no way to submit the real answer. Selecting via ui.press cannot reach the original dialog.
- **worktree-shape-fixer** (M02): Duplicates the existing shape-rewrite hook (~1% coverage by design). tool.call mods run before settings hooks, so a rewrite must still pass the real guards. Haiku-proposed rewrites plus ui.ask add nag and risk. Fixing the guard rules is the better fix.
- **guard-kernel** (M36): Replacing 16 shell PreToolUse guards (dcg, git-guard, settings-guard) with a resident module is a large safety-critical rewrite; sec-default and classic hooks already cover them. Latency gain is real but modest; huge surface, overlaps Blast Radius and community blockers, not a HoV fit.
- **session-minimap** (M17): Cosmetic skyline; overlaps Flight Recorder and Replay Theater, messages() caps at 4096, no per-cell press. Nobody reads a minimap after two weeks. Good demo but Will's papercuts (guards, shape refusals) are not addressed.
- **credit-meter** (M37): Meter is a blog suggestion and Will already has a local-statusline HUD showing 5h/7d quota. The token-eater funnel depends on an unknown expiry-file contract. Cosmetic without that; only the Spend button is novel.

## Dropped at merge as duplicates of shipped work

- session-ambient-weather: duplicates @anshuc's cartoon Spinner (1.1k likes) and @TzafrirR's What's-Agent-Doing box (community-shipped)
- quota-sunset: duplicates the blog's suggested cost/rate-limit meter via $.ui.status and the Token Weather blog example (its credit-meter funnel angle folded into credit-meter)
- sandbox-mode-runner: weak near-duplicate of mod-ledger/mod-gatekeeper, unverified that user-tier mods can intercept other user-tier mods; cut for the 48 cap
- hostile-mod-lab: weak, risky to ship attack code in a marketplace; cut for the 48 cap, covered in spirit by mod-ledger and tripwire-files
- mod-trust-card: depends on mod-ledger data and overclaims assurance; cut for the 48 cap (near-duplicate of mod-ledger/mod-gatekeeper)

## Synthesis

### Will's top picks

- **loop-breaker** (M12): Highest score. Result-after-next plus turn.abort is mod-only. xs build, and the loop-guard hook can only refuse.
- **secret-scrub** (M30): session.append is the only way to rewrite stored rows. Quiet and durable. Start with stored rows only.
- **precompact-lifeboat** (M08): Suits long xhigh sessions. Forks the model and verifies the handoff, which the compact hooks cannot. Ship note and re-inject first, no skip.
- **secret-stop** (M39): Pre-commit secret scan with a dialog. xs size, zero nag until a hit.
- **bg-job-board** (M05): Many parallel subagents and worktrees, so a /jobs pane is useful daily. Low viral value does not matter for personal use.
- **lesson-harvest** (M22): Feeds the existing memory-dream format. Opt-in and rate-limited to avoid nagging.

### House of Vibe top picks

- **mod-gatekeeper** (M19): Answers the dominant 'who audits a mod' theme. Nobody has shipped it. The install popup is a clear demo. State its limits honestly. Card: See what a mod can touch before it loads / Refuse risky powers by your rules / Re-asks when an update adds powers
- **loop-breaker** (M12): Av1dlive wanted it and nobody shipped it. The calm-to-sweating face is a clip that needs no narration. Card: Stops Claude repeating the same failing call / You can override or allowlist any tool / One tap to stop and rethink
- **secret-scrub** (M30): Security is the top theme. cat .env showing [REDACTED] is instantly legible. Card: Keys and tokens never reach saved history / Count shown, nothing silently lost / Per-tool opt-out
- **mod-ledger** (M44): A runtime log of what other mods read, run and fetch. Label it a log, not a firewall, and ship the log and first-seen-host alert only. Card: See every file, process and host each mod touches / Flags the first time a mod reaches a new host / Log only, you decide
- **install-preflight** (M45): Raw hooks and calls list before install is a 15-second clip. Complements harness-vet, which vets skills. Card: Plain-language view of what a plugin can do / Raw hooks and calls list is the authority / Install or cancel, your call
- **precompact-lifeboat** (M08): Context guard was the most-wanted unshipped item (Av1dlive, 153 bookmarks). A 'handoff saved' band makes the demo visual. Card: Saves a handoff note before compaction / Checks key facts survived / Re-injects the plan afterward

### Marketing angle

Lead with trust, since 'who audits a mod' is the dominant community worry. Launch HoV as the mods that audit and restrain mods. Pair mod-gatekeeper, mod-ledger and install-preflight under one banner: seatbelts for mods. Show loop-breaker and secret-scrub as the clips, since they work without narration. Put the limits on every card (a seatbelt, not a boundary; a log, not a firewall). Keep to 3 benefit rows per card, with 'you stay in control' as the closing row. Publish the tests and the claude plugin validate output so people can verify the claims themselves.

### Build specs the synthesis wrote

The loop-breaker and secret-stop sketches below are historical, not pending
builds or current contracts. The other sketches remain backlog; rankings and
publishing ideas above are retained from the original synthesis.

#### loop-breaker (M12, half-day; implemented)

Superseded by the [current loop-breaker README](loop-breaker/README.md).
The sketch below records the original proposal.

Highest score. Wanted by both Will and the community, xs size, feasibility 4, and a face clip anyone understands. Serves both audiences.

```text
Files: plugin.json (name loop-breaker), register.tsx, register.test.ts.
State ($.state, declare in PluginState): calls: Record<hash,{fails:number}>, worst: number (0-4).
Config: threshold=3, allow: string[] (tools exempt).
Hooks:
1. tool.call (all tools): hash = sha256 hex via crypto.subtle of tool + JSON of normalized args (sorted keys, trimmed strings). If allow includes tool, return next(e). If calls[hash].fails >= threshold, return {deny:'failed N times identically, try a different approach'} BEFORE calling next. Else r = await next(e). If r.isError, fails++, worst=max(worst,fails); if fails==threshold-1, return {...r, context:['This exact call failed twice. Try a different approach, e.g. <hint>']}. On success delete the key. NOTE: context goes on the RESULT, never into next({...e, context}). $.ui.toast('loop broken: same <tool> failure xN') on deny.
2. turn.start: reset calls and worst.
3. ui.render on AbovePrompt: await next(e); if worst<2 return it. Else Box with Text face (calm/uneasy/alarmed/sweating by worst 2/3/4) and a Button 'Stop and rethink' (hotkey r) -> $.turn.abort() then $.prompt.submit({text:'stop, state what you tried, propose a different approach'}). Yield when props.hasSurvey.
v1: skip the haiku hint. Optional $.ui.ask override.
Tests: 3 identical isError calls then 4th is denied. Different args are not denied. Allowlisted tool is never denied. A success resets the count. turn.start clears state. Hint context is on the result, not the input.
```

#### secret-scrub (M30, day)

Mod-only (session.append), high-value for Will and the leading security demo for HoV. Feasibility 4. Default to stored rows plus tool result, quiet UI.

```text
Files: plugin.json, register.tsx, patterns.ts (exported scrub(text)->{text,hits}), patterns.test.ts, register.test.ts.
State: $.state.count: number; $.state.handles: Record<string,string> (reversible map, memory only, never to $.store).
Config: kinds enabled, optOutTools: string[] (default []), entropyMin.
patterns.ts: regexes for sk-[A-Za-z0-9_-]{20,}, ghp_/github_pat_, AKIA[0-9A-Z]{16}, PEM blocks, and .env KEY=value lines where the key matches /KEY|TOKEN|SECRET|PASSWORD/. Plus a Shannon entropy check on long tokens. Replace with [REDACTED:kind:last4]. Fixture allowlist for obvious examples (EXAMPLE, xxxx).
Hooks:
1. session.append: r = next({...e, message: scrubbed}), rewriting text blocks and tool_result content. Increment count and store handle.
2. tool.call matcher Read|Bash: r = await next(e); rewrite text in r.result so the current step does not see the secret, unless tool is in optOutTools.
3. prompt.submit: if the prompt has a secret, $.ui.status('secret in prompt, scrubbing from history'). Never block.
4. $.ui.status shows 'scrubbed N secrets' when N>0, nothing at 0. No band.
Command: /scrub-count prints count.
Tests: each pattern redacts and keeps the last 4 chars. A normal code line is unchanged. The entropy gate skips hashes with an allowlist hint. session.append rewrites a tool_result. tool.call output is redacted. Handles are never written to $.store. optOut skips a tool.
```

#### secret-stop (M39, hour; implemented, retired 2026-10-03)

Built, redesigned in dotfiles#1510, wired globally on 2026-10-03 by operator
decision, and retired the same day on the operator's real-use verdict: blocking
git commands on a guess stopped agent fleets mid-work. The mod is deleted from
this folder; its last version is in git history at `d0d32c12`
(`mods/secret-stop/`). The sketch below records the original proposal.

xs, feasibility 4, concrete recurring risk. Reuses the secret-scrub patterns, so build it right after. Squarely for HoV non-expert audience.

```text
Files: plugin.json, register.tsx, scan.ts (scanDiff(diffText)->hits[{file,line,kind,redacted}]), scan.test.ts.
Hooks:
1. tool.call matcher Bash: match /\bgit\s+(commit|push|add)\b/. For commit with -a or -am, scan `git diff HEAD`. Otherwise scan `git diff --cached -U0`. Run via $.process.run(['git','diff',...],{timeoutMs:5000}), and `git status --porcelain` for .env* filenames (excluding .env.example). For git add, scan the working diff of the named paths. Ignore added lines only.
2. On hits: try { choice = await $.ui.ask('Found what looks like an API key in config.ts line 12 (sk-…4F2A). Commit anyway?', ['Remove it from the commit','Commit anyway','Cancel']) } catch { return {deny:'secret scan: could not ask, blocked'} }. 'Remove it' runs git reset -q -- <file> via $.process.run and returns {deny:'unstaged <file>, remove the secret and retry'}. 'Cancel' returns {deny}. 'Commit anyway' adds the hit hash to $.store allow list and calls next(e).
3. tool.call matcher Write: if the path matches .env* and is not .env.example, $.ui.ask Allow/Deny.
Patterns: sk-, ghp_, AKIA, PEM, generic KEY=value with entropy. Fixtures allowlist in $.store.
Tests: staged diff with AKIA is denied. Clean diff passes. commit -a scans HEAD diff. An allowlisted hash passes. ask rejection leads to deny. .env.example is ignored. Only added lines are scanned.
```

#### precompact-lifeboat (M08, day)

Most-wanted unshipped item and strong for long xhigh sessions. Build it fourth, note-and-reinject only, with no skip logic.

```text
Files: plugin.json, register.tsx, note.ts, register.test.ts.
State: $.state.pendingNote: string|null; $.state.verified: {ok:number,total:number}|null.
Hooks:
1. session.compact: note = (await $.model.fork({prompt:'List open tasks, files touched, decisions made, next step. Terse bullets.'})).text. Handle reason 'nothing-to-fork' by skipping the note. Write it with $.fs.write to <cwd>/.claude/handoff-<await $.session.id>.md. r = await next(e); then return {...r, messages:[...r.messages, noteMessage]} where noteMessage is a user-role row prefixed 'Handoff note saved before compaction:'. Never return {skip}. $.ui.log('handoff saved').
2. Verification: after next, $.model.complete haiku with the note and the first lines of $.session.messages(): 'list 5 key facts, which appear in the note?'. Store {ok,total} in $.state.verified.
3. ui.render AbovePrompt: if verified is set, show a Text band 'handoff saved, 4 of 5 facts verified' dismissed on turn.complete. Yield when props.hasSurvey.
Do not use classic.SessionStart with context. Its field is additionalContext.
Tests: compaction yields a messages array whose last element is the note. nothing-to-fork produces no write and no crash. The file is written to the expected path. Fork failure still lets compaction proceed. The verified atom is set.
```

## Community mod evaluations (2026-10-03)

These adoption notes complement the original build backlog; conceptual overlap
is not evidence that a particular implementation was already evaluated. They
help the next adopter avoid duplicating existing mods or treating demonstrations
as compatibility, safety or live-usage proof. Replace each dated decision when
its source changes or an actual trial supplies better evidence. No original
score or deferred secret-stop rollout decision changes here.

### Sources and backlog coverage

| Source | What was evaluated | Existing coverage and decision |
| --- | --- | --- |
| [Hamza's announcement](https://x.com/ihamzafer/status/2106076435932688427) and [collection][hamza-pinned] | The pinned repository lists 13 mods; selected implementations were read, not just demos. | M05 bg-job-board, M20 session-wall, M16 cartoon-tool-use and M41 welcome-back-recap overlap. The exact collection was not in the original backlog. See individual decisions below. |
| [Jarrod's announcement](https://x.com/jarrodwatts/status/2106153410697564235) and [image-view][image-pinned] | Pasted-image thumbnails above the terminal prompt. Source and tests read; not run or loaded. | Missing feature category. Conditional trial candidate, not a new build: first establish graphics-terminal compatibility. |
| [Dan: next-steps](https://x.com/daniel_mac8/status/2106125504331788749) and [community plugin][next-steps-source] | Zero to three current-session follow-up drafts, including available commands. Selecting fills a draft; the person still submits it. Uses a model fork. Source read from mutable main, not a pinned release. | Missing exact feature. M41 recap and M05/M20 dashboards are adjacent, not equivalents. Optional later trial; this does not aggregate multiple sessions. |
| [ClaudeDevs: You should Know](https://x.com/ClaudeDevs/status/2106118517447876618) | Announcement of a builtin plugin highlighting important information in output. Implementation not verified. | M14 turn-postcard overlaps, but important-output highlighting is a distinct candidate. Compare with session recaps before choosing another always-visible band. Not enabled by this evaluation. Built 2026-10-06 as the house mod lookout: the built-in never loads behind the gateway, so lookout asks the same kind of question from scratch on `$.model.fork` (see `README.md`). |
| [Dom: session purpose and disk display](https://x.com/dominikmartn/status/2106044283455406335) | Social-post description only; no implementation or portability verification. | M24 disk-watchdog and M05/M20 cover related needs. Useful category, not evidence to install this exact demo. |
| [Dan: mod-builder](https://x.com/daniel_mac8/status/2106066702551146912) | Demo and promised builder-skill update, not an inspected skill release. | M18 paste-to-mod overlaps. No established improvement over existing authoring tools; do not install from the announcement alone. |
| [Lydia's question](https://x.com/lydiahallie/status/2106066888501645655) | Community question asking whether people have built mods. | No specific implementation to score; replies were not exhaustively evaluated. |
| [JJ's ten examples](https://x.com/JJEnglert/status/2106022296884289953) | Capability overview, not ten released plugins. | Panels, notifications, guards and M30 secret-scrub already have conceptual coverage. |
| [Official getting-started guide](https://claude.dev/blog/getting-started-with-claude-code-mods/) | Authoring tutorial with Token Weather, Blast Radius and Replay Theater. | Those examples informed the original duplicate/rejection discussion. Reference material, not a blanket installation recommendation. |

### Hamza collection: individual decisions

Source snapshot: `hamzafer/claude-code-mods` at
`543abfa670c2242779c9f93cf2ee414a4709a300`. "Source read" below covers the main
implementation; dependencies and tests were not all audited. Agent Radar is
the exception: all six files in its plugin subtree were read before testing.
On 2026-10-03 upstream moved to `0ca6b2abed24b9a1df89bab93595e5eebdc4366d`,
added an MIT license and five mods (glance, md-preview, next-steps,
usage-meter, and a prompt-cache countdown in token-weather). The three vendored
mods are pinned there; the other additions were weighed against the live
statusline and the harness (glance needs claude.ai connectors this host does
not enable; usage-meter and token-weather's context part duplicate the
statusline) and not adopted.

| Priority | Mod | Decision and material limit | Evidence |
| --- | --- | --- | --- |
| 1 | agent-radar | Enabled globally on 2026-10-03 by operator decision as a vendored pinned copy (`agent-radar/`, see its `NOTICE.md`), re-pinned to `0ca6b2a` the same day; judged by real use. Current-session subagent activity, tool counts and completion notices, not a cross-session/worktree dashboard. Band shows four agents; pane offers nine selectable entries without pagination. | Source read; validation and tests below; `/radar` answered in a live session. |
| 2 | where-am-i | Deleted on 2026-10-07 on the operator's real-use verdict that it was too much: the four-line recap mostly restated the last reply, at four rows above every prompt and one Haiku completion per main turn. Its last version is in git history at `772c5e15`. Was enabled globally on 2026-10-03 by operator decision as a vendored pinned copy (`where-am-i/`, see its `NOTICE.md`), picked for coming back to a session. Summarizes goal/activity/next step with one Haiku completion after each main turn and can present an imperfect recap; the local fixes skip the call when `$.session.surfaces()` is empty and keep the Bash command text and arguments shaped like a common key out of the band and the recap prompt, best effort (CE P1s on #1531), recaps run in turn order and a long word is cut at the limit (Pro P2s on #1531); since 2026-10-04 each line is sized to the band's width rather than a fixed 70 characters. Judged by real use. | All six upstream files read; blob-verified; upstream tests pass; local headless, redaction and recap tests added. |
| 2b | next-steps | Deleted on 2026-10-06 on the operator's real-use verdict: the numbered list of next prompts above the input was unwanted. Do not re-adopt a next-prompt picker; its last version is in git history at `3cbe3ef3`. Was enabled globally on 2026-10-03 on the same terms (`next-steps/`, see its `NOTICE.md`): two or three draft follow-up prompts after each main turn, digits in an empty prompt pick one, nothing sends on its own. One Haiku completion per main turn, skipped for short replies, while agents run, and (local fix) when nothing draws the session; a turn whose start was missed clears the older turn's list (local fix). Upstream's port of the community plugin, pinned, in place of that plugin's mutable main. | All six upstream files read; blob-verified; upstream tests pass; local headless and stale-list tests added. |
| 3 | session-saver | Compare with existing resume/compaction support before adoption. Persistent parked notes and naming use model calls and an external `unpause` dependency. Not equivalent to M08's verified compaction handoff. | Source read. |
| 4 | replay-theater | Optional edit-review UX, not a replacement for Git diff or native /diff. Observes Edit/Write, not shell-driven edits; large diffs are suppressed. | Source read. |
| 5 | mission-control | Defer portability trial: README describes a macOS Chrome application path, graphical rendering and model-generated summaries. A file map may help, but WSL compatibility is unverified. | README only. |
| 6 | browser-lanes | Separate ownership/compatibility review needed. More than status: queues browser drivers and runs process inspection/termination. Cross-session coordination is not an established global lock. | Main source read; `attach.ts` ownership helper not inspected. |
| 7 | token-weather | Optional context-window display, not a 5h/7d quota monitor. Reads existing context usage at session start and main-turn completion; not continuous in-turn sampling. | Source read. |
| 8 | merge-gate | Do not add as a review authority. Counts a Codex review when it starts, not completed approval at a reviewed SHA; failed PR lookup passes the merge command through. Does not replace the existing governor or branch protection. | Source read; those two behaviors independently checked. |
| 9 | rulebook-guard | Skip for now: personal policy bundle overlaps existing rules and may add prompts. No assurance about enforcement from a README. | README only. |
| 10 | blast-radius | Skip additional guard layer for now; useful confirmation UX is not a permission boundary. Existing destructive-command protections remain authoritative. | README and official tutorial only. |
| 11 | oneform-line | Niche fitness-service integration, not a general coding improvement. | README only. |
| 12 | reels | Entertainment, not an engineering QoL priority. | README only. |
| 13 | snake | Entertainment, not an engineering QoL priority. | README only. |

Agent Radar trial preflight on Claude Code 2.1.288:

- All six downloaded plugin files matched their Git blob IDs at the pinned
  commit. No symlinks or submodules were present in that subtree. No root
  `LICENSE` file or plugin license field was found and no open-source license
  is assumed. A pinned copy is vendored at `agent-radar/` for the operator's own
  hosts (this repository is private); it is not redistributed or published.
- `claude plugin validate <pinned-agent-radar-folder>` passed with one warning:
  missing author metadata. Reported calls were agent listing, the clock,
  command registration, session messages, state and UI operations. The read
  implementation contains no explicit process, filesystem, network or model
  call, and passes tool events through without intentional rewriting/refusal.
- `claude plugin test <pinned-agent-radar-folder>`: **2 pass, 0 fail**. The
  upstream tests exercise a mocked engine beneath the mod: helper behavior,
  spawn/display, message selection and completion toast. They do not establish
  live rendering, timer cleanup, concurrent-agent behavior or daily usefulness.
- Strict `tsc --noEmit` check of hooks, declarations and tests passed using an
  external config and the already-generated Claude Code **2.1.287** API types.
  This is not a fresh 2.1.288 declaration check. The vendored copy later took
  local fixes (adopted agents' durations; `Clear finished` undone by the next
  `/radar`; the cap evicting running agents and a spawn landing mid-adoption),
  all found by the terminal review of the enabling PR; `agent-radar/NOTICE.md`
  records them.
- `/radar` answered in a live session on 2026-10-03 (the first live-load
  evidence); band rendering, coexistence with the loop-breaker band and daily
  usefulness are judged by real use now that the operator has wired it
  globally. The collection's other mods were not installed as a bundle.

### New feature gaps and trial limits

These are unranked adoption candidates, not additions to the original scored
build list:

- **Pasted-image previews:** [image-view][image-pinned], inspected at
  `12795b62f1c17f4b36c980e33672fbdff3a6731a`. Its README names Kitty-graphics
  terminals such as Kitty/Ghostty; WSL alone does not establish support.
  The background job exposed no recognized graphics-terminal indicator, so
  image-view was not installed. This is unknown compatibility, not proof of
  incompatibility. The source polls every 200 ms and depends on the session's
  image-cache layout. Contrary to the README's "image data never passes
  through the mod" claim, its metadata path calls `$.fs.read` with
  `as: 'bytes'` without a byte range. Local image bytes enter the mod; no
  explicit network request was found. This is a documentation discrepancy,
  not evidence of exfiltration. Tests were read, not executed.
- **Next-prompt suggestions:** the community plugin's next-steps generates
  editable drafts with `$.model.fork` from mutable main. Hamza's port (one
  Haiku `$.model.complete` over the last six messages, `maxTokens` 200) was
  adopted instead on 2026-10-03 at the pinned commit above and deleted on
  2026-10-06 on the operator's verdict; see the table.
- **Important-output highlighting:** You should Know is an announcement-backed
  candidate, not a source-reviewed adoption. Compare its actual behavior with
  Where Am I and M14 before adding overlapping summaries. Built 2026-10-06 as
  lookout, which flags one thing rather than summarizing, so it sat beside
  Where Am I's recap rather than repeating it; Where Am I was deleted on
  2026-10-07.

The original quota-sunset duplicate note should not be read as proof that
Token Weather measures subscription quota: the tutorial and inspected mod
measure context-window occupancy. Nor do adoption candidates establish a need
to rebuild M05/M20/M41; try the relevant existing implementation first and
retain only the unmet requirement.

[hamza-pinned]: https://github.com/hamzafer/claude-code-mods/tree/543abfa670c2242779c9f93cf2ee414a4709a300
[image-pinned]: https://github.com/jarrodwatts/claude-image-view/tree/12795b62f1c17f4b36c980e33672fbdff3a6731a
[next-steps-source]: https://github.com/anthropics/claude-plugins-community/tree/main/next-steps

