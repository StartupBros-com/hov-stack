#!/usr/bin/env bash
# wt-preserve.sh — what must happen before a worktree is removed, shared by
# wt-sweep.sh and wt-done.sh (hov-stack#384).
#
# Three things a removal used to lose:
#   - a Claude Code session idling in the worktree (no process shows it);
#   - gitignored deliverables: `git status` never lists them, and `git worktree
#     remove` deletes them with or without --force (git 2.43), so a worktree whose
#     only unshipped work is a report reads as clean;
#   - commits on a detached HEAD, which sit on no ref once the worktree's reflog
#     goes with it.
#
# Sourced, never executed. Callers must fail closed if this file is missing.

WT_PRESERVE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Prints why a Claude Code session holds worktree $1 and returns 0, or prints any
# `resumable:` notes and returns 1. A check that cannot answer reads as held,
# like alive(): erring that way only defers a removal.
wt_session_hold() {
  local out rc
  out=$(python3 "$WT_PRESERVE_DIR/wt_session_hold.py" --active-min "${ACTIVE_MIN:-120}" -- "$1"); rc=$?
  case $rc in
    0) printf '%s' "$out"; return 0 ;;
    1) printf '%s' "$out"; return 1 ;;
    *) printf 'session check unavailable (exit %s); treating as held' "$rc"; return 0 ;;
  esac
}

# Copies the gitignored files under .claude/deliverables/ of worktree $2 into the
# main checkout $1, at .claude/deliverables/from-worktrees/<worktree name>/ (a
# dated suffix if that exists already, so an earlier rescue is never overwritten),
# and verifies each copy byte for byte. $3 is DRY_RUN, $4 the date stamp. Returns 0
# when there is nothing to copy or every copy verified; otherwise the caller must
# keep the worktree. Only .claude/deliverables/ is rescued: it is where the global
# CLAUDE.md sends files the operator reads. Other ignored files (caches, builds,
# node_modules) are regenerable and still go with the worktree.
wt_rescue_deliverables() {
  local repo="$1" wt="$2" dry="$3" stamp="$4" list base root dest f rel n i
  local -a files
  list=$(mktemp) || return 1
  if ! git -C "$wt" ls-files -z --others --ignored --exclude-standard -- .claude/deliverables >"$list" 2>/dev/null; then
    rm -f "$list"; echo "      !! cannot list ignored deliverables in $wt"; return 1
  fi
  mapfile -d '' -t files <"$list"; rm -f "$list"
  n=${#files[@]}
  [ "$n" = 0 ] && return 0
  base=$(basename "$wt")
  root="$repo/.claude/deliverables/from-worktrees"
  dest="$root/$base"
  if [ -e "$dest" ]; then
    dest="$root/$base-$stamp"; i=2
    while [ -e "$dest" ]; do dest="$root/$base-$stamp-$i"; i=$((i+1)); done
  fi
  if [ "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" != "$(realpath -m "$repo")" ]; then
    echo "      !! $repo is not a work tree; $n ignored deliverable file(s) have nowhere to go"
    return 1
  fi
  if [ "$dry" = 1 ]; then
    echo "      would: copy $n ignored deliverable file(s) to $dest"
    return 0
  fi
  for f in "${files[@]}"; do
    rel="${f#.claude/deliverables/}"
    if ! mkdir -p "$(dirname "$dest/$rel")" || ! cp -p -- "$wt/$f" "$dest/$rel" || ! cmp -s -- "$wt/$f" "$dest/$rel"; then
      echo "      !! could not copy and verify $wt/$f into $dest"
      return 1
    fi
  done
  echo "      ok: copied $n ignored deliverable file(s) to $dest"
}

# Pins the detached HEAD of worktree $2 at refs/heads/recovered/wt-sweep-$3/<name>
# in repo $1, refusing to overwrite an existing ref. $4 is DRY_RUN. Returns 0 once
# the ref holds HEAD; otherwise the caller must keep the worktree. Not the
# pr-merged namespace: wt-sweep prunes an anchor with no same-named branch.
wt_pin_detached() {
  local repo="$1" wt="$2" stamp="$3" dry="$4" ref head out
  ref="refs/heads/recovered/wt-sweep-$stamp/$(basename "$wt")"
  if [ "$dry" = 1 ]; then
    echo "      would: git -C '$repo' update-ref '$ref' <HEAD of $wt>"
    return 0
  fi
  head=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null) || { echo "      !! cannot read HEAD of $wt"; return 1; }
  if out=$(git -C "$repo" update-ref "$ref" "$head" "" 2>&1); then
    echo "      ok: pinned detached HEAD $head at $ref"
    return 0
  fi
  echo "      !! FAILED: update-ref $ref $head"
  [ -n "$out" ] && printf '%s\n' "$out" | head -n 5 | sed 's/^/         /'
  return 1
}
