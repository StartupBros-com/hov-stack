#!/usr/bin/env bash
# wt-preserve.sh — what must happen before a worktree is removed, shared by
# wt-sweep.sh and wt-done.sh (hov-stack#384).
#
# Three things a removal used to lose:
#   - a Claude Code session idling in the worktree (no process shows it);
#   - gitignored deliverables and skill state: `git status` never lists them, and
#     `git worktree remove` deletes them with or without --force (git 2.43), so a
#     worktree whose only unshipped work is a report reads as clean;
#   - commits on a detached HEAD, which sit on no ref once the worktree's reflog
#     goes with it.
#
# Sourced, never executed. Callers must fail closed if this file is missing.

WT_PRESERVE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Prints why a Claude Code session holds worktree $1 and returns 0, or prints any
# `resumable:` notes and returns 1. $2, when set, is a session id that never counts
# as a holder (wt-done passes its caller's). $3, when above 0, is an idle window in
# hours (hov-stack#644): a worktree held only by a transcript that has not named it
# for that long prints `idle: <holder>; last named <N>h ago` and still returns 0,
# so a caller that does not look for the `idle: ` prefix reads it as held. A check
# that cannot answer reads as held, like alive(): erring that way only defers a
# removal. A caller that loaded wt-roots.sh (wt-sweep) passes its repo roots as the
# helper's alias roots, so a compat link left at a checkout's old name counts as a
# spelling of every worktree under it (hov-stack#661); WT_ALIAS_ROOTS, when set,
# wins, and without either the helper uses ~/SITES and ~.
wt_session_hold() {
  local out rc roots=""
  if [ -z "${WT_ALIAS_ROOTS+x}" ] && declare -F wt_roots >/dev/null; then
    roots=$(wt_roots | paste -sd: -)
  fi
  out=$(if [ -n "$roots" ]; then export WT_ALIAS_ROOTS="$roots"; fi
    python3 "$WT_PRESERVE_DIR/wt_session_hold.py" --active-min "${ACTIVE_MIN:-120}" \
      --idle-hours "${3:-0}" --exclude-session "${2:-}" -- "$1"); rc=$?
  case $rc in
    0) printf '%s' "$out"; return 0 ;;
    1) printf '%s' "$out"; return 1 ;;
    3) case $out in
         'idle: '*) printf '%s' "$out" ;;
         *) printf 'idle check gave no idle line; treating as held' ;;
       esac
       return 0 ;;
    *) printf 'session check unavailable (exit %s); treating as held' "$rc"; return 0 ;;
  esac
}

# Returns 0 when every gitignored file in worktree $1 is a rebuildable cache or
# sits where wt_rescue_deliverables copies it out from; otherwise prints the first
# other entry and returns 1. A worktree released as idle (hov-stack#644) has no
# session left to say an ignored .env, build output or venv can go, so only these
# can: node_modules, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .turbo,
# .next, .velite, .svelte-kit, .nuxt and .parcel-cache directories, *.pyc,
# .eslintcache and *.tsbuildinfo files, and .claude/deliverables/ and .context/.
# With --directory git also lists each untracked directory that holds only ignored
# content (`.claude/` around `.claude/deliverables/`) and then lists that content
# itself, so such a directory is skipped when an entry below it is listed.
wt_cache_only() {
  local list entry p
  local -a entries
  local -A parent=()
  list=$(mktemp) || { printf 'cannot make a temp file'; return 1; }
  if ! git -C "$1" ls-files -z --others --ignored --exclude-standard --directory >"$list" 2>/dev/null; then
    rm -f "$list"; printf 'cannot list ignored files'; return 1
  fi
  mapfile -d '' -t entries <"$list"; rm -f "$list"
  for entry in "${entries[@]}"; do
    p=${entry%/}
    while [[ $p == */* ]]; do p=${p%/*}; parent["$p/"]=1; done
  done
  for entry in "${entries[@]}"; do
    [ -n "${parent[$entry]+set}" ] && continue
    case "/${entry%/}" in
      /.claude/deliverables|/.claude/deliverables/*|/.context|/.context/*) ;;
      */node_modules|*/node_modules/*|*/__pycache__|*/__pycache__/*) ;;
      */.pytest_cache|*/.pytest_cache/*|*/.mypy_cache|*/.mypy_cache/*|*/.ruff_cache|*/.ruff_cache/*) ;;
      */.turbo|*/.turbo/*|*/.next|*/.next/*|*/.velite|*/.velite/*) ;;
      */.svelte-kit|*/.svelte-kit/*|*/.nuxt|*/.nuxt/*|*/.parcel-cache|*/.parcel-cache/*) ;;
      *.pyc|*/.eslintcache|*.tsbuildinfo) ;;
      *) printf '%s' "$entry"; return 1 ;;
    esac
  done
  return 0
}

# Copies the gitignored files under .claude/deliverables/ and .context/ of worktree
# $2 into the main checkout $1, at .claude/deliverables/from-worktrees/<worktree
# name>/ (a dated suffix if that exists already, so an earlier rescue is never
# overwritten), and verifies each copy byte for byte. A .context/ file lands under
# dot-context/ there. $3 is DRY_RUN, $4 the date stamp. Returns 0 when there is
# nothing to copy or every copy verified; otherwise the caller must keep the
# worktree. Two places are rescued: .claude/deliverables/, where the global
# CLAUDE.md sends files the operator reads, and .context/, where compound-
# engineering skills keep state meant to outlive a run (experiment logs, specs,
# digests), which their own docs say no commit, branch or push preserves. Other
# ignored files (caches, builds, node_modules) are regenerable and still go with
# the worktree.
wt_rescue_deliverables() {
  local repo="$1" wt="$2" dry="$3" stamp="$4" list base root dest f rel n i
  local -a files
  list=$(mktemp) || return 1
  if ! git -C "$wt" ls-files -z --others --ignored --exclude-standard -- .claude/deliverables .context >"$list" 2>/dev/null; then
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
    case "$f" in
      .context/*) rel="dot-context/${f#.context/}" ;;
      *) rel="${f#.claude/deliverables/}" ;;
    esac
    # $dest was new when this rescue began, so a file already there is one this
    # rescue copied (a deliverable under dot-context/ meeting a .context/ file).
    if [ -e "$dest/$rel" ] || [ -L "$dest/$rel" ]; then
      echo "      !! two rescued files map to $dest/$rel; nothing overwritten"
      return 1
    fi
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
