#!/usr/bin/env bash
# launchpad-freshen: keep ~/SITES main checkouts ("launch pads") current.
#
# Why: Agents View / background sessions start in the directory they were
# dispatched from, on whatever branch that checkout has. Because real work
# happens in worktrees, launch checkouts drift for weeks (observed 2026-07:
# one app's checkout parked on a dead codex branch, 196 commits behind, 304 dirty files),
# and every new session inherits that stale state for its reads.
#
# Modes:
#   (default)               scan $SITES_ROOT: ff-only pull of clean on-default
#                           checkouts, WARN on everything else, never touch it
#   --repo <path> [--heal]  single repo. With --heal, additionally switch a
#                           parked or detached checkout back to the default
#                           branch when provably safe. The SessionStart hook
#                           uses this: launching a session in a directory is
#                           the evidence it is a launch pad.
#
# Heal safety, ALL required before a switch:
#   - no tracked modifications (untracked files never block: git itself aborts
#     a switch or ff-merge on any collision, so they are safe to carry)
#   - no in-progress git state (rebase / merge / cherry-pick / bisect)
#   - HEAD is reachable from some remote ref, OR the tip is older than 24h,
#     so an actively-working agent's checkout is never yanked mid-task
# Switching never deletes anything: the parked branch ref stays intact.
#
# The harness checkout itself (the repository whose hooks/ the config dir links to, with a
# ./setup) is never fast-forwarded here: moving it without merging settings.json right after
# strands a hook's file and its registration apart. It goes through `./setup --sync`, which
# moves the checkout only when it can merge settings.json too, under one lock. With --heal that
# runs detached and its result shows at the next session start; otherwise it runs here, in the
# foreground, and its one `sync:` line is the output.
#
# Env: SITES_ROOT (default ~/SITES), DRY_RUN=1 (report only, no mutation),
#      FRESHEN_FETCH_TIMEOUT seconds (default 60; the hook passes 4).
set -uo pipefail

FETCH_T=${FRESHEN_FETCH_TIMEOUT:-60}
DRY=${DRY_RUN:-0}
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROUTE_RESOLVER="${REPO_ROUTE_RESOLVER:-$HERE/repo-route.py}"

# Shared with dotup rather than restated: a failed ff-only merge has exactly one
# correct diagnosis, and two copies of it is how the second one starts lying.
# Sourced fail-soft — a launch-pad freshen must not die because a lib moved; the
# fallback below is the old message, which is vague but never wrong.
# shellcheck source=../lib/repo-update.sh
. "$HERE/../lib/repo-update.sh" 2>/dev/null || true

# The route gate is shared with ./setup --sync (lib/repo-route-gate.sh), so both refuse the same
# checkouts for the same reasons. Without the lib every repo is refused: a freshen that cannot
# apply the gate changes nothing.
# shellcheck source=../lib/repo-route-gate.sh
if ! . "$HERE/../lib/repo-route-gate.sh" 2>/dev/null || ! declare -F repo_route_gate > /dev/null; then
  repo_route_gate() { route_gate_why="lib/repo-route-gate.sh did not load; skipped before mutation"; return 1; }
fi
route_gate() {
  repo_route_gate "$1" "$ROUTE_RESOLVER" && return 0
  echo "WARN launchpad $(basename "$1"): $route_gate_why"
  return 1
}

default_of() {
  local d
  d=$(git -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
  if [ -z "$d" ]; then
    local c
    for c in main master; do
      git -C "$1" rev-parse --verify --quiet "origin/$c" >/dev/null 2>&1 && { d=$c; break; }
    done
  fi
  echo "$d"
}

in_progress() {
  local g
  g=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -e "$g/rebase-merge" ] || [ -e "$g/rebase-apply" ] || [ -e "$g/MERGE_HEAD" ] \
    || [ -e "$g/CHERRY_PICK_HEAD" ] || [ -e "$g/BISECT_LOG" ]
}

# The config dir the way wt-done resolves it.
freshen_cfg() { printf '%s' "${CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"; }

# 0 when <repo> is the harness checkout the live config dir runs from.
is_harness_checkout() {
  local repo=$1 cfg
  [ -x "$repo/setup" ] || return 1
  cfg=$(freshen_cfg)
  [ -e "$cfg/hooks" ] && [ -e "$repo/hooks" ] || return 1
  [ "$(readlink -f "$cfg/hooks")" = "$(readlink -f "$repo/hooks")" ]
}

# 0 when a ./setup --sync holds the lock: the lock is a directory with its owner's pid, stale
# when the pid is dead or the directory is older than 15 minutes (a lock with no pid yet is
# young for a minute), as ./setup's own sync_lock_stale judges it.
sync_lock_live() {
  local d=$1/.hov-stack/sync.lock pid
  [ -d "$d" ] || return 1
  pid=$(cat "$d/pid" 2>/dev/null) || pid=
  if [ -z "$pid" ]; then
    [ -z "$(find "$d" -prune -mmin +1 2>/dev/null)" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$(find "$d" -prune -mmin +15 2>/dev/null)" ]
}

# The harness checkout's refresh: ./setup --sync (see the header).
sync_harness() {
  local repo=$1 heal=$2 name cfg out line
  name=$(basename "$repo")
  cfg=$(freshen_cfg)
  if [ "$DRY" = "1" ]; then
    echo "launchpad $name: would run ./setup --sync (DRY_RUN)"
    return
  fi
  if [ "$heal" = "1" ]; then
    # The hook kills this helper at 7 s; the sync is not bounded by that, so it is detached
    # and its result is shown by the next session start (hooks/SessionStart/settings-apply.js).
    if sync_lock_live "$cfg"; then
      # A sync is already running: starting another would only skip, and would truncate the
      # log the running one is writing.
      echo "launchpad $name: handed to ./setup --sync in the background; its result shows at the next session start"
      return
    fi
    mkdir -p "$cfg/.hov-stack" 2>/dev/null
    CLAUDE_CONFIG_DIR=$cfg HOV_SYNC_LOCK_WAIT=0 nohup bash "$repo/setup" --sync \
      > "$cfg/.hov-stack/sync.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo "launchpad $name: handed to ./setup --sync in the background; its result shows at the next session start"
    return
  fi
  # Waits for a running sync up to a minute: wt-done stops this helper at 90 s.
  out=$(CLAUDE_CONFIG_DIR=$cfg HOV_SYNC_LOCK_WAIT=${HOV_SYNC_LOCK_WAIT:-60} HOV_SYNC_FETCH_TIMEOUT=$FETCH_T bash "$repo/setup" --sync 2>&1 < /dev/null)
  line=$(printf '%s\n' "$out" | grep '^sync: ' | tail -n 1)
  if [ -n "$line" ]; then
    echo "launchpad $name: $line"
  else
    echo "WARN launchpad $name: ./setup --sync printed no result line"
  fi
}

process_repo() {
  local repo=$1 heal=$2 name def branch tracked behind state pushed tipage mergeerr
  name=$(basename "$repo")
  # Must precede default-branch, in-progress, switch, fetch and merge reads: a
  # warned/enforced independent launch pad has no mutation authority.
  route_gate "$repo" || return
  def=$(default_of "$repo")
  [ -z "$def" ] && { echo "launchpad $name: no origin default branch, skipped"; return; }
  if in_progress "$repo"; then
    echo "WARN launchpad $name: rebase/merge in progress, not touched"
    return
  fi
  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  # --no-optional-locks: the SessionStart hook kills this helper at 7 s, and a
  # status probe killed mid-write leaves a zero-byte index.lock (dotfiles#1590).
  tracked=$(git -C "$repo" --no-optional-locks status --porcelain 2>/dev/null | grep -c -v '^??')

  if [ -z "$branch" ] || [ "$branch" != "$def" ]; then
    state=${branch:-DETACHED HEAD}
    if [ "$tracked" -gt 0 ]; then
      echo "WARN launchpad $name: parked on '$state' with $tracked tracked modification(s), not touched; rescue to a branch, then rehab"
      return
    fi
    if [ "$heal" != "1" ]; then
      behind=$(git -C "$repo" rev-list --count "HEAD..origin/$def" 2>/dev/null || echo '?')
      echo "WARN launchpad $name: parked on '$state' ($behind behind origin/$def), not touched; launch a session there to self-heal, or rehab manually"
      return
    fi
    pushed=$(git -C "$repo" branch -r --contains HEAD 2>/dev/null | head -1)
    tipage=$(( $(date +%s) - $(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0) ))
    if [ -z "$pushed" ] && [ "$tipage" -lt 86400 ]; then
      echo "WARN launchpad $name: parked on '$state' with recent unpushed work (tip $((tipage / 3600))h old), not healed"
      return
    fi
    if [ "$DRY" = "1" ]; then
      echo "launchpad $name: would heal (switch '$state' -> $def) (DRY_RUN)"
      return
    fi
    if ! git -C "$repo" switch -q "$def" 2>/dev/null; then
      echo "WARN launchpad $name: cannot switch to $def (another worktree may hold it: git worktree list), not healed"
      return
    fi
    echo "launchpad $name: healed, switched '$state' -> $def (branch left intact)"
  fi

  if is_harness_checkout "$repo"; then
    sync_harness "$repo" "$heal"
    return
  fi

  if declare -F repo_fetch_origin >/dev/null; then
    if ! repo_fetch_origin "$repo" "$FETCH_T"; then
      echo "launchpad $name: fetch failed ($REPO_FETCH_WHY), skipped"
      return
    fi
  elif ! timeout "$FETCH_T" git -C "$repo" fetch --quiet origin; then
    echo "launchpad $name: fetch failed (lib/repo-update.sh not loaded; git's error is above), skipped"
    return
  fi
  behind=$(git -C "$repo" rev-list --count "HEAD..origin/$def" 2>/dev/null || echo 0)
  if [ "$behind" -eq 0 ]; then
    echo "launchpad $name: fresh"
    return
  fi
  # A tracked modification only blocks a fast-forward when it sits on a path the
  # update actually changes. Refusing on a blanket count conflated "dirty" with
  # "in the way" and permanently stranded any launch pad whose own writers keep a
  # file dirty: a private research repository's SEC watchers must run in the main checkout (that is
  # where the live db is) and rewrite data/research/_watchers/*.json on every poll,
  # so that checkout sat 6 commits behind across four merged PRs -- including the
  # one that fixed the report it renders -- and no session could heal it (#1094).
  #
  # The guarded merge below is the gate, and it is the STRICTER of the two: git
  # refuses exactly the overlaps that would clobber local work, and autostash stays
  # off so a dirty overlap can never be stashed and reapplied behind the caller's
  # back (the 2026-09-03 papercut: a plain --ff-only pull autostashed 35 tracked
  # mods and lost the re-apply). repo_ff_update() in lib/repo-update.sh answers the
  # same question the same way; this path kept a second, cruder answer, and the
  # crude one silently won. $tracked survives only as a cosmetic count now, so its
  # staleness as a pre-fetch snapshot can no longer decide anything.
  if [ "$DRY" = "1" ]; then
    nblock=0
    if declare -F repo_ff_blockers >/dev/null 2>&1; then
      nblock=$(repo_ff_blockers "$repo" "$def" 2>/dev/null | tr -cd '\0' | wc -c | tr -d '[:space:]')
      [ -n "$nblock" ] || nblock=0
    fi
    if [ "$nblock" -gt 0 ]; then
      echo "launchpad $name: would REFUSE ff of $behind commit(s): $nblock local path(s) collide with incoming changes (DRY_RUN)"
    elif [ "$tracked" -gt 0 ]; then
      echo "launchpad $name: would fast-forward $behind commit(s), carrying $tracked unrelated local edit(s) (DRY_RUN)"
    else
      echo "launchpad $name: would fast-forward $behind commit(s) (DRY_RUN)"
    fi
    return
  fi
  if mergeerr=$(git -C "$repo" -c merge.autostash=false merge --ff-only --quiet "origin/$def" 2>&1); then
    if [ "$tracked" -gt 0 ]; then
      echo "launchpad $name: fast-forwarded $behind commit(s), carried $tracked unrelated local edit(s)"
    else
      echo "launchpad $name: fast-forwarded $behind commit(s)"
    fi
  else
    # Name the cause and the files. "diverged or untracked collision" told the
    # operator which two things it might be and nothing about which, so the
    # message could be read for four days without acting on it (dotfiles#484).
    echo "WARN launchpad $name: ff-only merge failed, not touched"
    if declare -F repo_ff_explain >/dev/null 2>&1; then
      repo_ff_explain "$repo" "$def" "  " "$mergeerr"
    else
      echo "  (local $def diverged, or untracked files sit on incoming paths)"
    fi
  fi
}

if [ "${1:-}" = "--repo" ]; then
  REPO=${2:?usage: launchpad-freshen.sh --repo <path> [--heal]}
  HEAL=0
  [ "${3:-}" = "--heal" ] && HEAL=1
  [ -e "$REPO/.git" ] || { echo "launchpad $(basename "$REPO"): not a git repo, skipped"; exit 0; }
  process_repo "$REPO" "$HEAL"
  exit 0
fi

ROOT=${SITES_ROOT:-$HOME/SITES}
[ -d "$ROOT" ] || { echo "launchpad-freshen: $ROOT missing, nothing to do"; exit 0; }
for repo in "$ROOT"/*/; do
  [ -e "$repo/.git" ] || continue
  process_repo "${repo%/}" 0
done
exit 0
