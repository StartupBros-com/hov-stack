#!/usr/bin/env bash
# backup-harness.sh: keep the live Claude memory offsite-safe (recovery for a WSL disk loss).
#
# WHY: `sync.sh memory-push` mirrors ~/.claude/projects/*/memory into this repo but does NOT commit or push,
# so the git-backed copy silently drifts stale between manual pushes (a disk loss then loses the
# delta: the exact "memory is not recoverable" gap). This refreshes the mirror, commits ONLY the
# memory tree, and pushes it. Idempotent + fail-loud; meant to run on a daily timer
# (systemd/backup-harness.{service,timer}).
#
# SCOPE: memory only. settings.json, hooks, and managed settings stay on the manually reviewed
# flow. Each run uses a temporary detached worktree and advances a dedicated remote backup branch.
# It never commits to main, carries unrelated commits, or needs a PR merged before the next backup.
#
# PRIVACY: memory is private, and the backup branch is readable by anyone who can read origin.
# A run from a public checkout (hov-stack itself, or a fork of it) would publish every note, so
# nothing is pushed until origin is confirmed private (see the guard below). To back up from a
# public checkout, point DOTFILES at a checkout of a private repository (for the timer, a drop-in
# on backup-harness.service with Environment=DOTFILES=...), and CLAUDE_MEMORY_BACKUP_REPO at the
# same checkout so memory-audit.py reads the branch this pushes.
set -euo pipefail

# The checkout this script lives in; DOTFILES overrides it.
REPO="${DOTFILES:-$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)}"
BRANCH="${BACKUP_BRANCH:-backup/claude-memory}"
TMP_ROOT="${BACKUP_TMP_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-harness-backup}"
log() { echo "backup-harness: $*"; }
cd "$REPO" || { log "no dotfiles repo at $REPO" >&2; exit 1; }
[ -f sync.sh ] || { log "sync.sh missing" >&2; exit 1; }

# Refuse before anything is fetched, locked or copied unless origin is confirmed private.
#   - github.com: an unauthenticated repository lookup answers 200 only for a public
#     repository and 404 for a private (or missing) one. 404 passes; 200 refuses, and so does
#     every other answer, a network failure or a rate limit included.
#   - any other host cannot be checked, so it refuses unless HARNESS_BACKUP_REMOTE_PRIVATE=1
#     says you have confirmed it yourself.
# The URL checked is the one git pushes to (pushInsteadOf applied). It is never logged, since
# an https remote can carry a token; the GitHub owner/name is.
push_url=$(git remote get-url --push origin 2>/dev/null) || { log "no origin remote in $REPO" >&2; exit 1; }
github_slug=""
if [[ $push_url =~ ^(git@github\.com:|ssh://git@github\.com/|https://([^/@]+@)?github\.com/)([^/]+/[^/]+)/?$ ]]; then
  github_slug=${BASH_REMATCH[3]%.git}
fi
if [ "${HARNESS_BACKUP_REMOTE_PRIVATE:-0}" = 1 ]; then
  log "origin's privacy is vouched for by HARNESS_BACKUP_REMOTE_PRIVATE=1, not checked"
elif [[ $github_slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://api.github.com/repos/$github_slug") || true
  [ -n "$code" ] || code=000
  case $code in
    404) log "origin ($github_slug) is not publicly readable on GitHub; backing up there" ;;
    200)
      log "REFUSED: origin ($github_slug) is a public GitHub repository, so pushing memory there would publish it. Point DOTFILES at a checkout of a private repository." >&2
      exit 1 ;;
    *)
      log "REFUSED: could not confirm origin ($github_slug) is private (GitHub lookup answered HTTP $code); memory is not pushed" >&2
      exit 1 ;;
  esac
else
  log "REFUSED: origin is not a github.com owner/name, so its privacy cannot be checked; memory is not pushed. Set HARNESS_BACKUP_REMOTE_PRIVATE=1 once you have confirmed it is private." >&2
  exit 1
fi

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
# -f because .gitignore ignores /memory/ in every checkout (#346): without it new notes
# are refused as ignored, git exits 1 and nothing is staged.
git -C "$WORKTREE" add -A -f -- memory
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
