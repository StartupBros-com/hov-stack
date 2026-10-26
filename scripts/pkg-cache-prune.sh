#!/usr/bin/env bash
# pkg-cache-prune — reclaim package-manager caches and orphaned download debris.
#
#   DRY_RUN=1 (default) prints current sizes and the plan; DRY_RUN=0 executes.
#
# WHY THIS IS SAFE TO SCHEDULE
# The three package caches below are content-addressed and re-fetchable:
# pruning one never deletes a package a project still depends on, only the
# copies nothing currently references. The only cost is a re-download the next
# time a pruned package is needed fresh — real friction on a slow link, which
# is why this stays DRY_RUN-by-default and runs weekly rather than daily
# (these caches take weeks to regrow to their current size, not hours;
# measured 2026-08-11: pnpm store 25G, uv cache 28G, npm cache 9.4G).
# The huggingface lane is safe for the opposite reason: its targets are NOT
# cache content at all. hf/xet restarts an interrupted download from zero, so
# an orphaned `*.incomplete` partial is pure garbage nothing will ever read.
#
#   pnpm store prune   removes package versions no longer referenced by any
#                      pnpm-managed project's lockfile on this machine.
#   npm cache verify   npm's own safe reclaim path — garbage-collects unneeded
#                      cache entries and verifies the rest. Deliberately NOT
#                      `npm cache clean --force`: that wipes the ENTIRE cache
#                      unconditionally (npm's docs call clean "typically
#                      unnecessary"), which is a strictly bigger re-fetch bill
#                      for no extra safety over verify's targeted GC.
#   uv cache prune     removes unreachable wheels/sdists from uv's cache.
#   hf partials        deletes orphaned `*.incomplete` download partials under
#                      ~/.cache/huggingface, age-gated to >1 day untouched.
#                      Plain find(1), no CLI — see the lane comment for why
#                      this is deliberately NOT `hf cache prune`.
#
# None of these touch project node_modules/, .venv/, or lockfiles — only the
# shared, machine-wide cache stores under ~/.local/share/pnpm, ~/.cache/uv,
# ~/.npm, plus orphaned partials under ~/.cache/huggingface. A missing tool or
# cache dir is skipped, not a failure: not every checkout on this box uses all
# of them.
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
say() { [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null 2>&1; return 0; }

n_fail=0
n_ran=0
n_busy=0

# Contention is not breakage.
#
# Every package manager here takes a lock on its own cache, and this box runs
# agents around the clock, so a prune racing a live `uv`/`pnpm` is the NORMAL
# case, not a fault. Treating it as failure is what put this unit in `failed`
# from 2026-08-25 with nobody looking: `uv cache prune` sat 900s on
# ~/.cache/uv/.lock, exited non-zero, and the unit went red for a cache that was
# simply in use and would be pruned fine on the next run.
#
# That mattered beyond one red dot. Three units were failing on workstation and NONE had
# OnFailure= wired; a `failed` state that fires on routine contention is how a
# fleet learns to stop reading `failed`. Exit-code discipline has to land BEFORE
# alerting, or the alerting is just noise with a pager attached.
#
# Returns: 0 pruned, 1 genuinely failed, 2 skipped because the cache was busy.
# BUSY IS TWO TIERS, not a phrase plus a "cache context" test.
#
# History, because each version failed for a reason worth keeping:
#
#   v1  matched a bare phrase. A reviewer proved it exploitable: a fake
#       `could not acquire credentials` error exited 0 as BUSY.
#   v2  required a phrase AND cache/lock context. That is a NO-OP for npm --
#       every npm error ends with
#           npm error A complete log of this run can be found in: ~/.npm/_logs/...
#       so the `*"/.npm"*` token is satisfied by literally every npm failure.
#       Classification collapsed back to phrase-only for the one tool whose arm
#       was least evidenced, which re-opened the v1 exploit and additionally
#       swallowed fork/rlimit EAGAIN as "contention".
#
# The v2 defect is structural, not a bad token list: all three commands here are
# CACHE commands, so their error output names a cache or store almost by
# definition. A context test built out of cache words cannot discriminate
# between messages that all mention the cache.
#
# The distinction that does discriminate is whether the wording names contention
# BY ITSELF.

# TIER A -- wording that is contention on its own. No further evidence needed.
# `waiting for lock` and the in-use message are observed uv output; ENOLCK is
# the errno whose definition IS "no locks available".
_contention_wording() {
  case "$1" in
    *"waiting for lock"*|*"lock"*"already"*"held"*|*ENOLCK*|\
    *"currently in-use"*"waiting for other"*) return 0 ;;
  esac
  return 1
}

# TIER B -- generic errnos and English. Produced by fork failures, rlimit hits
# and socket exhaustion at least as readily as by a lock, so on their own they
# are NOT evidence of contention. Both spellings of the EAGAIN prose appear in
# the wild (npm capitalises it, pnpm does not).
_generic_wording() {
  case "$1" in
    *"could not acquire"*|*EAGAIN*|\
    *"Resource temporarily unavailable"*|*"resource temporarily unavailable"*|\
    *"waiting for other"*"process"*|*"is another"*"process running"*|\
    *"another process is running"*) return 0 ;;
  esac
  return 1
}

# A genuine lock ARTEFACT -- required alongside tier B. Deliberately NOT cache
# words: a cache path is not evidence about a generic errno, which is exactly
# the mistake v2 made.
_lock_artefact() {
  case "$1" in
    *.lock*|*lockfile*|*"lock file"*|*"lock on "*|*"/_locks/"*) return 0 ;;
  esac
  return 1
}

run() {
  local out rc
  if [ "$DRY_RUN" = 1 ]; then echo "  would: $*"; return 0; fi
  out=$("$@" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     | /'
  if [ "$rc" -eq 0 ]; then echo "  ok: $*"; return 0; fi

  # TIER A alone, or TIER B paired with a real lock artefact. See the tier
  # notes above for why "phrase + cache context" was not enough.
  #
  # A single `case` matches if ANY arm matches, so mixing anchored and unanchored
  # arms silently gives you the weakest one -- that is how three context-free
  # arms survived a version that claimed every pattern required context. Keeping
  # the tiers as separate predicates makes the weakest-arm problem structural
  # rather than a matter of writing every arm carefully.
  #
  # NO-CLAIM BOUNDARY: tier A comes from tool docs and observed uv output. I have
  # never captured a real npm or pnpm cache-contention run, so npm/pnpm messages
  # reach BUSY only by naming a lock artefact. If a genuine npm contention
  # message does not, it is reported as a FAILURE -- the correct direction to be
  # wrong in, since a skipped prune runs again next week and a swallowed failure
  # does not.
  if _contention_wording "$out" || { _generic_wording "$out" && _lock_artefact "$out"; }; then
    echo "  ~~ BUSY (cache in use; next run will retry): $*"; return 2
  fi
  echo "  !! FAILED: $*"; return 1
}

# Fold one run() outcome into the counters. Kept separate so each call site reads
# as one line and no site can forget the busy case.
tally() {
  case "$1" in
    1) n_fail=$((n_fail + 1)) ;;
    2) n_busy=$((n_busy + 1)) ;;
  esac
}

# -H dereferences a path given on the command line (only): ~/.cache/huggingface
# may legitimately be a symlink onto another disk (the usual post-disk-full
# relocation), and du/find in default -P mode would silently measure/walk the
# symlink itself — reporting 0 while orphans sit untouched forever. -H is a
# no-op for the plain directories the other lanes pass. Deliberately not -L:
# hub snapshots/ symlinks into blobs/, and -L would double-count those.
size_of() { du -shH "$1" 2>/dev/null | cut -f1; }

echo "===== pkg-cache-prune $([ "$DRY_RUN" = 1 ] && echo '(DRY RUN)') ====="
echo

echo "## pnpm store (~/.local/share/pnpm)"
if command -v pnpm >/dev/null 2>&1; then
  echo "  current: $(size_of "$HOME/.local/share/pnpm")"
  n_ran=$((n_ran + 1))
  run pnpm store prune; tally $?
  [ "$DRY_RUN" != 1 ] && echo "  after: $(size_of "$HOME/.local/share/pnpm")"
else
  echo "  pnpm not on PATH — skipped"
fi
echo

echo "## npm cache (~/.npm)"
if command -v npm >/dev/null 2>&1; then
  echo "  current: $(size_of "$HOME/.npm")"
  n_ran=$((n_ran + 1))
  run npm cache verify; tally $?
  [ "$DRY_RUN" != 1 ] && echo "  after: $(size_of "$HOME/.npm")"
else
  echo "  npm not on PATH — skipped"
fi
echo

echo "## uv cache (~/.cache/uv)"
if command -v uv >/dev/null 2>&1; then
  echo "  current: $(size_of "$HOME/.cache/uv")"
  n_ran=$((n_ran + 1))
  run uv cache prune; tally $?
  [ "$DRY_RUN" != 1 ] && echo "  after: $(size_of "$HOME/.cache/uv")"
else
  echo "  uv not on PATH — skipped"
fi
echo

echo "## huggingface cache (~/.cache/huggingface)"
# No CLI here, deliberately. hf ships `hf cache prune`, but shelling out to it
# would install a CLI to solve a find(1) problem (its standalone installer also
# writes a skill — rejected in the 2026-08-14 vet), and it additionally GCs
# unreferenced *revisions*, which are re-fetchable content this lane makes no
# claim about. Orphaned partials are different: hf/xet restarts an interrupted
# download from ZERO, so a partial whose download died is garbage nothing will
# ever read — the recorded incident left 32 orphans / 501 GB / disk at 99%
# (memory/-home-user-SITES-acme-infra/large-model-download-curl-vs-hf-xet.md).
# The >1-day mtime gate exists because this runs on a timer and downloads do
# not: a partial still being written has a fresh mtime and is left alone until
# a later run finds it stale.
HF_CACHE="$HOME/.cache/huggingface"
if [ -d "$HF_CACHE" ]; then
  echo "  current: $(size_of "$HF_CACHE")"
  # Reporting is never age-gated: a partial too young to delete still counts,
  # so "partials: none" always means none exist, not merely none eligible.
  read -r inc_count inc_bytes < <(find -H "$HF_CACHE" -type f -name '*.incomplete' -printf '%s\n' 2>/dev/null | awk '{n++; s+=$1} END {print n+0, s+0}')
  if [ "$inc_count" -eq 0 ]; then
    echo "  partials: none"
  else
    elig_count=$(find -H "$HF_CACHE" -type f -name '*.incomplete' -mmin +1440 2>/dev/null | wc -l)
    echo "  partials: $inc_count .incomplete file(s), $(numfmt --to=iec --suffix=B "$inc_bytes") total; eligible (untouched >1d): $elig_count"
    if [ "$elig_count" -gt 0 ]; then
      n_ran=$((n_ran + 1))
      # -ignore_readdir_race: an hf download racing this walk can remove
      # entries between readdir and stat, and find would otherwise report the
      # vanished path and exit non-zero — which run() classifies as FAILED
      # (its busy vocabulary is lock wording; find has none), paging for a
      # prune that succeeded. Vanish-races are the NORMAL case on a box
      # running agents around the clock, so they are excused. Every other
      # traversal error (e.g. an unreadable subdir) still exits non-zero and
      # still FAILs — deliberate: that is genuine breakage worth a red unit.
      run find -H "$HF_CACHE" -ignore_readdir_race -type f -name '*.incomplete' -mmin +1440 -print -delete; tally $?
      [ "$DRY_RUN" != 1 ] && echo "  after: $(size_of "$HF_CACHE")"
    else
      echo "  (nothing eligible — all partials touched <1 day ago; a live download is left alone)"
    fi
  fi
else
  echo "  ~/.cache/huggingface not present — skipped"
fi
echo

echo "===== summary ====="
[ "$DRY_RUN" = 1 ] && echo "(dry run — re-run with DRY_RUN=0 to apply)"
echo "pkg-cache-prune: ran:$n_ran failed:$n_fail busy:$n_busy"
if [ "$n_fail" -gt 0 ]; then
  say "pkg-cache-prune: $n_fail of $n_ran cache prune(s) FAILED" input
  exit 1
fi
# Busy is reported, never fatal: the cache is still there and the next run gets
# it. A unit that goes red for this is a unit whose red means nothing.
[ "$n_busy" -gt 0 ] && echo "(pkg-cache-prune: $n_busy of $n_ran skipped, cache busy — not a failure)"
exit 0
