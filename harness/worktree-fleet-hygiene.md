---
name: worktree-fleet-hygiene
description: "How Will's git-worktree fleet is kept clean — the wt-sweep script, smart-selective policy, and the cleanupPeriodDays gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: 43f473c7-a88f-448c-a1d4-13723c50324d
---

Will runs ~6 concurrent Claude Code sessions that constantly spawn git worktrees across ~/SITES repos, so worktrees accumulate fast (was 132 across 38 repos before the 2026-06-21 cleanup).

**Reusable sweep:** `~/.claude/scripts/wt-sweep.sh` (DRY_RUN=1 default; PUSH=0 default keeps branches local). Policy: clean+pushed → remove; has work & not abandoned → WIP-commit (git add -u, no junk) + keep branch local + remove worktree; abandoned (>14d old & >150 behind & <2 unpushed) → bundle to `<repo>/.git-archive/<date>/` then drop; no-remote repo → bundle + leave in place. SKIPS worktrees under `/tmp`, `.claude/jobs/`, or modified <120min (live jobs).

**Key facts learned:**
- Removing a worktree never deletes commits — the branch persists in the repo's ref store. So "preserve" = keep branch local; pushing is optional remote backup.
- Do NOT lower `cleanupPeriodDays` to force worktree auto-sweep — it ALSO controls chat-transcript retention, which `ce-sessions` depends on.
- `worktree.baseRef` is already the correct default `fresh`; the staleness cause was drift + reuse, not baseRef.
- Several ~/SITES dirs were sibling worktrees of one repo (a private repository had 6 sibling dirs; pi-mono's real git dir is at `~/.cache/checkouts/github.com/earendil-works/pi-mono`). Cleanup consolidated these.
- Bundle only when dropping — bundling preserved branches wasted 2.3GB of redundant archives.

Related: [[codex-delegation-setup]], [[claude-code-opus48-overload]].
