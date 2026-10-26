---
name: rlm-external-state-decision
description: "Standing decision (2026-08-11): do NOT adopt a persistent-kernel / RLM external-state layer or a keep-the-corpus-out-of-context rule — measured across two bake-offs, PRs #357 and #362; the baseline already externalises state to disk"
metadata: 
  node_type: memory
  type: project
  originSessionId: 35113b7e-f48d-41c1-b9b8-4e06989e89f8
---

Prime Agent (13.4k stars) makes a persistent IPython kernel its model's *only*
tool, so corpora are queried programmatically and never enter the prompt. The
open question was whether that mechanism class earns permanent rent here. Two
measured bake-offs say no.

**The decision: do not adopt.** Not the `pyk`-style persistent kernel, not a
"parse programmatically, don't read big files into context" rule in CLAUDE.md,
not a child registry / family-messaging / usage-dashboard layer. Auto-refine
stays rejected on separate safety grounds (self-modifying prompt, no human
gate). The only thing adopted from the whole workstream is six lines of
on-demand routing in `plugins/hov-stack/skills/agent-swarm/SKILL.md` (PR #353).

**Why — the mechanistic reason, not just the null.** Given Bash and a
filesystem, this harness *already* externalises state by default. Told to review
60 files it greps the keyphrases and finishes in 20 turns with **0 reads and 0
compactions**; forced to actually read, it survives two compactions and carries
its findings as literals inside a heredoc, one run annotating its own sources
`# investigation` / `# settlement hold vendors from notes`. The filesystem is
already durable external state and survives compaction because it never lived in
context. Prime needs a kernel because a kernel is all its model has.

**What the numbers were.** Round 1 (PR #357): 3 arms, 141 runs, all 100%, no
compaction ever reached — a weak null, correctly criticised as measuring
nothing. Round 2 (PR #362): the hard tournament, 2-3 real compactions per run,
164-184k peak context, facts discovered mid-review — all 3 arms 8/8, baseline
19/19 under compaction. The kernel arm used **more** context in 8/8 paired tasks
(sign test p=0.0078, 1.12-3.14x) for identical answers; that harm finding is
**PROVISIONAL**, not landable, because `ab-pair.sh` refused. Retained delegation
was offered and never once used (0/8) — **VOID**, no evidence either way, which
is why it stays operator-invoked rather than default.

**The counterfactual is the point.** The tempting cheap move was a doctrine line
telling the agent to parse programmatically. It measured as no-benefit and
directionally *worse* (431k vs 230k context tokens at `xl`). This decision
declined a plausible-looking regression, with receipts.

**How to apply:** treat "add a persistent kernel / external-state layer / a
keep-it-out-of-context rule" as already-answered. Do not re-propose it in
audits, vets or CLAUDE.md passes. Cite this note and the receipts instead of
re-running the experiment.

**Do-not-retry unless** one of these observably fires:

- a task class is found where this harness's baseline **measurably fails** on
  sealed ground truth (two experiments, five difficulty escalations and 19
  baseline attempts under compaction produced zero failures);
- or the subject model changes to one that does *not* spontaneously write state
  to files when handed a filesystem — that behaviour, not corpus size, is what
  makes the kernel redundant;
- or an agent-appropriate comparative instrument lands (issue #367), at which
  point the PROVISIONAL context-harm finding can be settled properly.

"Prime shipped a new version" is not a trigger.

**Evidence, all committed:** `scripts/rlm-bakeoff/RESULTS.md` (round 1),
`RESULTS-TOURNAMENT.md` (round 2), 177 run receipts and both `ab-pair` captures
under `scripts/rlm-bakeoff/results/`, and the instrument itself (sealed-truth
generators, stream-json runner with compaction counting, paired stats with
degeneracy detection) in the same directory. The directory left the tree once
this decision closed; read it at its last commit with
`git show 070682e5:claude/scripts/rlm-bakeoff/RESULTS.md`, or restore the whole
instrument with `git checkout 070682e5 -- scripts/rlm-bakeoff` to re-run it
when a trigger above fires.

**Method lessons worth reusing:** difficulty is an *entry criterion* — a family
does not enter a tournament until the baseline measurably fails on it; instrument
mechanism engagement *before* the headline runs, not after (the first vet blocked
on exactly that); and a zero-width bootstrap CI on all-agree data is not
precision — flag it degenerate and report rule-of-three instead.

Related: [[evidence-regime]], [[verification-architecture]],
[[third-party-skill-vetting]].
