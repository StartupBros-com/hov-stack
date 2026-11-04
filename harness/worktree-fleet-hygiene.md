---
name: worktree-fleet-hygiene
description: "How Will's git-worktree fleet is kept clean — the wt-sweep script, smart-selective policy, and the cleanupPeriodDays gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: 43f473c7-a88f-448c-a1d4-13723c50324d
---

Will runs ~6 concurrent Claude Code sessions that constantly spawn git worktrees across ~/SITES repos, so worktrees accumulate fast (was 132 across 38 repos before the 2026-06-21 cleanup).

**Reusable sweep:** `~/.claude/scripts/wt-sweep.sh` (DRY_RUN=1 default; PUSH=0 default keeps branches local). Policy: clean+pushed → remove; has work & not abandoned → WIP-commit (`git add -A`) + keep branch local + remove worktree; abandoned (>14d old & >150 behind & <2 unpushed) → bundle to `~/.claude/git-archive/<repo>/<date>/` then drop; no-remote repo → bundle + leave in place. SKIPS worktrees under `/tmp`, `.claude/jobs/`, modified <120min, held by a live process, or held by a Claude Code session (`scripts/lib/wt_session_hold.py`; a `done` job only prints `resumable:`): a job that is not `done`, a running session whose cwd is inside, a transcript written <120min ago under the worktree's slug, or (hov-stack#394) a transcript filed under any project whose records drive the worktree, if it belongs to a job not `done` or a live session or was written <120min ago. A transcript stays under the project its session launched from, so a session that entered a worktree or works in it with `git -C` or `cd` is seen only that way. Driving means a record's `cwd` (it follows EnterWorktree) or a tool input path (`file_path`, `path`, `notebook_path`, an absolute path in a Bash command); tool results and the text a tool writes do not count, and a relative `cd` is not seen. The paths are indexed per transcript in `~/.cache/hov-stack-wt-session-hold/` (`WT_HOLD_CACHE_DIR`), reading only bytes appended since: the first call read 7.1 GB in about 40 s on 2026-11-03, later ones about 0.5 s. `wt-done.sh` refuses an outside run on a held worktree the same way, never counting its caller's own session (`CLAUDE_CODE_SESSION_ID`); wt-sweep counts its caller, so a sweep never removes the worktree its caller drives. The cost: a running session holds every worktree it has driven, reads included, until it ends. On 2026-11-03 a dry-run sweep held 76 worktrees against 42 before #394; all 34 newly held were driven by 12 working jobs or live sessions, which the old check would have removed from under them.

**Key facts learned:**
- Removing a worktree keeps a branch's commits in the repo's ref store, so "preserve" = keep branch local; pushing is optional remote backup. It does NOT keep three things (hov-stack#384, the 2026-11-03 sweep): a session idling in the worktree; gitignored files, which `git worktree remove` deletes with or without `--force` (git 2.43), `.claude/deliverables/` included; and a detached HEAD's commits, which sit on no ref. So both scripts copy ignored `.claude/deliverables/` files to `<repo>/.claude/deliverables/from-worktrees/<name>/` (verified with `cmp`, never overwriting an earlier copy), and wt-sweep pins a detached HEAD at `refs/heads/recovered/wt-sweep-<date>/<name>`. A copy or pin that fails keeps the worktree. Other ignored files (builds, caches, `node_modules`) still go with it.
- Do NOT lower `cleanupPeriodDays` to force worktree auto-sweep — it ALSO controls chat-transcript retention, which `ce-sessions` depends on.
- `worktree.baseRef` is already the correct default `fresh`; the staleness cause was drift + reuse, not baseRef.
- Several ~/SITES dirs were sibling worktrees of one repo (a private repository had 6 sibling dirs; pi-mono's real git dir is at `~/.cache/checkouts/github.com/earendil-works/pi-mono`). Cleanup consolidated these.
- Bundle only when dropping — bundling preserved branches wasted 2.3GB of redundant archives.

Related: [[codex-delegation-setup]], [[claude-code-opus48-overload]].
