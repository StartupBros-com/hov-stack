---
description: Post-review skeptical adjudication for Compound Engineering review todos
---
You are running the Compound Engineering skeptical review pass **after** brainstorm → plan → work → review.

This is **not** a generic fresh code review and it is **not** an implementation pass.

Your job is to take the pending review findings from `/workflows-review` and adjudicate them using the implementation context already established in this session.

## Primary goal
Decide which review findings actually deserve action versus which ones would cause over-fixing, over-engineering, scope drift, or duplicate work.

## Operating mode
- Treat pending todo markdown files from `todos/` as **candidate findings**, not ground truth.
- Use the implementation intent from this session as a first-class input.
- Re-read the implementation plan before making decisions when a plan path is provided or obvious.
- Only read the brainstorm when the plan is missing critical product intent, rejected alternatives, or explicit non-goals.
- Prefer tightening or rewriting an existing todo over creating a brand-new one.
- Do **not** start a brand-new broad code review.
- Do **not** implement code fixes in this pass unless the user explicitly asks for that separately.

## Required workflow
1. Read the pending review todo files first, preferably through the `ce_todo` tool.
2. Reconstruct intended scope from the plan and, only if needed, the brainstorm.
3. For each pending todo, decide one of the following:
   - **ready** — valid finding worth fixing now
   - **pending** — maybe valid, but not ready / needs more context / better scoped later
   - **wont_fix** — not actually needed, out of scope, duplicate, or over-engineering
   - **rewrite** — the finding is directionally right but framed incorrectly; rewrite the todo and then leave it `ready` or `pending`
4. Use the `ce_todo` tool to update todo state deterministically:
   - `set_status` when status changes
   - `update` to tighten title, findings, or recommended action
   - `append_work_log` to explain the adjudication decision
5. If multiple todos describe the same issue, consolidate them.

## Decision standard
Approve only findings that materially improve correctness, simplicity, user intent fidelity, or production safety.

Reject findings that are mainly:
- speculative architecture polishing
- scope expansion not required by the plan
- abstraction for hypothetical future needs
- duplicate of an already-tracked issue
- technically true but not worth doing now

## Final output
Return a concise adjudication summary:
- **Ready now**
- **Left pending**
- **Marked wont_fix**
- **Rewritten / consolidated**

If there are no pending review todos, say that clearly and stop.

$@