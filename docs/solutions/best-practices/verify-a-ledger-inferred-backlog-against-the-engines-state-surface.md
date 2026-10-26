---
title: "Verify a ledger-inferred backlog against the engine's own state surface, not by summing log rows"
date: "2026-09-04"
category: best-practices
module: pro-gate-reservation-ledger
problem_type: best_practice
component: development_workflow
severity: high
resolution_type: workflow_improvement
applies_when:
  - "A report or agent infers a backlog of held/orphaned units (reservations, jobs, locks) by summing ledger or log rows whose terminal status is inferred from the absence of a later matching row, rather than read directly"
  - "The system that produced those log rows also exposes a live status surface (a --status --json command, a state file, a queue API) that reports current holds directly"
  - "The same logged field value can be written for both a preserved/successful outcome and a genuinely lost one (e.g. an exit-code branch that fires on completion-with-preservation, not just failure)"
  - "Retries, resumptions, or harvest/recovery attempts on the same underlying unit can each write their own log row, inflating a per-row count into an apparent multiple of the real backlog"
  - "Recovery, cleanup, or re-review work is about to be scheduled against the inferred number before cross-checking it against the system's own authoritative state"
symptoms:
  - "An adversarial refuter or reviewing agent claims N orphaned/unclaimed reservations (or hours) by counting outcome:in-progress ledger rows with no later terminal row for their key"
  - "The engine's own --status --json (or equivalent live state surface) reports far fewer live holds, all already marked superseded/awaiting-harvest, none pinning capacity"
  - "A large share of the counted in-progress rows turn out to be double-counted retries/harvest attempts on the same conversation or PR, or come from a code path that writes the same outcome value for a preserved run as for a lost one"
related_components:
  - pro-gate-oracle-review
tags:
  - ledger-inference
  - reservation-tracking
  - pro-gate
  - state-surface-verification
  - double-counting
  - capacity-accounting
  - orphan-detection
  - adversarial-review
---

# Verify a ledger-inferred backlog against the engine's own state surface, not by summing log rows

## Context

During the 2026-09-04 ChatGPT Pro capacity-ROI ideation session, an adversarial refuter argued that the proposed build order wasted the most valuable week of compute headroom. Its evidence: a Python pass over `~/.pro-review-daemon/ledger.jsonl`, grouping rows by `(repo, pr)` and counting `outcome:"in-progress"` rows older than 48 hours with no later terminal row for that group. That computation produced **98 reservations holding 60.75 hours of already-generated, already-paid Pro output, sitting permanently unclaimed** — framed as a structurally invisible backlog (the daemon only walks open, labelled PRs) that was perishable and needed a one-time harvest sweep that week. The orchestrator accepted the claim and wrote it into a committed ideation doc as the top recommendation.

Re-deriving the claim against pro-gate's own live state surface (`bin/oracle-review.sh --status --json`, at the merged v0.40.0 commit) found a different system:

- Measured 2026-09-04: `--status --json` listed **8** reservations total, every one `state:"superseded-awaiting-optional-harvest"`, `holds_capacity:false`. Under the runtime home (`~/.pro-review-daemon/`, not this repo), `in-progress/` held 8 file entries, `completed/` held 717, and a `stale-reservations/` directory exists — the engine already reaps what it can prove is dead.
- Re-deriving the refuter's method from the same ledger, with the `(repo, pr)` group key and the terminal-outcome set written out explicitly, gave **226 rows / 98.0 hours** — not 98 rows / 60.75 hours. The count moved by more than 2x on the choice of key alone, before even comparing to ground truth.
- Re-keying by `marker` (the actual identity of one conversation/reservation, rather than `(repo, pr)`, which several markers can share across retries and requeues) found 80 markers that never logged a terminal ledger outcome. Of those 80, the engine on 2026-09-04 still tracked **5** as live reservation state; the rest had already cycled out of every state directory.
- The corrected recommendation removed the harvest sweep from the ideation doc entirely in a follow-up commit.

Three mechanisms explain why the ledger-only inference overcounted, each grounded in the engine source (`bin/oracle-review.sh` in the StartupBros-com/pro-gate repo, at the merged v0.40.0 commit; line numbers are from that tree, not this one):

1. **An `in-progress` row means preserved, not lost.** `bin/oracle-review.sh:1744` documents the phase directly: `# in-progress (slot SPENT, model still generating: collect later with --harvest <marker>, NEVER relaunch).` The outcome is assigned at `bin/oracle-review.sh:2326`, `9) outcome=in-progress ;;`, inside the exit-code-to-outcome `case` that builds every ledger row. Exit 9 is produced by the `SALVAGE_PRESERVE` branch at `bin/oracle-review.sh:4089` (`elif [ "${SALVAGE_RAN:-0}" = 1 ] && [ "${SALVAGE_PRESERVE:-0}" = 1 ]; then`), whose comment at `bin/oracle-review.sh:4091-4092` states the intent plainly: "the Pro slot is spent and the answer may land any minute" — the branch persists a durable reservation and leaves the tab open before calling `pg_finish 9` at `bin/oracle-review.sh:4131`. An `in-progress` row is the ledger's record of a *parked, recoverable* answer, not a discarded one. Counting old `in-progress` rows as "lost" inverts the field's own documented meaning.
2. **One conversation can emit many rows.** `bin/oracle-review.sh:2246` sets `kind="fresh"; [ "${HARVEST:-0}" = 1 ] && kind="harvest"`, and that `kind` is written into every ledger row (`bin/oracle-review.sh:2383`, `2385`). A harvest is a later, separate process that re-reads an existing conversation over CDP rather than spending a new slot — of the 530 in-progress rows measured 2026-09-04, 242 carried `kind:"harvest"`: repeated collection *attempts* against the same underlying conversation, not 242 independent stuck reviews. Summing `secs` across them, or counting them as distinct backlog entries, multiplies one object's wall time by however many times it was polled.
3. **A superseded reservation holds no capacity and is optional by design.** When a PR's head moves, `pg_reservation_supersede` writes the ledger event at `bin/oracle-review.sh:969`: `{ts:$ts,outcome:"superseded",marker:$marker,proof:$proof,holds_capacity:false,charge_retained:true}`. The `--status --json` computation at `bin/oracle-review.sh:1272` reflects the same state: `holds_capacity:($life != "complete" and $life != "superseded")`, with `state:` set to `"superseded-awaiting-optional-harvest"` when superseded. These are answers to questions nobody is asking anymore (an old head), explicitly marked as not blocking capacity and not urgent — the opposite of the framing "perishable, unclaimed, needs a sweep this week."

A further, non-code but directly on-point data point: pro-gate issue #131 originally asked for exactly the kind of age/TTL-based terminal rule a ledger-age inference implicitly assumes exists. The issue was corrected in its own comment thread: "the 2026-09-01 re-scope on #109 states that no production terminalizer is authorized from age, TTL, repeated no-VERDICT, or absent spinner, and that implementation waits on a verified turn-scoped terminal DOM predicate." The maintainer deliberately withdrew age-based reaping as a design choice; a report that treats "old ledger row, no later terminal row" as proof of loss is reasoning from a reaping policy the system explicitly does not implement.

A prior session (session history, 2026-08-29 → 09-02) is a working precedent for the right side of this: finding all four review slots occupied, it queried `oracle-review.sh --status --json` and filtered on `holds_capacity == true` rather than guessing from markers, and explicitly refused to harvest or delete another session's reservation state. The pro-gate skill contract it was operating under states the general form — "do not infer an action from verdict prose, status phase, exit code, recoverability, or remaining rounds" — and this learning is that discipline applied to capacity accounting.

## Guidance

A ledger (or any append-only event log — audit trail, metrics stream, action history) records what *happened*. It is not the system's inventory of what currently exists or is currently collectable. When any report, agent, or refuter infers a backlog, debt, or "orphan" population by grouping and filtering event-log rows, verify that inference against the system's own live state surface before it drives a decision — especially a resourcing decision ("spend a week on this"). Concretely, before accepting a log-derived count:

1. **Find the state surface and read it first.** Most systems that maintain a ledger also expose a query over current state (a `--status` command, a state directory, a DB table keyed by current identity). Here that is `oracle-review.sh --status --json`, which reports `holds_capacity` and a `state:` string per reservation directly from the reservation directories on disk — not reconstructed from history.
2. **Check what the row's outcome actually means**, by reading the code that emits it, not by assuming English-word semantics. `in-progress` sounds unfinished-and-stuck; in this engine it is spelled out as `# slot SPENT, model still generating: collect later ... NEVER relaunch` (`bin/oracle-review.sh:1744`) — preserved, not lost.
3. **Check whether one underlying object can produce multiple rows.** A `kind` field, retry counter, or attempt index in the row schema is the tell. Summing a raw metric (`secs`, dollars, hours) across rows without deduplicating by the true identity key inflates the count by however many times the object was touched.
4. **Check whether the system already reaps what you're about to call outstanding.** A `superseded`, `expired`, `stale`, or equivalent terminal-adjacent state, with its own `holds_capacity:false` marking, means the system has already retired that entry from anyone's "must act on this" list — don't re-discover it as new debt.
5. **Re-derive the number under a second key before trusting it.** Grouping by `(repo, pr)` gave 98 rows / 60.75 h; re-deriving from the same ledger with the group key and terminal set spelled out gave 226 rows / 98.0 h; keying by `marker` gave 80. A count that swings that far with the choice of key is a property of the method, not of the backlog, and has no business being load-bearing for a plan.

## Why This Matters

The wrong inference was not a rounding error — it was large enough (98 claimed vs. 0 reservations pinning capacity as measured 2026-09-04; 60.75 hours of claimed "already-paid, unclaimed" output vs. 8 reservations that were all `holds_capacity:false`) to become the headline recommendation of a committed ideation document, arguing to spend the single most valuable week of compute headroom on a sweep against a backlog that, measured against the engine's own state, does not hold any capacity. Because ideation and adversarial-refutation output is meant to steer real build-order decisions, an unverified log-derived number that "sounds" alarming (hours of paid output "sitting unclaimed") can silently reallocate a scarce resource toward nothing.

This is also not a novel failure mode for this system — it is the same mistake one layer up the stack. `pro-lane-report.py` had the identical bug: it counted files present in `in-progress/` and reported "0 of 4 free" when the engine's own `--status --json` said 2 of 4 slots were actually free (fixed in dotfiles PR #884, which changed the report to read `holds_capacity` from the engine instead of counting files). Both bugs assumed a proxy for state — a directory listing in one case, an event-log group-by in the other — was equivalent to the state itself, when the engine had already moved past that state (superseded, harvested, reaped) without deleting the historical trace.

## When to Apply

- A report, agent, or "adversarial" reviewer infers a backlog, debt, waste, or "orphaned"/"unclaimed" population by grouping or filtering rows in an event log, ledger, audit trail, or metrics stream.
- That inference is about to justify spending non-trivial resources — a sweep, a migration, a week of prioritized work, a line in a committed planning document — rather than just informing idle curiosity.
- The system in question maintains any state surface distinct from its history log (a status command, a state directory, a table keyed by current identity) that could be queried directly instead of reconstructed from the log.
- The event schema includes a field like `kind`, `attempt`, `retry_count`, or similar that hints one underlying object can emit more than one row.
- The log's "unfinished" or "in-progress" outcome is being read as "lost" or "wasted" without having checked, in the code that emits it, whether the system's own design treats that state as preserved/recoverable instead.

## Examples

Wrong inference (ledger-only, unstable across its own re-runs):

```
group rows by (repo, pr)
keep group if latest row.outcome == "in-progress" and age(latest row) > 48h
  and no later row in the group has a terminal outcome
sum(row.secs for row in kept groups)
```
As reported into the ideation doc: 98 rows / 60.75 h.
Re-derived from the same ledger with the key and terminal set made explicit: 226 rows / 98.0 h.
Keyed by `marker` instead of `(repo, pr)`: 80 markers.
Neither run deduplicated `kind:"harvest"` rows (repeat collection attempts against one conversation) from `kind:"fresh"` rows, and neither checked whether the grouped PR's reservation had since been marked `superseded`.

Right check (state surface first, ledger only to attach history to markers the state surface already flagged):

```bash
# 1. Ground truth: what does the engine say holds capacity RIGHT NOW?
oracle-review.sh --status --json | jq -c 'select(.holds_capacity)'
```
```python
# 2. Only for markers the state surface flags, look up ledger history by marker (not repo/pr).
import json
pinned = {r["marker"] for r in
          (json.loads(l) for l in open("status.jsonl")) if r["holds_capacity"]}
for line in open("ledger.jsonl"):
    row = json.loads(line)
    if row.get("marker") in pinned:
        print(row["marker"], row.get("outcome"), row.get("kind"))
```
Result (measured 2026-09-04): 8 reservations total from `--status --json`, all `state:"superseded-awaiting-optional-harvest"`, `holds_capacity:false` — **0 reservations pinning capacity**. Separately, re-keying the ledger by `marker` found 80 markers with no terminal outcome ever logged, of which the engine still tracked 5 as live reservation state that day; the other 75 had already cycled out of every state directory pro-gate exposes.

## Related

- [Diagnose plugin behavior against the installed version and live record provenance, not caches](diagnose-against-installed-versions-not-plugin-caches.md) — same shape one layer over: trust the live, installed artifact over a cache/proxy of it; here the live artifact is the engine's own state surface, and the "cache" is the append-only ledger being read as if it were current inventory.
- [Verify a parity claim by exercising both sides, never by reading a design table](verify-parity-claims-by-exercising-both-sides.md) — same discipline of executing the real thing instead of trusting a derived description of it, applied to a two-sided agreement claim rather than a single system's current-state claim.
- pro-gate issue #131 and PR #132 — the issue's own withdrawn ask ("no production terminalizer is authorized from age, TTL, repeated no-VERDICT, or absent spinner") is the direct evidence that this engine deliberately does not treat an old, non-terminal ledger row as proof of loss; PR #132 fixed the related supersession bug that had let one specific reservation pin capacity for 44 hours.
- dotfiles PR #884 — the prior, structurally identical bug in `pro-lane-report.py`, which counted `in-progress/` files instead of reading `holds_capacity` from `--status --json` and reported "0 of 4 free" against an actual 2 of 4.
