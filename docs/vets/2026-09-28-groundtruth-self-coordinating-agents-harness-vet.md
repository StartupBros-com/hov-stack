# Harness vet: "Self-Coordinating Agents on Claude Code Cloud" (The Ground Truth) → global harness

**Date:** 2026-09-28
**Candidate:** https://thegroundtruth.media/p/self-coordinating-agents-on-claude
(Zhu Liang / paradite, page dated 2026-09-28). Prose only: no repo, no files,
no pinnable revision. Fetched 2026-09-28 as `page.html` (184,850 B); the
sentence-split text is 545 lines, and every `text.txt:N` below is a line in
that split, kept in the job's scratch dir, not in this repo.
**Self-description:** a personal dev stack where Claude Code Cloud sessions
coordinate each other through cross-session messaging, triggers, and a SQLite
knowledge base (`para-kb`), steered from a phone.
**Target vetted:** one — the global harness (`~/dotfiles` → `~/.claude`) as it
runs today: local WSL2, `claude --bg` jobs, `claude-loop.sh` workers, ARC CI.
**Use case asked:** "where is our stack better, where does theirs beat ours,
any major architectural issues, synthesize or cherry-pick" (operator, 2026-09-28).
**Landing depth:** report-only. Nothing installed, no settings, hook, skill or
doctrine file changed. This note is the only artifact. Follow-ups are offered
at the end, none performed. (Superseded 2026-09-28 for the follow-ups only:
the corrections under §4 record what a same-day pass then probed, filed as
#1450, and landed as doctrine-doc edits in #1451, and what a second pass the
same day set and landed in #1454; the original run's scope stands as
written. Landing PRs, all merged 2026-09-28: #1448 carries this note, #1451
the first corrections (dc22cb42), #1454 the second (27d0a80d). Table rows
and lines that a correction overtook carry an inline *(superseded …)*
marker and stay as written; the corrections under §4 are the current
state.)
**Run choices:** the `/harness-vet` phases were run by hand (the skill did
not expand because it was not the first token of the prompt); two Workflow
runs did the collection and the inward vet, both recorded in §2.

## 1. Headline

**Verdict: nothing to adopt or adapt; two things to extract as hypotheses;
one thing to reject for this runtime; the rest is SKIP.** The post describes
a cloud-first, session-per-task stack on a permission posture our runtime
cannot safely copy. Its value to us was the audit dividend: it forced the
first written evaluation of what this harness does and does not carry into
any non-local runtime, and it exposed one confirmed doctrine error in our
own cross-session messaging doc (X3).

Answering the four questions the operator asked, after the inward vet
downgraded most of my first-draft "ours is better" rows to "different model":

1. **Where ours is stronger.** An in-process guard layer on top of the shared
   platform rule (git-guard, dcg fail-closed, settings-guard, a managed root
   floor); a written claim/dedup/closeout protocol for work tracking; friction
   capture that fires from a hook, not only from an agent remembering to file;
   local compute with ssh, Tailscale, Docker and GPU in reach. Each of these is
   a mechanism the post does not describe, not proof the author lacks it.
2. **Where theirs is ahead.** Only one true capability gap: steering and
   monitoring sessions from a phone, with the laptop closed. That is a platform
   feature, not their code, and it is unused here because of our own gateway
   config plus an August probe that may be stale (X5). Two softer gaps: an
   explicit doctrine for spawn-a-peer-and-steer-it and for a live reviewer
   session (we have every primitive, no rule for when to use them), and
   structured retrieval of compounded knowledge, where the gap is ours and the
   post only motivates the question.
3. **Architectural issues surfaced.** Ranked by what the evidence supports:
   X3 (a confirmed doctrine error: messages sent *to* a bypass-mode loop worker
   are held forever, and our doc says the hold is "moot today"), X7 (ccflare is
   a machine-wide single point of failure documented in pieces with no owner
   line), X1 (the harness is deliberately machine-bound, and the cost of that
   choice for any cloud or routine runtime had never been written down), X4
   (stale permission counts in HARNESS.md), X2 (compounded learnings have a
   prose pointer and no retrieval path, consumption unmeasured), X5 and X6
   (two open probes). Details in §4.
4. **Cherry-pick, not synthesize.** Two extracts (V4, V8), both as measured
   hypotheses rather than ports, and three cheap probes. The post's central
   mechanism (triggers as a coordination bus) is undocumented by Anthropic and
   reported by the author as a workaround, so it is SKIP, not REJECT.

## 2. Measured, not inferred

**Runtime.** Session model Fable 5.1 (`claude-fable-5-1`). Collection and
verification stages ran as `lean-collector` / `lean-reader` on Sonnet at
session effort; the architecture skeptic ran on the session model.

**Workflow 1, collect (wf_1714dc34-549):** one live-docs fact-checker over
Anthropic's Claude Code docs (cross-session messaging, cloud environments,
Claude Code on the web, routines, Projects, channels, llms.txt) and three
harness inventories (coordination primitives, knowledge surfaces, cloud
portability). Reports kept as `platform.json`, `coordination.md`,
`knowledge.md`, `cloud.md` in the job scratch dir.

**Workflow 2, inward vet (wf_5c8cafde-331):** three refute-by-default lenses
(coverage, fairness, architecture) over the draft verdict table. 3 agents,
0 errors, 60 tool uses, 123,943 subagent tokens, 112 s. Outcome: 0 draft rows
upheld unchanged across all three lenses; 2 rows REFUTED (B6, V10); every
other row PARTIAL with a correction that is applied below. The corrections
are listed in §2 "Corrections to my own draft".

### Platform claims checked against live docs

| Claim (from the post or my draft) | Status | Evidence |
|---|---|---|
| Cloud VMs have no separate compute charge; tokens count against the plan | CONFIRMED | cloud docs; Anthropic-hosted VMs only |
| A peer message never counts as consent | CONFIRMED | cross-session-messaging docs, "how a session treats an incoming message" |
| The consent rule is instruction-level ("Claude Code instructs the receiving Claude…") | CONFIRMED | same page; so the author's CLAUDE.md override plausibly works, which is why V12 matters |
| Inbound default: a prompting receiver holds only bypass-class senders; **a bypassing receiver holds every message unless the sender also bypasses**; a `-p` session cannot show the dialog | CONFIRMED | same page, rule (5); this is the basis of X3 |
| User-level `~/.claude` settings and SessionStart hooks do not run in Anthropic-hosted cloud sessions; only repo-level `.claude/settings.json` hooks (single-repo sessions) | CONFIRMED | cloud docs; server-managed settings do apply there |
| Firing a routine starts a fresh session | CONFIRMED | routines docs |
| "Cloud sessions are invisible to ListAgents" (my draft) | REFUTED | a Remote Control–connected local session can list and message cloud sessions; cloud→cloud is undocumented |
| "Subagents can't be steered" (post, text.txt:230) | PARTIAL | SendMessage resumes a completed subagent by name; what holds is observability (subagents are not in the session list) |
| The six remote tool names the post uses (`list_sessions`, `list_triggers`, `create_trigger`, `ReadNotifications`, `fire_trigger`, `create_session`) | UNVERIFIABLE | 0 hits across every fetched doc page and llms.txt |
| A trigger delivering into an existing session | UNVERIFIABLE | documented triggers start new sessions |
| Auto-mode classifier stalls (post's reason for acceptEdits) | PARTIAL | thresholds 3-in-a-row / 20-total are documented and not configurable; the classifier can fail behind a gateway that drops review fields |
| Projects (coordinator conversation starting parallel cloud threads) | CONFIRMED as a documented first-party alternative | public beta, Pro/Max; not on Team |
| Self-hosted environments run hooks "seeded from the runner host's ~/.claude/" and lack API credentials | CONFIRMED from the cloud-environments page; the dedicated self-hosted page was **not fetched** | see V1 |

### Harness facts re-executed this session

- `jq` over `~/.claude/settings.json`: allow 281, deny 72, ask 25;
  `permissions.defaultMode` = acceptEdits; auto mode disabled;
  `isolatePeerMachines: true` at line 912; `crossSessionInbound` has no match
  (unset) *(superseded 2026-09-28, second follow-up: `accept` at line 913 of
  the live file and line 912 of the tracked copy; §4, X3 resolved)*;
  `ANTHROPIC_BASE_URL` points at a local gateway (line 4);
  `Bash(claude:*)` allowed (line 286); dcg PreToolUse at lines 633-636 with
  `DCG_FAIL_CLOSED=1` at line 14. No token or key from that file is quoted
  anywhere in this note.
- `sed -n 44,53p HARNESS.md`: line 45 reads allow ~210 / ask ~15 /
  deny ~70; line 52 is "Guardrail, not a jail — the laundering boundary leaks,
  deliberately"; line 51 carries the pstack-vet ruling that a delegated CLI
  child is ungated.
- `rg -F agent-ops`: `HARNESS.md:95` documents `discord-notify.sh`
  posting to Discord #agent-ops.
- `pgrep -af ccflare`: a `run-ccflare-stack.sh` runner and a `ccflare-guard`
  node process are live under `~/.config/better-ccflare/`; `systemctl --user
  list-units --all` shows no ccflare unit. So supervision exists beyond the
  `~/.bashrc` guard that `harness/claude-code-opus48-overload.md:25`
  describes, and that line is dated. Whether the guard restarts the proxy on
  crash was not tested.
- `harness/cross-session-messaging.md:28-50` read in full: lines 31-35
  state the sender-side hold rule; lines 44-47 say a held message to a `-p`
  worker "stays held forever" but that "only bypass-class senders trigger
  holds, so this is moot today", and give the per-worker remedy
  (`--settings '{"crossSessionInbound":"accept"}'`).
- `bin/claude-loop.sh:1586`: workers launch with `--permission-mode
  bypassPermissions` (confirmed by two skeptics and re-read here; lines 73 and
  1347 restate the posture).
- Round-3 ideation (`docs/ideation/2026-09-26-harness-throughput-and-ceremony-round-3-ideation.html`,
  tags stripped): line 416 "The memory index cannot trigger recall… about 190
  entries… Give every line a hook or drop it"; the Outcomes section (lines
  426-451) files ideas 2, 3 and 5 as #1428, #1429, #1430 and does **not** file
  the line-416 recall finding. So V4 overlaps an unfiled diagnosis, not a
  tracked chore.
- `docs/vets/` holds 9 prior notes; none covers this source, cloud sessions,
  Remote Control or routines (cloud.md §4). No docs/vets index file exists
  (rg for "docs/vets" across README, docs, HARNESS.md: nothing).

### Not measured

- No live-task behavioral comparison of any pattern (the post is doctrine, not
  a runnable component; no fixture was built).
- No probe of message delivery between an acceptEdits session and a bypass
  `-p` worker, in either direction (X3 rests on the documented rule).
- No re-probe of Remote Control behind ccflare (X5 stays at the August state).
- No probe of `DCG_FAIL_CLOSED=1` with a missing binary; per the architecture
  lens that question only arises in a self-hosted environment seeded from a
  runner host, since Anthropic-hosted sessions never load the hook at all.
- The 29-hook-command count and the 52-file / 3-mention docs/solutions counts
  come from the collector reports and were not re-counted by the skeptics.
- The article's six tool names could not be verified or refuted.

### Corrections to my own draft

The inward vet changed the shape of the answer. Recorded so the next reader
does not re-derive the first draft's errors.

- **A1 (trust boundary).** Layer one, "a peer message never counts as
  consent", is the platform's and shared with the author. Our addition is a
  convention layer (`cross-session-messaging.md:72-79`, `CLAUDE.md`
  peer-claims-are-data line) and local settings. `crossSessionInbound` is
  unset, so "bypass-class senders are held" is an upstream default we rely
  on, not something we enforce. The post overrides the platform rule
  knowingly and states its threat model (text.txt:236-239); "the article has
  layer one only" was absence-of-evidence and is withdrawn.
- **A2 (enforcement depth).** Different models, not a ranking: we add
  in-process guards on a shared machine whose allow list also includes
  `ssh`, `curl` and `git push`; they add host isolation ("the isolated cloud
  VM becomes your main safety boundary", text.txt:245-246) with no SSH key in
  the VM (text.txt:206). Our own doc calls ours a guardrail, not a jail.
- **A3 (work tracking).** Claims are advisory and dedup is a keyword backstop
  (`gh-tracking-and-claims.md:283`); `claim-reap.sh` runs DRY_RUN by default
  and is wired read-only into harness-weekly (:217). Reaping is not automatic.
  The post describes a tasks table (text.txt:212-214) and no claim protocol;
  that is a difference, not a win.
- **A4 (friction loop).** Parity. The post does not say whether capture is
  manual or automatic (text.txt:214), so "edge on automatic capture" is
  inferred from silence.
- **A5 (messaging depth).** Our operational knowledge is about *local*
  messaging (daemon-env trap, socket bind); the post's complaint is about the
  *cloud* surface (text.txt:257), and the author rarely uses local messaging
  (text.txt:219). Not comparable. The upstream issue numbers in the draft
  (#85116, #84945) were recalled from the enablement memory, not re-read this
  session.
- **A6 (local compute).** "No VM memory cap" was wrong in spirit: local WSL2
  has its own memory bound and reap (`harness/wsl-memory-bounds.md`).
  The author already runs SSH tasks locally (text.txt:205-206), so the
  exception list matches ours. Corrected to: local compute gives ssh,
  Tailscale, Docker and GPU at the cost of one machine with a WSL memory bound.
- **A7 (economics and governance).** Not comparative; the post has no
  economics section. Moved to context. Two factual fixes: `fanout-admission.js`
  is WARN-only by default (`CLAUDE_FANOUT_GATE_BLOCK` not armed); the
  60-minute loop backstop lives in `hooks/PreToolUse/loop-guard.js:33,62`
  (env `CLAUDE_LOOP_MAX_MS`, registered at settings.json:701) and
  `dispatcher-ratchets.md:116`, not in HARNESS.md. The 18.8k figure is
  CLAUDE.md tokens removed from context per lean-reader request
  (`RESULTS.md:62,176`); the dollar effect is a cent or two per stream.
- **B1 (mobile).** A platform capability unused here because of our config
  and an unverified probe. A gap pending re-probe, not "theirs beats ours".
- **B2 (session patterns).** "No doctrine or script" overstated: the
  dispatcher (`dispatcher-tick.sh` → `claude-loop.sh`) plus `gh-ready.sh`
  already sweep the board and spawn workers. The narrow gap: no rule for an
  interactive session to spawn a `--bg` peer and steer it, no live reviewer
  session, no overlapping handover. The post's "can't steer a subagent"
  premise (text.txt:230) is overstated per the docs; only observability holds.
- **B3 (retrieval).** The gap is ours; the post claims retrieval of tasks and
  tagged principles (text.txt:211-214), not of compounded solution docs.
  Retrieval over docs/solutions today is manual: a prose pointer in
  `CLAUDE.md` (the compounded-learnings line), memory files that link
  solution paths, and two skills that cite specific files
  (`skills-local/review-adversarial-first/SKILL.md:62,160`,
  `harness/evidence-regime.md:372`).
  Round 3 line 416 already diagnosed the memory-index half. Entry counts are
  two different denominators: ~190 index entries (round 3) vs 518 memory
  files (collector count, not re-verified).
- **B4 (notes channel).** Parity. The one real difference is an async note to
  a peer that is not alive, which SendMessage does not carry. #agent-ops is
  sourced at `HARNESS.md:95`.
- **B5 (fleet/job mgmt, schema extension).** "Ours: none" was not checked
  against heavy-job-admission or the dispatcher; withdrawn. The post describes
  these; nothing shows we need them.
- **B6 (cheaper coordinator).** REFUTED as a "beats ours" row: text.txt:247-248
  is an unmeasured model-choice observation, not a capability we lack.
- **V10.** REJECT on an UNVERIFIABLE claim was wrong per VERDICTS.md
  ("insufficient verification may mean SKIP pending evidence, never a
  security REJECT"). Now SKIP.
- **V12.** "Never (security finding)" was too strong. The author disclosed the
  trade-off and its precondition; the REJECT is for *our* runtime, where that
  precondition does not hold.
- **X1.** A documented design (`HARNESS.md:14` two-homes doctrine;
  `harness-clis-are-not-deployable-dependencies` memory), not a defect. The
  cost was unwritten.
- **X3.** The draft had the direction backwards in importance. See §4.

## 3. Verdicts

Target: global harness. Placement is "none" unless stated. State is
"proposed" for anything not yet filed; nothing here is landed.

| # | Component (post section) | Verdict | Placement / activation | Evidence status | State |
|---|---|---|---|---|---|
| V1 | Cloud-first execution + mobile steering (A) | SKIP now | none | compute-free CONFIRMED for Anthropic-hosted VMs only; those sessions load no user-level hooks (X1); the self-hosted path is UNKNOWN (page unfetched; ccflare/auth, credentials, guard seeding all open) | no install |
| V2 | `para-kb` as a SQLite service (B) | SKIP | none | knowledge.md mapping: gh issues + papercut + memory cover the task/feedback/notes surfaces | no install |
| V3 | Principles loaded on demand (B) | SKIP as mechanism | none | round-1 ruling "never trade one always-on layer for a parallel authority elsewhere" (2026-08-30); always-on cost measured under 1% because the prefix is cached | no install |
| V4 | Retrieval of compounded learnings (B → our X2) | EXTRACT as a hypothesis, folded into round 3's line-416 recall item | a retrieval path over docs/solutions (and memory-index hooks); placement decided by the measurement | behavior-shaping; **unverified value**; overlaps an unfiled round-3 diagnosis | proposed, unfiled *(superseded 2026-09-28: the memory-index half is filed as #1450; the docs/solutions half already has a reader, see "Corrections after merge")* |
| V5 | Feedback + triage (B) | SKIP as covered | papercut: `papercut-log.js` (PostToolUseFailure, settings.json:817) + `papercut add/triage/adopt/rollup` | control surface cited | no install |
| V6 | Agent notes channel (B) | SKIP | memory index + SendMessage + gh comments + #agent-ops | parity; async note to a non-live peer is the one uncovered shape | no install |
| V7 | Schema extension / fleet-job mgmt / self-documenting API / library CLI (B) | SKIP | none | no demonstrated need; "ours: none" withdrawn, unchecked | no install |
| V8 | SessionStart CLI vendoring (B) | EXTRACT the finding only (X1), no port | — | cloud.md; CONFIRMED that user-level hooks do not run in hosted cloud | recorded here |
| V9 | Native cross-session messaging (C) | SKIP as covered (transport) | on since 2026-08-08; `cross-session-messaging.md` | control surface cited; the doctrine gap is V11 | no install |
| V10 | Triggers / `create_session` / `ReadNotifications` as the coordination bus (C) | SKIP (not applicable to a local harness; author-reported, undocumented); watch Projects, channels, routines | none | remote-tools-exist UNVERIFIABLE; routines start new sessions CONFIRMED; the author calls it a workaround (text.txt:257) | no install |
| V11 | Sessions over subagents, spawn-and-steer, overlapping handover, live reviewer B (C+E) | SKIP pending evidence | none yet; if it survives, one doctrine paragraph in `cross-session-messaging.md` | behavior-shaping; the post's steering premise is overstated; an unpriced dependency (X3: holds into bypass workers); overlaps `claude-loop --resume-from` rotation (`dispatcher-ratchets.md:203-246`) and `handoff-compliance.js` / context-fence handoff | no install |
| V12 | Relayed approval counts as consent (D1) | REJECT for this runtime | none | peer-message-never-consent CONFIRMED; the post's own precondition, "every session belongs to me and runs in an isolated cloud VM… I would not use it on a shared account or a machine with sensitive data" (text.txt:236-239), does not hold on a WSL2 host with credentials in reach and a 281-entry allow list | no install |
| V13 | acceptEdits + allow list to avoid classifier stalls (D2) | SKIP as covered | `defaultMode` acceptEdits (settings.json:416) + auto mode disabled + guard layer | — | no install |
| V14 | Cheaper coordinator model (E3) | SKIP | — | no measurement on our workloads and none in the post; the operator's recorded preference (`user-runs-models-at-xhigh-or-max`) constrains any cost-motivated swap but is not the verdict | no install |

**Rollup, global target:** 0 ADOPT, 0 ADAPT, 2 EXTRACT (V4 as hypothesis,
V8 as finding), 11 SKIP (V11 as SKIP pending evidence), 1 REJECT (V12).
Delivery verdict: not applicable (no component to deliver). Content verdict:
as above.

### Do-not-retry unless

- **V1 / V10:** a cloud runtime is adopted on purpose (mobile steering or
  off-machine compute becomes a stated need) *and* either Remote Control is
  re-probed working behind ccflare or a self-hosted environment is stood up
  on our compute with the seeded-`~/.claude` path verified; or Anthropic
  documents in-session trigger delivery; or Projects leaves beta.
- **V2 / V6 / V7:** a task needs a store or channel that gh issues, papercut,
  memory, SendMessage and gh comments cannot hold; the concrete miss is the
  trigger (a cross-session note lost, a remote job to dispatch).
- **V3:** a behavioral measurement on our fixtures shows on-demand doctrine
  beating always-on; cost is not a reason (measured under 1%).
- **V11:** both (a) a two-direction delivery probe between an acceptEdits
  session and a bypass `-p` worker is recorded, and (b) a statement of what
  the pattern adds beyond `--resume-from` rotation and the handoff hooks; then
  a measurement across several paired tasks (`notify_when_idle` callbacks vs
  a Workflow arm), not one run.
- **V12:** the runtime is an isolated VM without broad credentials. On this
  host: never.
- **V14:** a coordinator-quality measurement on our own workloads; an
  operator preference change alone is not enough because the post gives no
  data either way.

### Proposed changes (none applied)

Per VERDICTS.md §4 these need rationale, exact files, provenance, pin, owner
and rollback. Only the first is a change to a committed file; the rest are
probes and an issue.

1. **Correct `harness/cross-session-messaging.md:44-47`** after the
   X3 probe: the hold rule that matters for `-p` workers is the *receiver*
   rule, not the sender rule, and "moot today" is wrong while
   `claude-loop.sh` runs workers in bypass mode. Provenance: Anthropic
   cross-session-messaging docs, rule (5), fetched 2026-09-28. Owner: whoever
   runs the probe. Rollback: revert the paragraph. Doctrine file, so it takes
   the inward vet before merge.
2. **Refresh or de-number `HARNESS.md:45`** (X4): either the live
   figures 281 / 25 / 72 with a date, or replace the counts with the `jq`
   command, since the file already warns against transcribed counts.
3. **File one issue** for V4 that carries the round-3 line-416 recall
   diagnosis and the docs/solutions retrieval half together, with the
   deciding measurement predeclared: held-out real past incidents (does a
   session avoid a documented, repeated mistake), the baseline arm being the
   existing CLAUDE.md pointer, counting injected tokens and irrelevant
   injections. Check the compound-engineering plugin for a learnings
   researcher before building anything (not verified here). *(Verified
   2026-09-28, second follow-up: it exists and is dispatched by ce-plan,
   ce-ideate and ce-code-review; see "Corrections after merge".)*
4. **Write the two-homes cost line** into `HARNESS.md` (X1): one sentence
   that any Anthropic-hosted session, Projects thread or routine runs with
   none of the user-level guards, doctrine or scripts, by design, and that
   the self-hosted seeded path is unevaluated.

## 4. Audit dividend

Findings about our own harness, ranked by evidence strength, each with the
control surface and what is still unprobed.

- **X3 — confirmed doctrine error: messages *to* loop workers are held
  forever, and the doc says the hold is moot.** *[Superseded 2026-09-28, see
  "Corrections after merge" (X3 measured, X3 resolved): a default-held
  message drops after `dialogExpiry`, both directions were probed, and
  `crossSessionInbound: accept` is now set user-wide.]* `bin/claude-loop.sh:1586`
  launches workers with `--permission-mode bypassPermissions` as `-p`. The documented
  inbound default (rule 5) says a bypassing receiver holds every message
  unless the sender also bypasses, and a `-p` session cannot show the
  approval dialog. Our whole interactive fleet is acceptEdits, so any
  SendMessage to a running loop worker is held until the 5-minute dialog
  expiry. `cross-session-messaging.md:44-47` covers only the sender-side rule
  and calls the case "moot today". The remedy is already written on the same
  lines (`--settings '{"crossSessionInbound":"accept"}'` per worker), it is
  just not applied. The reverse direction (worker → interactive, held as a
  bypass-class sender under lines 31-35) is inferred and there is no evidence
  workers ever send. Neither direction has been probed. Control surface: the
  loop's launch flags and the per-worker `--settings`.
- **X7 — ccflare is a machine-wide single point of failure documented in
  pieces.** `model-usage-tracking-infra.md:27`: all Claude Code traffic rides
  the gateway via the global base URL. `claude-code-opus48-overload.md:25`:
  persistence is a `~/.bashrc` guard, "NOT systemd"; live `pgrep` shows a
  runner script and a guard process now, so that line is dated, and
  restart-on-crash is untested. `dispatcher-rung1-live-2026-08-28.md:16`:
  systemd units never see the base URL and need a duplicated drop-in (two
  places to drift). `bin/claude-loop.sh:1575-1584`: a step that thinks
  for more than about 450 s without emitting text is aborted by the gateway's
  progress guard and retried by the client up to 20 times, a silent hang; the
  loop mitigates it with an undocumented thinking-display flag, and every
  other caller of the gateway is exposed unless it does the same. The same
  base URL is what the August probe blamed
  for disabling Remote Control (X5). No single doc line owns "what breaks
  when ccflare is down". Not a finding: ARC CI runners do not run `claude`
  (`harness-tests.yml:16` describes a bare runner; no `claude -p` in
  `.github/workflows`; runner image contents not inspected).
- **X1 — the harness is deliberately machine-bound, and the cost was never
  written down.** Two-homes doctrine (`HARNESS.md:14`), every hook command on
  an absolute `/home/user` path (29 per cloud.md, not re-counted), hooks and
  scripts symlinked into the dotfiles checkout, dcg at a versioned absolute
  path. Docs confirm Anthropic-hosted sessions carry over from the repo only
  and never load user-level settings or SessionStart hooks; server-managed
  settings do apply there. So a hosted session, Projects thread or routine
  runs with none of our guards, doctrine or scripts, by design. No prior vet
  or memory evaluated cloud, Remote Control or routines (cloud.md §4). The
  `DCG_FAIL_CLOSED=1` missing-binary question arises only in a self-hosted
  environment seeded from a runner host, and is unverified there.
- **X8 — guards are live symlinks into the canonical checkout.**
  `~/.claude/scripts` and hooks resolve into `/home/user/hov-stack/claude/`
  (cloud.md:12); `settings.json` is volatile and hand-applied (enablement
  memory :18). Branch state in the canonical checkout changes every session's
  guards live; `launchpad-advisory` heals launch-checkout staleness
  (cloud.md:78-80). Documented under two-homes; recorded here as the risk
  that pairs with X1.
- **X4 — stale counts.** `HARNESS.md:45` says allow ~210 / ask ~15 / deny
  ~70; live `jq` says 281 / 25 / 72 (read this session). The file warns
  against transcribing counts and is itself wrong.
- **X2 — compounded learnings have a pointer and no retrieval path.**
  docs/solutions (52 files per the collector) is written by `/ce-compound`;
  readers are the CLAUDE.md prose pointer, memory files linking solution
  paths, and two skills citing specific files. No injector, no CLI; cass
  indexes sessions, not docs. Whether sessions consult it is unmeasured, not
  shown to be zero. Round 3 line 416 diagnosed the memory-index half and no
  issue carries it.
- **X5 — possibly stale probe.** The 2026-08-08 enablement memory (line 20)
  says a non-`api.anthropic.com` base URL disables Remote Control. The
  current web docs sentence about gateways ("doesn't count as a third-party
  provider for this check") concerns the `--cloud` flag, not Remote Control,
  so the probe is neither confirmed stale nor contradicted. Re-probe when
  mobile steering is a stated need.
- **X6 — open question.** Whether an ended local *session* (not a subagent)
  can be resumed by SendMessage. Docs cover subagent resume by name and say
  nothing about ended top-level sessions.
- **Reused prior finding.** `HARNESS.md:51` (pstack vet 2026-09-18,
  architectural issue 3): PreToolUse guards do not reach a delegated CLI
  child. Same family as X1: every runtime outside this process's tool loop
  is ungated unless it brings its own guards. Killed hooks failing open
  (anthropics/claude-code#84302,
  `memory/-home-user-hov-stack/agentic-harness-recon-2026-08.md:32-36`)
  is the third member, detected not prevented, and `DCG_FAIL_CLOSED` does not
  cover it because the kill happens before dcg decides.
- **Extra drift noticed, not from the post.** CLAUDE.md regrew from 24,061 B
  (after #1310) to 27,094 B against the 28,081 B ceiling recorded in round 2.

### Corrections after merge (2026-09-28, follow-up pass)

Appended, not rewritten, per VERDICTS.md. The rows above keep their original
text; these entries supersede the lines they name.

- **X3, now measured.** Two headless workers plus this session, Claude Code
  2.1.284: an `acceptEdits` `-p` sender to a `bypassPermissions` `-p`
  receiver got `[Cross-session delivery notice] Your message to another
  session was held for the recipient user's approval ... Not delivered to
  that session's Claude yet`, and the receiver's own report listed only the
  bypass session's message; the bypass-to-bypass leg delivered. The
  bypass-to-`acceptEdits` leg was not measured (the receiver's send ran after
  the sender had exited) and rests on the documented rule. Of six sampled
  background sessions, five run bypass and one `acceptEdits`; with
  interactive sessions defaulting to `acceptEdits` (settings `defaultMode`,
  not sampled live), an interactive-to-bypass message is held, and the
  `acceptEdits`-to-bypass hold was probed headlessly. The hold is therefore
  the default between an interactive session and a background job, not a
  loop-worker corner case. Proposed change 1 landed in #1451, the PR
  carrying this section: `harness/cross-session-messaging.md` inbound-posture
  bullets and the `HARNESS.md` messaging line. Whether
  `claude-loop.sh` should start workers with
  `--settings '{"crossSessionInbound":"accept"}'` is a permission-surface
  decision left to the operator.
- **X7, under-checked.** §4 quoted the overload doc's "NOT systemd" and said
  "restart-on-crash is untested"; §2 reported no ccflare unit under
  `systemctl --user`. A *system* unit exists:
  `/etc/systemd/system/ccflare-stack.service`, enabled, active, `Restart=always`,
  `RestartSec=5`, `KillMode=control-group`, 17 drop-ins (only the tunnel
  drop-in read); its runner (`~/.config/better-ccflare/run-ccflare-stack.sh`,
  read 2026-09-28: `schedule_restart`, `RUNNER_RESTART_MAX_FAILURES=3`,
  `RUNNER_RESTART_WINDOW_MS=300000`, `RUNNER_CIRCUIT_EXIT_STATUS=75`)
  restarts the whole stack with backoff and exits 75 on the third failure in
  five minutes to hand it to systemd. Restart-on-crash is configured at two
  levels, not exercised; the `systemctl --user` query in §2 could not see a
  system unit. The unit additionally
  requires the ssh tunnel to the AI gateway host
  (`AI_GATEWAY_TUNNEL_REQUIRED=1`), an outage member the note missed. What
  stayed true: no owner line existed, and
  `claude-code-opus48-overload.md:25` still said "NOT systemd". Both are
  fixed in the same PR (owner line in `HARNESS.md` Doctrine; dated
  superseded marker on the stale line), so the §6 trigger "ccflare moves
  under systemd or gains an owner line" has fired and X7 is closed. The
  `dispatcher-rung1-live-2026-08-28.md:16` citation is a memory note
  (`memory/-home-user-hov-stack/`), not a harness doc.
- **X5, verified live.** `claude remote-control` on 2.1.284 exits with
  "Remote Control is only available when using Claude via api.anthropic.com.
  ANTHROPIC_BASE_URL is set"; the 2026-08-08 probe is current, not stale.
  Recorded in the messaging doc with the per-session `env -u` workaround,
  documented but not run. The X5 re-probe is closed.
- **X4.** Already filed as #1429 item (c) (replace the hand-copied counts
  with the `jq` line); open, unclaimed, no branch on 2026-09-28. Nothing new
  filed.
- **V4 and X2.** Filed as #1450 with the predeclared measurement: routing
  accuracy on a frozen suite judged from index descriptions only
  (`scripts/memory-recall-eval.py`, the dream pass's own metric,
  noise band 2 points per its `NOISE_BAND_POINTS`). Live index on
  2026-09-28: 59 lines, 17,490 bytes, 231 bare `[-](file)` fragments and 30
  hooked entries against the 200-line and 25 KB load cap; cass (#1235) is
  parked on upstream #494 with its index timer disabled, so the index is the
  only indexed recall path (files can still be grepped, and CLAUDE.md carries
  the pointer). compound-engineering 3.29.0's ce-plan skill text does not
  reference `docs/solutions` (one comment line matched; the plugin's agents
  were not searched); that half is a decision item on #1450, not a build.
- **V4 and X2, corrected (2026-09-28, second follow-up).** The "no reader"
  premise above was wrong. compound-engineering 3.29.0 has a prompt-driven
  read path: a `learnings-researcher` subagent that greps solution
  frontmatter and reads the shortlist, dispatched by ce-plan
  (`skills/ce-plan/references/research.md:53`; skipped on Lightweight
  plans), ce-ideate (`skills/ce-ideate/references/grounding.md:57`) and
  ce-code-review (`skills/ce-code-review/references/select-and-route.md:18`,
  only when a cheap path search finds a match); `ce-compound-refresh` audits
  the store. The grep missed it because 3.29 spells the path
  `<root>/solutions/`, not `docs/solutions`. ce-work, ce-debug and
  ce-brainstorm do not read it. A 30-day sweep of dotfiles session
  transcripts (tool_use blocks only; 258 top-level sessions, this job
  excluded): 65 sessions read `docs/solutions/`, 42 after a CE skill
  invocation, 52 of them bulk (five or more files, the researcher's shape)
  and 13 small ad hoc readers; Bash-shaped counts are upper bounds and the
  CE attribution over-counts in mixed sessions. The store had 51 of its 52
  files written in those 30 days. Both stores therefore have a live reader:
  memory at session start, docs/solutions at plan and review time. The
  #1450 decision item (a `reference` memory note per solution) is withdrawn:
  52 index lines would not fit the 430 bytes of headroom under the
  17,920-byte budget and would land in the archive tier, one hop away like
  the directory itself. cass's parking and the memory-index rehook in #1450
  stand.
- **X3, resolved (2026-09-28, second follow-up).** The operator chose
  user-wide `crossSessionInbound: accept` over the per-worker flag (an
  explicit "go" on the written recommendation, 2026-09-28; a global
  enabling, so it waited for that answer), on the
  recommendation that on a single-OS-user machine the class-default hold
  protects nothing the receiver's own permission mode does not already, and
  that a loop-only flag would leave `claude --bg` jobs (five of six sampled
  bypass) losing messages the same way. Applied by hand to the live
  `~/.claude/settings.json` (volatile; `sync.sh install` never copies it)
  and mirrored in the tracked `settings.json` (line 912) in the PR
  carrying this entry, #1454, merged 2026-09-28 as 27d0a80d. Runtime check,
  separate from the merge:
  `jq` read `accept` from the live file after the edit and again after the
  merge's activation had run the installer, present once; whether sessions
  already running re-read the file was not measured. Measured on 2.1.284
  with `-p` workers, one run per configuration (the script and its four
  outputs are kept in `experiments/cross-session-inbound-2026-09-28/`):
  with `--settings '{"crossSessionInbound":"accept"}'` on the bypass
  receiver only, `acceptEdits`-to-bypass delivered and the reverse leg (the
  one the first follow-up could not measure) was held with the delivery
  notice (the `acceptEdits` side had no value set, so that is the default
  rule for that receiver); with `accept` in live user settings and no
  flags, both legs delivered with no notice. Messaging docs read for this
  entry: with no value set, Claude Code groups sessions into bypass and
  prompting classes and holds across the line; a `-p` session drops a
  default-held message after `dialogExpiry` (five minutes by default) and
  reports it as expired to a sender it can reach; an unattached background
  session keeps the dialog open until attach, then drops the message after
  one further full deadline period. The "adding it to `claude-loop.sh`"
  question is moot under the user-wide setting. The PR's inward vet (three
  refute-by-default lenses) refuted the first draft's safety wording: "the
  receiver's own permission rules gate anything it asks for" is empty for a
  bypass receiver, and "the boundary is the OS user before and after" hid
  that a session whose own rules block editing settings can still post to
  a worker's socket. The doctrine now states the trade (human approval step
  exchanged for deny rules, hooks and the model-followed untrusted-peer
  rule; a relayed injection can reach every bypass worker at once), the
  reverse-direction loss (no dialog on worker-to-interactive messages), and
  `refuse` via `--settings` as the tighten for workers. Deletion condition
  recorded in the messaging doc.

## 5. Prior notes and reuse

- **Searched:** `docs/vets/` (9 notes, none on this source or on cloud,
  Remote Control, routines); the dotfiles memory index and the enablement,
  harness-clis and never-merge memories; `HARNESS.md`; the three
  ideation rounds. **Not searched:** the memory archive index's third-party
  vet tier; the compound-engineering plugin's own agent list (relevant to
  V4). Both are gaps, not evidence of absence. *(The plugin's agent list was
  searched in the second follow-up, 2026-09-28: a `learnings-researcher`
  exists; see "Corrections after merge".)*
- **Reused:** the round-1 "parallel authority" ruling (V3); round 3 line 416
  (V4, X2); the pstack vet's delegated-child ruling (X1 family); the
  2026-08-08 Remote Control probe (X5), carried as possibly stale.
- **Applicability:** a project-scope vet of the same post would change
  nothing above; every verdict turns on the runtime (local host with
  credentials), not on a repo. A future *cloud* target reopens V1, V10 and V12
  by the triggers in §3.
- **Private material:** none of the collector reports, the article scratch or
  any settings value is copied here beyond line numbers and public doc
  quotes.

## 6. Re-audit triggers

- The article gains a repo, or Anthropic documents the six tool names or
  in-session trigger delivery: re-run the platform table only.
- Any cloud, Projects or routine adoption in this harness: V1, V10, V12 and
  X1 come first, then the self-hosted page and the seeded-`~/.claude` path
  get fetched and probed before anything runs there.
- `claude-loop.sh` changes its permission mode, or `crossSessionInbound` is
  set at any scope: re-check X3 and the doc lines it cites. *(Fired
  2026-09-28: the second follow-up set it user-wide; the re-check is the X3
  resolved entry under §4. The trigger now reads: `crossSessionInbound`
  changing again from the user-wide `accept`, the same wording as the memory
  pointer.)*
- ccflare moves under systemd or gains an owner line: close X7. Resolved
  2026-09-28: the system unit already existed (the trigger's premise was
  wrong) and the owner line landed in #1451 (see the corrections under §4);
  X7 closed, with restart-on-crash configured but unexercised.
- Do not re-vet on enthusiasm or a repeat share; the four questions above are
  answered until one of these predicates fires.

### Closing checklist

- [x] Every component has a verdict, evidence status and no-install placement.
- [x] Safety findings retained across targets: V12 stays REJECT on any
      non-isolated host; X3 named with its control surface.
- [x] No landing was attempted, so no visibility, collision or invocation
      check was needed; recorded as report-only, not PARTIAL. (Superseded
      2026-09-28: the second follow-up landed a user-wide setting; its
      delivery test was one `-p` run per configuration under §4, X3
      resolved. Interactive and `claude --bg` receivers were not probed, so
      that check is PARTIAL.)
- [x] No behavior-shaping port was applied; the two extracts carry explicit
      unverified-value markers and a deciding measurement. (Superseded
      2026-09-28: the doctrine rewrite in #1454 was a behavior-shaping port
      and carried the three-lens inward vet recorded under §4.)
- [x] No security-posture change proposed without naming its file: change 1
      names `cross-session-messaging.md:44-47` and waits for the probe and
      the inward vet. (Done 2026-09-28: probed, vetted, landed in #1451. The
      user-wide `accept`, a global enabling, was proposed in writing and
      applied only after the operator's explicit go the same day.)
- [x] No diverged copies of the candidate exist (prose-only source).
- [x] Eval note exists at the promised location; follow-ups are offered, not
      filed; nothing is claimed shipped. (Superseded 2026-09-28: the
      corrections under §4 record what was then filed, #1450, and landed,
      #1451 and #1454. The filing and the doctrine edits were separate
      operator-directed jobs, not this report-only run.)
- [x] Shipment cites merged artifacts (added 2026-09-28): #1448 (this note),
      #1451 (dc22cb42), #1454 (27d0a80d), all merged 2026-09-28. The live
      settings value is runtime-verified separately (§4, X3 resolved). #1450
      is open and unclaimed; no other follow-on issue exists.
