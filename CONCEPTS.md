# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Evidence and verification

The vocabulary that governs what counts as proof here, and how a result may be recorded once the work is done.

### Planted negative

A test case pre-specified alongside an acceptance criterion that a naive wrong implementation would fail — near-identical to a passing case, differing **only** in the forbidden dimension, asserting the exact typed boundary.

Its purpose is detecting a gate that has silently stopped gating, which a happy-path suite cannot do. A guard proven once is a guard *assumed* thereafter, so planted negatives are re-planted after the gate they exercise changes. Enforcement artifacts get them too: a policy's claims stay assertions until a deliberate violation has bounced off them.

### Name-carried routing

A routing decision that a skill's name or id produced on its own, so that a test showing the name beside the description cannot tell whether the description routed. A routing verdict is name-carried until the name is neutralised or the prompts avoid its vocabulary; a result measured with the id visible supports only "name plus description routes".

### No-Claim Boundary

A required, explicit statement of what a green result does **not** prove, written before the result exists.

It buys structure rather than sincerity — a lazy one-liner satisfies the check. What it removes is the silent case, where the limits of a claim are simply never stated.

### Do-not-retry predicate

The falsifiable condition under which a recorded negative outcome may be revisited — an observable trigger, never "later."

Every negative-outcome entry carries one. Without it a negative result hardens into a permanent foreclosure of an option that might since have become viable; with it, a carefully recorded negative is a positive result on a time delay.

### Ceremony Test

The bar a process artifact must clear before being created at all: it names its consumer, its gate, the defect actually observed that motivated it, and the condition under which it gets deleted.

An artifact that cannot answer all four is not created. This is what prevents a parallel convention from being invented next to one that already exists.

### Named catch

A specific defect a gate demonstrably stopped, cited from a measurement or a counted record rather than from a code comment, memory note or skill file. It is the condition for keeping a gate.
*Avoid:* claimed catch

A gate with no named catch is cost, and a teardown removes it. A statement that a gate "caught X" counts only once it is checked. It is the gate-side counterpart of the Ceremony Test, which asks the same of a process artifact before the artifact is created.

### Outcome curve

The product repository's merged and opened pull requests, product share and open-to-merge latency, per merge week, used as the verdict on whether a process layer helps or hurts.
*Avoid:* throughput dashboard, merge-rate chart

It is read against the date each layer first appeared, and against bands written down before the reading. It measures cost, not quality. It can show that a layer slowed the work, but not that the layer kept defects out, which needs a separate count of defects reaching production. What a layer reports catching is the other side of the case, and a Named catch is what makes one of those reports count.

### Zero-run-green

The rule that a green aggregate is not evidence that anything ran: closure requires the set of checks that were *required* to equal the set that *passed*, over named checks.

An empty set is a failure, never a vacuous pass. The failure mode it guards against is a runner that matched zero files, a filter that selected nothing, or a benchmark that emitted null summaries — all of which exit successfully.

### Falsifiable assertion

An assertion that would actually fail if the defect it claims to guard were present; one that would not is vacuous and passes without evidence, indistinguishable from a real check in a green suite.

Two shapes recur. An assertion can measure a quantity the change does not move — counting the containers when the change appends inside one — so it reads identically whether or not the behavior occurred. Or it can assert an outcome that several code paths share, such as a single failure exit code, so a newly added branch that fires earlier satisfies it while the branch under test is never reached. Where Zero-run-green asks whether a required check ran at all, this asks whether a check that did run measured the thing under test.

### Pinned anchor

A locator a structural test uses to find a fact in source it reads rather than executes — an exact string it matches, whose position then feeds an assertion about ordering or structure.

Its failure mode is distinct from the assertion's. When the matched string is renamed, the anchor stops resolving, and unless resolution is asserted separately the test reports the property it could no longer check as violated — sending the reader to code that never changed. An anchor is also a caller of the string it matches, invisible to a sweep that looks for references to the identifier, and most invisible when the identifier survives the rename in its other roles. Resolution is therefore asserted before, and separately from, the property it feeds. Where a Falsifiable assertion asks whether an assertion that ran could fail at all, an anchor asks whether a failure names the condition that actually broke.

### Search feedback loop

An automation defect where a generated explanation is indexed by the same discovery query that produced it, so the tool's output becomes future evidence and can amplify its own verdict.

Generated evidence must use stable identifiers or live outside the searched corpus. A planted negative should prove that one run's generated output cannot change the next run's classification without new independent evidence.

### Latching gate

A fail-closed check whose refusal blocks the one change that would clear the condition it refuses on, so no retry can succeed and the refusal becomes permanent rather than protective.

The distinguishing feature is circularity, not strictness. A guard rejects a bad input and admits a good one; a latch rejects an input whose only remedy is gated behind the guard itself. An input that degrades monotonically — a growing index, an accumulating log, a lock never released — removes the last escape, because waiting cannot improve it.

Reporting correctly is no defence: a latch can diagnose its own refusal accurately on every run and still never open, which is what makes it survive review. The design-time question is whether the fix for a refusal is something this gate would also refuse. Where it is, the check needs a fixture isolated from the shared state it is really coupled to, so its verdict is attributable to the thing under test — or it must be demoted to advisory while keeping its notification path, as in Shadow mode. Downgrading a check's authority is not the same as deleting its visibility.

### Inward vet

An adversarial review of a change that touches hooks, guards, or doctrine, or that embodies a claim about platform or model behavior, run as two or three refute-by-default lenses before or immediately after merge.

The lenses are own-doctrine conformance, the strongest-lever check against official platform documentation, and — only when a behavioral claim is present — research grounding. Each is given the author's reasoning as claims to attack, never as context to confirm.

### Armor test

The test an always-loaded rule must pass before it earns a place: count the clauses that state the rule and the caveats that protect it from misfiring; a rule needing more caveats than clauses has already failed, because the caveats are the sign that the rule does not fit the cases it will meet.

It is applied together with measured recurrence, never instead of it: a rule that passes the armor test still has to target behavior that occurred before it and changed after it. Reviewers grafting exceptions onto a rule re-run the test on the result, since each graft is a caveat.

### Risk-keyed stop rule

An agent stop rule (stop, pause, confirm, decline) whose condition is the step the agent is about to take and what asked for it, rather than an event around it such as a turn, a time window, a tool class or having read something. The test is three questions asked before the rule is written or kept: what enforces it, what risk does the condition key on, and which incident is it for. A condition that names an event instead of a risk fails the second question even when the threat is real; the retired same-turn untrusted-content gate is the reference case (`docs/solutions/best-practices/key-an-agent-stop-rule-to-the-actions-risk-and-restate-it-verbatim.md`).

A rule that is restated outside its home file is carried verbatim with a pointer. A paraphrase is a second decision rule that no lens vetted.

### Trial fleet

A verification pass over the operator's real files in which one agent per file exercises a heuristic tool end to end into scratch and judges the rendered result, and a second refute-by-default agent verifies each claimed defect from the artifacts alone.
*Avoid:* real-file smoke, dogfood run

It complements the suite rather than replacing it: fixtures encode their author's model of the input, so the families a tool misses are found only in files the author did not write. Each confirmed family becomes a fixture, the fix goes into the shared rule, and the identical fleet re-runs on the new build; the score is correct outcomes over trials per round. Scratch copies are destroyed afterward because they are the operator's documents.

### Arm

One independent agent run inside a comparison: every arm gets the same fixture and rules, one candidate configuration each, and its output is labelled neutrally so the judge scores blind. An arm is also a unit of exposure: it treats whatever its launcher hands it as instruction, so an arm that can act on text will act on it, and review and measurement arms get the narrowest tool surface their stage needs.

An arm's envelope is only what the launcher hands it: the caller's own instruction files and memory are kept out, because their presence changes the answers and the cost, and the shape of that envelope is recorded with the run so results from different envelopes are never compared as if they were the same measurement.

### State surface

The query a system exposes over what currently exists or is currently collectable, keyed by present identity and answered from current state rather than reconstructed from history.
*Avoid:* status endpoint, live view

It is the ground truth for a backlog, a hold, or an orphan count; an event ledger records what happened and can only approximate it. A count derived by grouping and filtering ledger rows is a proxy for the state surface and is verified against it before it drives a resourcing decision, because a single object can emit many rows, an unfinished-looking outcome can mean preserved rather than lost, and the system may already have reaped what the rows still describe.

### Absence verdict

The claim that a store, script, log or surface has no reader or no consumer, made so that work can be filed to bridge it, retire it or bypass it.
*Avoid:* no-consumer finding, orphan claim, dead-store finding

The claim is only as good as the search behind it. Its state surface is the consuming systems' own definitions (their agent, prompt and reference files), read under every spelling of the path or identifier, plus a usage sample reported as an upper bound with its denominator; an index, a listing or a single-spelling grep is a proxy. A surface the verdict itself discloses as unsearched blocks the verdict rather than qualifying it, and a work item that inherits an absence verdict inherits the search that produced it.

### Rewrite receipt

The visible trace a guard leaves when it changes an agent's call instead of refusing it: one line in the tool result naming what was rewritten and why, plus a counted record in the friction log under a signature that names the shape. A rewrite without a receipt hides the friction it absorbed, so a rollup can no longer tell "fixed" from "masked".
*Avoid:* silent rewrite, transparent fix

### Reach check

The test a rewriting guard runs before it changes a call: not a fixed list of banned commands, but whether the guard can bound the call's effect statically to the session's worktree and scratch areas. It refuses whatever it cannot bound — git, `cd`, an outside path, the opaque-command set (`eval`, `xargs`, `parallel`, `awk`/`gawk`/`mawk`/`nawk`, `sed`), an inline or stdin-fed interpreter program (`python`/`node`/`perl`/`ruby` with `-c`/`-m`/`-e`/`--eval`, a bare `-`, or a heredoc), `find -exec`/`-execdir`, `gh pr checkout` and `gh repo clone|sync`, symlink creation (`ln -s`, `ln -f`, `cp -s`), a wrapper prefix carrying an option it doesn't recognize, an argument built from a variable or expression it can't resolve on a path-capable command, a literal argument that canonicalizes outside the allowed roots (a symlink counts), and a reaching command name appearing anywhere in a segment rather than only at its head. A call that reaches is never rewritten, because a script that carries it past the verifier is the `bash -c` hole wearing a filename.

### Never-red test

A changed, attributable regression **case** that passes both on its effective pre-fix source (with head tests overlaid) and at the reviewed head; it has not demonstrated that it catches the defect. It yields P1, or visible P3 with a reasoned path exemption. Unrun/unattributable cases and file-level fallbacks are P2, not RED proof, even when exempt. The requested manifest baseline may differ from the effective pre-fix revision after a valid later U2 trailer correction; both remain visible. Local RED is limited to an explicitly trusted later PR head of the operator-authorized current task, not arbitrary PR isolation. The baseline and first-round limits are in [evidence regime §8](harness/evidence-regime.md#8-review-round-evidence-and-freeze).

### Round record

A trusted, numbered PR marker comment containing the reviewed head, stable three-dot patch ID and changed-line size, actual/underlying verdict, live findings by severity/file, per-case RED evidence and effective baselines, streak, override and re-run status. The next round reads the full authoritative history; an already seen head or the previous non-rerun scored patch marks a re-run without changing the streak. A failed post has exact recovery paths for the pending record and captured ledger; file existence is unconfirmed until checked, and only U1 `confirm` reporting the exact single append, plus an exact pending-file match, proves a completed round (agents carry U1's compact view and confirm outcome, never re-typed history; the compact view leaves each RED test's command, reason and per-case statuses on the comment and keeps case names, which the never-red carry reads). Incomplete trusted marker history refuses instead of resetting to round one. See [evidence regime §8](harness/evidence-regime.md#8-review-round-evidence-and-freeze).

### Freeze verdict

`FROZEN` is the fourth PR review verdict when two consecutive scored rounds have positive, non-decreasing live P1+P2 counts **and** non-shrinking three-dot changed-line sizes. It names residual P1/P2 classes by file and preserves the underlying verdict. It stops further adversarial rounds, not required CE/security/CI/Pro review or the operator's prevalence decision; a PR-disclosed, operator-authorized boolean override admits only one invocation. An admission stop at an existing freeze creates no new round. See [evidence regime §8](harness/evidence-regime.md#8-review-round-evidence-and-freeze).

## Outcome taxonomy

The closed set of ways a negative or inconclusive result may be recorded. The set is closed precisely because free text loses the last two, and losing them manufactures false certainty.

### NEGATIVE(reverted)

A measured loss *or* a measured neutral, where the change was reverted. A neutral result is a revert too.

### NEGATIVE(retained-for-proof)

A negative result whose code stays in the tree, disabled, because the code itself is the evidence for the finding.

### PROVISIONAL

A result that survived a local check but has not cleared the real gate — directionally informative, not landable.

### NO_EVIDENCE

The precommitted gate could not be evaluated, or failed incoherently.

### VOID

The measurement **could not have detected** the thing it was aimed at — a dead flag, the wrong arm, a broken instrument.

VOID is not a rejection; the correct response is to fix the instrument and re-run. Recording a VOID as a NEGATIVE is the specific error the taxonomy exists to prevent, because it converts a broken measurement into a false do-not-retry rule that quietly forecloses a good option.

## Turn-end contract

The vocabulary for how a session may legitimately end its turn. Settled by the 2026-08-17 Positive Handoff Protocol brainstorm.

### Hand-back

A turn ending by returning actionable work to the operator that the agent could complete itself — "review this PR", "run these commands". Distinct from a genuine escalation, which cites an exception category and files an artifact.

The dominant measured form is asking the operator to review or merge a PR the session itself authored.

### Valid exit

A turn-end the completion predicate accepts: a `result:` whose claim matches observable state (PR merged, auto-merge armed, or a closing artifact filed), a `needs input:` backed by a filed `needs-human` escalation citing an exception-table category, or an explicit operator instruction to stop.

Text alone is never a valid exit; the predicate checks state, not phrasing. For a merged harness change, "live" is a separate state from "merged": it is settled by the Activation receipt, not by the merge record.

### Closeout

The step a session runs after its own PR merges. It proves from GitHub's merge record that the worktree's tip shipped. It then makes the worktree closable without discarding work or changing any file; at most the branch pointer moves, onto a merge commit with an identical tree. Last, it prints the Activation receipt. Run from inside the worktree, it leaves removal to the scheduled sweep and never hands removal to the operator.

Shipment is proven only from the PR's own record: GitHub merged exactly this tip, merged a head that contains it, or merged content identical to it. Content comparison against the default branch is never used, because a squash merge defeats every such heuristic. An answer the closeout could not obtain is never read as a yes: a failed lookup or an unreachable history refuses rather than guesses.

### Merge anchor

A remote-tracking reference that a Closeout writes to record a tip GitHub proved it merged, so tools that equate "reachable from a remote" with "pushed" treat the worktree as shipped. Claude Code's Agent View close check and its automatic worktree cleanup are two such tools.

It is written only after two independent GitHub records agree on the merged commit. Its lifetime is tied to its branch: it goes with the branch, or is pruned as an orphan by the next closeout or sweep if the branch was removed some other way. It is not shipment proof on its own: deleting the branch still needs a fresh proof, so an anchor can make a worktree closable but never makes unproven work disposable. Fetching every PR head wholesale was rejected for the same reason, since it would mark closed, unmerged work as pushed too.

### Activation receipt

The Closeout's own printed verdict on whether the canonical checkout contains a known merge:
- **checkout current / checkout not current:** the checkout includes the merge / its inclusion could not be confirmed. Closeout uses the safe fast-forward helper when the checkout is behind, then re-reads HEAD ancestry; a helper that exits cleanly without moving HEAD still yields "not current". A refusal retains the helper's diagnosis.
- **not applicable:** closeout could not establish an applicable merge to activate—for example, no merged PR was found, its head does not cover this tip, or required merge-history proof is missing. The receipt says why.

A positive receipt requires checking merge ancestry, never inference from the merge having happened or the helper exiting successfully. Unreadable state is reported, not treated as success. Full-mode closeout prints the receipt once per repository; dry-run only previews the freshen, and `--reconcile-only` never activates. A batch closeout can therefore print one branch's not-applicable receipt beside another branch's checkout-current one.

A checkout-current receipt alone proves neither runtime deployment nor freshness against every later upstream commit; it proves that one merge is an ancestor of the checkout's HEAD. Deployment claims need the relevant installed-file and consumer checks, and an already-running process may not reload. A negative activation receipt does not undo shipment proof. When the freshen refuses an overwrite, preserve the local state and obtain any required operator decision before resolving the collision, then re-run closeout. Handing the operator the refresh command instead is a Hand-back.

### Deliverable

A file produced for the operator to read once — an explainer, a report, a deck — as distinct from scratch only the agent reads and from documentation the repository keeps. A deliverable has one fixed home per repository and is shown to the operator by the harness's own opener in the turn that produced it; leaving the file for the operator to find and open themselves is a Hand-back.

It lives and dies with the worktree that produced it. A deliverable worth keeping is promoted into the repository's durable documentation through a reviewed change, never by leaving it where it landed.

### Shadow mode

An enforcement predicate running log-only: it evaluates exactly what it would block and records would-have-blocked events instead of blocking. The resulting rate is the metric that decides whether enforcement may be switched on.

Its purpose is to bound a gate's false-positive rate before the gate can hurt — measurement and enforcement share one code path, so the measured thing is the enforced thing. The rate is a false-positive rate only when the recorded event is the one enforcement would act on: a predicate that fires on every turn records turns, so its rate must be checked against what the flagged units did afterwards before it is read as a defect rate rather than an activity count.

## PR completion

The vocabulary for finishing a PR after its author stops. Settled by the 2026-10-03 Autonomous PR Completion brainstorm ([plan](docs/plans/2026-10-03-2243-feat-autonomous-pr-completion-plan.md)) and amended by the operator's 2026-10-04 ruling that no person decides a stopped review. Since 2026-10-17 the author does not stop first: Merge-and-end replaced the supervisor.

### Merge-and-end

The rule that the session which authored a PR also finishes it: it opens the PR ready for review, waits for CI, merges once the checks are green, and ends by reporting the merge commit, or leaves the PR open with the reason when CI stays red or the merge is refused.
*Replaced:* Owned PR, Parked PR

Only a diff touching billing, auth, migrations or CI gets a terminal review, one round, whose P0 and P1 findings are fixed before the merge; every other diff merges on CI alone. A red check the diff did not cause gets one failed-only rerun before it counts as blocking. Nothing runs after the session ends, so a PR left open is ordinary work for the next session.

### Owned PR

> **Retired 2026-10-17 (dotfiles#1873).** No supervisor owns PRs any more: under merge-and-end (`CLAUDE.md`) the authoring session merges its own PR or leaves it open with the reason. Kept as the record of the term.

A PR whose authoring session has handed it to the pro-gate supervisor, which then holds it through CI waits, review rounds, the merge and closeout until it merges, parks or is closed. Handing off is a valid exit only while a live supervisor owns the PR at its current head. It is distinct from a Hand-back: nothing returns to the operator.

When its review loop stops short of a clean result, the supervisor decides the PR itself. That covers the review governor, a cap, a fix session that changed nothing and a review that could not be delivered. If CI is green at the current head and the last completed review left no open P0, it merges the PR as it stands; otherwise it parks it. A named product choice always parks. This rule replaced the planned *stuck finding*, a per-finding stop with an independent checker that was never built.

### Parked PR

> **Retired 2026-10-17 (dotfiles#1873).** The owner and the dispatcher's recovery pass are gone, so nothing parks or resumes a PR. A PR left open with a park comment is ordinary open work for the next session. Kept as the record of the term.

The state of an owned PR its owner could not finish: open as a draft, claim released, with one park comment. The comment records why the loop stopped, why the stop did not merge, and the attempts made, which are the loop's stop comments, repair ledger and review text. It files no issue and carries no label, so it stays on the ordinary work surface. One park is not final: when the owner's stop decision was to merge and a Fleet red at the parked head interrupted that merge, the dispatcher's recovery pass resumes the owner an hour after the park, straight into the merge step, at most twice per owner record. Every other park, including one for an open P0, a named product choice, a test red or a CI wait that ended with no red check, stays until a session hands the PR off again or the record expires.

### Deciding run

Of the workflow runs at one head commit for the same workflow and triggering event, the newest-created one that ran at least one job; only its check runs describe that head, and the older runs it superseded are not CI evidence, red or green.

A re-trigger at the same commit, such as a ready flip or a description edit, adds a run beside the old one and a concurrency group usually cancels the old one, but the hosting platform keeps listing the cancelled run's checks. Reading every listed check misreads that cancellation as red; keeping one check per name can keep a pass that no longer describes the head. A run that skipped every job supersedes nothing. A deciding run counts as pending until it finishes, even when every job it lists so far has passed, because a job that waits on another is listed only once that one finishes. One that failed before any job ran counts as red, so a gap never reads as green. A merging session's "CI is green at the current head" means green by each workflow's deciding run.

### Fleet red

A red deciding run that the runner fleet produced rather than a test: no suite job failed, and every red job either never reported (the runner's finalize stall), lost its runner's contact with the server, or was stopped by its job timeout with its running step left without a recorded conclusion, the runner having stopped reporting. Its complement is a *test red*: a failed suite job, a failed local suite record, or a job its timeout stopped whose running step the cap concluded `cancelled`, a live runner's verdict, which may be a hang. A job cancelled before any runner took it, which GitHub serves with no runner and a start equal to its queue time, has no steps to read and is on its own a test red. A red whose signature cannot otherwise be read from the run's job steps and annotations is a test red until a later read succeeds: on 2026-10-13 GitHub served one finished job with all its steps and, within a minute, with none (its runner and timestamps intact), so an unreadable red is read again later instead of being called. Only a fleet red is the machine's to retry on its own, through one failed-only rerun (merge-and-end in `CLAUDE.md`); a test red waits for a changed head. Settled by the 2026-10-13 PR Path Recovery brainstorm; the cancelled-step reading of a live-runner hang rests on the classifier's comment, with no real capture yet.

## Autonomous dispatch

The vocabulary for the always-on work dispatcher. Settled by the 2026-08-21 Always-On Work Dispatcher brainstorm. The dispatcher itself retired on 2026-10-17 (dotfiles#1873); the terms stay because open `loop-run` PRs still need a disposition and the ledger readers remain.

### Disposition

The merge-or-close act on an autonomous PR by an actor other than the run that produced it — the keep-rate's only input. Until 2026-10-06 that actor was the operator. Since the operator's ruling that day (#1652), an unfenced agent session dispositions `loop-run` PRs, merging under merge-and-end (after CI, with one `/pro-gate` review only on billing, auth, migration or CI diffs); the producing run stays fenced from ready and merge (`CLAUDE_LOOP_GUARD=1`). Merging marks the run `kept`; closing unmerged marks it `waste`. Closing a bad autonomous PR is therefore a metric act that teaches the system what not to attempt, not cleanup.

### Keep-rate

Kept runs divided by dispositioned runs, for autonomous PRs. Together with cost-per-kept-PR (a gateway-window upper bound, dotfiles#1429) it is the governing graduation metric: every authority ratchet is flipped by reading it, and it is undefined over undispositioned PRs — which is why backpressure binds on unjudged output. Runs dispositioned after 2026-10-06 were judged by an agent after the gates, not by the operator, so a ratchet decision that reads the keep-rate across that date reads two kinds of judgement.

### Authority ratchet

> **Retired 2026-10-17 (dotfiles#1873).** The dispatcher whose powers these ratchets widened is gone, so no ratchet is flipped now. Kept so the plans and learnings that cite the term still read.

An explicit operator-flipped configuration widening of what the dispatcher may do (unattended timer start, merge rights, parallelism, the triage judge). Ratchets are decided from the ledger and never flip automatically; the shadow-mode → read-the-counter → enforce idiom generalized.

Some ratchets are *versioned consent*: the operator's acceptance of a privileged mode is recorded together with a version, and a version bump un-flips the ratchet until a human re-accepts. Enabling the mechanism's service is a separate act from granting its consent; a mechanism with the first and not the second runs but refuses its privileged work.

### loop-ok

> **Retired 2026-10-17 (dotfiles#1873).** The dispatcher that read this tag as intake is gone, so nothing admits work by it now; the loop-run fence still refuses a loop run that applies it. Kept so the plans, learnings and papercut docs that cite the tag still read.

The intake tag. An issue is dispatchable only when it is both ready (native-edge ready query) and tagged `loop-ok` — explicit human admission is the strongest early keep-rate filter, and the tag is the dispatcher lane's anti-laundering choke point: without it, agents file work, agents implement it, and the first human contact with the chain is a finished PR.

Who may apply it (amended 2026-08-28, operator decision): the operator, or an interactive session as mechanics for specific work the operator explicitly approved in that same session — the recorded approval is the admission act, the label write is clerical, and the session must be able to point to the approving exchange. Work no human approved in conversation (agent-discovered, cron-filed, another agent's suggestion) still requires the operator's own tag. Autonomous runs remain technically fenced from the label regardless (the loop-authority fence, `CLAUDE_LOOP_GUARD=1`), and `papercut family adopt` never applies it as a side effect of filing — filing a work item and admitting it to the autonomous lane stay two separate acts.

### Repository quality profile

> **Retired 2026-10-18 (dotfiles#1916).** The autonomous quality run that consumed profiles was removed with loop_quality; nothing reads a profile now. Kept as the record of the term.

The operator-approved, versioned runtime contract for autonomous work in one repository: strategy-source paths, required checks, quality route budgets, required CE/Pro capabilities, and rollout mode.

A profile is consumed before model execution and changes which work may launch; it is not a project summary or a substitute for product strategy.

### Review-ready draft

> **Retired 2026-10-18 (dotfiles#1916).** The autonomous quality run whose terminal state this was went with loop_quality. Kept as the record of the term.

The successful terminal state of an autonomous quality run: an open GitHub draft PR whose exact current head has valid strategy, implementation, independent DoD, CE-review, suite, and Pro-gate evidence.

Where a repository runs its required CI only at the head marked ready for review (dotfiles since #1598), a draft head's suite evidence is the local suite result recorded for that commit by `scripts/run-affected-suites.py`, and required-CI evidence first exists at the ready head. Elsewhere it is required CI at the draft head.

It is deliberately not GitHub's ready-for-review state and grants no ready, merge, auto-merge, or deploy authority; neither does the local suite record.

## Leaderboard submission

The vocabulary for the outbound usage-leaderboard feeds (viberank, tokscale). Settled by the 2026-08-22 Tokscale Submission Pipeline brainstorm; the admission floor and board table were settled by the 2026-09-10 Leaderboard Expansion brainstorm.

### Archive-before-POST

The rule that every outbound submission writes its exact would-be payload to a dated, durable local archive **before** any network send, so a failed POST still leaves the record and the archive survives upstream retention pruning.

The archive is the only durable local history of what was claimed publicly; vendor tools keep none. It doubles as the input for cross-source drift checks and for backfilling any later-onboarded board.

### Candidate board dossier

The evidence packet that decides whether a discovered token leaderboard is accepted, rejected, or held. It records source-backed submission mechanics, credential and updater posture, merge/rate-limit semantics, backfill support, unknowns, a no-claim boundary, and a falsifiable retry trigger.

A dossier is successful even when it rejects the board. Discovery never grants submission or timer authority; under the dossier lifecycle only an accepted dossier can proceed to backfill and one operator-observed submission. Boards admitted under the admission floor take the other route and never hold a dossier.

### Admission floor

The relaxed entry rule for a new leaderboard: a source-verified non-interactive submission path that a harness-owned timer can invoke, and a public profile or named row that results. It replaces the dossier for boards onboarded from September 2026 on. Nothing else is required for entry; what remains is a floor, not a gate: the harness owns the schedule (no vendor daemon, hook, scheduler, or MCP server), every vendor command is pinned or frozen on disk, archive-before-POST holds, and one unattended dry run must leave no side effect before a timer is enabled.

### Board table

The single versioned declaration of every board the shared submission runner serves: one row per board carrying its mechanism class, pin or digest, cadence, credential reference, archive name, and ranking window. Adding a board is one row plus its one-time login. The health report, the timer set, and the registry are all derived from it, so a board that is not in the table is not being submitted.

### Admission record

What a board admitted under the admission floor carries in the registry in place of a dossier: its board table row digest, the fingerprint of the evidence from its one unattended dry run, the date observed, and its mechanism and pin. The evidence itself stays private on the host; the registry row cites it by fingerprint and is written by a commit, never by a timer.

### Run receipt

The record the submission runner writes beside every archive: board, mechanism, pin or digest, archive path and digest, evidence class (wire payload, vendor preview, or local input), result, exit code, failure class (board or environment), and whether the vendor or endpoint was actually invoked (`sent`). Health reads receipts instead of correlating manager and journal evidence; only board-class failures count toward retirement. The last receipt of a successful real send is the board's `latest-ok` marker, which drives the due check, first-send gating, and the magnitude guard; an admission dry run that really sent (every pinned-command board, whose vendor sync is the send) writes that marker too, so admission is a supervised first submission and never repeats as a first send.

### Pin bump

The unattended change of one vendor version pin in the submission fleet. A bump is eligible only after a cooldown from the version's publish time, is proved locally without any board send, and lands as a pull request from a scratch worktree that merges through the required checks under a versioned operator consent. The board's next scheduled run is the live proof; a board-class failure after a pin change pages with the bump named. Settled by the 2026-09-12 Leaderboard Pin Bumps and Runner Fold plan.

## Papercut mining

The vocabulary for converting papercut telemetry into filed harness improvements. Settled by the 2026-08-26 Papercut Mining Loop brainstorm.

### Friction family

A curated group of raw papercut signatures asserted to share one cause, recorded as append-only events and folded into a single row at ranking time. Raw signatures stay immutable telemetry addresses; the family is the unit of triage, adoption, and suppression, and every membership decision is reversible by a later event.

### Candidate dossier

The decision packet triage prepares for one flagged family: a machine-prepared evidence half (counts, sessions, projects, samples, member signatures) and a session-authored judgment half (causal hypothesis with its strongest counterexample, owner class, cheapest remedy at the lowest promotion rung, pre-registered success measure, planted negative, No-Claim Boundary). Only a complete dossier may be adopted into a work item; automation prepares the packet, never the work.

### Disposition epoch

The interval that opens when a family's work item is closed and ends at the family's next recorded lifecycle event — a new adoption or a no-remedy verdict. Recurrence commenting is bounded to one comment per epoch: a family that keeps recurring nags its closed item exactly once, no matter how many passes observe the recurrence.

### Claim boundary

The stored, machine-enforced scope on a friction family's member signature that says which captured records count as evidence about the remedy: a target suffix, a target prefix naming a class of shape-coded targets, a repeats-only rule, or any combination.
*Avoid:* family scope (the command that records one), scope

Its content comes from the dossier's No-Claim Boundary, not from whichever records happened to trip a read. Recording a new boundary replaces the whole previous one rather than adding to it. A record that cannot prove it is inside the boundary (no captured target, no parseable time) never counts, in either direction.

### Loop-breaking remedy

A remedy that stops the second and later attempts of a retry loop (a guard that denies the retry, a hook that rewrites it) rather than preventing the first failure.

Its signature keeps firing once per caller while the fix works, so its claim boundary must be repeats-only: only the second or later occurrence of the same signature for the same session, agent and target, in parsed-time order, is evidence. A remedy that stops the first failure outright keeps the occurrence count, where a required second occurrence would hide a genuine regression.

### Verification stage

The derived read of a closed friction family's fix, recomputed from the post-closure records inside its claim boundary every time the family is shown and never stored: `regressed` when a claimed record postdates closure or a recurrence comment exists, `verifying` while the exposure floor or the minimum elapsed time is still unmet inside the window, `verified` once both are met, and `provisional` when the window lapsed without enough exposure.

Exposure counts distinct sessions since closure. The floor scales with the family's pre-fix baseline and is never lowered; the minimum elapsed time covers a weekly-cadence recurrence and is not waived by a shorter window. A regressed read names the first post-closure record that tripped it so the read can be checked against the claim boundary in place.

## Context management

### Load class

The context lifetime assigned to an agent artifact — always loaded, loaded on invocation, or read only after a named trigger — chosen by how often its content changes decisions rather than by how important the content is.

Demotion changes when an authority enters context, not whether it remains authoritative: the always-loaded layer keeps the decision and retrieval pointer, while an on-read authority holds infrequent evidence, mechanics, and recovery detail.

### Context fence

> **Retired 2026-10-18 (dotfiles#1913, teardown move 5).** The fence, its Stop handoff and the PostCompact compliance counter are gone; no hook stops a session on context size now, and the CLI's own compaction is the only context management. Kept so the learnings that cite the fence still read.

The check that stops a launcher-run session once its context size reaches the launcher's limit, so the work continues in a fresh session seeded from a handoff instead of losing detail to the CLI's own compaction.

It runs only in launcher-dispatched sessions, never in interactive ones. Context size is one request's input as the session's own transcript records it: fresh, cache-written and cache-read tokens together. For a response whose main model ran several passes around a server-side tool, it is the last main-model pass, never the sum across passes. When a reading is incomplete the fence counts more rather than less, and when the transcript cannot be read at all it lets the session continue. A trip first tells the session to write its handoff and stop. A session that keeps calling tools is stopped, and the handoff is written for it.

### Compaction floor

The context size a session comes back to on its first request after an automatic compaction. It holds the compaction summary, the cached system and tool prefix, and a remainder that has not yet been broken down, so it sits well above the summary's own size.

An automatic compaction trigger saves context only when it sits well above the floor. A trigger close to it makes the session refill and compact again within a few turns, each time spending a summarization request and starting its cached conversation over, until the CLI reports that compaction is thrashing. The floor is measured per model and workload from the sessions' own transcripts, never inferred from the summary size.

## Agent memory

### Memory index

The always-loaded file of one-line pointers to a project's memory notes. The CLI reads it only up to a fixed line and byte limit, the load cut, so a pointer below that point is invisible to sessions although it is still in the file.

The harness's index maintenance holds the index to a stricter budget than the load cut: run on an index over that budget, it moves the lowest-ranked pointers to the Archive tier. A hand-written prose line is kept verbatim, though it may move above the entries, but a line shaped like a pointer is treated as an entry and can be moved, including a pointer whose target is not a note.

### Archive tier

A pointer file kept below the load cut that sessions never load on their own and reach only by searching it. A note listed there still counts as reachable, so moving its pointer out of the Memory index removes it from default context without orphaning it.

### Memory mirror

A copy of live agent memory that the memory tools compare against, byte for byte, before they rewrite live memory. The committed copy in the repository changes only when someone refreshes it, so it lags live memory. A match proves only that a copy held those bytes at that moment, not that the copy is pushed anywhere it could be recovered from.

## Agent tool surfaces

### Data-source CLI

A thin, hand-rolled command-line wrapper over one external data API (`gsc`, `dfs`, `exa-cli`, `firecrawl-cli`), or over a vendor's own CLI when that CLI's surface is unsafe to expose directly (`vastai`, which refuses the vendor's key-printing and key-redirecting invocations before any exec and keeps the vendor's own output flag), that agents call through Bash instead of an MCP server: `--help` is the authority for its surface, `--json` is accepted after the subcommand where the wrapper defines the output, and where the wrapper owns a credential it resolves env, then Bitwarden Secrets Manager, then `~/.secrets`, unless it holds an Exact-record binding, which resolves that one record and nothing else, with `--where` naming the source that resolved without calling the provider wherever the source can vary (`firecrawl-cli` leaves credentials to the vendor's own configuration and has no `--where`, except its API-only `search --categories developer` path, which reads `FIRECRAWL_API_KEY` from the environment and sends it itself).

It exists because a command on PATH reaches every lane — sessions, subagents, Codex, cron — while an MCP server reaches only the client that registered it. Each one deploys as a `DOTFILES_LINKS` symlink into `~/.local/bin`, probes offline in `tool-smoke.sh`, and, where an MCP server preceded it, either retires that server or records the pairing as a documented coexistence in the CLI-supersedes-MCP doctor check; a retirement's surviving allow entries are the drift that check exists to catch.

### Exact-record binding

A wrapper's credential reference that names one secrets-store record by its identifier, so the wrapper retrieves that record alone and accepts its value only when the record's identifier, name and project all match the reference.

It has no fallback: an empty reference is a refusal, never a search of the store or a turn to another credential source. The identifier is not a secret. Finding it is a separate, one-time lookup that reads record names and identifiers in the authorized project only, never values, and selects exactly one exact-name match.

### Thinking display

The reasoning-stream mode a Claude Code session requests at launch, which decides whether the upstream streams the model's reasoning as text or as signature-only frames that carry no content. Headless runs default to the content-free mode, and interactive sessions do too unless the operator opts in, so harness launchers and the shared settings request the text-bearing mode explicitly.

It matters because the gateway judges a stream alive by content-bearing frames only: a long reasoning phase in the content-free mode is indistinguishable from a dead stream, is failed over to another account from the start, and is retried by the client until the session looks hung.

## Config sync

The vocabulary for how the harness's tracked configuration reaches a host's live Claude Code configuration, and why the direction differs by file.

### Volatile file

A live configuration file that the running client rewrites in place, so the repo can hold only a copy of it rather than a link to it. The live copy is authoritative once a host has one: installing seeds it only on a host that lacks it, pushing captures live into the repo, and a difference between the two reads as drift to be captured, never as a change waiting to be delivered. A change that originates in the repo therefore reaches live automatically only through a Reconciler, and otherwise only through a deliberate apply on each host, which for the permission surface goes through that surface's approval gate; an edit to the tracked copy alone is dead on every host that already has the file, and the capture step would remove it from the repo.
*Avoid:* copy-synced file, unlinked file

### Reconciler

A sync step that merges one canonical, repo-originated entry into a Volatile file on the host: it adds or updates only that entry, proves nothing else changed, replaces the file atomically, and keeps a backup. Reconcilers exist per entry because the volatile file's default direction is live-to-repo. Hook registrations and harness environment keys have them; ordinary permission rules currently do not, so a permission rule added in the repo reaches a host only by a deliberate per-host apply. An entry with neither a Reconciler nor that apply is not deployed, however green its merge.

## Tracking and claims

> **Retired 2026-10-17 (fleet teardown move 7).** Issue claims (the `claimed` label, the `Claimed by session` comment, the TTL and `Released:` marker) and the claim reaper with its reap verdicts are gone; `wt-new.sh` now only resolves the route, checks the issue is open and makes the worktree. The terms stay out of new text.

## Harness units

The vocabulary for the harness's own scheduled units and how their outcomes reach the operator.

### Weekly toast

> **Timer retired 2026-10-17 (dotfiles#1893).** The harness report runs on demand now, not every Monday; the toast and its line-counting rule are unchanged.

The operator notification the Monday harness report raises when it found something needing attention. The report decides by counting its own warning lines, and only a warning printed at the start of a line counts, so a script that feeds the report and indents its warnings never reaches the operator. It is the weekly push channel: a unit that wants a condition seen writes it as a countable warning line and exits clean, and the report carries it.

### Unit failure alert

The immediate page a harness unit raises when it fails (a non-zero exit, a timeout, or a kill), wired through systemd's on-failure hook rather than the report. It is the crash channel, distinct from the Weekly toast: a harness unit's contract is that a warning is a clean exit carried to the next report, and only a failure pages now, so a run that cannot proceed because of a transient (the network never came up, nothing was ruled) warns and exits clean rather than paging.

A unit whose own environment cannot resolve a dependency it needs (see House PATH) is misconfigured rather than unlucky: it records the miss as an error, and a unit set to treat recorded errors as failures exits non-zero and pages with the cause, because carrying it to the next report would hide it.

### Network readiness probe

The bounded wait a scheduled user unit runs before its script when the script's first action needs the network. The user manager has no network-online target, so ordering a unit on it waits for nothing; the probe instead asks the host the unit is about to use, every few seconds for a bounded time, and lets the script start once one exchange completes. Its own result never fails the unit: on the deadline it warns and the script runs anyway, keeping whatever failure contract it already had, so the probe moves the start and never the outcome. A unit whose script makes no network call of its own, or whose daemon reconnects by itself, records why it has no probe instead.

### House PATH

The search path a scheduled user unit declares in its own file so its script resolves user-installed and version-managed binaries the way a login shell does. The user manager starts a unit with its own search path, the stock system one unless the manager's environment has been changed, and not the login shell's, so a binary that lives only under the user's home or a version manager's shims is "not found" there, and nothing observed in a shell session proves otherwise. Every scheduled user unit whose script is run directly declares it or is listed as an exempt unit with its reason.
*Avoid:* unit PATH, systemd PATH

An exemption is a deferral with an audit due, not a verdict. The audit is running the unit's binary under the manager itself; a not-found result there lifts the exemption rather than justifying it.

### Unit environment probe

A test that runs a scheduled unit's script under the real user manager with the environment the unit file itself declares, so the test's scope is the runtime's scope. It parses the unit's own environment lines rather than restating them, isolates the run from live services (an unreachable service endpoint, a target that cannot exist), and asserts the run reaches a known early exit; a negative probe under the stock search path, a Planted negative, must fail the way the unit would, and must still reach the same exit, proving the unit's unrelated work is not withheld. Where no manager answers or the binary is absent from the host entirely, it prints a counted skip rather than passing silently (see Zero-run-green). It proves the environment a unit file declares, not the installed copy, and the Activation receipt does not prove the installed copy either: it shows only that the checkout advanced. The installed copy is proved after activation by asking the manager for the live unit's environment and confirming that no reload is pending.

## Plugin release

### Marketplace card

The one entry in the plugin marketplace's distribution manifest that pins a plugin to an exact release: its source commit, version, tag and release id. Installs follow the card, and a release is announced only once the card names it.

Moving a card to a newer release is a *repin*. The release train opens and lands repins itself, and lands one only when it changes nothing but the pins the train itself computed. An older repin landed after a newer one would move the card backwards, so a repin that a newer one supersedes is closed, not merged. A staged draft is published only once the card on the default branch pins it, re-checked right before the publish.

## Flagged ambiguities

- A *Weekly toast* (the Monday report's notification, raised from counted warning lines) and a *Unit failure alert* (the immediate page when a harness unit fails) are different channels with different triggers: a warning is a clean exit that reaches the first, a failure reaches the second. "Alert" had been used for both.
- "Mirror" names both the committed in-repo copy of memory and any directory handed to the memory tools' freshness check, such as a checkout of the pushed backup branch. Only a pushed copy is a recovery copy; a passing freshness check proves a byte match, not recoverability.
- A *Network readiness probe* (a wait the unit itself runs before its script) and a *Unit environment probe* (a test of the environment a unit file declares) share only the word.
- A *Claim boundary* (the stored scope on a papercut family signature) and a *No-Claim Boundary* (what a green result does not prove) share only the word. (The issue *Claim* it was once confused with is retired.)
- A *saturated* eval (every arm scores identically at ceiling) and a *genuinely null* result look the same in the top-line number and are not the same finding; the first is `VOID`-adjacent — the measurement could not discriminate — while the second is `NEGATIVE`. See `docs/solutions/best-practices/agent-bakeoff-eval-discrimination-failure.md`.
- *Claim boundary* (the stored, machine-enforced scope on a family signature) and *No-Claim Boundary* (the dossier's prose statement of what a green result does not prove) are distinct: the second is written first and is the source the first is encoded from. See `docs/solutions/best-practices/verify-loop-breaking-remedies-by-counting-repeats-not-occurrences.md`.
- An *event ledger* and a *State surface* are not interchangeable sources for "how many are outstanding": the ledger is history and the state surface is inventory. See `docs/solutions/best-practices/verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md`.
- A *Merge anchor* (a reference recording a proven-merged tip so worktree closers treat it as shipped) and a *Pinned anchor* (a string a structural test locates in source) share only the word. The older name "merge-anchored closeout", like the sweep's "merge-anchored reconcile" line, is a third sense: shipment proven from the PR's merge record, whichever proof held, not the reference.
- A *Reconciler* (the host sync step that merges one repo entry into a Volatile file) and the release train's repin reconciler (the scheduled job that keeps each *Marketplace card* on its plugin's newest release) share only the word.
- A *Pin bump* (one vendor version pin in the leaderboard submission fleet) and a *repin* (a *Marketplace card* moved to a newer release) are different changes with different gates.
- A *staged draft* (a release the train built and holds unpublished only until the *Marketplace card* that pins it merges, after which the train publishes it with no human step) and a *Review-ready draft* (a PR state) are different objects, and neither implies the code behind it was reviewed: a merged, tagged and staged version can still carry defects that only a review finds, and since nothing after the version-bump merge waits for a person, that merge is when it ships. See `docs/solutions/best-practices/merging-a-plugin-version-bump-is-the-ship-moment.md`.
- A *reap* of a Claim (the claim reaper retiring an expired tracking unit), Claude Code's *pressure reap* (the client itself stopping a session's running background command when host memory pressure coincides with a long stretch without human input) and the *memory watchdog* (the harness process that removes orphaned and oversized processes) share only the verb; an earlier learning attributed the second to the third. See `docs/solutions/best-practices/poll-long-waits-from-a-monitor-running-a-script-file-not-a-sleeping-background-shell.md`.
