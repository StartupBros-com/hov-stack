# Review pipeline (optional)

By default, token-eater opens a draft PR and leaves the review to you — run `/ce-code-review`, look it over yourself, or use whatever review flow you prefer. **Nothing in this pipeline replaces your final review, and token-eater never merges.**

This playbook runs only when `review_before_pr: true` is set in config.

## What one optional pass does

After a chore's deterministic gate passes and before the draft PR is opened:

1. Run one review pass on the diff using an available review skill (e.g. `ce-code-review --comment`, `multi-model-triangulation`, or similar). The chosen skill should receive the diff, the files modified, the gate command and its output, and the chore's success criterion.
2. Surface any actionable findings in plain language. Require concrete file/line references; ignore vague style notes.
3. If findings are clearly mechanical and gate-verifiable (e.g. a formatting residue, an unused import the lint gate will catch), apply the fix and re-run the gate. If the gate passes, continue to PR creation. If it fails, roll back and record the failure.
4. Any finding that requires product judgment, touches files outside the chore scope, or cannot be gate-verified is deferred to the human — note it in the PR body and stop.
5. Open the draft PR through `references/result-handling.md` as normal.

## Invariants

- Never auto-merge or auto-mark-ready.
- Never treat this pass as the authoritative safety check — the deterministic gate from `references/delegation-invocation.md` is always authoritative.
- Every PR must be independently reviewable as its own slice; do not combine unrelated chores.
- After posting the PR and any review notes, stop. The human decides whether to merge.

## Member-facing summary

```markdown
Review pipeline (optional pass):

- The project check passed.
- One review pass ran before the draft PR was opened.
- Findings: <plain summary, or "none — diff looked clean">.
- Deferred to human review: <finding, or "none">.
- Draft PR: <url>
- token-eater did not merge or mark this PR ready.
```
