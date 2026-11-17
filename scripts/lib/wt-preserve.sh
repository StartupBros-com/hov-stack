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
# .next, .velite, .svelte-kit, .nuxt, .parcel-cache and dist directories, *.pyc,
# .eslintcache, *.tsbuildinfo and next-env.d.ts files, and .claude/deliverables/
# and .context/. dist/ and next-env.d.ts (dotfiles#2259) are build output: on
# 2026-11-16 they were all that kept 9 of the operator's 40 idle-kept worktrees.
# Not listed, on purpose: .astro, .wrangler (local dev databases), .venv,
# worker-configuration.d.ts, supabase/.temp and the like.
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
      */dist|*/dist/*|*/next-env.d.ts) ;;
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

# Prints "<epoch><TAB><what>" for the newest local work in worktree $1 and returns
# 0, or prints why it cannot tell and returns 1; the caller must then keep the
# worktree (hov-stack#721). Local work is every path `git status` lists, untracked
# files one by one, dated by its own mtime; a path that no longer exists (a delete,
# a rename's source) is dated by its nearest surviving directory, whose mtime the
# delete moved. When $2, the unshipped count, is above 0, HEAD's committer time
# counts too: HEAD is then itself unshipped and the newest such commit. A session
# that drives a worktree only through script files or another harness names it in
# no tool call, so wt_session_hold cannot see it; this date can.
# Gitignored files are not looked at: `git status` does not list them.
wt_newest_work() {
  local wt="$1" unp="${2:-0}" list stats e p q t best=-1 what="" i=0 n
  local -a ents=() cands=() times=()   # set, not just declared: callers run under set -u
  list=$(mktemp) || { printf 'cannot make a temp file'; return 1; }
  if ! git -C "$wt" status --porcelain=v1 -z --untracked-files=all >"$list" 2>/dev/null; then
    rm -f "$list"; printf 'cannot list changed files'; return 1
  fi
  mapfile -d '' -t ents <"$list"; rm -f "$list"
  n=${#ents[@]}
  while (( i < n )); do
    e=${ents[i]}; i=$((i+1))
    p=${e:3}
    # With -z a rename or copy puts its source in the next field, without a status.
    case ${e:0:2} in R*|C*) (( i < n )) && { cands+=("${ents[i]}"); i=$((i+1)); } ;; esac
    cands+=("$p")
  done
  for i in "${!cands[@]}"; do
    q=${cands[i]%/}; [ -n "$q" ] || q=.
    while [ ! -e "$wt/$q" ] && [ ! -L "$wt/$q" ]; do
      case $q in */*) q=${q%/*} ;; *) q=. ;; esac
    done
    cands[i]=$q
  done
  if (( ${#cands[@]} > 0 )); then
    stats=$(mktemp) || { printf 'cannot make a temp file'; return 1; }
    # stat's own exit status counts: a path gone between the listing and here is a
    # sign of live work, not something to date by the survivors.
    if ! (cd "$wt" && printf '%s\0' "${cands[@]}" | xargs -0 stat --printf '%Y %n\0' --) >"$stats" 2>/dev/null; then
      rm -f "$stats"; printf 'cannot read the mtime of every changed path'; return 1
    fi
    mapfile -d '' -t times <"$stats"; rm -f "$stats"
    for e in "${times[@]}"; do
      t=${e%% *}
      case $t in ''|*[!0-9]*) printf 'unreadable mtime for %s' "${e#* }"; return 1 ;; esac
      if (( t > best )); then best=$t; what=${e#* }; fi
    done
  fi
  if [ "$unp" -gt 0 ] 2>/dev/null; then
    t=$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null)
    case $t in ''|*[!0-9]*) printf 'cannot read the time of the newest unshipped commit'; return 1 ;; esac
    if (( t > best )); then
      best=$t; what="unshipped commit $(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"
    fi
  elif [ "$unp" != 0 ]; then
    printf 'unshipped count %s is not a number' "$unp"; return 1
  fi
  if (( best < 0 )); then printf 'git status listed no local work'; return 1; fi
  printf '%s\t%s' "$best" "$what"
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
