# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Local changes:
- disable-model-invocation set to true (on-demand posture) where upstream did not
  already set it.
- The frontmatter description drops "Read-only; it proposes motion with exact values,
  it does not implement it." (Rule 1 still says so.)
- Rule 1's handoff names `ce-plan` for a tracked change and `animate` for a small one,
  instead of upstream's `improve-animations plan`; the closing paragraph's handoff
  says the same.
- Rule 2 drops "No exceptions for "it would look cool."".
- The Speed gate's UI budget is 500ms (upstream 300ms), and the hold-to-confirm
  recipe is marked exempt from that budget.
- A closing paragraph is added: prefer one root-cause row against a shared component
  over one row per call site, and state the blast radius.

One of the three DETECTORS in this batch. The harness had four skills covering motion
(emil-design-eng, interactive-visualization-creator, ui-polish, pick-ui-library) and
none of them detect anything — they are all reference/authoring material. This one
finds motion that is missing, which the other two detectors do not: a sweep of
a private React app found conditional renders without transitions, shared buttons
without press feedback, and marketing lists whose items entered all at once.
A shared-component fix can therefore improve many call sites at once.

Its mandatory "rejected candidates" section is the reason it is safe to run: the sweep
above also correctly REJECTED the cmdk palette, admin tables, sonner toasts and the
Radix overlay primitives as already-correct or correctly restrained.
