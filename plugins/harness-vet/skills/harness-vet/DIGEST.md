# The harness digest

Freeze one shared artifact context plus a small delta for each target. Give
every reader/verifier the shared block and the target rows relevant to its
job. Discover once, reuse across readers; do not repeat a safety audit for
every project or mistake a single-project inventory for the whole fleet.

## Discovery sweep

Start in phase 1 for intake, then complete and freeze in phase 2. Inventory
only relevant locations, with bounded searches that include hidden skill
folders but exclude dependencies and worktree copies unless explicitly targeted.

- **Targets and tasks**: verified project paths, global scope if requested or
  justified, or unresolved scope. Record the intended job and runtime surfaces;
  local availability does not imply hosted availability.
- **Instructions and skills**: effective global/managed instructions plus each
  project's instructions, skills, nested locations and plugin registrations.
  Record source paths, revisions, activation/visibility state and precedence.
  Check whether a skill directory also contains a plugin manifest. Discover
  controls from live docs/runtime; do not impose one harness's tier names.
- **Available capability**: what can actually perform this target's task,
  including callable global on-demand skills, CLIs and subagents. Separate
  activation/name conflicts from semantic overlap. Record covering mechanism,
  invocation path, access and constraints. An off, inaccessible or unrelated
  project's skill is not coverage merely because its files exist, and neither
  is the candidate's own copy at another scope. Record beside the incumbent
  the contenders phase-1 discovery slated or triaged for this task, each at a
  resolved revision (dropped ones stay in the Contenders row with their
  reason), so readers and verifiers compare against the best of what exists
  and not only against what is installed. Credential access counts the
  same way: resolve it through the harness's documented per-task path (secrets
  runbook, credential registry), not ambient env vars or a tool's own login,
  which a harness may keep empty on purpose [measured: an empty env read as
  "agents hold no Cloudflare credential" while four live tokens sat in the
  secrets manager].
- **Tooling and boundaries**: effective MCP/services, tool grants, hooks,
  permissions and sandboxing. Distinguish a requested permission from an
  observed effect. Scope/discovery restrictions are not execution containment.
- **Prior notes**: shared indexes and target-project notes, source aliases,
  search locations, freshness and gaps. Do not assume a canonical global
  memory exists; use project notes with cross-links if none is available.
- **Landing and upkeep**: target repo conventions, review tools, memory/report
  location, source pin, update owner, rollback, and install destination. Note
  which validation instruments actually include project and nested directories.

## Template

```
Context (established facts, do not re-derive):
- Candidate: <source identity, revision/content digest, component inventory>
- Shared environment: <agent/platform versions, global capabilities, guards>
- Prior artifact evidence: <security/maintenance findings; provenance>
- Prior notes searched: <shared + project locations, aliases, gaps/freshness>
- Target rows, one per requested/inferred target:
  - Target/task/runtime: <path or global or unresolved; chosen/inferred>
  - Effective context: <global + local + nested/plugin sources and sizes>
  - Available incumbent: <mechanism, invocation/access, target-task coverage>
  - Contenders: <upstream, revision, lane/pass that found it, substitute or
    complement, slated | triaged | dropped(reason)> — content facts only; no
    stars, likes, follower counts, recency or author reputation in this row
  - Placement/activation options: <verified controls, precedence, observed vs configured>
  - Delivery: <destination, review/testing tools, landing depth, update/rollback owner>
- Local vet history: <counts if known; otherwise imported prior, not local data>
- Standing rule: SKIP-as-covered requires equivalent capability demonstrably
  available for THIS target's task, including callable global on-demand tools;
  a copy of the candidate at another scope is a placement question first
  (VERDICTS.md), not automatic coverage. Scope can change fit and cost, not
  erase applicable artifact safety findings.

Your task: <reader/verifier brief>. Evidence means file:line, observed output
or a fetched primary source. New platform/model facts get live-doc checks,
never dismissal merely because they postdate training. Unknowns stay unknown.
```

## Freshness

Rebuild target inventories each run. Verify every asserted path/name exists;
record inaccessible paths rather than inventing state. Carry forward only
still-applicable evidence and conventions. A stale search index cannot justify
"never evaluated" [measured: a four-day-old index hid the newest vet].
