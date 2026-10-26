# Dispatcher authority ratchets

> **Retired 2026-10-17 (dotfiles#1872).** The dispatcher
> (`dispatcher-tick.{service,timer}`, `dispatcher-tick.sh`,
> `dispatcher-status.sh`) and the owner fleet it fed were removed; the
> merge-and-end rule in `CLAUDE.md` is the successor.
> `dispatcher-ledger.sh` and `dispatcher-cost.py` stay as the ledger readers
> that claude-loop, harness-doctor and harness-weekly still consume. The
> rungs below are history.

The always-on work dispatcher (issue #444; plan
`docs/plans/2026-08-21-2308-feat-always-on-work-dispatcher-plan.md`) widens
its authority only through the rungs below. Every flip is an explicit
operator act, decided by reading the ledger's two governing numbers —
keep-rate (kept / dispositioned) and cost-per-kept-PR (clean rows; a
gateway-window upper bound, dotfiles#1429) — plus the
undispositioned-age counter, all from `dispatcher-ledger.sh summary` or the
weekly surface. Nothing flips automatically. Every flip appends an audit row:

    dispatcher-ledger.sh audit-flip --ratchet <name> --keep-rate <x> --cost-per-kept <y>

A terminal row that is provably WRONG (the #584 incident: reconcile's
dead-pid probe stamped clean-ended runs `broken` seconds after they finished,
before their PR verdict) is never rewritten — repair appends an
`audit-correction` row instead, and `summary` folds it in: the run leaves the
broken count and counts by the correction's disposition, with
`audit-corrected: N` naming how many. Only a run carrying an `ended` row
qualifies — broken+ended is the mis-mark signature; a never-ended broken run
is presumed genuinely broken. Omit `--disposition` while the PR
verdict is still pending, then append a second, completing correction once
it's judged. First-terminal-wins stays intact throughout — corrections
overlay the truth; history is never edited in place:

    dispatcher-ledger.sh audit-correction --run-id <id> --voids broken \
      [--disposition kept|waste] --reason "<why the terminal row is wrong>"

The shadow → read-the-counter → enforce idiom generalized
([[verification-architecture]]): rung 0 is the shadow phase; each rung's
criteria are suggestions to start from, not thresholds the machine checks —
the operator reads the numbers and decides.

## Rung 0 — operator-fired ticks (superseded by rung 1 since 2026-08-28)

Historical state: the timer existed on disk and was deliberately NOT enabled
(`sync.sh` deployed it but excluded it from the enable-now line). Live state
checked 2026-09-02: `dispatcher-tick.timer` is enabled and ticking, so rung 1
below is the current rung. Rung 0 remains the fallback when the timer is
disabled; you run ticks by hand:

    ~/.claude/scripts/dispatcher-tick.sh          # one gate-chain pass
    ~/.claude/scripts/dispatcher-status.sh        # what state is it in

**Supervised-tick runbook:**

0. Provision the intake labels in the target repo — they are consumed
   everywhere but created nowhere, and the first live tag attempt failed on
   exactly this (2026-08-28, issue #549):

       gh label create loop-ok  --repo <owner/repo> --color 0E8A16 \
         --description "Operator-applied intake gate: dispatchable when gh-ready AND tagged (gh-tracking-and-claims.md)"
       gh label create loop-run --repo <owner/repo> --color 1D76DB \
         --description "Dispatcher-produced PR; org-wide open count is the backpressure signal"

   (GitHub caps label descriptions at 100 characters.)

1. Tag one small, well-specified issue `loop-ok` (a human-admission act: the
   operator's own tag, or a session tagging work the operator explicitly
   approved in that same session — gh-tracking-and-claims.md has the
   amended rule; autonomous runs stay fenced from the label).
2. Fire a tick while watching. Expected: gates log a structured reason or a
   dispatch line; a dispatch makes its worktree via wt-new (no PR yet — the run opens it
   after the first push), appends claimed+launched rows, and
   the run records routine start/completion events locally. Since
   [PR #1729](https://github.com/StartupBros-com/hov-stack/pull/1729), Discord
   notifications are reserved for actionable incidents, including failed,
   stranded, untracked, human-decision, and review-unknown outcomes. A subsequent
   tick's discovery poll labels the PR `loop-run` and appends the pr-opened row
   once it exists.
3. Disposition the resulting PR (merge or close). A later tick's reconcile
   appends kept/waste; `summary` reflects it.
4. Poll cadence while at rung 0: nothing automated watches for stalls yet —
   check `dispatcher-status.sh` when you expect activity. First escalation
   drill: run one issue whose work needs a closed-table category (e.g. a
   credentials touch) and confirm the needs-human artifact + Discord alert
   arrive (the plan's AE5 live proof).
5. Pause any time: `touch ~/.claude/dispatcher.paused` (resume: `rm`).

## Rung 1 — the timer (unattended ticks)

**Flip:** `systemctl --user enable --now dispatcher-tick.timer`

**Before flipping, in the same sitting:**
- Read the ledger: suggested floor ~10 dispositioned runs with keep-rate you
  would accept compounding unattended, and no unexplained `broken` rows.
- Keep the existing `dispatcher-stalled` entry active in
  `harness/deferral-watchlist.tsv`; that row is the command's single
  source of truth. Two signals: the timer's own `LastTriggerUSec` age (an
  enabled timer silent >45 min fires) and a wedged in-flight run (a run whose
  latest ledger row is still claimed/launched after 7 h, past the loop's
  worst-case ~2x `CLAUDE_LOOP_MAX_MS` wall clock, fires; the tick keeps
  exiting 0 during such a run, so `OnFailure=` never sees it and reconcile
  only marks dead pids broken). Known disabled/masked timers are quiet;
  unreadable timer state, last-trigger time, or ledger is broken, not
  healthy. Ledger mtime is not a signal: an idle tick appends no row, so an
  empty backlog read as a stall (it did, 2026-09-17), and a healthy run
  appends nothing between launched and ended. The row is read weekly by
  harness-doctor section 27, which bounds detection latency; doctor check 28
  owns ledger integrity.
- Append the audit row.
- Update `RUNG=1` in `config/dispatcher.env` (doctor check 28 reads it:
  a missing ledger warns at rung >= 1).

**Calibration owned at this rung:** `YIELD_MAX`, `YIELD_ALLOWLIST`, and
`MAX_USD` in `dispatcher.env`. Known headless automation (e.g. the weekly
memory-mine session) counts as load and over-yields the dispatcher — the safe
error direction. When a scheduled headless job is added to the box, add its
exclusion here; this doc owns keeping that list current.

`MAX_USD` (the per-run budget fence, issue #562) is reviewed against
`dispatcher-ledger.sh summary`'s `cut-short:` budget count: stops climbing
while keep-rate holds means the fence is eating legitimate work (the #558
incident — a feature-sized run killed ~90% done at the original budget); zero
stops forever means it may be too loose to catch a runaway early. Operator
decision 2026-08-28 set a per-run budget. Like every knob here, it never changes
automatically.

`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (the SDK's background-task wait
ceiling, issue #583) is raised by claude-loop.sh from the stock 600s to the
run's own wall-clock value (`CLAUDE_LOOP_MAX_MS`; default set in `bin/claude-loop.sh`): the 600s
default terminated a run mid-Workflow after substantial spend —
nothing delivered, reported as success until the #583 surfaces landed. A
dispatched run already carries two real fences (`MAX_USD` and the wall
clock), so a tighter third ceiling adds no safety, only another kill path.
Honest timing (inward vet, 2026-08-28, against the installed CLI 2.1.243):
the SDK starts this timer when the main loop *quiesces*, not at launch, so
it grants background work up to that much drain time *after* the
interactive phase — worst-case total run duration is ~`CLAUDE_LOOP_MAX_MS`
+ ceiling, during which the single-run dispatcher slot
stays occupied; spend remains fenced by `--max-budget-usd` throughout.
Review it against `summary`'s `cut-short:` background-tasks count exactly
as `MAX_USD` is reviewed against its budget count; override per-run via the
environment (claude-loop.sh respects a pre-set value — except `0`, wait
forever, which the wrapper overrides back to the wall-clock value because
the loop-guard fence only ticks on tool calls and an idle infinite wait
would be unfenced). The `empty-delivery:` counter is the same review's
cross-check — a cut-short run that also delivered nothing is pure waste,
the first thing a ceiling calibration should drive to zero.

The ceiling governs only subagent and workflow waits. A backgrounded shell on
its own does not hold a headless session open: five seconds after the model's
reply ends with only shells still running, the SDK kills them and exits 0 with
no line on any surface (CLI 2.1.261, the print-mode wind-down; measured on run
issue-184-1788674488, 2026-09-06, and on pro-gate#159 fix rounds 1 and 2,
2026-09-05 — each ended 5 s after its last reply, edits uncommitted). No
ceiling value changes that, so the child prompt (`dispatcher-tick.sh`) and the
pro-gate fixer prompt tell the model to run suites in the foreground and never
end a reply with a background task running (dotfiles#1019). The pro-gate
fixer, which runs under the loop's own `timeout`, lifts the ceiling outright
(`0`); the wrapper keeps its wall-clock value because nothing else fences an
idle child.

The context-size fence (`CLAUDE_LOOP_MAX_CTX_TOKENS`, dotfiles#1282) and its
`claude-loop.sh --resume-from` rotation were retired in harness teardown move 5
(2026-10-18): over the fence's lifetime on this host it wrote no handoff (5 raw
marks, 0 trips), the PostCompact compliance ledger had no reader, and the three
hooks cost a `node` spawn on every tool call, Stop and compaction. The ledger's
`--stopped` enum is back to `budget|background-tasks`.

## Rung 2 — merge authority (dispatcher PRs through an unattended owner)

**Flipped 2026-10-16** (operator ruling in the harness round-8 ideation
session, dotfiles#1841; the script change shipped in dotfiles#1842).

**Flip:** `pr-handoff.sh` accepts a `loop-run` PR once the ledger holds an
`ended` row for its `loop/<run_id>` run; the owner then carries it through
review, CI and the merge of the exact reviewed head under the existing
merge-your-own-gate-green-PRs convention. Before that row the handoff still
refuses and names the run and the ledger it read, because `claude-loop.sh`'s
own Pro loop may be pushing to the branch; it also refuses a `loop-run` PR
whose head branch is not `loop/<run_id>`, since there is no run to check. Any `ended` row qualifies, one carrying `stopped`
(budget, background-tasks) or `empty:true` included: the row
proves the wrapper stopped pushing, and the owner's review decides whether
the PR is worth keeping. Disposition (`kept`/`waste`) still comes from the
owner's merge or close through reconcile, so the keep-rate keeps reading
these runs; the owner's judgement is agent judgement, as every disposition
since 2026-10-06 has been (`CONCEPTS.md` → Keep-rate).

**Read at the flip:** keep-rate 55.5% (61 kept / 110 dispositioned), 1
broken, 11 undispositioned (oldest 265.9 h), cost-per-kept n/a
(contaminated-kept 61, no clean row). That is below the 0.75 the rung-1
audit row recorded (`ratchet-flip`, `rung-1-timer`, 2026-08-28T09:14:30Z),
and the figure mixes operator and agent judgement across 2026-10-06. The
earlier text here asked for ~25+ dispositioned runs on a baseline the
operator trusts: 110 clears the count, and whether the mixed figure is a
trusted baseline was the operator's ruling, not a measurement. The audit row
(`ratchet-flip`, `rung-2-merge`, appended 2026-10-16T08:11:02Z, before this
change merged) carries `cost_per_kept: 0` as a placeholder because
`audit-flip` requires a number and no clean value exists; the rung-1 row
carries the same placeholder. The operator flipped with those numbers read;
the reason was the 11
undispositioned PRs themselves: they sat against `K=10`, so the dispatcher
had deferred on backpressure at every tick since 2026-10-13 while no path
finished them (#1652 made them agent work, but the handoff refuse left
in-session finishing as the only route, and no session took it).

**What did not change:** `hooks/PreToolUse/loop-guard.js`. The
earlier text here expected the flip to relax the loop-authority fence for
flipped classes; it does not need to, because the fence governs a
`CLAUDE_LOOP_GUARD=1` run's merge, ready, handoff, intake-label, ledger and
installed-script surfaces, and this flip opens the unfenced handoff path
after that run has ended (`pr-handoff.sh` still refuses a fenced caller
before any PR read). The "routine class"
definition the earlier text asked for is replaced by the owner's review
ladder: every dispatcher PR gets the same adversarial, CE, Pro, CI and
exact-head merge an operator-authored PR gets, so no class is merged on
less review than before.

**Residual the flip accepts:** the unconditional refuse was also a second
barrier that did not depend on the environment. The fence is a guardrail,
not a jail (`loop-guard.js` header): a fenced run that cleared
`CLAUDE_LOOP_GUARD` in a child process could now reach `pr-handoff.sh` for
its own `loop/` PR, and the ended row it needs is a line in a ledger whose
fence is pattern-based too. What still stands between that PR and `main` is
the owner's ladder: adversarial, CE, Pro, CI and the exact-head merge. The
gate matches the ended row by `run_id` alone (ended rows carry `repo:
null`); a run id is `issue-<n>-<epoch>`, so a cross-repo collision needs the
same issue number claimed in the same second.

**Calibration owned at this rung:** `RUNG=2` in `dispatcher.env`. `K` still
counts open `loop-run` PRs org-wide; their clearing now depends on owners,
so a stalled owner fleet shows up as `defer:backpressure` ticks rather than
as an operator queue. Un-flip: restore the unconditional `loop-run` refuse
in `pr-handoff.sh`, set `RUNG=1`, revert the Rung 2 paragraphs in
`HARNESS.md` and `gh-tracking-and-claims.md`, and append a `ratchet-flip`
audit row naming the un-flip.

## Rung 3 — parallelism / the triage judge

Parallelism is NOT a config flip: R4's single-run gate, the singleton tick
lock, and the status surface's ledger-tail in-flight read all assume one run
— budget that redesign when considered. The judge (pre-sorting finished PRs
into looks-mergeable / needs-eyes / probably-waste) calibrates against ~20-30
dispositioned PRs and adds `waste` sub-categorization when it lands.

## Related

`harness/gh-tracking-and-claims.md` (labels, claims),
`CONCEPTS.md` → Autonomous dispatch (vocabulary),
`harness/deferral-watchlist.tsv` (circuit-breaker-revisit fires the
moment the dispatcher first writes a run log — that posture question is due
before rung 1, by design).
