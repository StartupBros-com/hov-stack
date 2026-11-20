#!/usr/bin/env bash
# wt-sweep-hold-matrix.test.sh — what one sweep plan keeps and removes: a worktree
# for each hold the session-hold helper returns, each named in a different spelling
# of its path, under each index-cache state the live sweep meets (hov-stack#806).
#
# THE DEFECTS THIS GUARDS
#   - hov-stack#795: a record with no timestamp was dated by its transcript's mtime
#     at scan time. A rebuilt index (cache lost, renamed or versioned) re-dated every
#     such record to about now, and on 2026-11-19 a rebuild held 44 idle worktrees
#     for another day. Rows r-blob, r-nopred, r-app and h-app pin that an undated
#     record takes the time of the dated record before it (none: never recent), the
#     same whether the index is warm, empty, or an older helper's that lacks it.
#   - A worktree whose name ends in `.`: paths read from transcripts lose a trailing
#     dot (_norm), so a cwd or `git -C` naming the worktree itself never matched it.
#     Rows h-dot. and h-cwd.
#   Every other row pins a hold that already works, named as git lists the worktree,
#   through a renamed checkout's compat link (old -> new), or through a symlinked
#   worktrees directory (wts -> new/.claude/worktrees). With IDLE_RELEASE_HOURS=0,
#   an unreadable job record, or an unreadable transcript, nothing is called idle.
#
#   Hermetic: bare origin + repo + worktrees under mktemp; a fake Claude home and
#   index cache; the repo-route resolver stubbed to a verified empty scan; no
#   wt-done. Never touches the operator's tree, remotes, ~/.claude, ~/.cache, or gh.
set -uo pipefail
unset WT_RESUMABLE_HOURS WT_ALIAS_ROOTS

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3')";; esac; }
same(){ # $1 label  $2 want  $3 got: one path per line
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"; diff <(printf '%s\n' "$2" | grep .) <(printf '%s\n' "$3" | grep .) | sed -n 's/^</      missing: /p; s/^>/      extra:   /p'
  fi
}

cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"

starttime(){ python3 -c 'import sys; print(open(f"/proc/{sys.argv[1]}/stat").read().rsplit(")", 1)[1].split()[19])' "$1"; }
ago(){ date -u -d "-$1" +%Y-%m-%dT%H:%M:%S.000Z; }

S="$TMP/sites"; R="$S/new"; W="$R/.claude/worktrees"
E="$TMP/elsewhere"; L="$TMP/launch"
H="$TMP/claude"; P="$H/projects"
HELD="h-live h-job h-slug h-dot. h-done h-bind h-proj h-cwd. h-unread h-app"
IDLE="r-stale r-old r-blob r-nopred r-app"   # released as idle: clean, cache-only, shipped
UNHELD="r-bindold r-doneold r-cleared r-plain"
{
  mkdir -p "$S" "$E" "$L" "$H/sessions" "$H/jobs" "$P/-elsewhere" "$P/-launch"
  git init --bare -q -b main "$TMP/origin.git"
  git init -q -b main "$R"
  git -C "$R" remote add origin "$TMP/origin.git"
  printf '.claude/worktrees/\n' >"$R/.gitignore"; echo base >"$R/base.txt"
  git -C "$R" add -A; git -C "$R" commit -qm base; git -C "$R" push -q -u origin main
  for n in $HELD $IDLE $UNHELD; do
    git -C "$R" worktree add -q "$W/$n" -b "${n%.}" main   # a branch name cannot end in `.`
    git -C "$W/$n" push -q -u origin "${n%.}"
  done
} >/dev/null 2>&1
ln -s new "$S/old"                      # a renamed checkout's compat link (hov-stack#661)
ln -s new/.claude/worktrees "$S/wts"    # a symlinked worktrees directory

# Three spellings of a worktree's path: as git lists it, and through each link.
real(){ printf '%s' "$W/$1"; }
old(){ printf '%s' "$S/old/.claude/worktrees/$1"; }
wts(){ printf '%s' "$S/wts/$1"; }
slugof(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# Records as Claude Code writes them. Each carries its time, except an
# api-request-blob: its copy of an earlier message as it sends it again, with no
# timestamp and no cwd.
rec(){ printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$(ago "$2")" "$1"; }
tool(){ # $1 age  $2 tool name  $3 input JSON
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"%s","input":%s}]}}\n' \
    "$(ago "$1")" "$E" "$2" "$3"
}
blob(){ printf '{"type":"api-request-blob","sessionId":"s","hash":"h","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s"}}]}}\n' "$1"; }
bind(){ # $1 worktree path, or "" for the record that clears the binding
  local ws=null
  [ -n "$1" ] && ws="{\"originalCwd\":\"$L\",\"worktreePath\":\"$1\",\"worktreeName\":\"x\"}"
  printf '{"type":"worktree-state","worktreeSession":%s,"sessionId":"s"}\n' "$ws"
}
job(){ # $1 id  $2 state  $3 more JSON fields; its session id is s-<id>
  mkdir -p "$H/jobs/$1"
  printf '{"state":"%s","name":"%s","sessionId":"s-%s"%s}\n' "$2" "$1" "$1" "$3" >"$H/jobs/$1/state.json"
}

# ===== held ========================================================================
# h-live: a live session's cwd (renamed spelling).
printf '{"pid":%s,"procStart":"%s","sessionId":"s-live","cwd":"%s","name":"live"}\n' \
  "$$" "$(starttime $$)" "$(old h-live)" >"$H/sessions/$$.json"
# h-job: a working job's own worktree (symlinked spelling).
job h-job working ",\"cwd\":\"$E\",\"worktreePath\":\"$(wts h-job)\""
# h-slug: a working job whose transcript is filed under the worktree's project (renamed).
T="$P/$(slugof "$(old h-slug)")/s-h-slug.jsonl"; mkdir -p "$(dirname "$T")"
rec "$E" '3 hours' >"$T"; touch -d '-3 hours' "$T"
job h-slug working ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# h-dot.: a blocked job ran `git -C` on the worktree itself 3h ago (trailing dot).
T="$P/-elsewhere/s-h-dot.jsonl"
tool '3 hours' Bash "{\"command\":\"git -C $(real h-dot.) status --short\"}" >"$T"; touch -d '-3 hours' "$T"
job h-dot blocked ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# h-done: a done job's own worktree, its last turn 5h ago (inside the resume window).
job h-done "done" ",\"cwd\":\"$E\",\"worktreePath\":\"$(real h-done)\",\"lastTerminalAt\":\"$(ago '5 hours')\""
# h-bind: a done job (5h) whose transcript's worktree-state record binds it (symlinked).
T="$P/-launch/s-h-bind.jsonl"; bind "$(wts h-bind)" >"$T"; touch -d '-3 hours' "$T"
job h-bind "done" ",\"cwd\":\"$L\",\"linkScanPath\":\"$T\",\"lastTerminalAt\":\"$(ago '5 hours')\""
# h-proj: a transcript under its project directory written 30m ago (renamed).
T="$P/$(slugof "$(old h-proj)")/p1.jsonl"; mkdir -p "$(dirname "$T")"
rec "$(old h-proj)" '30 minutes' >"$T"; touch -d '-30 minutes' "$T"
# h-cwd.: a blocked job read in it 48h ago, so it is idle by age, but its session last
# recorded its cwd there, so a resume carries on in it (trailing dot).
T="$P/-elsewhere/s-h-cwd.jsonl"
{ tool '48 hours' Read "{\"file_path\":\"$(real h-cwd.)/base.txt\"}"; rec "$(real h-cwd.)" '47 hours'; } >"$T"
touch -d '-47 hours' "$T"
job h-cwd blocked ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# h-unread: a done job (5h) launched from it, whose transcript cannot be read (symlinked).
T="$P/-launch/s-h-unread.jsonl"   # not empty: an empty transcript is never opened
rec "$L" '30 hours' >"$T"; touch -d '-30 hours' "$T"; chmod 000 "$T"
job h-unread "done" ",\"cwd\":\"$L\",\"originCwd\":\"$(wts h-unread)\",\"linkScanPath\":\"$T\",\"lastTerminalAt\":\"$(ago '5 hours')\""
if [ -r "$T" ]; then   # root reads it anyway: then nothing holds it
  echo "  note: running as root, chmod 000 leaves files readable; h-unread is expected unheld"
  HELD="${HELD/ h-unread/}"; UNHELD="$UNHELD h-unread"
fi
# h-app: a working job's transcript gains an undated record naming it after the
# index first read it (appended below); the dated record before that is 2h old,
# since a record whose timestamp does not parse dates nothing after it.
TA="$P/-elsewhere/s-h-app.jsonl"
{ rec "$E" '2 hours'; printf '{"type":"system","timestamp":"not-a-date","content":"x"}\n'; } >"$TA"
job h-app working ",\"cwd\":\"$E\",\"linkScanPath\":\"$TA\""

# ===== idle: released ==============================================================
# r-stale: a blocked job's own worktree; its state.json is 30h old, no session runs.
job r-stale blocked ",\"cwd\":\"$E\",\"worktreePath\":\"$(wts r-stale)\""
touch -d '-30 hours' "$H/jobs/r-stale/state.json"
# r-old: a blocked job read in it 48h ago and has worked elsewhere since (renamed).
T="$P/-elsewhere/s-r-old.jsonl"
{ tool '48 hours' Read "{\"file_path\":\"$(old r-old)/base.txt\"}"; rec "$E" '47 hours'; } >"$T"; touch -d '-47 hours' "$T"
job r-old blocked ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# r-blob: a working job's transcript, written just now, names it only in an undated
# record after a dated one 48h old (renamed).
T="$P/-elsewhere/s-r-blob.jsonl"
{ rec "$E" '48 hours'; blob "$(old r-blob)/base.txt"; rec "$E" '0 hours'; } >"$T"
job r-blob working ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# r-nopred: #795's planted negative: an undated record naming it with no dated record
# before it, then a dated record written now naming something else.
T="$P/-elsewhere/s-r-nopred.jsonl"
{ blob "$(real r-nopred)/base.txt"; rec "$E" '0 hours'; } >"$T"
job r-nopred working ",\"cwd\":\"$E\",\"linkScanPath\":\"$T\""
# r-app: as h-app, but the dated record before the appended one is 48h old.
TB="$P/-elsewhere/s-r-app.jsonl"; rec "$E" '48 hours' >"$TB"
job r-app working ",\"cwd\":\"$E\",\"linkScanPath\":\"$TB\""

# ===== unheld: removed =============================================================
# r-bindold: a done job bound to it whose last turn ended 30h ago, past the window.
T="$P/-launch/s-r-bindold.jsonl"; bind "$(real r-bindold)" >"$T"; touch -d '-30 hours' "$T"
job r-bindold "done" ",\"cwd\":\"$L\",\"linkScanPath\":\"$T\",\"lastTerminalAt\":\"$(ago '30 hours')\""
# r-doneold: a done job's own worktree, last turn 30h ago, state.json rewritten now.
job r-doneold "done" ",\"cwd\":\"$E\",\"worktreePath\":\"$(old r-doneold)\",\"lastTerminalAt\":\"$(ago '30 hours')\""
# r-cleared: a done job (5h) whose binding a later worktree-state record cleared.
T="$P/-launch/s-r-cleared.jsonl"; { bind "$(wts r-cleared)"; bind ""; } >"$T"; touch -d '-3 hours' "$T"
job r-cleared "done" ",\"cwd\":\"$L\",\"linkScanPath\":\"$T\",\"lastTerminalAt\":\"$(ago '5 hours')\""
# r-plain: nothing names it.

for n in $HELD $IDLE $UNHELD; do touch -d '-3 hours' "$W/$n"; done   # older than ACTIVE_MIN

paths(){ for n in "$@"; do printf '%s\n' "$W/$n"; done | sort; }
# shellcheck disable=SC2086  # word lists
EXPECTED=$(paths $IDLE $UNHELD)
# shellcheck disable=SC2086
NOLAPSE=$(paths $UNHELD)

sweep(){ # $1 index cache dir  [$2 IDLE_RELEASE_HOURS]
  DRY_RUN=1 ROOT="$S" WT_CLAUDE_HOME="$H" WT_HOLD_CACHE_DIR="$1" WT_DONE_BIN="$TMP/no-wt-done" \
    REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=120 PUSH=0 \
    IDLE_RELEASE_HOURS="${2:-24}" bash "$SCRIPT" 2>&1
}
# The worktree path each plan removal names, one per line, sorted.
removals(){ grep -o "worktree remove --force '[^']*'" <<<"$1" | sed "s/.*--force '//; s/'\$//" | sort; }
# Strip `ts` from every index entry in $1, as an older helper writes them; print how many had one.
strip_ts(){ python3 - "$1" <<'PY'
import glob, json, sys
n = 0
for f in glob.glob(sys.argv[1] + "/*.json"):
    with open(f) as fh:
        c = json.load(fh)
    for e in c.get("entries", {}).values():
        if "ts" in e:
            n += 1
            del e["ts"]
    with open(f, "w") as fh:
        json.dump(c, fh)
print(n)
PY
}
has_ts(){ python3 - "$1" "$2" <<'PY'
import glob, json, sys
for f in glob.glob(sys.argv[1] + "/*.json"):
    with open(f) as fh:
        e = json.load(fh).get("entries", {}).get(sys.argv[2])
    if isinstance(e, dict) and isinstance(e.get("ts"), (int, float)):
        print("yes")
        break
PY
}

echo "wt-sweep — hold matrix (#806)"

# The index first reads every transcript; then h-app's and r-app's transcripts each
# gain an undated record naming them, whose dated predecessor is before that read.
mkdir -p "$TMP/cache-first"
out=$(sweep "$TMP/cache-first")
has "the plan finds the repo" "$out" "repos discovered: "
blob "$(wts h-app)/base.txt" >>"$TA"
blob "$(old r-app)/base.txt" >>"$TB"
cp -a "$TMP/cache-first" "$TMP/cache-warm"
mkdir -p "$TMP/cache-empty"
cp -a "$TMP/cache-first" "$TMP/cache-older"
n=$(strip_ts "$TMP/cache-older")
if [ "${n:-0}" -gt 0 ]; then ok "the warm index carries each transcript's last record time ($n entries)"
else no "the warm index carries each transcript's last record time (none found)"; fi

for state in warm empty older; do
  out=$(sweep "$TMP/cache-$state")
  same "index $state: the plan removes exactly the idle and unheld worktrees" "$EXPECTED" "$(removals "$out")"
  [ "$state" = empty ] && has "index empty: #795's planted negative is idle with no time" "$out" \
    "last named only by records with no time"
done
if [ "$(has_ts "$TMP/cache-older" "$TA")" = yes ]; then ok "index older: the recovered time is kept for the next run"
else no "index older: the recovered time is kept for the next run"; fi

# ===== nothing is called idle ======================================================
mkdir -p "$TMP/cache-off"
out=$(sweep "$TMP/cache-off" 0)
same "IDLE_RELEASE_HOURS=0: only the unheld worktrees" "$NOLAPSE" "$(removals "$out")"

mkdir -p "$H/jobs/half" "$TMP/cache-half"
printf '{"state":"work' >"$H/jobs/half/state.json"
out=$(sweep "$TMP/cache-half")
same "a half-written state.json: only the unheld worktrees" "$NOLAPSE" "$(removals "$out")"
rm -rf "$H/jobs/half"

T="$P/-elsewhere/s-unreadable.jsonl"; rec "$E" '0 hours' >"$T"; chmod 000 "$T"
if [ -r "$T" ]; then
  echo "  note: running as root, chmod 000 leaves files readable; unreadable-transcript run skipped"
else
  mkdir -p "$TMP/cache-unread"
  out=$(sweep "$TMP/cache-unread")
  same "an unreadable transcript written now: only the unheld worktrees" "$NOLAPSE" "$(removals "$out")"
fi
chmod 600 "$T"

echo
echo "wt-sweep-hold-matrix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
