#!/usr/bin/env bash
# wt-unlock.sh — remove a git lock file only with proof that its writer is gone
# (dotfiles#1590). wt-done.sh and wt-new.sh run it before their first
# repository write; it also works by hand on any checkout.
#
# WHY
#   A git probe killed at its final index write-back leaves a 0-byte
#   index.lock (git removes its lock on SIGTERM, not on SIGKILL; measured
#   2026-10-19 on #1590), and every later fetch, reset or commit on that
#   checkout fails with "File exists". dcg refuses `rm` of a lock from a shell
#   by design and does not read inside scripts, so this helper is the
#   sanctioned path, and it removes nothing without the proof below. New locks
#   are prevented upstream (GIT_OPTIONAL_LOCKS=0 and diff.autoRefreshIndex=false
#   on the probes, #1944 and #1954); this clears the ones a killed
#   mandatory-lock command still leaves.
#
# PROOF, all three per lock, else the lock is kept and the reason printed
#   age     mtime older than 60 s. A live git holds a lock for milliseconds
#           and a hook for seconds; a minute is past every measured write.
#   holder  no process has the lock file open: proc_liveness.py's fd signal
#           (its cwd, environ and cmdline signals also count, erring toward
#           held).
#   git     no `git` process on the lock's scope in three probes a second
#           apart; a probe that sees one, or cannot answer, keeps the lock
#           (a keep is never worse than today; a statusline git passing
#           through costs one more run). A lock private to a worktree (its
#           gitdir's index.lock and refs) scopes to that gitdir and checkout.
#           A shared lock (packed-refs.lock and refs/**/*.lock in the common
#           dir) scopes to the common dir plus every registered worktree's
#           checkout, because a git in a linked worktree writes shared refs
#           with nothing in its cwd, argv or environment naming the common
#           dir (review P1 on #1957). The main checkout's own index.lock
#           scopes to the common dir and the main root (the first entry of
#           `git worktree list`) from whichever checkout runs the helper:
#           wt-done runs it from a linked worktree, and a git in the main
#           root names neither that worktree nor the common dir. When the
#           worktree list cannot be read, every lock in the common dir is
#           kept as unknown scope. This probe covers the window where git
#           has closed a ref lock's fd but not yet renamed it.
#   A liveness scan that cannot answer (exit 2) keeps the lock.
#
# SCOPE  index.lock, packed-refs.lock and refs/**/*.lock, in the worktree
#   gitdir and in the common dir. Untouched: HEAD.lock, config.lock,
#   shallow.lock, the `locked` worktree marker, anything under objects/.
#
# USAGE  [DRY_RUN=0] wt-unlock.sh <checkout-path>
#   DRY_RUN=1 (the default, as in wt-done.sh and wt-sweep.sh) prints
#   `would: rm` and removes nothing. Exit 0: no lock kept. Exit 1: at least
#   one lock kept, reason printed. Exit 2: usage, or not a git checkout.
#   WT_UNLOCK_LIB and WT_UNLOCK_PROCFS point the tests at a lib copy and a
#   fake procfs.
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
MIN_AGE=60
LIB="${WT_UNLOCK_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib}"
PROCFS="${WT_UNLOCK_PROCFS:-/proc}"
LIVENESS="$LIB/proc_liveness.py"

[ $# -eq 1 ] || { echo "usage: wt-unlock.sh <checkout-path>" >&2; exit 2; }
[ -f "$LIVENESS" ] || { echo "wt-unlock: missing $LIVENESS" >&2; exit 2; }
if ! dirs=$(git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null); then
  echo "wt-unlock: not a git checkout: $1" >&2
  exit 2
fi
gitdir=$(realpath -m "$(printf '%s\n' "$dirs" | sed -n 1p)")
common=$(realpath -m "$(printf '%s\n' "$dirs" | sed -n 2p)")
checkout=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || checkout="$1"
checkout=$(realpath -m "$checkout")
# Every registered checkout of this repo, the main worktree first: the scope
# of a shared lock, and the root the main index.lock scopes to. Empty when git
# cannot list them; every lock in the common dir is then kept.
worktrees=()
while IFS= read -r p; do
  [ -n "$p" ] && worktrees+=("$(realpath -m "$p")")
done < <(git -C "$checkout" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

# One "<owning dir>\t<lock path>" line per lock in scope.
candidates() {
  local d p seen=""
  for d in "$gitdir" "$common"; do
    case "|$seen|" in *"|$d|"*) continue ;; esac
    seen="$seen|$d"
    [ -f "$d/index.lock" ] && printf '%s\t%s\n' "$d" "$d/index.lock"
    [ -f "$d/packed-refs.lock" ] && printf '%s\t%s\n' "$d" "$d/packed-refs.lock"
    if [ -d "$d/refs" ]; then
      find "$d/refs" -type f -name '*.lock' -print | while IFS= read -r p; do
        printf '%s\t%s\n' "$d" "$p"
      done
    fi
  done
  return 0
}

probe() { python3 "$LIVENESS" --procfs "$PROCFS" "$@"; }
first_line() { tr '\t' ' ' <<<"$1" | sed -n 1p; }

kept=0
keep() { kept=$((kept + 1)); echo "kept: $1 ($2)"; }

now=$(date +%s)
while IFS=$'\t' read -r dir lock; do
  [ -n "$lock" ] || continue
  if ! mtime=$(stat -c %Y -- "$lock" 2>/dev/null); then
    keep "$lock" "vanished during the scan"
    continue
  fi
  size=$(stat -c %s -- "$lock" 2>/dev/null || echo '?')
  age=$((now - mtime))
  if [ "$age" -lt "$MIN_AGE" ]; then
    keep "$lock" "fresh: ${age}s old, under ${MIN_AGE}s; its writer may be live"
    continue
  fi

  out=$(probe -- "$lock" 2>&1); rc=$?
  case $rc in
    1) ;;
    0) keep "$lock" "held open: $(first_line "$out")"; continue ;;
    *) keep "$lock" "liveness unavailable (rc $rc): $(first_line "$out")"; continue ;;
  esac

  if [ "$dir" = "$common" ] && [ "${#worktrees[@]}" = 0 ]; then
    keep "$lock" "cannot list this repo's worktrees, so its scope is unknown"; continue
  fi
  if [ "$lock" = "$common/index.lock" ]; then
    scope=("$common" "${worktrees[0]}"); where="the main checkout"
  elif [ "$dir" = "$common" ]; then
    scope=("$common" "${worktrees[@]}"); where="any checkout of this repo"
  else
    scope=("$gitdir" "$checkout"); where="this worktree"
  fi
  # Three negative samples a second apart; the first positive or
  # unanswerable sample ends the loop and keeps the lock.
  rc=1; out=""
  for try in 1 2 3; do
    [ "$try" -gt 1 ] && sleep 1
    out=$(probe --comm git -- "${scope[@]}" 2>&1); rc=$?
    [ "$rc" = 1 ] || break
  done
  case $rc in
    1) ;;
    0) keep "$lock" "a git process is on $where (probe $try of 3): $(first_line "$out")"; continue ;;
    *) keep "$lock" "liveness unavailable (rc $rc): $(first_line "$out")"; continue ;;
  esac

  proof="${age}s old, ${size} bytes, no process holds it open, no git on $where"
  if [ "$DRY_RUN" = 1 ]; then
    echo "would: rm $lock ($proof)"
  elif rm -f -- "$lock"; then
    echo "cleared: $lock ($proof)"
  else
    keep "$lock" "rm failed"
  fi
done < <(candidates)

[ "$kept" = 0 ]
