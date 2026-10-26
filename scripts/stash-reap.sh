#!/usr/bin/env bash
# stash-reap.sh: drop verified-dead git stashes from a SHARED stash stack by
# SHA, never by index. Companion to the /stash-mining skill, which classifies
# stashes; this script is the part that has to be right when it finally drops
# one.
#
# Env:
#   DRY_RUN=1 (default)      report only. DRY_RUN=0 drops (see CONFIRM below).
#   STASH_REAP_CONFIRM=<n>   required when DRY_RUN=0: must equal the number of
#                            stashes this run would drop. A stale number means
#                            the stack moved since you read the plan -> refuse.
#   REPO=<path>              repo whose stash stack to reap (default: the
#                            harness checkout this script lives in).
#   BUNDLE=<dir>             optional recovery bundle; when set, each stash's
#                            live diff must byte-match its entry under
#                            <dir>/diffs/, named either <short-sha>.diff or
#                            <NNN>.diff resolved by SHA via <dir>/manifest.txt.
#
# Input: SHAs as args, or one per line on stdin ("<sha>" or "<sha> # note").
# Summary line: "stash-reap: candidates:N gone:N no-backup:N mismatch:N dropped:N"
#
# Why SHA-addressed. `stash@{N}` is a stack POSITION, not an id. On this host 16+
# agent sessions share one stack through the common git dir, and `git stash
# store` (how an autostashed rebase files its entry) can insert at any depth.
# Measured 2026-08-27 mid-run: the stack went 17 -> 15 under a live peer while a
# drop plan built from indexes sat open. Index-addressed drops are a
# wrong-stash-deleted bug waiting for a race; this re-resolves SHA -> index
# immediately before every drop and re-verifies rev-parse still returns the
# expected SHA.
#
# Why the backup ref is mandatory. A dropped stash is unreachable and gc-able.
# refs/stash-backup/<short-sha> keeps the commit alive after the drop, so the
# work survives even a wrong verdict. No ref, no drop -- the script creates one
# rather than skipping, because a missing backup is the only failure here that
# is not recoverable.
#
# Relationship to git-guard. git-guard blocks a bare `git stash drop` typed at a
# session, deliberately. It matches on the Bash command string, so it does NOT
# see the drop inside this script -- stated plainly rather than left implicit.
# That is why DRY_RUN=0 additionally requires STASH_REAP_CONFIRM to equal the
# exact candidate count: the gate is moved, not removed, and an agent cannot
# satisfy it by guessing. Run DRY_RUN=0 yourself once you have read the plan.
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
REPO="${REPO:-$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)}"
BUNDLE="${BUNDLE:-}"
CONFIRM="${STASH_REAP_CONFIRM:-}"

candidates=0 gone=0 nobackup=0 mismatch=0 dropped=0

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "WARN stash-reap: $REPO is not a readable git repo"
  echo "stash-reap: candidates:0 gone:0 no-backup:0 mismatch:0 dropped:0"
  exit 1
}

# stdin is only consumed when no SHAs were passed as args, so `stash-reap.sh
# <sha>` stays usable interactively without hanging on a terminal read.
shas=("$@")
if [ "${#shas[@]}" -eq 0 ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    shas+=("$line")
  done
fi

[ "${#shas[@]}" -gt 0 ] || {
  echo "stash-reap: no SHAs given (args or stdin)"
  echo "stash-reap: candidates:0 gone:0 no-backup:0 mismatch:0 dropped:0"
  exit 1
}

# SHA -> current stack position, or rc 1 when the SHA is no longer listed.
stash_index_of() {
  local n
  n=$(git -C "$REPO" stash list --format='%H' | grep -nxF "$1" | head -1 | cut -d: -f1)
  [ -n "$n" ] || return 1
  printf '%d' "$((n - 1))"
}

# The REFLOG subject, which is what `git stash list` shows and therefore what
# the operator matches against when authorizing a drop. It is not the commit
# subject: `git stash store -m autostash` (how a failed rebase files its entry)
# writes a bare "autostash" reflog subject over a commit whose own subject is
# "WIP on main: ...". Printing the commit subject here showed a string that
# appeared nowhere in `git stash list`.
stash_msg_of() {
  local n
  n=$(stash_index_of "$1") || return 1
  git -C "$REPO" stash list --format='%gs' | sed -n "$((n + 1))p"
}

backup_ref_of() {
  git -C "$REPO" for-each-ref --format='%(refname) %(objectname)' refs/stash-backup/ \
    | awk -v s="$1" '$2 == s { print $1; exit }'
}

# Locate a stash's diff inside BUNDLE, printing the path. Preferred layout is
# <short-sha>.diff. The /stash-mining skill writes <NNN>.diff instead, numbered
# by the stash's row in the bundle's own manifest.txt at capture time, so fall
# back to that -- looked up BY SHA, never by live stack position. The manifest
# is a frozen capture-time record; the number is only where the bundle filed the
# file, so this does not reintroduce index addressing.
#
# Without this fallback the SHA-named path never exists for a skill-produced
# bundle, so BUNDLE refused every stash, and the operator's way out was to unset
# BUNDLE -- turning the strongest gate here into one nobody runs. Found
# 2026-08-27 when a 12-stash drop had reported mismatch:0 with BUNDLE unset,
# i.e. no comparison had ever actually run.
bundle_diff_for() {
  local full="$1" d m n
  d="$BUNDLE/diffs/${full:0:12}.diff"
  if [ -f "$d" ]; then printf '%s' "$d"; return 0; fi
  m="$BUNDLE/manifest.txt"
  [ -f "$m" ] || return 1
  n=$(awk -F'|' -v s="$full" '$2 == s { print NR - 1; exit }' "$m")
  [ -n "$n" ] || return 1
  d=$(printf '%s/diffs/%03d.diff' "$BUNDLE" "$n")
  [ -f "$d" ] || return 1
  printf '%s' "$d"
}

# Pass 1: classify every SHA without mutating anything, so a plan that has gone
# stale is reported in full rather than half-executed.
plan_sha=(); plan_idx=()
for sha in "${shas[@]}"; do
  full=$(git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null)
  if [ -z "$full" ]; then
    echo "  unknown  $sha  (not a commit in this repo)"
    gone=$((gone + 1))
    continue
  fi

  if ! idx=$(stash_index_of "$full"); then
    echo "  gone     ${full:0:12}  (already off the stack; backup ref decides recoverability)"
    gone=$((gone + 1))
    continue
  fi

  ref=$(backup_ref_of "$full")
  if [ -z "$ref" ]; then
    ref="refs/stash-backup/${full:0:12}"
    if [ "$DRY_RUN" = "0" ]; then
      if git -C "$REPO" update-ref "$ref" "$full"; then
        echo "  backup   ${full:0:12}  created $ref"
      else
        echo "WARN stash-reap: could not create $ref for ${full:0:12}; refusing to drop it"
        nobackup=$((nobackup + 1))
        continue
      fi
    else
      echo "  backup   ${full:0:12}  would create $ref"
    fi
  fi

  # Setting BUNDLE asserts the bundle covers these stashes, so a MISSING entry
  # is a failure, not a skip. A comparison that cannot run must never read as a
  # comparison that passed.
  if [ -n "$BUNDLE" ]; then
    if ! d=$(bundle_diff_for "$full"); then
      echo "WARN stash-reap: BUNDLE set but no diff for ${full:0:12} (tried diffs/${full:0:12}.diff and manifest.txt); refusing to drop it unverified"
      mismatch=$((mismatch + 1))
      continue
    fi
    if ! git -C "$REPO" stash show -p --binary "$full" 2>/dev/null | cmp -s - "$d"; then
      echo "WARN stash-reap: ${full:0:12} does not byte-match $d; refusing to drop it"
      mismatch=$((mismatch + 1))
      continue
    fi
  fi

  echo "  ready    ${full:0:12}  stash@{$idx}  $(stash_msg_of "$full")"
  plan_sha+=("$full")
  plan_idx+=("$idx")
  candidates=$((candidates + 1))
done

summary() {
  echo "stash-reap: candidates:$candidates gone:$gone no-backup:$nobackup mismatch:$mismatch dropped:$dropped"
}

if [ "$DRY_RUN" != "0" ]; then
  # Carry BUNDLE into the suggested command. Omitting it printed a line that
  # silently turned OFF the byte-match the plan had just passed, so an operator
  # following this tool's own advice dropped unverified.
  bundle_env=""
  [ -n "$BUNDLE" ] && bundle_env="BUNDLE=$BUNDLE "
  echo "stash-reap: DRY_RUN=1 -- nothing dropped. To drop these $candidates:"
  echo "  DRY_RUN=0 STASH_REAP_CONFIRM=$candidates REPO=$REPO ${bundle_env}$0 ${shas[*]}"
  summary
  exit 0
fi

if [ "$CONFIRM" != "$candidates" ]; then
  echo "WARN stash-reap: STASH_REAP_CONFIRM='$CONFIRM' != candidate count $candidates -- refusing."
  echo "     The stack moved since the plan was written, or the count was guessed."
  summary
  exit 1
fi

# Pass 2: drop highest-index-first (fewest shifts) AND re-resolve before each
# one, so a concurrent peer drop between passes cannot retarget us.
order=$(for i in "${!plan_sha[@]}"; do echo "${plan_idx[$i]} $i"; done | sort -rn | awk '{print $2}')
for i in $order; do
  sha="${plan_sha[$i]}"
  if ! idx=$(stash_index_of "$sha"); then
    echo "  gone     ${sha:0:12}  (dropped by a peer mid-run)"
    gone=$((gone + 1)); candidates=$((candidates - 1))
    continue
  fi
  actual=$(git -C "$REPO" rev-parse --verify --quiet "stash@{$idx}" 2>/dev/null)
  if [ "$actual" != "$sha" ]; then
    echo "WARN stash-reap: stash@{$idx} is ${actual:0:12}, expected ${sha:0:12} -- refusing this drop"
    mismatch=$((mismatch + 1)); candidates=$((candidates - 1))
    continue
  fi
  if git -C "$REPO" stash drop "stash@{$idx}" >/dev/null 2>&1; then
    echo "  dropped  ${sha:0:12}  (was stash@{$idx}; kept at $(backup_ref_of "$sha"))"
    dropped=$((dropped + 1))
  else
    echo "WARN stash-reap: git stash drop stash@{$idx} failed for ${sha:0:12}"
    mismatch=$((mismatch + 1)); candidates=$((candidates - 1))
  fi
done

summary
