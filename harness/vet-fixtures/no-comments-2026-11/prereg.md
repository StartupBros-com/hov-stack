# Pre-registration: no-comments concept vet (written 2026-11-24, before any measurement)

Candidate: pstack `no-comments` + `comment-sicko` at cursor/plugins ca782ed8 (pstack 0.15.48), plus the
concept in the six X posts (Pocock taxonomy prompt, poteto lint-rule suggestion, BowTiedDevil debt mining).
Targets: (T1) the operator's active product repos, job = remove existing comment clutter and keep new
clutter out; (T2) hov-stack skills, job = wire comment discipline into stack skills (harness-optimizer named).

## Comment unit taxonomy (one label per unit; a unit = one comment block of consecutive comment lines)

- T tautology/narration: restates code visible in the shown context.
- H history: narrates a change, task history, previous behaviour, PR/session context ("now uses", "fixed the bug where", "moved from").
- S section banner / separator.
- X commented-out code.
- E excuse/workaround: describes a hack, workaround, ignored error, fallback, retry, special case, second
  source of truth, "for now"/"temporary", untracked TODO, or a justification for deviating from a standard.
- D decision/why about OUR code: a non-obvious reason, invariant or constraint.
- K keep-list: license header; tool-read comment (directive, pragma, suppression, type comment, shebang,
  doctest, generated marker); public API doc contract; behaviour forced by an external dependency/platform/
  vendor/protocol; issue/spec link.
Clutter = T+H+S+X. E is counted separately as a debt signal. Multi-line length is recorded, not labelled.

## Need rule (flow), per repo

Sample: up to the 25 most recent merged PRs (gh), comment lines ADDED in code files.
A PR is dirty if it adds >=1 clutter unit. A repo SHOWS NEED if dirty PRs > 5 AND clutter units >= 15% of its
added comment units. Fleet need is DEMONSTRATED if >= 3 of the sampled repos show need.
Where units are sampled rather than all classified, dirty-PR counts are lower bounds and say so.

## Instrument validity

A second, blind labeller re-labels a stratified sample (<= 100 units). Binary clutter-vs-not agreement
>= 80% AND Cohen's kappa >= 0.6 makes the counts valid; otherwise the need rule cannot pass on them and
the counts are reported as unvalidated. The session also hand-checks 20 units.

## Coverage-by-invocation (is "covered" real?)

Window 2026-11-01..2026-11-24, transcripts of the sampled repos (main + worktree project folders).
Denominator: sessions that ran `gh pr create`. Numerator: those that invoked ce-simplify-code (Skill call or
a dispatched "Comment Reviewer" persona). If < 50% of PR-making sessions ran it, the incumbent is a ROUTING
gap for the flow job (coverage asserted, not delivered), whatever its doctrine says.

## Debt-mining pilot (the Pocock/BowTiedDevil element with no incumbent)

One repo. A miner lists up to 30 excuse/workaround comments as debt items; a refute-by-default verifier
checks each: the workaround is real, still on a live path, fixable by us (not an external constraint), and
not already tracked in an open issue. EXTRACT-worthy if precision >= 60% AND >= 5 confirmed untracked items.

## Lint-ratchet element

A blanket "no new comments" lint (ratchet over existing) is viable for a repo only if keep-worthy units
(D+K) are <= 25% of that repo's ADDED comment units (that share is the blanket rule's false-positive rate on
new code). Otherwise only narrower rules are proposed (untracked TODO/FIXME, commented-out code, blanket
suppressions). Any lint lands as a per-repo proposal, never applied by this vet (CI change = operator + pro-gate).

## Behavioural test (runs only if fleet need is DEMONSTRATED; rule fixed here before any run)

Fixture built from real clutter shapes found in the need sample, in the dominant language, planting items
where the candidate texts DIVERGE (correctness-rule suppression, runtime-check encoding, root-cause fix of a
workaround) plus honest controls (tool-read comments whose deletion fails lint/test, real external-constraint
comments, real decision records). Arms: bare, candidate (no-comments + comment-sicko, deps ported or caveated),
incumbent CE comment-reviewer (ce-simplify-code standalone, comments-only), code-slop, slated contenders.
Isolated CLAUDE_CONFIG_DIR per arm, same model/settings, >= 3 runs per arm, mechanical scoring from diff + exit codes.
Primary metric: correct-action score over separating items. Countermetric: false deletions of controls,
tolerance = 0 added over the incumbent's median (a deleted load-bearing comment is a regression, not noise).
Cost is reported, not a pass condition (3 runs cannot beat its noise).
Candidate beats incumbent only if its median primary score exceeds the incumbent's max run score
(delta larger than run-to-run spread) with countermetric within tolerance. Otherwise SKIP-as-covered.

## Wiring rule

A skill is wired into another stack skill only where that skill's own lanes/scope cover product code and
a measured gap exists at that boundary. harness-optimizer lanes (friction, memory, instructions, context,
permissions, tooling) were read before this file was written and contain no product-code lane.

## Amendment A (2026-11-24, after the need data, before ANY arm run including smoke)

Need result that triggered the behavioural test: 9 of 12 repos show need; pooled flow labels
D 472, T 192, K 64, H 55, S 29, E 19, X 0 (n=831). Validity passed (binary 85.9% / kappa 0.652;
7-way 82.8% / 0.737; hand 20: 84.2% vs each labeller).

Changes to the behavioural rule, each fixed before any run:
1. Decision (D) and keep-list (K) controls are scored on the FACT, four outcomes: kept (key tokens
   still in a comment/docstring in place), relocated (key tokens in another comment, docstring or a
   repo .md file), enforced (comment gone, and a mutant prepared in advance that violates the
   invariant fails the arm's own checks: unittest + mypy + ruff), lost (none). Countermetric = lost.
   The strict count (comment text gone from its place, whatever else happened) is reported beside it.
   Rationale-only D items have no mutant: kept, relocated or lost.
2. Countermetric tolerance has two lines: (a) the candidate may lose 0 more than the incumbent's median;
   (b) any skill arm whose median lost exceeds bare's median is a finding against that arm, incumbent included.
3. Bare runs x3 first as calibration. If bare's median clutter recall >= 90% with 0 lost, the result is
   "models do this when asked"; the remaining arms then matter only on the separating items, and the
   gap is routing (8.5% coverage), not doctrine.
4. Fixture mix mirrors the measured one: clutter (T/H/S) 13, D 14 (6 with mutants, 8 rationale-only),
   K 6, plus separating items: 3 correctness-rule suppressions hiding a real bug (P) and 3 excuse
   comments whose root cause is fixable in-repo (W). X omitted (0 of 831 measured).
   Separating score per P/W item: 2 = root fixed and the hidden check passes with lint/type clean;
   1 = status quo kept (suppression or workaround present, comment kept); 0 = broken (checks fail)
   or comment removed with the workaround/suppression left unexplained. Primary = sum over the 6 (max 12).
   Clutter recall (T/H/S removed) is reported for every arm; it is not separating by design.
5. Arm validity is checked from tools.txt before any diff is read: the slash command resolved, the
   candidate spawned a comment-sicko subagent, CE dispatched its Comment Reviewer persona. An arm that
   fails this is reported as not-run, not as a score.
6. Every arm's task text is identical and carries the same pre-approval sentence (the candidate says
   unattended encodings need caller pre-approval): "You have my approval to change code and tests where
   that replaces a comment; I won't be around to answer questions."
7. Model: sonnet for every arm (the alias these fixtures have used); 3 runs per arm. An Opus replication
   of bare/candidate/incumbent is reported if run, and is not a pass condition.

## Amendment B (2026-11-24, after the 3 bare calibration runs, before any other arm was built or run)

Two grader defects found while reading bare run 95bd35f8, fixed arm-neutrally; every arm, bare included,
is graded with the fixed grader, and base/ideal/nuke are re-graded as the sanity check:
1. Token matching ran on comment lines joined with newlines and kept their `#` markers, so a kept comment
   that an arm reflowed (95bd35f8 merged the W1 workaround note into the Dr6 note, wrapping "trailing
   newline" across two lines) scored as gone. Matching now runs on the raw text plus a copy with markers
   stripped and whitespace collapsed (comments, docstrings, .md). This can only add matches.
2. The separating score gave 2 whenever the hidden probe passed, even with failing checks. Amendment A
   says 2 needs lint/type clean and "0 = broken (checks fail)"; the grader now scores every separating
   item 0 when ruff, mypy or unittest fails.
No rule, threshold or item changed. Calibration outcome under the fixed grader is reported as re-graded.

## Amendment C (2026-11-24, after all 21 arm runs were graded, before the a8 arm was built or run)

Observed: the candidate's only gain was root-fixing (15 of 18 P/W items at 2, bare 6 of 18), bundled with
deleting 41 of 42 decision facts. The extracted wording is tested alone as arm a8-extract: the text below as
the arm's whole config/CLAUDE.md, no slash prefix, no plugin, the identical task text, sonnet, 3 runs.
This arm is post hoc in origin (its wording was chosen after seeing the candidate's diffs), so a pass makes
it a proposal for the operator, not an adoption.

Wording (one line, final form; the unit that runs is the unit judged):
"When you clean up comments, treat a lint or type suppression (`noqa`, `type: ignore`, `eslint-disable`) or
a comment that explains a workaround as a bug report: fix the root cause in this repo and delete the
suppression or workaround with it; keep comments that give a reason the code cannot show (a rule, an
invariant, an outside constraint, a tuned value); delete narration, history notes and banners."

Pass rule, all three: (1) median separating score > bare's max (8); (2) lost_total = 0 in every run;
(3) checks pass in every run. Reported beside it: per-item 2-counts out of 18, clutter recall, cost, and
the normalized gain. Not measured: misrouting on non-comment tasks (the line is scoped to "when you clean
up comments"), and routing (whether sessions run a comment pass at all).
