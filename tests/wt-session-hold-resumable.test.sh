#!/usr/bin/env bash
# wt-session-hold-resumable.test.sh — a done job holds the worktree it can be
# resumed into (hov-stack#793).
#
# THE DEFECT
#   A background job whose turn has ended is `done`: the resting state of every job
#   left waiting for its user, overnight for instance. Its process is gone and, by
#   the time a sweep runs, so is the worktree lock. The helper let a done job hold
#   nothing, so wt-sweep removed its merged worktree, and resuming the job found it
#   gone ("Your worktree ... no longer exists ... The worktree binding has been
#   cleared"): 27 removals on one host in three days, every job resumed within 24
#   hours of its last turn.
#
#   Acceptance: a done job whose last turn ended within WT_RESUMABLE_HOURS (24)
#   holds the worktree it is bound to, by name (worktreePath/cwd), by its
#   transcript's project directory, or by its own transcript's last
#   `worktree-state` record; never as idle.
#   Planted negatives: the state.json mtime is not the clock when lastTerminalAt is
#   there; a binding a later record replaced or cleared binds nothing; an agent
#   transcript's binding is not the job's; the caller's own session never holds;
#   past the window, or with it at 0, the result is exactly the old one.
#
#   Hermetic: Claude homes, the transcript index cache and repos live under mktemp;
#   never touches the operator's ~/.claude, ~/.cache, remotes or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib"
HELPER="$LIB/wt_session_hold.py"
SWEEP="$HERE/../scripts/wt-sweep.sh"
[ -f "$HELPER" ] && [ -f "$SWEEP" ] || { echo "FAIL: cannot find $HELPER or $SWEEP"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
unset WT_RESUMABLE_HOURS WT_ALIAS_ROOTS

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (expected '$2', got '$3')"; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3': $2)";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }
kept(){ [ -d "$2" ] && ok "$1" || no "$1 (worktree $2 is gone)"; }
gone(){ [ -d "$2" ] && no "$1 (worktree $2 still there)" || ok "$1"; }

slug(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
iso(){ date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# The helper as wt-preserve.sh runs it, on a fixture home. ACTIVE_MIN 0: no
# transcript counts as recently written, so only the job records decide.
hold(){ local h=$1; shift; python3 "$HELPER" --active-min 0 --claude-home "$h" --cache-dir "$TMP/cache" "$@"; }
# A done job: $1 home, $2 job id, $3 session id, $4 launch dir, $5 transcript,
# $6 lastTerminalAt (JSON value, or "" for none).
job(){
  local last=""
  [ -n "$6" ] && last=",\"lastTerminalAt\":$6"
  mkdir -p "$1/jobs/$2"
  printf '{"state":"done","name":"overnight","sessionId":"%s","resumeSessionId":"%s","cwd":"%s","originCwd":"%s","linkScanPath":"%s","updatedAt":"%s"%s}\n' \
    "$3" "$3" "$4" "$4" "$5" "$(iso '-1 hour')" "$last" >"$1/jobs/$2/state.json"
}
# A transcript: a first user record launched in $3, then a worktree-state record
# per remaining argument (a path binds the session to it, "" clears the binding).
transcript(){
  local t=$1 sid=$2 launch=$3; shift 3
  mkdir -p "$(dirname "$t")"
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"%s","message":{"role":"user","content":"go"}}\n' \
    "$launch" "$sid" "$(iso '-6 hours')" >"$t"
  for b in "$@"; do bindrec "$b" "$sid" >>"$t"; done
  touch -d '-5 hours' "$t"
}
bindrec(){
  if [ -n "$1" ]; then
    printf '{"type":"worktree-state","worktreeSession":{"originalCwd":"/launch","worktreePath":"%s","worktreeName":"n","worktreeBranch":"b","sessionId":"%s"},"sessionId":"%s"}\n' "$1" "$2" "$2"
  else
    printf '{"type":"worktree-state","worktreeSession":null,"sessionId":"%s"}\n' "$2"
  fi
}
H5=$(iso '-5 hours'); H30=$(iso '-30 hours')

echo "wt_session_hold — a done job holds the worktree it can be resumed into (#793)"
W="$TMP/w"; mkdir -p "$W/repo/.claude/worktrees/a" "$W/repo/.claude/worktrees/b"
WA="$W/repo/.claude/worktrees/a"; WB="$W/repo/.claude/worktrees/b"; LAUNCH="$W/repo"

# --- 1. bound through its transcript's project directory, 5 hours idle: held -----
H="$TMP/h1"; T="$H/projects/$(slug "$WA")/sid-1.jsonl"
transcript "$T" sid-1 "$LAUNCH"; job "$H" r1 sid-1 "$LAUNCH" "$T" "\"$H5\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "slug-bound, 5h: held (exit 0)" 0 "$rc"
has "slug-bound, 5h: names the job and its last turn" "$out" 'job r1 "overnight" is done and can be resumed: its last turn ended 5.0h ago'
out=$(hold "$H" --idle-hours 1 -- "$WA"); rc=$?
chk "slug-bound, 5h, idle window 1h: held, never idle (exit 0)" 0 "$rc"
hasnot "slug-bound, idle window: no idle line" "$out" "idle: "
out=$(hold "$H" -- "$WB"); rc=$?
chk "slug-bound: another worktree under the launch dir is not held (exit 1)" 1 "$rc"

# --- 2. PLANTED NEGATIVE: the caller's own session never holds -------------------
out=$(hold "$H" --exclude-session sid-1 -- "$WA"); rc=$?
chk "slug-bound, own session excluded: not held (exit 1)" 1 "$rc"

# --- 3. past the window: exactly the old result ----------------------------------
job "$H" r1 sid-1 "$LAUNCH" "$T" "\"$H30\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "slug-bound, 30h: not held (exit 1)" 1 "$rc"
has "slug-bound, 30h: warns as before" "$out" 'resumable: job r1 "overnight" is done; resuming it would find this worktree gone'

# --- 4. PLANTED NEGATIVE: a fresh mtime and updatedAt are not the clock ----------
touch "$H/jobs/r1/state.json"
out=$(hold "$H" -- "$WA"); rc=$?
chk "fresh mtime, lastTerminalAt 30h: not held (exit 1)" 1 "$rc"

# --- 5. the window at 0 turns the hold off -----------------------------------------
job "$H" r1 sid-1 "$LAUNCH" "$T" "\"$H5\""
out=$(WT_RESUMABLE_HOURS=0 hold "$H" -- "$WA"); rc=$?
chk "WT_RESUMABLE_HOURS=0: not held (exit 1)" 1 "$rc"
has "WT_RESUMABLE_HOURS=0: warns as before" "$out" 'resumable: job r1 "overnight" is done'
out=$(hold "$H" --resumable-hours 0 -- "$WA"); rc=$?
chk "--resumable-hours 0: not held (exit 1)" 1 "$rc"
out=$(hold "$H" --resumable-hours 4 -- "$WA"); rc=$?
chk "--resumable-hours 4, last turn 5h ago: not held (exit 1)" 1 "$rc"
out=$(WT_RESUMABLE_HOURS=soon hold "$H" -- "$WA" 2>"$TMP/err"); rc=$?
chk "WT_RESUMABLE_HOURS not a number: the default applies, held (exit 0)" 0 "$rc"
has "WT_RESUMABLE_HOURS not a number: says so" "$(cat "$TMP/err")" "ignored WT_RESUMABLE_HOURS='soon'"
out=$(hold "$H" --resumable-hours -1 -- "$WA" 2>/dev/null); rc=$?
chk "--resumable-hours -1: usage error (exit 2)" 2 "$rc"
out=$(hold "$H" --resumable-hours inf -- "$WA" 2>/dev/null); rc=$?
chk "--resumable-hours inf: usage error (exit 2)" 2 "$rc"

# --- 6. the clock: milliseconds, and the mtime only when lastTerminalAt is absent --
job "$H" r1 sid-1 "$LAUNCH" "$T" "$(( ($(date +%s) - 5 * 3600) * 1000 ))"
out=$(hold "$H" -- "$WA"); rc=$?
chk "lastTerminalAt in milliseconds, 5h: held (exit 0)" 0 "$rc"
job "$H" r1 sid-1 "$LAUNCH" "$T" ""
out=$(hold "$H" -- "$WA"); rc=$?
chk "no lastTerminalAt, fresh state.json: held (exit 0)" 0 "$rc"
touch -d '-30 hours' "$H/jobs/r1/state.json"
out=$(hold "$H" -- "$WA"); rc=$?
chk "no lastTerminalAt, state.json 30h old: not held (exit 1)" 1 "$rc"

# --- 7. bound by its own transcript's last worktree-state record: held -----------
H="$TMP/h7"; T="$H/projects/$(slug "$LAUNCH")/sid-7.jsonl"
transcript "$T" sid-7 "$LAUNCH" "$WA"; job "$H" r7 sid-7 "$LAUNCH" "$T" "\"$H5\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "binding, filed under the launch dir: held (exit 0)" 0 "$rc"
has "binding: names the transcript and the binding" "$out" "its transcript $T binds it to $WA"
out=$(hold "$H" -- "$WA"); rc=$?
chk "binding, read again from the cache: held (exit 0)" 0 "$rc"
out=$(hold "$H" --exclude-session sid-7 -- "$WA"); rc=$?
chk "binding, own session excluded: not held (exit 1)" 1 "$rc"
job "$H" r7 sid-7 "$LAUNCH" "$T" "\"$H30\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "binding, 30h: not held (exit 1)" 1 "$rc"
job "$H" r7 sid-7 "$LAUNCH" "$T" "\"$H5\""

# --- 8. PLANTED NEGATIVE: a later record clears the binding (incremental read) ---
bindrec "" sid-7 >>"$T"; touch -d '-5 hours' "$T"
out=$(hold "$H" -- "$WA"); rc=$?
chk "binding cleared by an appended record: not held (exit 1)" 1 "$rc"
bindrec "$WA" sid-7 >>"$T"; touch -d '-5 hours' "$T"
out=$(hold "$H" -- "$WA"); rc=$?
chk "binding re-entered by an appended record: held (exit 0)" 0 "$rc"

# --- 9. PLANTED NEGATIVE: an earlier binding a later record replaced -------------
H="$TMP/h9"; T="$H/projects/$(slug "$LAUNCH")/sid-9.jsonl"
transcript "$T" sid-9 "$LAUNCH" "$WA" "$WB"; job "$H" r9 sid-9 "$LAUNCH" "$T" "\"$H5\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "replaced binding: the old worktree is not held (exit 1)" 1 "$rc"
out=$(hold "$H" -- "$WB"); rc=$?
chk "replaced binding: the new one is (exit 0)" 0 "$rc"

# --- 10. PLANTED NEGATIVE: a cleared binding from a fresh read --------------------
H="$TMP/h10"; T="$H/projects/$(slug "$LAUNCH")/sid-10.jsonl"
transcript "$T" sid-10 "$LAUNCH" "$WA" ""; job "$H" r10 sid-10 "$LAUNCH" "$T" "\"$H5\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "cleared binding: not held (exit 1)" 1 "$rc"

# --- 11. PLANTED NEGATIVE: an agent transcript's binding is not the job's --------
H="$TMP/h11"; T="$H/projects/$(slug "$LAUNCH")/sid-11.jsonl"
transcript "$T" sid-11 "$LAUNCH"
transcript "$H/projects/$(slug "$LAUNCH")/sid-11/subagents/agent-1.jsonl" sid-11 "$LAUNCH" "$WA"
job "$H" r11 sid-11 "$LAUNCH" "$T" "\"$H5\""
out=$(hold "$H" -- "$WA"); rc=$?
chk "agent transcript binding: not held (exit 1)" 1 "$rc"

# --- 12. a transcript that cannot be read holds what is under the launch dir -------
if [ "$(id -u)" != 0 ]; then
  H="$TMP/h12"; T="$H/projects/$(slug "$LAUNCH")/sid-12.jsonl"
  transcript "$T" sid-12 "$LAUNCH" "$WA"; chmod 000 "$T"
  job "$H" r12 sid-12 "$LAUNCH" "$T" "\"$H5\""
  out=$(hold "$H" -- "$WA" 2>/dev/null); rc=$?
  chk "unreadable transcript, worktree under the launch dir: held (exit 0)" 0 "$rc"
  has "unreadable transcript: says why" "$out" "could not be read and this worktree is under its launch directory"
  job "$H" r12 sid-12 "$TMP/elsewhere" "$T" "\"$H5\""
  out=$(hold "$H" -- "$WA" 2>/dev/null); rc=$?
  chk "unreadable transcript, worktree outside the launch dir: not held (exit 1)" 1 "$rc"
  chmod 600 "$T"
else
  echo "  skip: unreadable-transcript cases (running as root)"
fi

# --- 13. through wt-sweep: kept inside the window, removed past it ----------------
# ROOT holding one repo whose worktree is clean and pushed: the clean path removes
# it unless something holds it.
cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"
mkfix(){
  local d="$TMP/$1"
  {
    mkdir -p "$d"
    git init --bare -q -b main "$TMP/$1-origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$TMP/$1-origin.git"
    echo base >"$d/repo/base.txt"; git -C "$d/repo" add -A; git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    git -C "$d/repo" worktree add -q "$d/repo-wt" -b "$1" main
    git -C "$d/repo-wt" push -q -u origin "$1"
  } >/dev/null 2>&1
}
sweep(){ # $1 root  $2 claude home
  DRY_RUN=0 ROOT="$1" WT_CLAUDE_HOME="$2" WT_HOLD_CACHE_DIR="$TMP/cache" WT_DONE_BIN="$TMP/no-wt-done" \
    REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 \
    WT_SWEEP_LIB="$LIB" bash "$SWEEP" 2>&1
}
for case in in past off; do
  mkfix "s$case"
  H="$TMP/hs$case"; WT="$TMP/s$case/repo-wt"; T="$H/projects/$(slug "$TMP/s$case/repo")/sid-s.jsonl"
  transcript "$T" sid-s "$TMP/s$case/repo" "$WT"
  last=$H5; [ "$case" = past ] && last=$H30
  job "$H" s1 sid-s "$TMP/s$case/repo" "$T" "\"$last\""
  if [ "$case" = off ]; then out=$(WT_RESUMABLE_HOURS=0 sweep "$TMP/s$case" "$H"); else out=$(sweep "$TMP/s$case" "$H"); fi
  case $case in
    in)
      kept "sweep, done job 5h, merged and clean: worktree kept" "$WT"
      has "sweep, done job 5h: skip names the job" "$out" 'skip (Claude session: job s1 "overnight" is done and can be resumed'
      ;;
    past)
      gone "sweep, done job 30h: worktree removed as before" "$WT"
      ;;
    off)
      gone "sweep, WT_RESUMABLE_HOURS=0: worktree removed as before" "$WT"
      ;;
  esac
done

# A slug-bound done job past the window still warns, and the warning is printed by
# wt-sweep itself, not by a short-lived child (journald drops a dead child's unit).
mkfix swarn
H="$TMP/hswarn"; WT="$TMP/swarn/repo-wt"; T="$H/projects/$(slug "$WT")/sid-w.jsonl"
transcript "$T" sid-w "$TMP/swarn/repo"; job "$H" w1 sid-w "$TMP/swarn/repo" "$T" "\"$H30\""
out=$(sweep "$TMP/swarn" "$H")
gone "sweep, slug-bound 30h: removed" "$WT"
has "sweep, slug-bound 30h: warned as resumable" "$out" '  ~ resumable: job w1 "overnight" is done'
has "sweep, slug-bound 30h: counted" "$out" "resumable-warned:1"

echo "wt-session-hold-resumable: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
