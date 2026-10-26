#!/usr/bin/env bash
# wt-roots.sh — which directories on this box hold git repos.
#
# Sourced by wt-sweep.sh and wt-new.sh so the two agree about what exists.
# Both used to hardcode `ROOT="${ROOT:-$HOME/SITES}"` independently, which made
# every repo outside ~/SITES invisible to both — including `dotfiles`, the repo
# the harness itself is developed in and the largest worktree pile on the box.
#
# THE DEFECT THIS EXISTS TO FIX (issue #511)
#   wt-sweep.service runs weekly with Environment=DRY_RUN=0 and no ROOT, so the
#   automated worktree GC had never once swept dotfiles. It did not error or warn;
#   it printed `removed:8` across all of ~/SITES and read as a healthy sweep. With
#   $HOME included the same invocation plans 31. harness-weekly.sh calls it
#   DRY_RUN=1 with no ROOT either, so the weekly *plan* never surfaced the backlog
#   and the 2026-08-12 manual reclaim (528 -> 72 worktrees, ~46 GB) silently
#   re-accumulated. A tool whose target is out of scope reports success either way,
#   which is why this went 15 days unnoticed.
#
# WHY $HOME AND NOT A CURATED LIST
#   Direct children only, never recursive. A hardcoded checkout path would fix
#   today's symptom and re-break the moment the next repo is cloned somewhere else
#   — the same class of bug, one repo later. Non-git directories are dropped by the
#   rev-parse guard below, and repos reachable from both roots collapse on the
#   git-common-dir dedup wt-sweep.sh already does per candidate.
#
# ROOT= STILL MEANS EXACTLY ONE ROOT
#   An explicit ROOT is returned alone, so every existing caller, the ONLY= filter,
#   and `ROOT=$HOME` in the docs behave precisely as before. Only the *default*
#   widened.
#
# REPO_ROOTS (KTD9, plan docs/plans/2026-09-27-2139-feat-issue-first-claims-
# content-reap-plan.md): the default is now read from config/dispatcher.env
# through the shared cfg_get() in dispatcher-common.sh, mirroring
# dispatcher-tick.sh's own REPO_ROOTS read (:342-343) -- same $HOME expansion by
# plain string substitution, never eval; same DISPATCHER_CONFIG override seam.
# The compiled-in default passed to cfg_get is "$HOME/SITES:$HOME", identical to
# the hardcoded fallback this replaced, so every existing caller (wt-new.sh,
# wt-sweep.sh) sees the same roots as before at the shipped config default.

# Emit one root directory per line.
wt_roots() {
  if [ -n "${ROOT:-}" ]; then
    printf '%s\n' "${ROOT%/}"
    return 0
  fi
  local WT_ROOTS_LIB_DIR CONFIG_FILE raw expanded roots root
  WT_ROOTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  declare -F cfg_get >/dev/null || . "$WT_ROOTS_LIB_DIR/dispatcher-common.sh"
  CONFIG_FILE="${DISPATCHER_CONFIG:-$WT_ROOTS_LIB_DIR/../../config/dispatcher.env}"
  raw=$(cfg_get REPO_ROOTS '$HOME/SITES:$HOME')
  expanded="${raw//\$HOME/$HOME}"
  IFS=':' read -r -a roots <<< "$expanded"
  for root in "${roots[@]}"; do
    [ -n "$root" ] && printf '%s\n' "${root%/}"
  done
}

# Emit one git repo (or worktree) directory per line, across every root.
# Order is root order, so ~/SITES keeps winning any ambiguity it used to win.
wt_repo_candidates() {
  local root d
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -d "$d" ] || continue          # unmatched glob stays literal; drop it
      d="${d%/}"
      git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
      printf '%s\n' "$d"
    done
  done < <(wt_roots)
}
