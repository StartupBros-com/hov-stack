---
name: evidence-regime
description: "Ceremony Test, zero-run-green law (gate-check.sh), No-Claim Boundary, planted negatives, and the negative-evidence outcome taxonomy incl. VOID/NO_EVIDENCE; ab-pair.sh for paired perf claims"
metadata:
  node_type: memory
  type: project
---

# Evidence regime

Controls that make a green result meaningful. This document distills general lessons
about evidence and process overhead from a third-party skill, evaluated on
2026-08-06. Its Rust model-porting workflow was not adopted; the controls here
address defects observed in this harness.

## 1. The Ceremony Test (applies to every new process artifact, including these)

A process artifact may exist only as a hard gate for a named capability. At creation it names:

1. **consumer** — who or what reads it,
2. **gate** — what cannot ship without it,
3. **defect** — the OBSERVED defect class justifying it, never a speculative one,
4. **delete-when** — its retirement condition.

The usable test: *does running code or a release gate branch on this artifact?* A dashboard or
meta-report only humans read is ceremony; don't create it. Process work earns zero capability
credit. Process share is a **diagnostic, never a quota** — the moment a ratio becomes a target,
the label gets optimised instead of the work.

**Disclosure does not launder a gamed metric.** A headline number stays a violation even when
the breakdown admitting the gaming sits beside it — the number's consumer reads the headline,
not the footnote. Measured 2026-08-10 on a planted fixture: two doctrine-primed audit arms
cleared a "bug backlog −30%" headline because its 16-stale-closures-without-repro breakdown was
disclosed in the same paragraph ("nothing here hides the ball"), while the un-primed arm
flagged it. Honesty about the method does not convert a gamed number into an honest one; judge
the headline as its consumer will read it. (`memory/jsm-process-porn-skill-vet-2026-08.md`)

**Keep process proportional to delivery.** Agents can spend their time building checks
while the actual deliverable stalls. Bound that work, record deferred checks explicitly,
and redirect effort when governance commits grow without progress on the deliverable.
Every script referenced below records its consumer, gate, defect and retirement condition
in its header; new harness checks should too.

## 2. Zero-run green is FAILURE — `scripts/gate-check.sh`

**The law:** a green aggregate is not evidence that anything ran. Closure requires the REQUIRED
set to equal the PASSED set over *named* checks. An empty set is a failure, never a vacuous pass.

We found this class three times before naming it, all recorded in
[drive-dont-defer-merges](drive-dont-defer-merges.md): a skipped job reports Success and
satisfies branch protection (**a members-app change merged untested, 2026-07-29**); an `on:`-filtered
workflow leaves its check Pending forever; an aggregator missing `if: always()` reports green
when an upstream job failed.

It is not only a CI phenomenon. A test runner that matched zero files, a `pytest -k` that
selected nothing, and a benchmark that emitted null summaries all exit 0. A live
`acme-evals/experiments/runtime_benchmarks/raw/*/*/throughput-probe.json` carries a valid
`throughput-probe/v0` schema, `repeats: 3`, and **every `summary.median_*` null** — a result
file that measured nothing, byte-indistinguishable in shape from one that did.

`gate-check.sh <owner/repo> <pr>` asserts every required check's conclusion is `success`. It
degrades by tier, and the tiers are not equivalent. UNPROTECTED (no protection rule) and
UNAVAILABLE (nothing readable) exit 3 and say in words that this is *not* a pass; an empty
required set exits 1. But when protection is merely **unreadable** it widens the assertion to
every observed check and *can* print `PASS` at exit 0 — always carrying `NOTE: asserted over
all observed checks; the required set could not be read.` Read that NOTE as a narrower claim
than it looks, not a clean gate: the tool is honest about its scope, so the scope is the thing
to check. (Verified 2026-08-06 by fixture; an earlier draft of this section claimed partial
modes never emit PASS, which was false for exactly this mode.)

It reads **both** protection mechanisms. A ruleset-protected branch 404s `Branch not protected`
on the classic endpoint exactly like an unprotected one, so `UNPROTECTED` is only concluded
after `/repos/{o}/{r}/rules/branches/{b}` also comes back empty; a ruleset-derived required set
binds as hard as a classic one and is labelled `from repository ruleset`. Until #196 it read
only classic protection and told us **this repo's own main was unprotected** while two active
rulesets gated it (#193) — the same permissive misclassification the tool exists to catch, in
the tool itself.

## 3. The No-Claim Boundary

One line, written **before** implementation, stating what a green result cannot be claimed to
prove. It is the tracker-level twin of "what this does NOT prove", and it makes proof-class
inflation a violation of the work item's own text rather than a judgment call at merge time.

Now a required field on the work-spec issue form and a section in the PR template. The defect
it answers is recorded in `memory/fix-first-merge-premise-verification.md`: merging on "the PRs
that passed review" when the PR body's claim was stale.

**Enforced at the chokepoint, not by the form.** GitHub honours an issue-form `required:` only
in the web New Issue UI — never on `gh issue create --body-file`, which is the path
`wt-new.sh` and therefore every agent takes. A field marked required but unenforced is worse
than an unmarked one: it buys false confidence. So `scripts/work-spec-check.sh` runs in
`wt-new.sh` immediately before `gh issue create` and refuses a body missing (or leaving empty)
Acceptance Criteria, Planted negative, or No-Claim Boundary. Its section regex mirrors
`verify-seed.sh`'s extractor, so a body that passes is one `verify-seed.sh` can actually read.

Two consequences worth stating plainly. First, the guard makes `wt-new.sh`'s fallback skeleton
self-synchronising: if that heredoc drifts from the required set, the fallback path fails the
guard, which is why no `work-spec.yml` -> markdown generator exists — the check catches the
drift the generator would have prevented, with less code. Second, and this is its ceiling:
**the guard buys structure, not sincerity.** It proves a section exists with something under
it; a lazy one-liner satisfies it. What it removes is the silent case — a required section
simply absent, with no signal at all.

## 4. Planted negatives

Every acceptance criterion pre-specifies at least one case a naive wrong implementation would
fail — near-identical to its positive, differing **only** in the forbidden dimension, asserting
the exact typed boundary. A suite that only proves the happy path cannot detect a gate that has
stopped gating.

Two of ours were exactly this absence: `ci-self-validating-guard-pattern` (a guard must check
the trusted base-branch checker against PR files *as data*, not the PR's own copy) and
`scoped-static-check-nesting-vouching` (rescoping a file-wide check to per-call spans left a
nesting hole). `tests/evidence-regime.test.sh` is the worked example.

Related: **gate/validator code is its own lane.** A change to a gate never rides along in the PR
it gates; it gets reviewed on its own, because the cheapest way to make a suite pass is to
weaken it.

**Enforcement machinery gets planted negatives too.** A policy file's claims are assertions
until a planted violation has bounced off them: plant an illegal transition and confirm the
gate actually refuses it. Both directions of this are already on the record here —
`gate-check.sh` reported this repo's own main unprotected until #196 because it read only
classic protection, and a SKILL.md-less dir planted under the skills directory (#297/#298) deployed
silently until the localizer grew its guard. Re-plant after the gate changes; a guard proven
once is a guard assumed thereafter.

Planted-defect fixtures for prompt-skill arms (not perf arms) get a blinding check before they
run; the procedure and its banned-word list live in the harness-vet skill's phase 4
(dotfiles#1202 item 8, from the pstack vet).

For PR review rounds, **pre-fix RED is case-level evidence, not a green-file certificate**.
An added or changed regression case closes its finding only if it fails on the effective
pre-fix source with the head's test files overlaid and passes at the reviewed head.
A named case passing on both revisions is never-red (P1; P3 only with an explicit,
reasoned exemption). An unresolved/unsupported/fails-at-head case, an unfetchable
pre-fix revision or a file-level-only fallback remains P2 even if exempt. A synthetic
whole-file failure does not prove each named case red. See §8 for round selection,
state and limits.

## 5. Negative-evidence outcome taxonomy — `.claude/scratch/NOTES.md`

Recording dead ends already stops the next session repeating them
([verification-architecture](verification-architecture.md)). Free text under-records in two
specific ways, so the outcome is now a **closed** set:

| Outcome | Meaning |
|---|---|
| `NEGATIVE(reverted)` | measured loss or neutral; change reverted. NEUTRAL is a revert too. |
| `NEGATIVE(retained-for-proof)` | kept in tree, disabled, because the code IS the proof |
| `PROVISIONAL` | survived a local check but has not cleared the real gate; not landable yet |
| `NO_EVIDENCE` | the precommitted gate could not be evaluated, or failed incoherently |
| `VOID` | the measurement **could not have detected** the thing (dead flag, wrong arm, broken harness). Not a rejection — re-run. |

`VOID` and `NO_EVIDENCE` are the two that free text loses, and both have already bitten us.
`memory/acme-evals-predictive-skip-not-throttling.md` is textbook VOID: 90-second sample kills
were the `predictive_skip` hard-skip policy, first diagnosed as provider throttling. Anything
measured while `reap_dead_in_flight` ran without a liveness check
(`acme-evals-cloud-eval-drain-concurrency-hazards`) is VOID too. Filed as NEGATIVE, those become
false do-not-retry rules that quietly foreclose good options.

Every entry carries **`Do-not-retry unless: <predicate>`** — an explicit condition, never
"later". We already do a weaker version of this in evaluation memory notes ("re-eval triggers
recorded": `beads-bv-evaluation-2026-07`, `graphsub-evaluation-2026-08`); this makes the field
mandatory and the outcome typed. A carefully recorded negative result is a positive result on a
time delay.

Durability: NOTES.md is gitignored and dies with the worktree; the PR body is the durable copy.
For repos with real perf/eval surface (a private evals repository, better-ccflare) prefer an in-tree
`docs/NEGATIVE_EVIDENCE.md` so the ledger accumulates and stays greppable. Everywhere else the
PR body is enough — a per-repo ledger in a docs site fails the Ceremony Test.

## 6. Paired A/B with a refusal gate — `bin/ab-pair.sh`

Any comparative perf claim runs through it. Interleaved ABBA ordering cancels the
"always second" thermal confound; a cv% gate REFUSES a verdict rather than reporting a noisy
one; a non-zero exit from either arm is VOID, never a timing row. `--metric <dot.path>` reads a
number out of each arm's JSON stdout so tok/s comparisons are expressible, and a **null** metric
is VOID — the private evals repository probe shape above.

It enforces pairing and refusal, not host quietness. It also refuses to rank commands too fast
to measure, which is correct: spawn jitter is not a performance difference.

## 7. The inward vet — adversarial review for harness-behavior changes

harness-vet gates what enters from outside; this tier applies the same bar to
what we build ourselves. A diff that touches hooks, guards, or doctrine, or
embodies a claim about platform/model behavior, gets 2-3 refute-by-default
lenses before or immediately after merge: own-doctrine conformance, the
strongest-lever check against official platform docs, and — only when a
behavioral claim is present — research grounding. The author's reasoning is
supplied as claims to attack, never as context to confirm.

For review routing, exact `CLAUDE.md`, `AGENTS.md` and `HARNESS.md` basenames
and Markdown beneath a `harness/` path-segment pair carry the existing
security domain alongside docs, including nested and case-variant paths. A CLEAN
result therefore does not take the docs-only CE skip. This is filename/path
classification, not semantic detection of every platform/model-behavior claim;
the broader inward-vet trigger above still applies. Domain tags do not establish
terminal Pro exemption: the separate ordinary-prose check in
`skills-stack/review-adversarial-first/SKILL.md` requires current trusted CLEAN
review evidence plus complete revision-bound file eligibility. It preserves
this inward vet, CI and the existing CE routing.

Receipt (2026-08-11, wf_79595f46, 3 Sonnet agents, ~8 min, on PR #325): it
corrected 3 of the reviewer's 4 claim-halves, surfaced two documented
mechanisms nobody had discussed (PostCompact; SessionStart's compact matcher),
and caught its own broken detector (a case-sensitive memory grep read as "no
note exists"). Issue #330 is the worked output.

## 8. Review-round evidence and freeze

**Creation gate (§1):** consumer = the `review-adversarial-first` workflow's
RedFirst/Record stages and the reviewer closing a regression finding; gate =
verified regression evidence before closing a finding and trusted round history
before admitting another review in a review/fix loop; observed defect = **one** never-red
regression case on #1294 closed a finding, and three review loops required the
operator to stop them. The other two #1294 misses were tests covering only one
of multiple shapes and are outside this gate. Delete the round/RED apparatus
when this entry tier is retired, or after three consecutive calendar months
that each contain at least one scored round (re-runs excluded) whose
`red_first.tests` include a path with status `ran` or `file-level` (RED
executed), and in which no round records a never-red finding or a freeze. A
round whose RED was unverifiable or not applicable does not qualify, and a
month without a qualifying round does not count toward the three. It is a
capability gate, not a dashboard or a certificate.

**Proof boundary:** a later PR round only runs local RED on an explicitly
trusted captured 40-hex head of the operator-authorized current task. After
frozen admission, it refuses a missing/moved head or one whose PR API head/base
identity, same-repository head/base provenance, or numeric author/operator API
IDs do not match; metadata alone is not authorship proof. A first PR round
and branch/path review remain compatible, but this is **trusted-head local RED**,
not isolation for arbitrary PRs. No global sandbox setting changes. PR
rounds select PR test paths changed since the **latest recorded head**,
including a re-run; each path keeps the baseline its first run requested when
revisited, or the earlier recorded head a trailer ran that request from
(fixed on first sight, even one whose run came back unverifiable: a later
trailer's revision never replaces it), otherwise uses that latest head. A carried baseline counts only as a 40-hex SHA equal to an earlier
recorded head, and a round whose selection failed seeds no baseline. U2's
`Red-first-base: <path> -- <sha>` selects an older defect revision (validated
against the PR range); `Red-first-exempt: <path> -- <reason>` lowers attributable
never-red from P1 to visible P3, but does not skip execution or lower P2
attribution failures. A never-red P1 stays live across re-runs and source-only
rounds, and counts as live P1 for the churn streak, until this round holds
evidence about its case: a `ran` or `file-level` re-run names that exact case
(the synthetic whole-file case does not count); a `ran` re-run starts from the
revision that flagged the live P1, so the case's absence means it was reverted,
renamed or deleted; the path is unchanged against its requested baseline; or the
path leaves the PR files or is absent at head. The flagging revision is the
earliest run naming the case among the trailing records that still hold that
P1. A trailer that moves the baseline past the case clears nothing. Neither does
a run from a later re-flag's revision, or from an earlier run's, such as one
that verified a stronger version of the case. Each record stores its
live findings, so the carry chains from round to round. A P1 is carried even
when no recorded RED test names its case: the history arrives by cooperative
agent transport, and a missing attribution must not drop a P1. A lens title
that copies the never-red prefix is therefore carried too; the carry errs
toward keeping. RED findings are matched by their exact `path::case` title,
so cases whose names differ only in punctuation or letter case stay separate
live findings. A lens finding merged with one takes that title and severity
unless the lens finding is unrefuted and stricter; the case is then named only
in the raw `red_first`. A path re-runs only
when it changes again and is re-selected; a `Red-first-exempt` trailer likewise
takes effect only then. U2 owns trailer resolution, checkout and overlay.
Missing old heads are explicit unverifiable/P2, not empty candidate sets: after
a force-push that makes the previous recorded head unfetchable, the round is
selection-unverifiable for every PR test path and no trailer restores it. A
rebase keeps recorded baselines and streaks, but a baseline that is no longer
an ancestor cannot execute. Every pre-fix tree U2 executes (a manifest
baseline, a standalone `--pre-fix` or a trailer revision) must be an ancestor
of the trusted head, so authorizing that head authorizes its in-range history,
including intermediate commits no round reviewed. After a rebase or force-push
the earlier heads are no longer ancestors, so affected paths come back
unverifiable P2 with a reason beginning `pre-fix <sha> is not an ancestor of
head`; in a shallow clone a failed probe reads `pre-fix <sha> cannot be proven
an ancestor of head <head> in a shallow clone; fetch full history (git fetch
--unshallow)`. The remedy is a `Red-first-base` trailer naming the in-range
defect revision from before the test changed, effective only when its path is
re-selected and only while the trailer stays in range; a trailer revision
that leaves the test unchanged at head comes back unverifiable P2
(`Red-first-base <sha> leaves <path> unchanged at head; name the defect
revision from before the test changed`), never an unchanged exclusion. An unverifiable P2 is not carried into later rounds, so until
re-selection the rewritten case is verified with the local red-first command
([skill](../skills-stack/review-adversarial-first/SKILL.md) Step 4). Existing tests already in the PR at
round 1 have no earlier recorded head: RED is `not-applicable`, **not**
verified. Defect shapes
without a changed test are outside this proof. Each raw path/case retains
pre-fix/head results and exemption reason; aggregate `red_first.status` may be
`verified` with an exempt never-red P3, which does *not* prove that case red.
`red_first.requested` preserves the selected manifest path/baseline pairs;
`red_first.tests[].pre_fix` and `unchanged[].pre_fix` are the effective
baselines after valid U2 trailer correction, and may differ from requested.
A separate Sonnet file reader checks the entire on-disk manifest, full PR
file list and RED report against transported output before scoring. Drivers
come only from an explicit trusted `driver_root` directory containing both
scripts, or the operator-installed `~/.claude/scripts` (never from target
checkout metadata). Each invocation uses a fresh directory under optional
`scratch_root` (default `/tmp`). Missing mechanical RED output or divergent
files fail review rather than inventing P2 evidence; a nonzero `red-first.sh`
exit throws `red-first-stage-failed` naming `red-first.err` and, when the
RedFirst agent returned one, its diagnostic. These independent agents
check cooperative transport, **not** non-forgeable execution or cross-family
independence. Collect's PR file lists and changed-test selection facts are
checked only against each other (the three file lists must agree, and blob
facts must match the changed paths), not re-read, so a copy that omits a path
consistently from all of them passes and can skip that path's RED or clear
its carried P1.

**Durable round and score:** U1's PR marker comments are read in full via
`review-rounds.py read --compact` as `{target, rounds, ledger_errors, view}`,
each numbered round holding a trusted envelope and nested `record`. The compact
view omits each RED test's `command` and `reason` and reduces each case to its
`name`; no decision reads the omitted fields, which stay on the PR comment: on
#1390 a Collect agent abbreviated the full 22.5 KB history rather than echo it,
and the workflow refused a non-compact or altered ledger. Collect's copy is
first shape-checked, and a malformed copy or one reporting invalid trusted
history stops there (failing closed). Then, before admission, selection,
baselines or the carry, a separate Sonnet file reader re-reads the captured
ledger file, and Collect's copy must equal the reader's; a divergent copy, a
failed read or an empty reader result throws `ledger-read-failed`, because a
shape-valid copy with a shortened case list or findings list otherwise records
a round the full history would not. The never-red carry
reads the kept case names to find the revision that flagged a live never-red
P1; the workflow refuses history whose RED tests lack them. Only the authenticated
operator's numeric GitHub API `user.id` and explicitly supplied trusted numeric
IDs admit comments; body, login and association cannot confer trust. Errors are
visible; a failed read never becomes an empty ledger. Invalid/unknown trusted
marker history stops as `ledger-history-incomplete`; known untrusted-author
noise stays visible without becoming trust. After every record posting outcome
(including a thrown response), a **different** Sonnet agent runs
`review-rounds.py confirm` on the captured ledger file (Collect redirects the
compact read into it) and the pending record file. U1 itself compares current
trusted history with both and reports `appended`, `unchanged` or `conflict`,
so no agent re-types history: on #1390 a Readback agent re-typing it
"corrected" a duplicate round and failed a correct post. An exact single
append plus the pending file matching the composed record confirms; a
confirmed append whose pending file was not read back stops (`pending_mismatch`
null); after a failed or thrown post, proven
unchanged history permits at most three total posting attempts, each retry
only after that attempt's readback compared the pending file equal to the
composed record (the posting agent's own write confirmation is not that
comparison, and U1 posts whatever the file holds); a reported
success that readback cannot yet see, a read failure, or a conflict stops.
`review-rounds.py record` itself posts only while trusted history holds exactly
`round - 1` rounds, so re-running a successful command refuses instead of
appending a duplicate (observed live on #1390, where round 3 duplicates
round 2 as a re-run). The record includes head,
stable three-dot patch ID, three-dot added+deleted `diff_lines`, underlying and
actual verdict, live findings by severity/file, raw `red_first`, streak, override
and re-run flag. Count **live P1+P2 only** (not P3). A scored round churns only
when that count is **positive and non-decreasing** and `diff_lines` is
**non-shrinking** against the previous scored round; freeze at **streak ≥ 2**.
The first scored round starts at zero; a zero count or any count/size shrink
resets streak to zero. A previously seen head is a re-run; so is a new head with
the same patch ID as the previous **non-rerun scored** round. A historical patch
recurring after an intervening scored patch is not automatically a re-run.
Re-runs are still recorded and numbered but neither advance nor reset scoring.
Read the entire authoritative history; only the displayed table may cap at 32.
Historical calibration is **NOT EVALUATED**: the recovered 2026-09 returns
lack pinned head/base/diff sizes and clean control endpoints; do not tune or
waive this threshold from them.

**Stop and recovery:** A completed PR round returns `CLEAN`, `BORDERLINE`,
`DIRTY` or `FROZEN` with `underlying_verdict`, `findings`, `touched_domains` and
`rounds`; FROZEN names residual live P1/P2 classes by file/title. An unflagged
admission against a frozen latest record stops before lenses/RED/Record with
prior evidence and **no new round**. Only an operator-authorized, PR-disclosed
boolean `args.continue_past_freeze: true` admits one override invocation. It
stores `override: true` with the underlying verdict; if it still churns,
including on a re-run, frozen state persists and the next unflagged admission
blocks. A converging scored override resets the streak. FROZEN stops adversarial
repetition, not mandatory CE/security/CI or terminal Pro review, and grants no
merge permission. Freeze-and-ship rests on the operator's prevalence
measurement, and a known unrefuted bypass of a blocking (enforced) control is
not frozen-and-shipped on low prevalence alone: fix it, narrow it, or
downgrade the control to warn-only and disclose it (guidance 3 of
[the stopping-rule learning](../docs/solutions/best-practices/stop-adversarial-review-loops-on-measured-prevalence-not-a-clean-round.md)).
The Workflow runtime delivers a thrown error to the caller as message and
stack only, so the `frozen`, `ledger-history-incomplete`,
`ledger-write-failed` and `ledger-record-too-large` stops end their message
with one line beginning `payload=` that carries their decision data as JSON.
That runtime (Claude Code 2.1.280) cuts the middle out of an error rendering
over 11,024 characters, and the rendering adds up to five stack lines of up to
501 characters each, so a typed-stop message stays at or under 8,000
characters. A summary line over 2,000 characters, or a `ledger-write-failed`
reason over 1,000, is cut with a trailing `…`; array fields are then shortened
to prefixes, largest first, and `payload.truncated` maps each shortened field
to its original length; if even that fails, the payload
is `{code, truncated: "payload exceeds the delivery limit"}`. For every typed
stop, a missing or unparseable `payload=` line is reported FAILED, runs
`/ce-code-review`, and never claims the CLEAN docs-only skip.
A typed `untrusted-head`
refuses the captured SHA and reason before RED/lenses/Record, with no invented
completed round. A round whose record body would exceed the 65,536-character
comment limit stops as `ledger-record-too-large` before any post: its verdict
is real but unrecorded. That limit is not in GitHub's published API docs; the
harness took it from papercut's local refusal of issue bodies past it, added on
an issue #527 review finding (tests/test_papercut.py). No comment post
has been observed failing at it. A
`ledger-write-failed` payload carries the exact intended `record_path`,
captured `ledger_path`, trusted `driver_dir`, whether writing the record file
was confirmed (an unconfirmed path is **not** a claim that the file exists),
and `pending_mismatch`: `true` (pending file compared with the composed
record, differs), `false` (compared equal after the last posting attempt,
whose agent could write the file) or `null` (not compared since then). No
completed verdict exists until U1 `confirm` reports its exact single append
and the pending file matches the composed record. Only `pending_mismatch`
false permits accepting that append without reposting, or, on proven
unchanged history when the post did not report success, a bounded retry of
the same file; true or null never posts the pending file, and on `appended`
stops adversarial rounds for the PR with ledger integrity unproven. The
skill's Step 3 table still routes `/ce-code-review` from the payload's `underlying_verdict`
and `touched_domains`.
Collect/lens/RED failures are also FAILED, never clean. Confirmed persisted
rounds with pending scratch cleanup remain completed. Branch/path reviews keep the old verdict
routing with `rounds.enabled: false` and no PR primitives. Operational routing
and recovery live in the [skill](../skills-stack/review-adversarial-first/SKILL.md).

## Deliberately NOT taken

The source skill's tracker-level machinery — policy-enforced state machines, root meta-beads
with inherited `agent_context`, capacity caps as verification-debt bounds — is built for a
multi-agent swarm against a bead tracker. We ruled out that stack in the 2026-07-22 beads
evaluation and the reasons still hold at solo-operator concurrency. Its RH-1..12 numbering is
likewise not imported wholesale; the selected controls above have observed local
defects behind them. Adding the rest would fail §1.

Related: [drive-dont-defer-merges](drive-dont-defer-merges.md),
[verification-architecture](verification-architecture.md),
[gh-tracking-and-claims](gh-tracking-and-claims.md).
