#!/usr/bin/env bash
# wt-sweep — safe, reusable git-worktree fleet cleanup.
#
#   DRY_RUN=1 (default) prints the plan; DRY_RUN=0 executes.
#   PUSH=1 also pushes preserved branches to origin (default 0 = keep local).
#   WT_SWEEP_ALLOW_TMP=1 also sweeps worktrees under /tmp (test suites only; never
#   set it on the timer -- a live job's scratch lives there).
#   ROOT=<dir> sweeps exactly that one directory of repos. Default is ~/SITES
#     AND $HOME's direct children, so repos outside ~/SITES — dotfiles most of
#     all — are swept too; see lib/wt-roots.sh and issue #511.
#   ONLY=<name> restrict to one repo. ACTIVE_MIN=120 — skip worktrees touched
#   within this many minutes (assumed owned by a live session).
#
# Policy (smart-selective, zero-loss):
#   clean & all commits on remote ............ remove worktree
#   has unique work (tracked OR untracked), not abandoned .. WIP-commit ALL changes (add -A), keep branch local, remove worktree
#   abandoned (>14d old & >150 behind, <2 unpushed, no untracked) .. bundle to ~/.claude/git-archive/<repo>/, remove worktree, delete branch
#   no remote configured ..................... bundle --all as backup, leave worktree in place
#   recently active / under /tmp or .claude/jobs ..... SKIP (a live job owns it)
#   any live process has its cwd inside ...... SKIP (/proc scan — mtime alone is not liveness)
#
# Branches are NEVER force-deleted while they hold >=2 unpushed commits.
# Removing a worktree never deletes commits — the branch persists in the repo.
# Destructive steps run ONLY after their preservation step (bundle / WIP commit) succeeds.
set -uo pipefail
# ROOT is deliberately NOT defaulted here — lib/wt-roots.sh owns the default so
# this script and wt-new.sh cannot silently drift apart again (issue #511).
DRY_RUN="${DRY_RUN:-1}"; PUSH="${PUSH:-0}"
ONLY="${ONLY:-}"; ACTIVE_MIN="${ACTIVE_MIN:-120}"
# Preview reads must not refresh an index or acquire optional Git locks. Every
# mutation is separately routed through run(), but status itself may otherwise
# rewrite index metadata while answering a read-only question.
# Unconditional since dotfiles#1590: run()'s mutations take mandatory locks
# regardless, and a status probe killed mid-write under DRY_RUN=0 leaves a
# zero-byte index.lock that dcg will not let an agent remove.
export GIT_OPTIONAL_LOCKS=0
# Shared liveness implementation (fd+cwd+cmdline) — lib/proc_liveness.py, also
# used by reclaim-sweep.py (issue #378). Overridable so the test suite can point
# alive() at the checkout's copy (and at a broken path for the fail-closed case).
LIB="${WT_SWEEP_LIB:-$(dirname "$(readlink -f "$0")")/lib}"
# Root discovery is shared with wt-new.sh, and is the one thing that decides
# whether a repo is even a candidate — so it is sourced, not reimplemented.
. "$LIB/wt-roots.sh"
# Merged-PR anchors (refs/remotes/pr-merged/<branch>) written by wt-done.sh: the
# anchor-excluded unshipped count and the orphan listing are shared, not copied.
# Missing lib = refuse to run: this script has no errexit, so without the guard every
# unshipped count would read empty, i.e. 0, and the clean path force-removes.
# shellcheck source=SCRIPTDIR/lib/wt-anchor.sh
. "$LIB/wt-anchor.sh" 2>/dev/null || { echo "wt-sweep: cannot load $LIB/wt-anchor.sh" >&2; exit 1; }
# Merge-anchored closeout (issue #589). A squash-merged branch whose remote ref
# GitHub auto-deleted has commits reachable from no durable ref, so `unp` below
# counts already-shipped work as unique and this sweep preserves it forever --
# 69 dotfiles worktrees were stuck exactly there on 2026-08-28. wt-done.sh proves
# the tip is byte-identical to the PR's merge commit and moves the pointer onto
# it; `unp` then reads 0 and the EXISTING clean-removal path below does the rest.
# Overridable so the test suite can point at a checkout copy, and simply skipped
# when absent -- an older wt-done (or none) must degrade to the old behaviour,
# never to an error.
WT_DONE="${WT_DONE_BIN:-$(dirname "$(readlink -f "$0")")/wt-done.sh}"
STAMP="$(date +%Y%m%d)"; AGE_ALIVE_DAYS=14; BEHIND_STALE=150
now=$(date +%s); declare -A seen
n_rm=0; n_keep=0; n_drop=0; n_bundle=0; n_skip=0; n_leave=0; n_route=0; n_anchor=0
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/pr-owner-state.sh
. "$HERE/lib/pr-owner-state.sh" || { echo 'wt-sweep: cannot load PR-owner state contract' >&2; exit 1; }
ROUTE_RESOLVER="${REPO_ROUTE_RESOLVER:-$HERE/repo-route.py}"
# This scan happens before `worktree prune` and every removal path. A verified,
# registered canonical common-dir may proceed to the existing safety gates even
# when the route also has independent clones. Independent or incompletely proven
# common-dirs remain excluded in every rollout mode.
# One scan per root. The result is a `|`-delimited set of git-common-dirs, so the
# roots' answers concatenate without re-parsing. EVERY root must scan cleanly: a
# resolver that cannot answer for one root leaves that root's repos unguarded, and
# sweeping the others anyway would be exactly the partial-coverage failure this
# whole change exists to remove.
#
# The two failure stages stay separate, and so do their two messages. Collapsing
# the resolver call into the parser's pipeline made "scan failed" unreachable --
# an unrunnable resolver just fed the parser empty stdin and came back as a parse
# error, losing the distinction between "the resolver did not run" and "the
# resolver answered something we do not trust". Both strings are a contract:
# repo-route-maintenance.test.sh greps for the second one verbatim.
ROUTE_SKIP_COMMON=""
while IFS= read -r _root; do
_scan=$(python3 "$ROUTE_RESOLVER" scan --sites-root "$_root" --format json 2>/dev/null) || {
  echo "WARN wt-sweep: repo-route scan failed; refusing all mutations (root: $_root)" >&2
  exit 1
}
_skip=$(printf '%s' "$_scan" | python3 -c '
import json, os, sys

def path(value):
 return (isinstance(value, str) and bool(value) and os.path.isabs(value)
         and os.path.normpath(value) == value)

def authority_evidence(entry, group_route):
 canonical=entry.get("canonical_path")
 recorded=entry.get("recorded_common_dir")
 identity=entry.get("canonical_identity")
 mode=entry.get("mode")
 if not (entry.get("verified") is True
         and entry.get("authority_registered") is True
         and entry.get("canonical_missing") is False
         and entry.get("route") == group_route
         and mode in {"observe", "warn", "enforce"}
         and isinstance(identity, str) and bool(identity)
         and path(canonical) and path(recorded)):
  return None
 return canonical, recorded, identity, mode

def canonical_proof(entry, group_route):
 classification=entry.get("classification")
 common=entry.get("common_dir")
 recorded=entry.get("recorded_common_dir")
 canonical=entry.get("canonical_path")
 top=entry.get("top_level")
 base=(authority_evidence(entry, group_route) is not None
       and path(common) and common == recorded
       and path(top) and entry.get("repo") == top)
 if not base:
  return False
 if classification == "canonical":
  return top == canonical and entry.get("git_dir") == common
 if classification == "canonical-sibling":
  return top != canonical
 return False

try:
 d=json.load(sys.stdin)
 if d.get("schema") != "repo-route-scan.v1": raise ValueError("unexpected scan schema")
 if d.get("verified") is not True: raise ValueError("scan unverified")
 groups=d.get("routes")
 if not isinstance(groups, list): raise ValueError("routes is not a list")
 out=[]
 for group in groups:
  if not isinstance(group, dict): raise ValueError("route group is not an object")
  route=group.get("route")
  if not isinstance(route, str) or not route: raise ValueError("route id missing")
  for field in ("unverified", "canonical_missing", "collision", "authority_missing"):
   if not isinstance(group.get(field), bool): raise ValueError("route flags incomplete")
  entries=group.get("entries")
  if not isinstance(entries, list) or not entries: raise ValueError("route entries incomplete")
  group_blocked=(group["unverified"] or group["canonical_missing"]
                 or group["authority_missing"])
  if not group_blocked:
   evidence=[authority_evidence(entry, route) for entry in entries]
   if any(item is None for item in evidence) or len(set(evidence)) != 1:
    group_blocked=True
  for entry in entries:
   if not isinstance(entry, dict) or not path(entry.get("common_dir")):
    raise ValueError("route entry common-dir missing or invalid")
   common=entry["common_dir"]
   if group_blocked or not canonical_proof(entry, route):
    out.append(common)
 print("|" + "|".join(sorted(set(out))) + "|")
except Exception as e:
 print("__ERROR__:" + str(e))
' 2>/dev/null) || _skip="__ERROR__"
# `__ERROR__*`, not `__ERROR__:*`. The `||` above sets a BARE `__ERROR__` with no
# colon when python itself cannot start, which the colon-anchored pattern never
# matched — so an unrunnable resolver fell through with an empty skip-list and
# swept every repo unguarded. A guard that cannot answer must refuse, not wave
# through; the colon form only ever caught the case where python ran fine.
case "$_skip" in
  ""|__ERROR__*) echo "WARN wt-sweep: repo-route scan result unverified; refusing all mutations (root: $_root)" >&2; exit 1 ;;
esac
ROUTE_SKIP_COMMON="$ROUTE_SKIP_COMMON$_skip"
done < <(wt_roots)

# On failure git's own reason follows the FAILED line, indented and capped at five
# lines: a bare "!! FAILED" left the journal silent on why a removal refused.
run(){ local out; if [ "$DRY_RUN" = 1 ]; then echo "      would: $*"; return 0; fi
  if out=$(eval "$@" 2>&1); then echo "      ok: $*"; return 0; fi
  echo "      !! FAILED: $*"; [ -n "$out" ] && printf '%s\n' "$out" | head -n 5 | sed 's/^/         /'; return 1; }
# ALIVE_BEGIN (extracted verbatim by tests/wt-sweep-alive.test.sh — keep markers)
# a worktree is live if ANY process holds an open fd inside it, has its cwd at/inside
# it, carries it in its environment, or names it in its cmdline. A daemon can hold a
# worktree via a --cwd FLAG while its own process cwd is elsewhere (detached,
# reparented to init), which /proc/*/cwd cannot see. Sweeping out from under one
# leaves an orphan writing forever: on 2026-08-06 a codex app-server-broker survived
# its swept worktree and wrote ~400 GiB over 15 days (37 GiB/day) into
# ~/.codex/logs_2.sqlite before anyone noticed. See scripts/agent-write-guard.py.
# All four signals live in ONE shared implementation, lib/proc_liveness.py, shared
# with reclaim-sweep.py (issue #378); it excludes its own pid, so it cannot match
# the path in its own argv.
# Erring toward "alive" only defers a sweep; erring the other way silently burns SSD
# endurance, so the asymmetry is intentional — and a checker that cannot answer
# (missing lib, unreadable /proc: rc>=2) reads as ALIVE, never as dead.
alive(){ python3 "${LIB:?}/proc_liveness.py" --quiet -- "$1" >/dev/null 2>&1
  case $? in 0) return 0;; 1) return 1;;
    *) echo "      !! proc_liveness unavailable — treating as live: $1" >&2; return 0;; esac; }
# ALIVE_END
def_of(){ local r="$1" d
  d=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null|sed 's@^origin/@@')
  [ -z "$d" ] && for c in main master; do git -C "$r" rev-parse --verify -q "origin/$c">/dev/null 2>&1 && { d=$c;break;}; done
  [ -z "$d" ] && d=$(git -C "$r" branch -r 2>/dev/null|grep -v HEAD|head -1|sed 's@.*origin/@@;s/ //g')
  echo "${d:-main}"; }
# Orphan pr-merged anchors: the branch is gone (dropped by this sweep, or deleted by
# Agent View, ExitWorktree, or a human), so the anchor protects nothing. Deleting one
# never loses work -- it mirrors a server ref. Collected before acting, like the
# candidate list below.
prune_anchors(){ local a; local -a orphans
  mapfile -t orphans < <(wt_orphan_anchors "$1")
  for a in ${orphans[@]+"${orphans[@]}"}; do
    run "git -C '$1' update-ref -d '$a'" && n_anchor=$((n_anchor+1))
  done; }

# Collected up front rather than iterated as a stream: the loop body runs git
# commands that read stdin, which would eat a `while read` loop's input.
mapfile -t _candidates < <(wt_repo_candidates)

# Scope receipt. #511 survived 15 weekly green runs because the summary reported
# an OUTCOME (`removed:8`) and never its SCOPE -- and `removed:8` over the wrong
# root is indistinguishable from `removed:8` over the right one. Printing what was
# searched is what makes a future scope regression legible instead of silent.
printf 'roots: %s\n' "$(wt_roots | paste -sd' ' -)"
printf 'repos discovered: %d%s\n\n' "${#_candidates[@]}" \
  "$([ -n "$ONLY" ] && printf ' (ONLY=%s filter applies below)' "$ONLY")"
for dir in ${_candidates[@]+"${_candidates[@]}"}; do
  dir="${dir%/}"; git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || continue
  cdir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null); case "$cdir" in /*) ;; *) cdir="$dir/$cdir";; esac
  cdir=$(realpath -m "$cdir" 2>/dev/null); [ -n "${seen[$cdir]:-}" ] && continue; seen[$cdir]=1
  repo=$(dirname "$cdir"); name=$(basename "$repo")
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  case "$ROUTE_SKIP_COMMON" in *"|$cdir|"*)
    echo "### $name (repo-route authority/collision guard; skipped before prune/removal)"
    n_route=$((n_route+1))
    continue ;;
  esac
  mapfile -t paths < <(git -C "$repo" worktree list --porcelain 2>/dev/null|awk '/^worktree /{print $2}')
  # Before the worktree pass too, so a repo with no linked worktree left still sheds
  # the anchors of branches deleted since the last sweep.
  prune_anchors "$repo"
  (( ${#paths[@]} > 1 )) || continue
  run "git -C '$repo' worktree prune"
  def=$(def_of "$repo"); has_remote=0; git -C "$repo" remote 2>/dev/null|grep -q . && has_remote=1
  has_def=0; git -C "$repo" rev-parse --verify -q "origin/$def">/dev/null 2>&1 && has_def=1
  arch="$HOME/.claude/git-archive/$(basename "$repo")/$STAMP"
  echo "### $name (def=$def remote=$([ $has_remote = 1 ]&&echo yes||echo no))"
  for wt in "${paths[@]:1}"; do
    [ -d "$wt" ] || continue
    # --- skip live worktrees ---
    if [ "${WT_SWEEP_ALLOW_TMP:-0}" != 1 ]; then
      case "$wt" in */.claude/jobs/*|/tmp/*) echo "  ~ skip (job/tmp): $wt"; n_skip=$((n_skip+1)); continue;; esac
    fi
    mt=$(stat -c %Y "$wt" 2>/dev/null||echo 0); if (( (now-mt)/60 < ACTIVE_MIN )); then echo "  ~ skip (active <${ACTIVE_MIN}m): $(basename "$wt")"; n_skip=$((n_skip+1)); continue; fi
    if alive "$wt"; then echo "  ~ skip (held by live process): $(basename "$wt")"; n_skip=$((n_skip+1)); continue; fi
    if pr_owner_worktree_owned "$wt"; then echo "  ~ skip (PR owner): $(basename "$wt")"; n_skip=$((n_skip+1)); continue; fi
    base=$(basename "$wt"); bf="${base//\//_}"
    br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null||echo ""); det=0; [ -z "$br" ]&&det=1
    porc=$(git -C "$wt" status --porcelain 2>/dev/null)
    trk=$(printf '%s' "$porc"|grep -vc '^??'); [ -z "$porc" ]&&trk=0
    unt=$(printf '%s' "$porc"|grep -c '^??'); [ -z "$porc" ]&&unt=0
    # pr-merged anchors are excluded: they make a proven tip closable in Agent View,
    # but the branch is only dropped below when wt-done re-proves it and prints
    # WT_DONE_PROOF=head. Counting them would send an anchored worktree down the
    # clean path with its branch kept as litter.
    # A count that cannot be read is not 0: the clean path below force-removes.
    if ! unp=$(wt_unshipped_count "$wt") || [ -z "$unp" ]; then
      echo "  ~ skip (cannot count unshipped commits; nothing removed): $(basename "$wt")"; n_skip=$((n_skip+1)); continue
    fi
    # HEAD as wt-done will see it. Its proof is spent below only while HEAD is still
    # this commit, so a commit landing after the proof is never force-removed with it.
    head0=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null)
    # Reconcile BEFORE the metrics are printed, so the DRY_RUN plan predicts what
    # DRY_RUN=0 will actually do instead of reporting a removal it would skip.
    # --reconcile-only: this loop already owns worktree removal, and it must stay
    # the single place that decides it.
    shipped_tip=0
    if [ "$unp" -gt 0 ] && [ $det = 0 ] && [ "$trk" = 0 ] && [ "$unt" = 0 ] && [ -x "$WT_DONE" ]; then
      if rec_out=$(DRY_RUN="$DRY_RUN" "$WT_DONE" --reconcile-only "$wt" 2>&1); then
        echo "      ~ merge-anchored reconcile: branch shipped via a merged PR (wt-done.sh)"
        # Proof A (GitHub's exact merged head; trees differ because main moved on): the
        # pointer stays put on purpose, so re-reading `unp` would still count shipped
        # commits as value and park the worktree in the preserve path below -- branch
        # kept as litter, or re-pushed under PUSH=1 (reproduced on a fixture, #842).
        # wt-done's whole-line machine line is the authority, exactly as in its own
        # full-mode disposal; grep -x so an echoed branch name can never collide.
        grep -qx 'WT_DONE_PROOF=head' <<<"$rec_out" && shipped_tip=1
        if [ "$DRY_RUN" = 1 ] || [ "$shipped_tip" = 1 ]; then unp=0
        elif ! unp=$(wt_unshipped_count "$wt") || [ -z "$unp" ]; then
          echo "      ~ skip (cannot count unshipped commits after reconcile; nothing removed)"; n_skip=$((n_skip+1)); continue
        fi
      fi
    fi
    [ $has_def = 1 ] && behind=$(git -C "$wt" rev-list --count "HEAD..origin/$def" 2>/dev/null) || behind=0; behind=${behind:-0}
    ct=$(git -C "$wt" log -1 --format=%ct 2>/dev/null||echo "$now"); age=$(( (now-ct)/86400 ))
    printf '  • %-44s trk:%s unt:%s unpush:%s behind:%s age:%sd\n' "${br:-$base}" "$trk" "$unt" "$unp" "$behind" "$age"

    if [ $has_remote = 0 ]; then
      run "mkdir -p '$arch'"; run "git -C '$wt' bundle create '$arch/$bf.bundle' --all"
      echo "      => keep in place (no remote; bundled)"; n_bundle=$((n_bundle+1)); n_leave=$((n_leave+1)); continue
    fi
    has_value=0; [ "$trk" -gt 0 ]&&has_value=1; [ "$unt" -gt 0 ]&&has_value=1; [ "$unp" -gt 0 ]&&has_value=1
    if [ $has_value = 0 ]; then
      # On the proof path unp was zeroed by wt-done's word, not counted, and wt-done ran
      # network round trips since trk/unt were read. Spend the proof only on the commit
      # it was about, in the state it was checked in.
      if [ "$shipped_tip" = 1 ] && [ "$DRY_RUN" != 1 ] &&
         { [ "$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null)" != "$head0" ] ||
           [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; }; then
        echo "      => SKIP (worktree changed after wt-done's proof; nothing removed)"; n_skip=$((n_skip+1)); continue
      fi
      if run "git -C '$repo' worktree remove --force '$wt'"; then
        n_rm=$((n_rm+1))
        # Head-proof branches sit on no durable ref by construction, so `branch -d` would
        # refuse; -D is authorised by GitHub naming this exact tip as the commit it merged.
        # Counted as dropped, not preserved: the first draft of this path reported one
        # worktree as both `preserved-local:1` and `dropped:1`.
        if [ "$shipped_tip" = 1 ] && [ $det = 0 ] && [ "$br" != "$def" ] \
           && run "git -C '$repo' branch -D '$br'"; then n_drop=$((n_drop+1))
        else n_keep=$((n_keep+1)); fi
      fi
      continue
    fi
    # untracked files never qualify for the bundle-and-drop path (bundles hold commits, not untracked)
    stale=0; (( age>AGE_ALIVE_DAYS && behind>BEHIND_STALE && unp<2 && unt==0 )) && stale=1
    if [ $stale = 1 ]; then
      ssha=""
      if [ "$trk" -gt 0 ]; then
        if [ "$DRY_RUN" = 1 ]; then
          echo "      would: capture tracked changes for the bundle (no stash objects written in dry run)"
          ssha="'<tracked-changes capture on apply>'"
        elif ! ssha=$(git -C "$wt" stash create "wt-sweep $STAMP") || [ -z "$ssha" ]; then
          echo "      => SKIP (tracked changes could not be captured — nothing removed)"
          n_skip=$((n_skip+1)); continue
        fi
      fi
      if run "mkdir -p '$arch'" && run "git -C '$wt' bundle create '$arch/$bf.bundle' HEAD $ssha"; then
        echo "      => DROP (abandoned; bundled to $arch/$bf.bundle)"; n_bundle=$((n_bundle+1))
        if run "git -C '$repo' worktree remove --force '$wt'"; then
          n_rm=$((n_rm+1))
          [ $det = 0 ] && [ "$br" != "$def" ] && run "git -C '$repo' branch -D '$br'" && n_drop=$((n_drop+1))
        fi
      else
        echo "      => SKIP (bundle failed — nothing removed)"; n_skip=$((n_skip+1))
      fi
    else
      echo "      => preserve (branch kept local$([ $PUSH = 1 ]&&echo ', pushed'))"
      if [ "$trk" -gt 0 ] || [ "$unt" -gt 0 ]; then
        if ! run "git -C '$wt' add -A" || ! run "git -C '$wt' commit --no-verify -m 'wip: archive before wt-sweep $STAMP'"; then
          echo "      => SKIP (WIP commit failed — nothing removed)"; n_skip=$((n_skip+1)); continue
        fi
      fi
      [ $PUSH = 1 ] && [ $det = 0 ] && run "git -C '$wt' push -u origin '$br'"
      run "git -C '$repo' worktree remove --force '$wt'" && { n_rm=$((n_rm+1)); n_keep=$((n_keep+1)); }
    fi
  done
  # Anchors of the branches this pass just dropped. A DRY_RUN plan cannot list
  # those (the branches still exist), and re-listing the pre-pass orphans would
  # double-count them.
  [ "$DRY_RUN" = 1 ] || prune_anchors "$repo"
done

# External-workspace advisory (dotfiles #908). A skill that emits a whole sibling bundle
# names it <project>__<skill>_workspace/ beside the repo; de-monolithize is the one such
# skill today (<project>__demonolith_workspace/, e.g. ~/SITES/<project>__demonolith_workspace).
# wt_roots yields the roots the repos live under (~/SITES, ~), so the bundles sit directly
# under each root. Past AGE_ALIVE_DAYS — the same threshold as an abandoned worktree — they
# are almost always forgotten. Warn only, never delete: the skill that made one says when it
# is consumed, and nothing here can know that.
n_ws=0; now=$(date +%s)
while IFS= read -r ws; do
  [ -n "$ws" ] && [ -d "$ws" ] || continue
  wsb=$(basename "$ws")
  [ -n "$ONLY" ] && [ "${wsb%%__*}" != "$ONLY" ] && continue   # ONLY=<repo> scopes this too
  # An unreadable mtime reads as epoch 0, i.e. maximally old, the same way line ~160 treats
  # a worktree whose stat fails: a bundle we cannot date is a bundle to look at, not to hide.
  age=$(( (now - $(stat -c %Y "$ws" 2>/dev/null || echo 0)) / 86400 ))
  if (( age > AGE_ALIVE_DAYS )); then
    echo "  • external workspace ${ws} is ${age}d old (>${AGE_ALIVE_DAYS}d): consume it or delete it by hand"
    n_ws=$((n_ws+1))
  fi
done < <(wt_roots | while IFS= read -r r; do ls -d "$r"/*__*_workspace 2>/dev/null; done | sort -u)

echo; echo "===== wt-sweep $([ $DRY_RUN = 1 ]&&echo '(DRY RUN)') ====="
printf 'scope: %d repos under %s\n' "${#_candidates[@]}" "$(wt_roots | paste -sd' ' -)"
printf 'removed:%d  preserved-local:%d  dropped:%d  bundled:%d  kept-in-place:%d  skipped-active:%d  stale-workspaces:%d  skipped-route:%d  anchors-pruned:%d\n' \
  "$n_rm" "$n_keep" "$n_drop" "$n_bundle" "$n_leave" "$n_skip" "$n_ws" "$n_route" "$n_anchor"
[ $DRY_RUN = 1 ] && echo "(dry run — re-run with DRY_RUN=0 to apply)"
exit 0