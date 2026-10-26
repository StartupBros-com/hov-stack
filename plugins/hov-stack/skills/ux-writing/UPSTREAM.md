# Upstream provenance

Frozen snapshot of https://github.com/scarletkc/agents `skills/ux-writing/SKILL.md`
(commit 9ff8dddb6714eb8e0b2f19c5a311441df244ecf7, 2026-08-27, Apache-2.0 — LICENSE and NOTICE text carried
alongside), vendored 2026-09-01 by `/harness-vet` (memory note
`scarletkc-agents-ux-writing-vet-2026-09`). The body is byte-identical to
upstream except the frontmatter block: a first-line comment naming the upstream
file and pointing here, and `disable-model-invocation: true`, added; upstream
`license`/`metadata` keys kept. Re-diff manually and on purpose; not
auto-tracked (single-author repo, seven weeks old, every content commit so far
was additive).

Modification notice (Apache-2.0 section 4(b)): this `SKILL.md` is a modified
version of the upstream file, changed only in the frontmatter as above; its
first frontmatter line says so. LICENSE and NOTICE are upstream's, unchanged.

## Why invoke-only

Upstream's description is a six-clause trigger ("writing or changing any
user-visible string ... reviewing a diff that touches copy or docs") that would
auto-fire on most coding turns in a tree of ~110 model-invocable skills
(109 lacking `disable-model-invocation: true` on 2026-09-01). The
review value is real but episodic — a docs/copy diff, a README rewrite, a CLI
output change — so it is reached for by name: `/ux-writing`. Zero always-on
context cost. Codex tree: not allowlisted in `codex-skills.txt`; if that
changes, `agents/openai.yaml` already sets `allow_implicit_invocation: false`.

## Evidence that carried the verdict

Planted-defect fixture (`harness/vet-fixtures/scarletkc-agents/`, v2):
21 planted copy/docs/CLI-output defects + 8 honest controls, three arms at
Sonnet, two trials each. Candidate 17/21 both trials, 0 false accusations;
incumbent doctrine (readme-writing + de-slopify + cli-agent-ergonomics +
cli-doctor-mode, ~42KB) 9/21 both trials, 1 false accusation each; bare 5 and
7. Of the 9 defects no incumbent trial caught, the candidate caught 7. Cost
observed: both candidate trials missed two cross-file fact contradictions the
bare arms found — the doctrine narrows attention as well as sharpening it. A
first fixture (v1) was withdrawn before commit for reusing the candidate's own
example text; SCORING.md keeps it labeled as non-evidence. Construct caveat:
the fixture was written from the candidate's rule list, so it shows the
doctrine changes behavior on what it names and that the incumbents do not name
the same things — not the real-world frequency of those defects.

Rule overlap against this harness (reader pass, file:line-verified): 24 bolded
rules — 16 with no incumbent, 6 partial, 2 fully covered (adjectives-need-
evidence ↔ readme-writing "Claims get a number or an example, or they get cut";
one-canonical-home ↔ writing-for-agents "Single source of truth", scoped there
to agent docs only).

## Known tension, left unpatched

"Restating and linking is a bug ... Delete the restatement" (Documentation
section) sits next to this harness's CLAUDE.md Global Rule "Don't remove or
narrow existing config, flags, compat surfaces, or callers as a side effect of
a task that didn't ask for it — flag it instead of deleting it." The two do not
collide on their own terms (prose vs. config/compat surfaces), but an agent
running `/ux-writing` mid-task should treat unrequested doc deletions the way
the Global Rule treats config: flag, then delete only inside the task's scope.
This note lives here rather than in SKILL.md so the body stays byte-identical
to upstream for re-diffs. No documented precedence rule between CLAUDE.md and a
skill body was found; the stakes (an over-eager prose deletion, caught in
review) are low enough to leave to operator judgment rather than patch the body.

## What was NOT vendored from the same repo

codex-cli, scoped-change, worktree-pr, marketing-copy, talk-like-scarletkc,
AGENTS.md, user/AGENTS.md — verdicts and re-eval triggers in the memory note.

Local addition: `agents/openai.yaml` supplies Codex display metadata and a default prompt, with `policy.allow_implicit_invocation: false`.
