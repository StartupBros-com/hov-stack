#!/usr/bin/env bash
# backup-harness.sh: keep the live Claude memory offsite-safe (recovery for a WSL disk loss).
#
# WHY: `sync.sh push` mirrors ~/.claude/projects/*/memory into this repo but does NOT commit or push,
# so the git-backed copy silently drifts stale between manual pushes (a disk loss then loses the
# delta: the exact "memory is not recoverable" gap). This refreshes the mirror, commits ONLY the
# memory tree, and pushes it. Idempotent + fail-loud; meant to run on a daily timer
# (systemd/backup-harness.{service,timer}).
#
# SCOPE: memory only. settings.json, hooks, and managed settings stay on the manually reviewed
# flow. Each run uses a temporary detached worktree and advances a dedicated remote backup branch.
# It never commits to main, carries unrelated commits, or needs a PR merged before the next backup.
set -euo pipefail

# The checkout this script lives in; DOTFILES overrides it.
REPO="${DOTFILES:-$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)}"
BRANCH="${BACKUP_BRANCH:-backup/claude-memory}"
TMP_ROOT="${BACKUP_TMP_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-harness-backup}"
log() { echo "backup-harness: $*"; }
cd "$REPO" || { log "no dotfiles repo at $REPO" >&2; exit 1; }
[ -f sync.sh ] || { log "sync.sh missing" >&2; exit 1; }

mkdir -p "$TMP_ROOT"
exec 9>"$TMP_ROOT/backup.lock"
flock -n 9 || { log "another backup is already running" >&2; exit 1; }
WORKTREE=$(mktemp -d "$TMP_ROOT/run.XXXXXX") || exit 1
rmdir "$WORKTREE"
cleanup() {
  rc=$?
  git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rmdir "$WORKTREE" 2>/dev/null || true
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -f "${PUSH_LOG:-}" 2>/dev/null || true
  trap - EXIT INT TERM
  exit "$rc"
}
trap cleanup EXIT INT TERM

git fetch -q origin "+refs/heads/main:refs/remotes/origin/main"
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
fi
git worktree add --detach "$WORKTREE" origin/main >/dev/null

# memory-push copies only live memory into the temporary worktree's mirror. Volatile settings never
# enter the backup commit.
#
# Its stdout is the copy plan -- hundreds of COPY lines on a normal run, too noisy for the journal,
# and the reason six consecutive nightly failures logged a refusal with no indication of what was
# refused. Capture it, stay quiet while the push succeeds, and replay it when it does not. stderr is
# left unredirected so a refusal or a quarantine warning reaches the journal as it happens.
PUSH_LOG=$(mktemp "$TMP_ROOT/memory-push.XXXXXX.log") || exit 1
push_rc=0
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}" bash "$WORKTREE/sync.sh" memory-push \
  >"$PUSH_LOG" || push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  log "memory-push failed (exit $push_rc); last 40 lines of its copy plan follow" >&2
  tail -n 40 "$PUSH_LOG" | sed 's/^/backup-harness:   /' >&2
  rm -f "$PUSH_LOG"
  exit "$push_rc"
fi
tail -n 1 "$PUSH_LOG" | sed 's/^/backup-harness: /'
rm -f "$PUSH_LOG"
git -C "$WORKTREE" add -A -- memory
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" && \
   git -C "$WORKTREE" diff --cached --quiet "origin/$BRANCH" -- memory && \
   git diff --quiet "origin/$BRANCH" origin/main -- . ':!memory'; then
  log "memory and harness already current on $BRANCH"
  exit 0
fi

n=$(git -C "$WORKTREE" diff --cached --name-only origin/main -- memory | wc -l | tr -d ' ')
tree=$(git -C "$WORKTREE" write-tree)
parents=(-p origin/main)
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  parents=(-p "origin/$BRANCH" -p origin/main)
fi
commit=$(printf 'chore(backup): Claude harness snapshot (%s live memory path(s))\n' "$n" | \
  git -C "$WORKTREE" -c user.name='harness-backup' -c user.email='harness-backup@localhost' \
  commit-tree "$tree" "${parents[@]}")
if git -C "$WORKTREE" push -q origin "$commit:refs/heads/$BRANCH"; then
  log "pushed current harness plus ${n} live memory path(s); offsite-safe on $BRANCH"
else
  log "PUSH FAILED: snapshot exists locally but is not offsite-safe" >&2
  exit 1
fi
