---
title: "Do not feed search-result text back into the searched corpus"
date: 2026-08-30
category: logic-errors
module: dispatcher-claim-dedup
problem_type: logic_error
component: development_workflow
symptoms:
  - "An advisory duplicate warning becomes a permanent high-risk refusal on a later dispatch"
  - "A generated tracking artifact starts matching the discovery query that produced it"
  - "Weak keyword matches hide the checkout-local branch that actually triggered possible risk"
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - "github-search"
  - "tracking-pr-evidence"
  - "claim-admission"
tags:
  - search-feedback
  - duplicate-detection
  - dispatcher
  - pr-body
  - evidence-provenance
  - planted-negative
---

# Do not feed search-result text back into the searched corpus

> **Retired machinery (2026-10-18).** The dispatcher and the dedup pre-flight this fix lived in were removed (#1873 and #1902, teardown 2026-10-17/18). `scripts/gh-dedup-check.sh` and `scripts/dispatcher-tick.sh`, cited below, no longer exist, and `wt-new.sh` no longer renders duplicate evidence. The lesson still holds for any producer whose output can land in the corpus it searches.

## Problem

An automation can corrupt its own future observations when it writes search-result text into a surface indexed by the same search. The dispatcher hit this while making possible-duplicate evidence visible: copying matched PR and issue titles into a tracking PR body would make that generated PR match later title-derived queries, so an old loop PR could rediscover itself and escalate a later claim from advisory `possible` risk to blocking `high` risk.

The failure was not hypothetical. A read-only probe searched GitHub pull requests for `recover_pro_marker`, a token present in PR #732's body but not its title, and GitHub returned PR #732. That established PR body text as part of the search corpus rather than assuming title-only behavior.

## Symptoms

- `gh-dedup-check.sh` derives significant terms from the issue title and searches all pull requests using those terms (`scripts/gh-dedup-check.sh:43-47`, `scripts/gh-dedup-check.sh:58-62`).
- Dispatcher branches include the issue number (`scripts/dispatcher-tick.sh:530-540`). If a prior loop PR reappears in the term search, its branch name satisfies the exact-issue high-risk rule (`scripts/gh-dedup-check.sh:103-109`).
- A later claim can therefore stop at `duplicate risk HIGH` using evidence created by the prior run itself, not independent duplicate work.
- Producer-order truncation can make the visible evidence look like generic keyword noise while the exact local-branch signal is omitted.

## What Didn't Work

### Leaving the warning in stderr

`possible` risk originally emitted only a warning. The dispatcher redirected it into a tick log, so the evidence existed but not on the tracking PR a reviewer opened. That was observability without a consumer.

### Copying matched titles into the PR body

The first visibility design rendered `title // ref` for each match. This fixed the log-only problem but created a search feedback loop: matched titles carry the same vocabulary as the source issue by construction, and GitHub indexes the generated body.

Markdown indentation and shell quoting were not enough. They made text inert for rendering and execution, but they did not remove it from GitHub's search index.

### Treating all evidence as equivalent

A GitHub PR or issue is hosted evidence. A local branch returned under `--checkout` is explicitly `checkout-only` evidence (`gh-dedup-check.sh`, retired in #1902). One blanket instruction to close work as duplicate overstated local evidence and could misclassify the loop's own earlier branch as another implementation.

### Capping without preserving the decisive signal

The producer appends local branches after hosted search results. Taking the first ten matches can hide the branch that independently caused `possible` risk. An omitted count alone is honest about volume but not sufficient for action.

## Solution

PR #737 moved duplicate visibility to the tracking PR body without copying searchable titles:

- GitHub matches render as stable `#number + URL` identifiers.
- Local branches render as their ref plus `(checkout-only)` scope.
- Hosted matches get confirm-before-close guidance; local branches get separate caution that they may be an earlier run of the same loop.
- At most ten matches render in producer order. The omission summary preserves omitted kinds and names omitted local refs.
- The full-detail command remains visible.
- `none`, `possible`, and `high` retain their original control semantics, and the dispatcher-facing `wt-new.sh --json` object remains unchanged.

Rendering was owned at `wt-new.sh`'s PR-body boundary, the one place that had both the structured result and the PR body, so the dedup producer and dispatcher gained no parallel formatting or state. #1900 retired `pr-open-if-missing.sh` and #1902 retired the dedup pre-flight itself; `wt-new.sh` now prints a `gh pr create` command and renders nothing. The lesson stands for any producer whose output can land in the corpus it searches.

The focused suite pinned the dangerous axes until #1902 removed it with the producer:

- title text is absent from the body;
- GitHub number and URL survive;
- local ref and scope survive;
- match text cannot trigger the closing-keyword advisory;
- exactly ten has no omission summary;
- more than ten discloses omitted local refs;
- clean risk adds no section;
- high risk still produces zero claim, worktree, push, or PR effects;
- `--json` keeps its existing keys.

## Why This Works

Stable identifiers preserve provenance without reproducing the query-bearing vocabulary that caused the match. The generated artifact remains useful to a human but is much less likely to become evidence for the discovery algorithm that produced it.

Separating hosted and checkout-local evidence preserves authority. A reviewer can act on a linked GitHub object after confirming it is the same task, while a local branch is presented as a machine-scoped lead to inspect rather than a reason to close work.

The prevention tests exercise feedback and authority, not only formatting. The planted title contains search-like, closing-keyword, Markdown, shell-looking, and control-whitespace text; the body must still contain only the stable identifier. A separate URL-shaped negative proves the trusted PR header, not appended evidence, is the input to closing-keyword detection.

## Prevention

- Model discovery systems as a graph: identify every output surface and ask whether the next discovery query indexes it.
- Do not put query-bearing free text from search results into a corpus searched by the same terms. Prefer stable identifiers, canonical URLs, or a surface excluded from discovery.
- Preserve evidence authority in the rendered form. Hosted, checkout-local, inferred, and incomplete evidence must not share one action instruction.
- When output is capped, retain the evidence that triggered the verdict. If ordering is fixed, disclose omitted high-signal identifiers rather than only a count.
- Add a feedback planted negative: generated output from run one must not change run two's classification unless new independent evidence exists.
- Probe external search semantics with a read-only discriminating token before encoding assumptions about which fields are indexed.
- Test the call order and consumer boundary. A formatter can be safe while a later body scanner reinterprets its output.

## Related Issues

- PR #737 — shipped the final identifier-only evidence projection and its regression suite.
- Issue #710 — tracked the original log-only possible-duplicate warning.
- `docs/plans/2026-08-30-1740-fix-dispatcher-followup-intent-plan.md` — implementation plan; its title-rendering detail was superseded by the live GitHub search probe while preserving provenance intent.
- `docs/plans/2026-08-28-1624-feat-autonomous-issue-quality-plan.md` — live dispatcher strategy source; related to evidence and recovery, but not the owner of this search-feedback fix.
