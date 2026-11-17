#!/usr/bin/env bash
# wt-sweep-fresh-work.test.sh — fresh local work holds a worktree (hov-stack#721).
#
# THE DEFECT THIS GUARDS (the live sweep of 2026-11-17)
#   A working job drove its worktree only through `bash <file>` scripts and a Codex
#   run, so no tool call named the worktree and wt_session_hold found no holder.
#   Its edits were all below the top directory, whose mtime was hours old, so the
#   ACTIVE_MIN gate passed too. The sweep sent it down the preserve path: a WIP
#   commit, then `worktree remove --force`, under the job.
#
#   Now a worktree whose newest uncommitted or unshipped work is younger than
#   FRESH_WORK_HOURS (24 by default) is skipped before the WIP-commit and bundle
#   paths. Every hold case below has a twin 25 h old that goes on exactly as
#   before, so the guard cannot pass by holding everything. Each worktree's top
#   directory is dated a day back and ACTIVE_MIN is 120, and the plan is checked
#   for the guard's own message, so the ACTIVE_MIN gate is never what holds it.
#
#   No-claim: green does not show that gitignored work, or an edit inside a nested
#   checkout or submodule, is seen (`git status` does not list either, so neither
#   does the guard), nor that the window is the right size. Case 12's plan/apply
#   parity runs with wt-done stubbed out; a branch wt-done reconciles is counted
#   shipped in a plan and re-counted on apply, which this suite does not cover.
#
#   Hermetic: bare origin + repo + worktrees under mktemp, an empty fake Claude home
#   (no session names any worktree here), HOME under mktemp for the stale path's
#   bundles, the repo-route resolver stubbed to a verified empty scan. Never touches
#   the operator's tree, remotes, ~/.claude, or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset FRESH_WORK_HOURS   # the default is what most cases test

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3')";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (want '$2', got '$3')"; }
kept(){ [ -d "$2" ] && ok "$1" || no "$1 (worktree $2 is gone)"; }
gone(){ [ -d "$2" ] && no "$1 (worktree $2 still there)" || ok "$1"; }

cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"
EMPTY="$TMP/claude-empty"; mkdir -p "$EMPTY" "$TMP/home"

# ROOT=$TMP/$1 holding one repo (origin outside the root) and one worktree per
# further argument, $TMP/$1/<name> on branch <name>, pushed: clean and shipped.
# Each holds sub/f.txt, sub/g.txt and source/s.txt (a directory name longer than the
# three status characters, for case 13). Dates come from the caller's environment.
mkfix(){
  local d="$TMP/$1" w; shift
  {
    mkdir -p "$d/repo/sub" "$d/repo/source"
    git init --bare -q -b main "$d-origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$d-origin.git"
    echo f >"$d/repo/sub/f.txt"; echo g >"$d/repo/sub/g.txt"; echo base >"$d/repo/base.txt"
    echo s >"$d/repo/source/s.txt"
    git -C "$d/repo" add -A; git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    for w in "$@"; do
      git -C "$d/repo" worktree add -q "$d/$w" -b "$w" main
      git -C "$d/$w" push -q -u origin "$w"
    done
  } >/dev/null 2>&1
}
ago(){ printf '%s +0000' "$(( $(date +%s) - $1 ))"; }
# Two unshipped commits on worktree $1, the newer one $2 seconds old.
unshipped(){
  { echo one >>"$1/base.txt"; git -C "$1" add -A
    GIT_AUTHOR_DATE="$(ago $(( $2 + 3600 )))" GIT_COMMITTER_DATE="$(ago $(( $2 + 3600 )))" git -C "$1" commit -qm one
    echo two >>"$1/base.txt"; git -C "$1" add -A
    GIT_AUTHOR_DATE="$(ago "$2")" GIT_COMMITTER_DATE="$(ago "$2")" git -C "$1" commit -qm two; } >/dev/null 2>&1
  touch -d '-2 days' "$1/base.txt"
}
settle(){ touch -d '-1 day' "$@"; }   # the top directory: the ACTIVE_MIN gate must pass
sweep(){ # $1 root  $2 DRY_RUN  [$3 lib dir]; FRESH_WORK_HOURS comes from the caller
  HOME="$TMP/home" DRY_RUN="$2" ROOT="$1" WT_CLAUDE_HOME="$EMPTY" WT_HOLD_CACHE_DIR="$TMP/hold-cache" \
    WT_DONE_BIN="$TMP/no-wt-done" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 \
    ACTIVE_MIN=120 PUSH=0 WT_SWEEP_LIB="${3:-$HERE/../scripts/lib}" bash "$SCRIPT" 2>&1
}
state(){ git -C "$1" rev-parse HEAD 2>/dev/null; git -C "$1" status --porcelain 2>/dev/null; }
wips(){ git -C "$1" log --all --format=%s 2>/dev/null | grep -c -F 'wip: archive before wt-sweep'; }
# The plan must stay off the gates the guard is not: the ACTIVE_MIN gate and the
# session check. Otherwise a hold could be theirs.
notothers(){
  hasnot "$1: not held by the ACTIVE_MIN gate" "$2" "skip (active"
  hasnot "$1: not held by a session" "$2" "Claude session"
}

echo "wt-sweep — fresh local work holds a worktree (#721)"

# --- 1. a tracked file modified 1 h ago, in a subdirectory: held, nothing written --
mkfix dirty dirty; WT="$TMP/dirty/dirty"
echo edited >>"$WT/sub/f.txt"; touch -d '-1 hour' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
before=$(state "$WT")
out=$(sweep "$TMP/dirty" 1)
has "fresh edit, plan: skip names the work and its age" "$out" \
  "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=24: sub/f.txt; nothing removed)"
hasnot "fresh edit, plan: no preserve planned" "$out" "=> preserve"
notothers "fresh edit" "$out"
out=$(sweep "$TMP/dirty" 0)
kept "fresh edit, apply: worktree kept" "$WT"
chk "fresh edit, apply: HEAD and status unchanged" "$before" "$(state "$WT")"
chk "fresh edit, apply: no WIP commit" 0 "$(wips "$TMP/dirty/repo")"
has "fresh edit, apply: counted as skipped" "$out" "removed:0  preserved-local:0"

# --- 2. its twin, 25 h old: the preserve path runs as before ------------------------
mkfix dirtyold dirtyold; WT="$TMP/dirtyold/dirtyold"
echo edited >>"$WT/sub/f.txt"; touch -d '-25 hours' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
out=$(sweep "$TMP/dirtyold" 1)
has "old edit, plan: preserve" "$out" "=> preserve (branch kept local)"
hasnot "old edit, plan: no fresh-work skip" "$out" "local work"
out=$(sweep "$TMP/dirtyold" 0)
gone "old edit, apply: worktree removed" "$WT"
chk "old edit, apply: one WIP commit" 1 "$(wips "$TMP/dirtyold/repo")"
git -C "$TMP/dirtyold/repo" show dirtyold:sub/f.txt 2>/dev/null | grep -qx edited \
  && ok "old edit, apply: the edit is on the kept branch" || no "old edit, apply: the edit is on the kept branch"
has "old edit, apply: counted as preserved" "$out" "removed:1  preserved-local:1"

# --- 3. clean, unshipped commits, the newest 1 h old: held --------------------------
mkfix unp unp; WT="$TMP/unp/unp"
unshipped "$WT" 3600; settle "$WT"
ct=$(git -C "$WT" log -1 --format=%ct); age=$(( $(date +%s) - ct ))
(( age >= 3600 && age < 3700 )) && ok "fixture: newest commit is 1 h old" || no "fixture: newest commit is 1 h old (${age}s)"
[ -z "$(git -C "$WT" status --porcelain)" ] && ok "fixture: worktree clean" || no "fixture: worktree clean"
short=$(git -C "$WT" rev-parse --short HEAD); before=$(state "$WT")
out=$(sweep "$TMP/unp" 1)
has "fresh commit, plan: skip names the commit" "$out" \
  "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=24: unshipped commit $short; nothing removed)"
has "fresh commit, plan: counted unshipped" "$out" "unpush:2"
notothers "fresh commit" "$out"
out=$(sweep "$TMP/unp" 0)
kept "fresh commit, apply: worktree kept" "$WT"
chk "fresh commit, apply: HEAD unchanged" "$before" "$(state "$WT")"

# --- 4. its twin, 25 h old: preserved and removed as before -------------------------
mkfix unpold unpold; WT="$TMP/unpold/unpold"
unshipped "$WT" $(( 25 * 3600 )); settle "$WT"
tip=$(git -C "$WT" rev-parse HEAD)
out=$(sweep "$TMP/unpold" 1)
has "old commit, plan: preserve" "$out" "=> preserve (branch kept local)"
out=$(sweep "$TMP/unpold" 0)
gone "old commit, apply: worktree removed" "$WT"
chk "old commit, apply: branch kept at its tip" "$tip" "$(git -C "$TMP/unpold/repo" rev-parse -q --verify refs/heads/unpold)"
chk "old commit, apply: no WIP commit (nothing was uncommitted)" 0 "$(wips "$TMP/unpold/repo")"

# --- 5. a fresh file under an old untracked directory: each file is dated -----------
mkfix untr untr; WT="$TMP/untr/untr"
mkdir -p "$WT/newdir"; echo a >"$WT/newdir/a.txt"; touch -d '-1 hour' "$WT/newdir/a.txt"
touch -d '-25 hours' "$WT/newdir"; settle "$WT"
out=$(sweep "$TMP/untr" 1)
has "fresh file in old untracked dir: held, file named" "$out" "under FRESH_WORK_HOURS=24: newdir/a.txt; nothing removed"
touch -d '-25 hours' "$WT/newdir/a.txt" "$WT/newdir"
out=$(sweep "$TMP/untr" 1)
has "twin, 25 h old: preserve" "$out" "=> preserve (branch kept local)"

# --- 6. a tracked file deleted 1 h ago: dated by the directory the delete moved ------
mkfix del del; WT="$TMP/del/del"
rm "$WT/sub/f.txt"; touch -d '-1 hour' "$WT/sub"; settle "$WT"
out=$(sweep "$TMP/del" 1)
has "fresh delete: held, directory named" "$out" "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=24: sub; nothing removed)"
touch -d '-25 hours' "$WT/sub"
out=$(sweep "$TMP/del" 0)
gone "twin, 25 h old: removed" "$WT"
git -C "$TMP/del/repo" cat-file -e del:sub/f.txt 2>/dev/null \
  && no "twin: the delete is on the kept branch" || ok "twin: the delete is on the kept branch"

# --- 7. a staged rename: both of its paths are read, neither breaks the dating -----
mkfix ren ren; WT="$TMP/ren/ren"
git -C "$WT" mv sub/f.txt sub/h.txt; touch -d '-1 hour' "$WT/sub/h.txt"; touch -d '-25 hours' "$WT/sub"; settle "$WT"
out=$(sweep "$TMP/ren" 1)
has "fresh rename: held, new path named" "$out" "under FRESH_WORK_HOURS=24: sub/h.txt; nothing removed"
touch -d '-25 hours' "$WT/sub/h.txt" "$WT/sub"
out=$(sweep "$TMP/ren" 1)
has "twin, 25 h old: preserve" "$out" "=> preserve (branch kept local)"
hasnot "twin: dating did not fail on the rename's source" "$out" "cannot date"

# --- 8. the stale path: an old, far-behind branch with a fresh edit is held too -----
# The stale path dates only HEAD; a fresh edit on a 2020 branch used to be bundled
# and its branch deleted.
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' mkfix stale stale
parent=$(git -C "$TMP/stale/repo" rev-parse HEAD); tree=$(git -C "$TMP/stale/repo" rev-parse 'HEAD^{tree}')
for ((i=0; i<151; i++)); do parent=$(printf 'advance %s\n' "$i" | git -C "$TMP/stale/repo" commit-tree "$tree" -p "$parent"); done
{ git -C "$TMP/stale/repo" update-ref refs/heads/main "$parent"; git -C "$TMP/stale/repo" push -q origin main; } >/dev/null 2>&1
WT="$TMP/stale/stale"; ARCH="$TMP/home/.claude/git-archive"
echo edited >>"$WT/sub/f.txt"; touch -d '-1 hour' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
out=$(sweep "$TMP/stale" 1)
has "fixture: the branch reads as stale" "$out" "behind:151 age:"
has "stale, fresh edit, plan: held" "$out" "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=24: sub/f.txt; nothing removed)"
hasnot "stale, fresh edit, plan: no bundle planned" "$out" "bundle create"
out=$(sweep "$TMP/stale" 0)
kept "stale, fresh edit, apply: worktree kept" "$WT"
git -C "$TMP/stale/repo" rev-parse -q --verify refs/heads/stale >/dev/null && ok "stale, fresh edit, apply: branch kept" || no "stale, fresh edit, apply: branch kept"
[ -e "$ARCH" ] && no "stale, fresh edit, apply: no bundle written" || ok "stale, fresh edit, apply: no bundle written"
touch -d '-25 hours' "$WT/sub/f.txt"
out=$(sweep "$TMP/stale" 0)
has "stale twin, 25 h old: DROP as before" "$out" "=> DROP (abandoned"
gone "stale twin: worktree removed" "$WT"
[ -n "$(find "$ARCH" -name '*.bundle' 2>/dev/null)" ] && ok "stale twin: bundle written" || no "stale twin: bundle written"

# --- 9. FRESH_WORK_HOURS=0 turns the guard off -----------------------------------
mkfix off off; WT="$TMP/off/off"
echo edited >>"$WT/sub/f.txt"; touch -d '-1 hour' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
out=$(FRESH_WORK_HOURS=0 sweep "$TMP/off" 0)
has "knob 0: preserve as before" "$out" "=> preserve (branch kept local)"
gone "knob 0: worktree removed" "$WT"

# --- 10. PLANTED NEGATIVE: a knob that is not a whole number stops the sweep -------
mkfix bad bad; WT="$TMP/bad/bad"
echo edited >>"$WT/sub/f.txt"; touch -d '-25 hours' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
before=$(state "$WT")
out=$(FRESH_WORK_HOURS=24h sweep "$TMP/bad" 0); rc=$?
chk "bad knob: exits 2" 2 "$rc"
has "bad knob: says why" "$out" "FRESH_WORK_HOURS must be a whole number of hours, at most 9 digits (got '24h'); nothing swept"
kept "bad knob: worktree kept" "$WT"
chk "bad knob: nothing written" "$before" "$(state "$WT")"
out=$(FRESH_WORK_HOURS=0000000024 sweep "$TMP/bad" 0); rc=$?
chk "ten-digit knob: exits 2" 2 "$rc"
kept "ten-digit knob: worktree kept" "$WT"
chk "ten-digit knob: nothing written" "$before" "$(state "$WT")"

# --- 11. PLANTED NEGATIVE: work that cannot be dated keeps the worktree ------------
mkfix nodate nodate; WT="$TMP/nodate/nodate"
echo edited >>"$WT/sub/f.txt"; touch -d '-25 hours' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
cp -r "$HERE/../scripts/lib" "$TMP/lib-nodate"
printf '\nwt_newest_work(){ printf "planted failure"; return 1; }\n' >>"$TMP/lib-nodate/wt-preserve.sh"
before=$(state "$WT")
out=$(sweep "$TMP/nodate" 0 "$TMP/lib-nodate")
has "undatable: skip says why" "$out" "=> SKIP (cannot date local work: planted failure; nothing removed)"
kept "undatable: worktree kept" "$WT"
chk "undatable: nothing written" "$before" "$(state "$WT")"

# --- 12. the plan lists exactly what the apply does, on a mixed root ---------------
mkfix mix a-fresh b-old c-fresh d-old
echo edited >>"$TMP/mix/a-fresh/sub/f.txt"; touch -d '-1 hour' "$TMP/mix/a-fresh/sub/f.txt"
echo edited >>"$TMP/mix/b-old/sub/f.txt"; touch -d '-25 hours' "$TMP/mix/b-old/sub/f.txt"
unshipped "$TMP/mix/c-fresh" 3600; unshipped "$TMP/mix/d-old" $(( 25 * 3600 ))
for w in a-fresh b-old c-fresh d-old; do settle "$TMP/mix/$w/sub" "$TMP/mix/$w"; done
decisions(){ grep -E '^  • |=> |^removed:' | sed 's/ [0-9]*h old,/ Nh old,/'; }
plan=$(sweep "$TMP/mix" 1 | decisions)
apply=$(sweep "$TMP/mix" 0 | decisions)
chk "mixed root: plan and apply print the same decisions" "$plan" "$apply"
has "mixed root: two held, two preserved" "$apply" "removed:2  preserved-local:2  dropped:0  bundled:0  kept-in-place:0  skipped-active:2"
kept "mixed root: fresh dirty kept" "$TMP/mix/a-fresh"; kept "mixed root: fresh unshipped kept" "$TMP/mix/c-fresh"
gone "mixed root: old dirty removed" "$TMP/mix/b-old"; gone "mixed root: old unshipped removed" "$TMP/mix/d-old"

# --- 13. a rename only the work tree shows (` R`): its source is dated too ---------
# `mv` keeps the file's old mtime; only the source directory the move emptied is
# fresh. Before, the source field was read as a record of its own, cut to
# "rce/s.txt" and dated by the old top directory, so the worktree was preserved.
mkfix wren wren; WT="$TMP/wren/wren"
mkdir "$WT/dest"; mv "$WT/source/s.txt" "$WT/dest/s.txt"; git -C "$WT" add -N dest/s.txt
touch -d '-25 hours' "$WT/dest/s.txt" "$WT/dest"; touch -d '-1 hour' "$WT/source"; settle "$WT"
[ "$(git -C "$WT" status --porcelain=v1 -z | tr '\0' '|')" = ' R dest/s.txt|source/s.txt|' ] \
  && ok "fixture: git shows the rename in the work-tree column only" \
  || no "fixture: git shows the rename in the work-tree column only (got '$(git -C "$WT" status --porcelain=v1 -z | tr '\0' '|')')"
before=$(state "$WT")
out=$(sweep "$TMP/wren" 1)
has "work-tree rename: held, the emptied source directory named" "$out" \
  "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=24: source; nothing removed)"
notothers "work-tree rename" "$out"
out=$(sweep "$TMP/wren" 0)
kept "work-tree rename, apply: worktree kept" "$WT"
chk "work-tree rename, apply: no WIP commit" 0 "$(wips "$TMP/wren/repo")"
chk "work-tree rename, apply: HEAD and status unchanged" "$before" "$(state "$WT")"
touch -d '-25 hours' "$WT/source"
out=$(sweep "$TMP/wren" 1)
has "twin, 25 h old: preserve" "$out" "=> preserve (branch kept local)"

# --- 14. leading zeros are decimal: 08 is 8 hours, 010 is 10 ----------------------
# Bash arithmetic reads 08 as bad octal (the test errored to false and the edit was
# preserved) and 010 as 8 (a 9 h old edit was preserved).
mkfix oct oct; WT="$TMP/oct/oct"
echo edited >>"$WT/sub/f.txt"; touch -d '-1 hour' "$WT/sub/f.txt"; settle "$WT/sub" "$WT"
out=$(FRESH_WORK_HOURS=08 sweep "$TMP/oct" 0); rc=$?
chk "knob 08: sweep exits 0" 0 "$rc"
has "knob 08: held as 8 hours" "$out" "=> SKIP (local work 1h old, under FRESH_WORK_HOURS=8: sub/f.txt; nothing removed)"
kept "knob 08: worktree kept" "$WT"
touch -d '-9 hours' "$WT/sub/f.txt"
out=$(FRESH_WORK_HOURS=010 sweep "$TMP/oct" 0)
has "knob 010: a 9 h old edit held as under 10 hours" "$out" "=> SKIP (local work 9h old, under FRESH_WORK_HOURS=10: sub/f.txt; nothing removed)"
kept "knob 010: worktree kept" "$WT"
chk "knobs 08 and 010: no WIP commit" 0 "$(wips "$TMP/oct/repo")"

# --- 15. a worktree removed while it is being dated: the helper returns, refusing ---
# Another sweep or a closeout can remove it between `git status` and the dating.
# Before, the climb to the nearest existing directory reached "." and looped forever.
mkfix van van; WT="$TMP/van/van"
echo edited >>"$WT/sub/f.txt"
cat >"$TMP/vanish.sh" <<'SH'
set -u
. "$1/wt-preserve.sh"
# git status answers, then the worktree is moved away before anything is dated.
git(){ command git "$@"; local rc=$?; case " $* " in *" status "*) mv "$WT_VANISH" "$WT_VANISH.moved" ;; esac; return $rc; }
wt_newest_work "$WT_VANISH" 0
SH
out=$(WT_VANISH="$WT" timeout 30 bash "$TMP/vanish.sh" "$HERE/../scripts/lib" 2>&1); rc=$?
chk "vanished mid-scan: helper refuses rather than hangs" 1 "$rc"
has "vanished mid-scan: says why" "$out" "the worktree vanished during the scan"

echo
echo "wt-sweep-fresh-work: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
