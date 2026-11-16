#!/usr/bin/env bash
# wt-session-hold-aliases.test.sh — a hold must survive a second spelling of the
# worktree path (hov-stack#661).
#
# THE DEFECT THIS GUARDS
#   wt_session_hold.py and pr_owner_worktree_owned compared paths as strings. A
#   checkout renamed with a compat link left at its old name (or reached through any
#   link) has two spellings: records keep the one their session saw, and git lists
#   whichever it recorded. A record naming one spelling then held nothing listed
#   under the other, which is how #398's worktrees were removed from under the
#   sessions using them.
#
#   Each hold is planted in both directions (old-spelling record with a new-spelling
#   check, and the reverse): a job's cwd, a job's transcript project (slug), a live
#   session's cwd, a project directory's recent transcript, a path a transcript's
#   tool call drives, and the idle window (a lapsed mention is idle, not unheld; a
#   last cwd in the other spelling holds). Negatives: a sibling worktree sharing a
#   prefix, and no alias roots (the given spelling's real path still holds; the
#   other direction does not, which shows the alias scan does that work). Then the
#   PR-owner predicate, the wrapper passing wt-roots' roots, and one wt-sweep apply
#   through a real `old -> new` repo link that keeps the held worktree and removes
#   an unheld one. Last, the shape the #661 swap leaves (folder renamed, link at the
#   old name, git records still naming the old spelling): a job recorded under the new
#   spelling and a process handed the old one both keep their worktrees.
#
#   Hermetic: everything under mktemp; a fake Claude home per case. Never touches
#   the operator's tree, ~/.claude, ~/.cache, remotes or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
HELPER="$LIB/wt_session_hold.py"
[ -f "$HELPER" ] || { echo "FAIL: cannot find $HELPER"; exit 1; }

# The physical path: realpath must not differ from the spelling the test builds.
TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3'; output: $OUT)"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3': $2)";; esac; }
kept(){ if [ -d "$2" ]; then ok "$1"; else no "$1 (worktree $2 is gone)"; fi; }
gone(){ if [ -d "$2" ]; then no "$1 (worktree $2 still there)"; else ok "$1"; fi; }

starttime(){ python3 -c 'import sys; print(open(f"/proc/{sys.argv[1]}/stat").read().rsplit(")", 1)[1].split()[19])' "$1"; }
ago(){ date -u -d "-$1" +%Y-%m-%dT%H:%M:%S.000Z; }
slug(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
rec(){ printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$2" "$1"; }
readrec(){ # $1 cwd  $2 file read  $3 timestamp
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s"}}]}}\n' "$3" "$1" "$2"
}
home(){ mkdir -p "$TMP/h-$1/jobs" "$TMP/h-$1/sessions" "$TMP/h-$1/projects/-elsewhere"; }
job(){ # $1 case  $2 state  $3 cwd  [$4 linkScanPath]
  mkdir -p "$TMP/h-$1/jobs/j$1"
  printf '{"state":"%s","name":"j%s","sessionId":"s%s","cwd":"%s","linkScanPath":"%s"}\n' \
    "$2" "$1" "$1" "$3" "${4:-}" >"$TMP/h-$1/jobs/j$1/state.json"
}
session(){ # $1 case  $2 cwd
  printf '{"pid":%s,"procStart":"%s","sessionId":"s%s","cwd":"%s","name":"live"}\n' \
    "$$" "$(starttime $$)" "$1" "$2" >"$TMP/h-$1/sessions/$$.json"
}
OUT=""
ALIAS=""
hold(){ # $1 case  $2 worktree  [$3 idle hours]; sets OUT, returns the helper's exit
  OUT=$(WT_ALIAS_ROOTS="$ALIAS" python3 "$HELPER" --claude-home "$TMP/h-$1" --cache-dir "$TMP/cache" \
    --active-min 120 --idle-hours "${3:-0}" -- "$2" 2>&1)
}

S="$TMP/sites"
mkdir -p "$S/new/.claude/worktrees/x/sub" "$S/new/.claude/worktrees/x2" "$TMP/elsewhere"
ln -s new "$S/old"
NEW="$S/new/.claude/worktrees/x"
OLD="$S/old/.claude/worktrees/x"
ALIAS="$S"

echo "wt_session_hold — a hold under either spelling (#661)"

home 1; job 1 running "$OLD"
hold 1 "$OLD"; chk "job cwd, same spelling: held" 0 $?
hold 1 "$NEW"; chk "job cwd old, checked new: held" 0 $?
has "the holder is the job" "$OUT" "job j1"
home 2; job 2 running "$NEW/sub"
hold 2 "$OLD"; chk "job cwd new (below the root), checked old: held" 0 $?

home 3; job 3 running "$S/old/.claude/worktrees/x2"
hold 3 "$NEW"; chk "a sibling sharing the prefix (x2) does not hold x" 1 $?

ALIAS=""
hold 1 "$NEW"; chk "no alias roots: old record, new check is not held (the alias scan holds it)" 1 $?
hold 2 "$OLD"; chk "no alias roots: new record, old check still held (its real path)" 0 $?
ALIAS="$S"

home 4; job 4 running "$TMP/elsewhere" "$TMP/h-4/projects/$(slug "$OLD")/s4.jsonl"
hold 4 "$NEW"; chk "job transcript project is the old spelling's slug, checked new: held" 0 $?
home 5; job 5 running "$TMP/elsewhere" "$TMP/h-5/projects/$(slug "$NEW")/s5.jsonl"
hold 5 "$OLD"; chk "job transcript project is the new spelling's slug, checked old: held" 0 $?

home 6; session 6 "$OLD/sub"
hold 6 "$NEW"; chk "live session cwd old, checked new: held" 0 $?
has "the holder is the session" "$OUT" "has its cwd here"
home 7; session 7 "$NEW"
hold 7 "$OLD"; chk "live session cwd new, checked old: held" 0 $?

home 8; mkdir -p "$TMP/h-8/projects/$(slug "$OLD")"
rec "$TMP/elsewhere" "$(ago '5 minutes')" >"$TMP/h-8/projects/$(slug "$OLD")/s88.jsonl"
hold 8 "$NEW"; chk "recent transcript under the old spelling's project, checked new: held" 0 $?
has "the holder is that project directory" "$OUT" "a transcript under $TMP/h-8/projects/$(slug "$OLD")"
home 9; mkdir -p "$TMP/h-9/projects/$(slug "$NEW")"
rec "$TMP/elsewhere" "$(ago '5 minutes')" >"$TMP/h-9/projects/$(slug "$NEW")/s99.jsonl"
hold 9 "$OLD"; chk "recent transcript under the new spelling's project, checked old: held" 0 $?

home 10; session 10 "$TMP/elsewhere"
readrec "$TMP/elsewhere" "$OLD/sub/f.txt" "$(ago '3 hours')" >"$TMP/h-10/projects/-elsewhere/s10.jsonl"
touch -d '-3 hours' "$TMP/h-10/projects/-elsewhere/s10.jsonl"
hold 10 "$NEW"; chk "a live session's transcript read under the old spelling, checked new: held" 0 $?
has "the holder names the path read" "$OUT" "names $OLD/sub/f.txt"
home 11; session 11 "$TMP/elsewhere"
readrec "$TMP/elsewhere" "$NEW/f.txt" "$(ago '3 hours')" >"$TMP/h-11/projects/-elsewhere/s11.jsonl"
touch -d '-3 hours' "$TMP/h-11/projects/-elsewhere/s11.jsonl"
hold 11 "$OLD"; chk "a live session's transcript read under the new spelling, checked old: held" 0 $?

# The idle window (#644): a failed job's transcript last named the worktree 48 h ago.
home 12; job 12 failed "$TMP/elsewhere" "$TMP/h-12/projects/-elsewhere/s12.jsonl"
{ rec "$TMP/elsewhere" "$(ago '50 hours')"; readrec "$TMP/elsewhere" "$OLD/f.txt" "$(ago '48 hours')"
  rec "$TMP/elsewhere" "$(ago '47 hours')"; } >"$TMP/h-12/projects/-elsewhere/s12.jsonl"
touch -d '-47 hours' "$TMP/h-12/projects/-elsewhere/s12.jsonl"
hold 12 "$NEW"; chk "no idle window: an old-spelling mention holds the new spelling" 0 $?
hold 12 "$NEW" 18; chk "idle window 18 h, mention 48 h old under the old spelling: idle, not unheld" 3 $?
has "the idle line" "$OUT" "idle: "
home 13; job 13 failed "$TMP/elsewhere" "$TMP/h-13/projects/-elsewhere/s13.jsonl"
{ readrec "$TMP/elsewhere" "$OLD/f.txt" "$(ago '48 hours')"; rec "$OLD" "$(ago '47 hours')"; } \
  >"$TMP/h-13/projects/-elsewhere/s13.jsonl"
touch -d '-47 hours' "$TMP/h-13/projects/-elsewhere/s13.jsonl"
hold 13 "$NEW" 18; chk "idle window, last cwd in the old spelling, checked new: held" 0 $?
has "the holder is the last cwd" "$OUT" "last recorded its cwd at $OLD"
home 14; job 14 failed "$TMP/elsewhere" "$TMP/h-14/projects/-elsewhere/s14.jsonl"
readrec "$TMP/elsewhere" "$NEW/f.txt" "$(ago '2 hours')" >"$TMP/h-14/projects/-elsewhere/s14.jsonl"
touch -d '-2 hours' "$TMP/h-14/projects/-elsewhere/s14.jsonl"
hold 14 "$OLD" 18; chk "idle window, a new-spelling mention 2 h old, checked old: held, not idle" 0 $?

echo "pr_owner_worktree_owned — an owner record under either spelling"
po(){ # $1 record worktree  $2 state  $3 path asked about; prints the predicate's exit
  local r="$TMP/po/.claude/.loop-state/pr-owner/k"
  mkdir -p "$r"
  printf '{"state":"%s","worktree":"%s"}\n' "$2" "$1" >"$r/owner.json"
  # shellcheck source=SCRIPTDIR/../scripts/lib/pr-owner-state.sh
  ( HOME="$TMP/po"; . "$LIB/pr-owner-state.sh"; pr_owner_worktree_owned "$3" ); echo $?
}
OUT="(pr-owner)"
chk "record old, asked new: owned" 0 "$(po "$OLD" owned "$NEW")"
chk "record new, asked old: owned" 0 "$(po "$NEW" owned "$OLD")"
chk "record and question the same spelling: owned" 0 "$(po "$NEW" owned "$NEW")"
chk "record names the sibling x2: not owned" 1 "$(po "$S/old/.claude/worktrees/x2" owned "$NEW")"
chk "a merged record owns nothing" 1 "$(po "$OLD" merged "$NEW")"

echo "wt_session_hold wrapper — wt-sweep's repo roots become the alias roots"
wrap(){ # $1 roots wt_roots prints  [$2 WT_ALIAS_ROOTS, set only when given]
  (
    unset WT_ALIAS_ROOTS
    [ $# -lt 2 ] || export WT_ALIAS_ROOTS="$2"
    export WT_CLAUDE_HOME="$TMP/h-1" WT_HOLD_CACHE_DIR="$TMP/cache"
    # shellcheck source=SCRIPTDIR/../scripts/lib/wt-preserve.sh
    . "$LIB/wt-preserve.sh"
    eval "wt_roots(){ printf '%s\n' '$1'; }"
    wt_session_hold "$NEW" "" 0 >/dev/null
  ); echo $?
}
mkdir -p "$TMP/empty"
chk "wt_roots names the root holding the link: held" 0 "$(wrap "$S")"
chk "wt_roots names another root: not held" 1 "$(wrap "$TMP/empty")"
chk "WT_ALIAS_ROOTS wins over wt_roots" 0 "$(wrap "$TMP/empty" "$S")"

echo "wt-sweep — one apply through a real old -> new repo link"
E="$TMP/e"
{
  mkdir -p "$E/sites"
  git init --bare -q -b main "$E/origin.git"
  git init -q -b main "$E/sites/new"
  git -C "$E/sites/new" remote add origin "$E/origin.git"
  printf '.claude/\n' >"$E/sites/new/.gitignore"
  echo base >"$E/sites/new/base.txt"; git -C "$E/sites/new" add -A; git -C "$E/sites/new" commit -qm base
  git -C "$E/sites/new" push -q -u origin main
  for n in w1 w2; do
    git -C "$E/sites/new" worktree add -q "$E/sites/new/.claude/worktrees/$n" -b "$n" main
    git -C "$E/sites/new/.claude/worktrees/$n" push -q -u origin "$n"
  done
  ln -s new "$E/sites/old"
} >/dev/null 2>&1
cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"
home e; job e running "$E/sites/old/.claude/worktrees/w1"
OUT=$(unset WT_ALIAS_ROOTS; DRY_RUN=0 ROOT="$E/sites" WT_CLAUDE_HOME="$TMP/h-e" WT_HOLD_CACHE_DIR="$TMP/cache" \
  WT_DONE_BIN="$TMP/no-wt-done" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 \
  IDLE_RELEASE_HOURS=24 WT_SWEEP_LIB="$LIB" bash "$SCRIPT" 2>&1)
kept "a running job names w1 under the old spelling: kept" "$E/sites/new/.claude/worktrees/w1"
has "the sweep says why" "$OUT" "job je"
gone "w2, held by nothing, is removed (the sweep did run)" "$E/sites/new/.claude/worktrees/w2"

echo "wt-sweep — the renamed checkout: git still lists the old spelling (no worktree repair)"
# The shape the #661 swap leaves: the folder moved to its new name with a link at the old
# one, and git's worktree records still naming the old spelling. A job started after the
# move records the new spelling; a process started before it was handed the old one.
# Running `git worktree repair` here would relist v3 under the new spelling and lose the
# argv hold, which is why the swap leaves the records alone until the link goes.
F="$TMP/f"
{
  mkdir -p "$F/sites"
  git init --bare -q -b main "$F/origin.git"
  git init -q -b main "$F/sites/old"
  git -C "$F/sites/old" remote add origin "$F/origin.git"
  printf '.claude/\n' >"$F/sites/old/.gitignore"
  echo base >"$F/sites/old/base.txt"; git -C "$F/sites/old" add -A; git -C "$F/sites/old" commit -qm base
  git -C "$F/sites/old" push -q -u origin main
  for n in v1 v2 v3; do
    git -C "$F/sites/old" worktree add -q "$F/sites/old/.claude/worktrees/$n" -b "$n" main
    git -C "$F/sites/old/.claude/worktrees/$n" push -q -u origin "$n"
  done
  mv "$F/sites/old" "$F/sites/new"; ln -s new "$F/sites/old"
} >/dev/null 2>&1
has "git lists v1 under the old spelling" "$(git -C "$F/sites/new" worktree list --porcelain)" "$F/sites/old/.claude/worktrees/v1"
home f; job f running "$F/sites/new/.claude/worktrees/v1"
(cd "$TMP" && exec python3 -c 'import time; time.sleep(300)' "$F/sites/old/.claude/worktrees/v3") & HOLDER=$!
sleep 1
OUT=$(unset WT_ALIAS_ROOTS; DRY_RUN=0 ROOT="$F/sites" WT_CLAUDE_HOME="$TMP/h-f" WT_HOLD_CACHE_DIR="$TMP/cache" \
  WT_DONE_BIN="$TMP/no-wt-done" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 \
  IDLE_RELEASE_HOURS=24 WT_SWEEP_LIB="$LIB" bash "$SCRIPT" 2>&1)
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
kept "a running job names v1 under the new spelling: kept" "$F/sites/new/.claude/worktrees/v1"
has "the sweep says why" "$OUT" "job jf"
kept "a process handed v3's old spelling in its argv: kept" "$F/sites/new/.claude/worktrees/v3"
gone "v2, held by nothing, is removed (the sweep did run)" "$F/sites/new/.claude/worktrees/v2"

echo
echo "wt-session-hold-aliases: $pass passed, $fail failed"
[ "$fail" = 0 ]
