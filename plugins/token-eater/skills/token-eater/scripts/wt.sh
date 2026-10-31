#!/usr/bin/env bash
# wt.sh — token-eater worktree lifecycle: isolation, concurrency, and cleanup.
#
# Vendors the best practices from the compound-engineering `ce-worktree`
# (worktree-manager.sh) and `wt-sweep.sh` so token-eater is self-contained for
# users who do not have those skills installed.
#
# Isolation: each chore runs in its own worktree on a branch cut from a COMMITTED
# ref, so the user's main checkout (and any uncommitted WIP) is never touched and
# they can keep working. Concurrency: worktree/branch names are keyed by run-id, and
# the brief git ref operations are serialized with a per-repo flock, so parallel
# token-eater sessions cannot corrupt each other.
#
# Subcommands:
#   create  <repo> <run-id> <chore-slug> [base-ref]   -> prints the new worktree path
#   cleanup <repo> <worktree> keep|drop                -> remove worktree; keep or drop the branch
#   sweep   <repo>                                      -> remove orphaned te worktrees (DRY_RUN=1 default)
set -euo pipefail

WORKTREE_SUBDIR=".claude/worktrees"          # the user's on-disk convention
ACTIVE_MIN="${ACTIVE_MIN:-120}"              # skip worktrees touched within this many minutes (live)

die() { echo "wt.sh: $*" >&2; exit 2; }
repo_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "not a git repo: $1"; }

# Run git ref-mutating ops under a short-held per-repo lock (avoids index.lock races
# between parallel token-eater sessions). flock is optional — degrade if absent.
with_lock() {
  local repo="$1"; shift
  local lock; lock="$(git -C "$repo" rev-parse --git-common-dir)/token-eater.lock"
  case "$lock" in /*) : ;; *) lock="$repo/$lock" ;; esac
  if command -v flock >/dev/null 2>&1; then
    ( flock -x -w 30 9 || die "timed out acquiring repo lock"; "$@" ) 9>"$lock"
  else
    "$@"
  fi
}

cmd_create() {
  local repo run_id slug base
  repo="$(repo_root "${1:?repo}")"; run_id="${2:?run-id}"; slug="${3:?chore-slug}"; base="${4:-HEAD}"
  local branch="token-eater/${run_id}-${slug}"
  local wt="$repo/$WORKTREE_SUBDIR/te-${run_id}-${slug}"

  # keep the worktree dir AND the run-artifact dir out of the index (idempotent), so a
  # user's `git add .` can never stage worktrees or run artifacts (prompt/schema/result/
  # gate logs under .token-eater/runs/) into a chore PR. Written to .git/info/exclude, NOT
  # .gitignore: appending to .gitignore dirtied the user's working tree — a direct
  # violation of "your checkout and uncommitted work are never touched". info/exclude lives
  # in the shared git dir, so it covers the main checkout AND every worktree, invisibly.
  local excl
  excl="$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null || true)"
  case "$excl" in ''|/*) : ;; *) excl="$repo/$excl" ;; esac
  if [ -n "$excl" ]; then
    mkdir -p "$(dirname "$excl")" 2>/dev/null || true
    for ig in "$WORKTREE_SUBDIR/" ".token-eater/"; do
      if ! { [ -f "$excl" ] && grep -qxF "$ig" "$excl"; }; then
        printf '%s\n' "$ig" >> "$excl" 2>/dev/null || true
      fi
    done
  fi

  # branch from a COMMITTED ref (never the dirty working tree) so main is untouched
  with_lock "$repo" git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" \
    || die "worktree add failed (branch $branch may already exist)"

  # --- set the worktree up to actually run the gate (ce-worktree + the deps fix) ---
  # 1. env files: INTENTIONALLY NOT copied. The autonomous service (and the repo's own gate/install
  #    scripts) run in this worktree; copying real .env/.env.* secrets here would expose DB creds / API
  #    keys to a third-party coding service and risk them landing in commits/PRs/telemetry. A gate that
  #    genuinely needs env is a future opt-in (cf. --install-deps), not a silent default.
  # 2. dependencies (symlink, so the gate's tsc/vitest/pytest resolve) + exclude from change detection
  local exclude; exclude="$(git -C "$wt" rev-parse --git-path info/exclude)"
  for dep in node_modules .venv venv; do
    if [ -e "$repo/$dep" ] && [ ! -e "$wt/$dep" ]; then
      ln -s "$repo/$dep" "$wt/$dep" 2>/dev/null && printf '%s\n' "$dep" >> "$exclude"
    fi
  done

  echo "$wt"
}

cmd_cleanup() {
  local repo wt mode
  repo="$(repo_root "${1:?repo}")"; wt="${2:?worktree}"; mode="${3:?keep|drop}"
  local branch; branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "")"
  with_lock "$repo" git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  if [ "$mode" = drop ] && [ -n "$branch" ] && [ "$branch" != "$(default_branch "$repo")" ]; then
    # never force-delete a branch holding real unpushed work (wt-sweep rule)
    local unpushed; unpushed="$(git -C "$repo" rev-list --count "$branch" --not --remotes 2>/dev/null || echo 0)"
    if [ "${unpushed:-0}" -lt 2 ]; then
      with_lock "$repo" git -C "$repo" branch -D "$branch" 2>/dev/null || true
    else
      echo "wt.sh: kept branch $branch ($unpushed unpushed commits — not force-deleting)" >&2
    fi
  fi
}

default_branch() {
  local b
  b="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  # `git symbolic-ref` can exit 0 with EMPTY output when origin/HEAD is unset (common on
  # repos set up via `git remote add` rather than `git clone`), so a trailing `|| echo main`
  # never fires. Probe the actual remote refs locally (no network) before defaulting.
  [ -z "$b" ] && git -C "$1" show-ref --verify -q refs/remotes/origin/main   && b=main
  [ -z "$b" ] && git -C "$1" show-ref --verify -q refs/remotes/origin/master && b=master
  echo "${b:-main}"
}

cmd_sweep() {
  local repo; repo="$(repo_root "${1:?repo}")"
  local dry="${DRY_RUN:-1}"; local now; now="$(date +%s)"
  git -C "$repo" worktree prune 2>/dev/null || true
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r wt; do
    case "$wt" in *"/$WORKTREE_SUBDIR/te-"*) : ;; *) continue ;; esac   # only token-eater worktrees
    [ -d "$wt" ] || continue
    # skip live worktrees (a running session owns them)
    case "$wt" in */.claude/jobs/*|/tmp/*) echo "skip(job): $wt"; continue ;; esac
    local mt; mt="$(stat -c %Y "$wt" 2>/dev/null || stat -f %m "$wt" 2>/dev/null || echo 0)"   # GNU stat || BSD/macOS stat
    if (( (now - mt) / 60 < ACTIVE_MIN )); then echo "skip(active): $wt"; continue; fi
    if command -v lsof >/dev/null 2>&1 && lsof +D "$wt" >/dev/null 2>&1; then echo "skip(in-use): $wt"; continue; fi
    local branch unpushed
    branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "")"
    unpushed="$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
    if [ "$dry" = 1 ]; then
      echo "would remove orphan worktree: $wt (branch $branch, $unpushed unpushed — branch kept)"
    else
      with_lock "$repo" git -C "$repo" worktree remove --force "$wt" 2>/dev/null \
        && echo "removed: $wt (branch $branch preserved)"
    fi
  done
  [ "$dry" = 1 ] && echo "(DRY_RUN — re-run with DRY_RUN=0 to apply)"
}

case "${1:-}" in
  create)  shift; cmd_create  "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  sweep)   shift; cmd_sweep   "$@" ;;
  *) die "usage: wt.sh create|cleanup|sweep ..." ;;
esac
