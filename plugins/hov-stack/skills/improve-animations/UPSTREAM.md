# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Local change: disable-model-invocation set to true (on-demand posture) where
upstream did not already set it.

This is the most heavily patched skill of the six. Upstream ships a full
audit-AND-plan-AND-execute workflow that would have collided with three separate
conventions here, so it was cut down to a finder. Local changes:

1. **Phase 4 replaced by a handoff.** Upstream wrote its own plan files to a top-level
   `plans/` dir with `NNN-slug.md` naming. The real convention is `<docs-root>/plans/`
   (default `docs/plans/`) with `YYYY-MM-DD-NNN-slug` naming, resolved by the shared
   docs-root block that ce-plan/ce-work/ce-code-review all read; a private app already stores
   its plans there and has no top-level `plans/`. Left as shipped it would have created a second,
   ungoverned plans dir invisible to ce-work's discovery and unprotected by
   ce-code-review's Protected Artifacts rule. Selected findings now hand off to
   `ce-plan`, which owns all of that.

2. **`plan`, `execute` and `reconcile` variants removed.** The execution path dispatched executors into
   worktrees with no issue, no claim label and no draft PR — the exact "branch with
   neither is invisible work" pattern the lifecycle rule forbids. `wt-new.sh` +
   `ce-work` own that path.

3. **Phase-2 subagents pinned to sonnet.** Upstream never pins, so a `deep` run would
   fan out up to 8 mechanical grep-and-read agents on the session model. Also added an
   instruction to count vendored component libraries (`packages/ui/src/shadcn`)
   separately from hand-written app code, since a defect in pasted-in code is a
   different decision and may be reverted on the next paste.

4. **PLAN-TEMPLATE.md demoted to a checklist.** Kept because it names what a good
   animation plan must carry — exact file:line, exact values from AUDIT.md, the repo's
   own tokens, and a feel-check step. It is now explicitly a handoff checklist, not an
   output format, and its "write plans/README.md" instruction is removed.

AUDIT.md duplicates emil-design-eng's rule catalogue almost verbatim. That is fine —
both are invoke-only and never load together. The net-new value is detection: eight
named audit categories and their grep patterns. A sweep of a private React app
found overly broad transitions, sparse reduced-motion handling, hover transforms
without hover-capability checks, and trigger-anchored overlays without the
appropriate transform origin. Those categories teach what to inspect without
publishing the application's code inventory.

Additional SKILL.md changes: description, introduction, operating posture, hard rules, invocation table, and selection/stop wording now describe findings-only output and the planning/execution/review handoff; direct fixes also point to `find-animation-opportunities` for missing motion.
