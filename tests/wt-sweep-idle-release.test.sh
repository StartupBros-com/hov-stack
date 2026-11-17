#!/usr/bin/env bash
# wt-sweep-idle-release.test.sh — the idle release and the lock skip (hov-stack#644).
#
# THE DEFECT THIS GUARDS
#   The transcript-mention hold (#390, #394, #398) had no expiry. On 2026-11-14 the
#   workstation's root disk fell to 12 GiB free, most of it in agent worktrees whose
#   PR had merged days earlier: a blocked or finished job's transcript had once named
#   them, so the sweep skipped them forever.
#
#   Now a mention that is IDLE_RELEASE_HOURS old (24 by default) no longer holds a
#   worktree that is clean, on a branch, cache-only and proven shipped. Everything
#   else stays held, and each rule has a planted negative here: a mention inside the
#   window (from a holder, or from any transcript written in it), a session whose last
#   cwd is in the worktree, a job's own worktree, an ignored .env, a dirty tree, a
#   pushed-but-unmerged branch, a lock, an unparseable timestamp, a helper that fails,
#   and IDLE_RELEASE_HOURS=0. A plan (DRY_RUN=1) must name exactly what the apply
#   removes.
#
#   Hermetic: bare origin + repo + worktrees under mktemp; a fake Claude home and
#   transcript-index cache; the repo-route resolver stubbed to a verified empty scan;
#   no wt-done (the release proof here is HEAD on origin/main). Never touches the
#   operator's tree, remotes, ~/.claude, ~/.cache, or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
LIB="$HERE/../scripts/lib"
HELPER="$LIB/wt_session_hold.py"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3')";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }
kept(){ [ -d "$2" ] && ok "$1" || no "$1 (worktree $2 is gone)"; }
gone(){ [ -d "$2" ] && no "$1 (worktree $2 still there)" || ok "$1"; }

cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"

starttime(){ python3 -c 'import sys; print(open(f"/proc/{sys.argv[1]}/stat").read().rsplit(")", 1)[1].split()[19])' "$1"; }
ago(){ date -u -d "-$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# Transcript records as Claude Code writes them, with the record time it stamps.
rec(){ printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$2" "$1"; }
readrec(){ # $1 cwd  $2 file read  $3 timestamp
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"%s"}}]}}\n' "$3" "$1" "$2"
}
sweep(){ # $1 root  $2 DRY_RUN  $3 claude home  [$4 IDLE_RELEASE_HOURS]  [$5 lib dir]
  DRY_RUN="$2" ROOT="$1" WT_CLAUDE_HOME="$3" WT_HOLD_CACHE_DIR="$TMP/hold-cache" WT_DONE_BIN="$TMP/no-wt-done" \
    REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 \
    IDLE_RELEASE_HOURS="${4:-24}" WT_SWEEP_LIB="${5:-$LIB}" bash "$SCRIPT" 2>&1
}
# The worktree path each plan or apply removal names, one per line, sorted.
removals(){ grep -o "worktree remove --force '[^']*'" <<<"$1" | sed "s/.*--force '//; s/'\$//" | sort; }

# ROOT=$1: one repo, its bare origin outside the root, and worktree $1/<name> on
# branch <name> at main's tip, pushed, for each name after $1: clean and shipped.
mkrepo(){
  local d="$1" n; shift
  {
    mkdir -p "$d"
    git init --bare -q -b main "$d-origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$d-origin.git"
    printf '.claude/deliverables/\n.context/\n.env\nnode_modules/\n__pycache__/\n' >"$d/repo/.gitignore"
    echo base >"$d/repo/base.txt"; git -C "$d/repo" add -A; git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    for n in "$@"; do
      git -C "$d/repo" worktree add -q "$d/$n" -b "$n" main
      git -C "$d/$n" push -q -u origin "$n"
    done
  } >/dev/null 2>&1
}

echo "wt-sweep — idle release and lock skip (#644)"

M="$TMP/m"
mkrepo "$M" rel cache deliv livewt plain env nestenv unship dirty lockwt fresh garb cwdwt jobwt recent2
# The releasable ones carry only what may go: caches, and a deliverable that is rescued.
# pkg/ and .claude/ hold only ignored content, so git lists them as well as what is in
# them; the release must look through them, not stop at them.
mkdir -p "$M/cache/node_modules/x" "$M/cache/__pycache__" "$M/cache/pkg/node_modules/y" "$M/deliv/.claude/deliverables"
echo 'module.exports=1' >"$M/cache/node_modules/x/index.js"; echo pyc >"$M/cache/__pycache__/a.cpython-312.pyc"
echo 'module.exports=2' >"$M/cache/pkg/node_modules/y/index.js"
echo 'the report' >"$M/deliv/.claude/deliverables/report.md"
echo 'TOKEN=1' >"$M/env/.env"                       # ignored, not a cache: no session left to say it can go
mkdir -p "$M/nestenv/tools/node_modules"; echo 'TOKEN=2' >"$M/nestenv/tools/.env"   # the same, inside such a dir
echo new >"$M/dirty/new.txt"                        # untracked: not clean
{ echo two >"$M/unship/two.txt"; git -C "$M/unship" add -A; git -C "$M/unship" commit -qm two
  git -C "$M/unship" push -q; } >/dev/null 2>&1     # pushed, never merged: not shipped
git -C "$M/repo" worktree lock --reason "operator hold" "$M/lockwt"

H="$TMP/h"; mkdir -p "$H/jobs/j1" "$H/jobs/j2" "$H/sessions" "$H/projects/-elsewhere" "$H/projects/-gone"
T1="$H/projects/-elsewhere/s1.jsonl"; T2="$H/projects/-elsewhere/s2.jsonl"
T3="$H/projects/-elsewhere/s3.jsonl"; T4="$H/projects/-gone/s4.jsonl"
# j1: a blocked job that once read in every worktree below. Its own cwd is elsewhere.
printf '{"state":"blocked","name":"toucher","sessionId":"s1","cwd":"%s","linkScanPath":"%s"}\n' "$TMP" "$T1" >"$H/jobs/j1/state.json"
# j2: a blocked job whose OWN worktree is jobwt. A job's own worktree never goes idle.
printf '{"state":"blocked","name":"owner","sessionId":"s2","cwd":"%s","worktreePath":"%s","linkScanPath":"%s"}\n' \
  "$TMP" "$M/jobwt" "$T2" >"$H/jobs/j2/state.json"
# s3: a live session that read in livewt two days ago and works elsewhere now.
printf '{"pid":%s,"procStart":"%s","sessionId":"s3","cwd":"%s","name":"parked"}\n' "$$" "$(starttime $$)" "$TMP" >"$H/sessions/$$.json"
{
  rec "$TMP" "$(ago '50 hours')"
  for n in rel cache deliv env nestenv unship dirty lockwt cwdwt jobwt recent2; do readrec "$TMP" "$M/$n/base.txt" "$(ago '48 hours')"; done
  readrec "$TMP" "$M/fresh/base.txt" "$(ago '2 hours')"           # inside the window: held
  readrec "$TMP" "$M/garb/base.txt" "not-a-date"                 # unparseable: the file's mtime stands in
  rec "$M/cwdwt" "$(ago '47 hours')"                              # j1's last cwd is in cwdwt: held
} >"$T1"
touch -d '-1 hour' "$T1"
readrec "$TMP" "$M/jobwt/base.txt" "$(ago '48 hours')" >"$T2"; touch -d '-48 hours' "$T2"
{ readrec "$TMP" "$M/livewt/base.txt" "$(ago '48 hours')"; rec "$TMP" "$(ago '47 hours')"; } >"$T3"; touch -d '-47 hours' "$T3"
# s4 ended (no job, no live session), but it read in recent2 three hours ago: in use.
readrec "$TMP" "$M/recent2/base.txt" "$(ago '3 hours')" >"$T4"; touch -d '-3 hours' "$T4"

RELEASED=$(printf '%s\n' "$M/cache" "$M/deliv" "$M/livewt" "$M/plain" "$M/rel" | sort)

# --- 1. IDLE_RELEASE_HOURS=0 is today's behaviour: a mention holds at any age -----
out=$(sweep "$M" 1 "$H" 0)
has "off: released-idle 0" "$out" "released-idle:0"
hasnot "off: no idle line" "$out" "~ idle: "
has "off: an old mention still holds" "$out" "skip (Claude session: job j1 \"toucher\" is blocked; its transcript $T1 names $M/rel/base.txt): rel"
chk "off: only the unheld worktree is planned" "$M/plain" "$(removals "$out")"

# --- 2. the plan (DRY_RUN=1) -------------------------------------------------------
plan=$(sweep "$M" 1 "$H")
chk "plan: releases exactly the clean, cache-only, shipped, idle ones (plus the unheld one)" "$RELEASED" "$(removals "$plan")"
has "plan: names the idle holder and its age" "$plan" "~ idle: job j1 \"toucher\" is blocked; its transcript $T1 names $M/rel/base.txt; last named 48h ago"
has "plan: says why it releases" "$plan" "=> release (idle 24h+, clean, cache-only, shipped)"
has "plan: the live session's old mention is idle too" "$plan" "~ idle: session pid $$ \"parked\" is live; its transcript $T3 names $M/livewt/base.txt"
has "plan: the deliverable would be copied out" "$plan" "would: copy 1 ignored deliverable file(s) to $M/repo/.claude/deliverables/from-worktrees/deliv"
has "plan: lock skipped with its reason" "$plan" "skip (locked: operator hold): lockwt"
has "plan: ignored .env keeps it" "$plan" "skip (Claude session, idle but keeps ignored .env: job j1"
has "plan: an ignored .env inside an all-ignored dir keeps it" "$plan" "skip (Claude session, idle but keeps ignored tools/.env: job j1"
has "plan: dirty keeps it" "$plan" "skip (Claude session, idle but not clean on a branch: job j1"
has "plan: pushed but unmerged keeps it" "$plan" "=> SKIP (idle, but not proven shipped: not on origin/main and no merged PR found; nothing removed)"
has "plan: a mention inside the window holds" "$plan" "skip (Claude session: job j1 \"toucher\" is blocked; its transcript $T1 names $M/fresh/base.txt): fresh"
has "plan: an unparseable time reads as the file's mtime, so it holds" "$plan" "names $M/garb/base.txt): garb"
has "plan: the session's last cwd holds" "$plan" "its session last recorded its cwd at $M/cwdwt): cwdwt"
has "plan: a job's own worktree holds" "$plan" "skip (Claude session: job j2 \"owner\" is blocked): jobwt"
has "plan: any transcript naming it inside the window holds" "$plan" "names $M/recent2/base.txt): recent2"
has "plan: counts" "$plan" "removed:5"
has "plan: counts the idle releases and the lock" "$plan" "locked:1  released-idle:4"
for n in rel cache deliv livewt plain; do kept "plan removed nothing: $n" "$M/$n"; done

# --- 3. the apply (DRY_RUN=0) removes exactly what the plan named -----------------
out=$(sweep "$M" 0 "$H")
chk "apply: same set as the plan" "$RELEASED" "$(removals "$out")"
for n in rel cache deliv livewt plain; do gone "apply: $n released" "$M/$n"; done
for n in env nestenv unship dirty lockwt fresh garb cwdwt jobwt recent2; do kept "apply: $n kept" "$M/$n"; done
has "apply: counts" "$out" "locked:1  released-idle:4"
chk "apply: the deliverable was rescued byte for byte" "the report" \
  "$(cat "$M/repo/.claude/deliverables/from-worktrees/deliv/report.md" 2>/dev/null)"
[ -f "$M/env/.env" ] && ok "apply: the .env is untouched" || no "apply: the .env is untouched"
git -C "$M/repo" rev-parse --verify -q refs/heads/unship >/dev/null && ok "apply: the unmerged branch is kept" \
  || no "apply: the unmerged branch is kept"

# --- 4. the helper directly: exit codes, a corrupt cache, a failing check ---------
C="$TMP/hold-cache"
hold(){ python3 "$HELPER" --claude-home "$H" --cache-dir "$C" --active-min 0 "$@"; }
out=$(hold --idle-hours 24 -- "$M/env"); rc=$?
chk "helper: idle exits 3" 3 "$rc"
has "helper: idle line" "$out" "idle: job j1"
out=$(hold -- "$M/env"); rc=$?
chk "helper: without --idle-hours a mention holds (exit 0)" 0 "$rc"
out=$(hold --idle-hours 24 -- "$M/fresh"); rc=$?
chk "helper: a mention inside the window holds (exit 0)" 0 "$rc"
cachefile=$(ls "$C"/*.v2.json 2>/dev/null | head -n 1)
[ -n "$cachefile" ] && ok "helper: writes a versioned cache" || no "helper: writes a versioned cache"
printf '{not json' >"$cachefile"
out=$(hold --idle-hours 24 -- "$M/fresh"); rc=$?
chk "helper: a corrupt cache file is rebuilt, still held" 0 "$rc"
# An entry whose recorded times are not numbers is rescanned, never trusted as empty.
python3 - "$cachefile" "$T1" <<'PY'
import json, os, sys
path, t = sys.argv[1], sys.argv[2]
d = json.load(open(path))
st = os.stat(t)
d["entries"][t] = {"owner": "s1", "dev": st.st_dev, "ino": st.st_ino, "offset": st.st_size,
                   "paths": {"/nowhere": "yesterday"}, "cwd": None}
json.dump(d, open(path, "w"))
PY
out=$(hold --idle-hours 24 -- "$M/fresh"); rc=$?
chk "helper: a malformed cache entry is rescanned, still held" 0 "$rc"
out=$(hold --idle-hours -1 -- "$M/fresh" 2>&1); rc=$?
chk "helper: a negative window is a usage error (exit 2)" 2 "$rc"
err=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import wt_session_hold as m
m.check = lambda *a, **k: 1 / 0
sys.exit(m.main(["--claude-home", sys.argv[2], "--idle-hours", "24", "--", sys.argv[3]]))' "$LIB" "$H" "$M/env" 2>&1 >/dev/null); rc=$?
chk "helper: an internal error exits 4, never 1" 4 "$rc"
has "helper: and says to treat it as held" "$err" "check failed, treat as held"

# --- 5. a helper that cannot answer holds, through the sweep ----------------------
E="$TMP/e"; mkrepo "$E" one
mkdir -p "$TMP/lib4" "$TMP/lib3"; cp -R "$LIB/." "$TMP/lib4/"; cp -R "$LIB/." "$TMP/lib3/"
printf 'import sys\nsys.exit(4)\n' >"$TMP/lib4/wt_session_hold.py"
printf 'import sys\nsys.exit(3)\n' >"$TMP/lib3/wt_session_hold.py"
out=$(sweep "$E" 0 "$H" 24 "$TMP/lib4")
has "exit 4: treated as held" "$out" "skip (Claude session: session check unavailable (exit 4); treating as held): one"
kept "exit 4: nothing removed" "$E/one"
out=$(sweep "$E" 0 "$H" 24 "$TMP/lib3")
has "exit 3 without an idle line: treated as held" "$out" "skip (Claude session: idle check gave no idle line; treating as held): one"
kept "exit 3 without an idle line: nothing removed" "$E/one"

# --- 6. a dead, stale job's own worktree lapses (hov-stack#403); dist/ is a cache ---
# A job that is not done holds the worktree it names only while a running session
# record carries one of its ids (sessionId, resumeSessionId, transcript id) or its
# state.json was written inside the window. Past both, it is an idle hold like a
# lapsed mention: released only clean, cache-only and shipped. The jobs in section 2
# hold because their records were just written. dist/ and next-env.d.ts count as
# build output (dotfiles#2259); .wrangler/ and .venv/ do not.
slug(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
D="$TMP/d"
mkrepo "$D" deadown deaddist deadlive deadlive2 deadlive3 deadfresh deaddirty deadwrangler deadvenv deadunship deadcwd sharedcwd sharedid
mkdir -p "$D/repo/.git/info"; printf 'dist/\nnext-env.d.ts\n.wrangler/\n.venv/\n' >>"$D/repo/.git/info/exclude"
mkdir -p "$D/deaddist/dist" "$D/deaddist/apps/web/dist" "$D/deadwrangler/.wrangler/state" "$D/deadvenv/.venv/bin"
echo a >"$D/deaddist/dist/a.js"; echo b >"$D/deaddist/apps/web/dist/b.js"; echo n >"$D/deaddist/apps/web/next-env.d.ts"
echo db >"$D/deadwrangler/.wrangler/state/d1.sqlite"; echo py >"$D/deadvenv/.venv/bin/python"
echo new >"$D/deaddirty/new.txt"
{ echo two >"$D/deadunship/two.txt"; git -C "$D/deadunship" add -A; git -C "$D/deadunship" commit -qm two
  git -C "$D/deadunship" push -q; } >/dev/null 2>&1
dirty_head=$(git -C "$D/deaddirty" rev-parse HEAD)

H2="$TMP/h2"; L="$H2/projects/-launch"; mkdir -p "$H2/sessions" "$L"
job(){ # $1 id  $2 name  $3 extra JSON fields  [$4 age, default 30 hours; "" = just written]
  mkdir -p "$H2/jobs/$1"
  printf '{"state":"blocked","name":"%s","cwd":"%s",%s}\n' "$2" "$TMP" "$3" >"$H2/jobs/$1/state.json"
  [ -n "${4-30 hours}" ] && touch -d "-${4-30 hours}" "$H2/jobs/$1/state.json"
}
T3="$H2/projects/$(slug "$D/deadown")/s3.jsonl"; mkdir -p "$(dirname "$T3")"
# j3 launched in its worktree: its record's cwd and its transcript's project both name it.
mkdir -p "$H2/jobs/j3"
printf '{"state":"blocked","name":"own","sessionId":"s3","cwd":"%s","linkScanPath":"%s"}\n' "$D/deadown" "$T3" >"$H2/jobs/j3/state.json"
touch -d '-30 hours' "$H2/jobs/j3/state.json"
{ rec "$D/deadown" "$(ago '31 hours')"; readrec "$D/deadown" "$D/deadown/base.txt" "$(ago '30 hours')"; } >"$T3"
touch -d '-30 hours' "$T3"
# j4: names its worktree only in worktreePath, and has no transcript at all.
job j4 distjob "\"sessionId\":\"s4\",\"worktreePath\":\"$D/deaddist\",\"linkScanPath\":\"$L/s4.jsonl\""
# j5: stale record, but a live session carries its resumeSessionId: never lapses.
job j5 resumed "\"sessionId\":\"s5\",\"resumeSessionId\":\"r5\",\"worktreePath\":\"$D/deadlive\",\"linkScanPath\":\"$L/s5.jsonl\""
printf '{"pid":%s,"procStart":"%s","sessionId":"r5","cwd":"%s","name":"live5"}\n' "$$" "$(starttime $$)" "$TMP" >"$H2/sessions/$$.json"
# j6: dead, but its record was just written: inside the window.
job j6 fresh "\"sessionId\":\"s6\",\"worktreePath\":\"$D/deadfresh\",\"linkScanPath\":\"$L/s6.jsonl\"" ""
job j7 dirtyjob "\"sessionId\":\"s7\",\"worktreePath\":\"$D/deaddirty\",\"linkScanPath\":\"$L/s7.jsonl\""
job j8 wrangler "\"sessionId\":\"s8\",\"worktreePath\":\"$D/deadwrangler\",\"linkScanPath\":\"$L/s8.jsonl\""
job j9 venv "\"sessionId\":\"s9\",\"worktreePath\":\"$D/deadvenv\",\"linkScanPath\":\"$L/s9.jsonl\""
job j10 unshipped "\"sessionId\":\"s10\",\"worktreePath\":\"$D/deadunship\",\"linkScanPath\":\"$L/s10.jsonl\""
# j11 launched elsewhere and entered deadcwd: its transcript's last cwd is there.
T11="$L/s11.jsonl"
job j11 entered "\"sessionId\":\"s11\",\"linkScanPath\":\"$T11\""
{ rec "$TMP" "$(ago '32 hours')"; readrec "$TMP" "$D/deadcwd/base.txt" "$(ago '31 hours')"; rec "$D/deadcwd" "$(ago '30 hours')"; } >"$T11"
touch -d '-30 hours' "$T11"
# sharedcwd: a lapsed job named it, and the live session's own last cwd is there.
# The lapse frees only the lapsed job's own cwd, so the live session still holds it.
T12="$L/s12.jsonl"; T13="$L/r5.jsonl"
job j12 shared "\"sessionId\":\"s12\",\"linkScanPath\":\"$T12\""
readrec "$TMP" "$D/sharedcwd/base.txt" "$(ago '30 hours')" >"$T12"; touch -d '-30 hours' "$T12"
rec "$D/sharedcwd" "$(ago '30 hours')" >"$T13"; touch -d '-30 hours' "$T13"
# j16: stale record, but a live session carries its own sessionId (its transcript
# has another id, so the sessionId alone proves it alive).
job j16 livesid "\"sessionId\":\"s16\",\"worktreePath\":\"$D/deadlive2\",\"linkScanPath\":\"$L/t16.jsonl\""
printf '{"pid":%s,"procStart":"%s","sessionId":"s16","cwd":"%s","name":"live16"}\n' "$$" "$(starttime $$)" "$TMP" >"$H2/sessions/live16.json"
# j17: stale record whose sessionId differs from its transcript's name; the live
# session carries only the transcript's id (t17), which alone proves it alive.
job j17 ownerid "\"sessionId\":\"s17\",\"worktreePath\":\"$D/deadlive3\",\"linkScanPath\":\"$L/t17.jsonl\""
printf '{"pid":%s,"procStart":"%s","sessionId":"t17","cwd":"%s","name":"live17"}\n' "$$" "$(starttime $$)" "$TMP" >"$H2/sessions/live17.json"
# sharedid: j14 lapsed and entered it, but fresh j15 resumes j14's session, so that
# session's last cwd still holds.
T14="$L/s14.jsonl"
job j14 entered2 "\"sessionId\":\"s14\",\"linkScanPath\":\"$T14\""
job j15 resumer "\"sessionId\":\"s15\",\"resumeSessionId\":\"s14\",\"linkScanPath\":\"$L/s15.jsonl\"" ""
{ readrec "$TMP" "$D/sharedid/base.txt" "$(ago '31 hours')"; rec "$D/sharedid" "$(ago '30 hours')"; } >"$T14"
touch -d '-30 hours' "$T14"

DEADREL=$(printf '%s\n' "$D/deadcwd" "$D/deaddist" "$D/deadown" | sort)
plan=$(sweep "$D" 1 "$H2")
chk "dead job: the plan releases exactly the dead, stale, clean, shipped ones" "$DEADREL" "$(removals "$plan")"
has "dead job: its own worktree is idle, saying its session is gone" "$plan" \
  "~ idle: job j3 \"own\" is blocked and its session is not running; its transcript $T3 names $D/deadown"
has "dead job: a record naming it with no transcript is idle too" "$plan" \
  "~ idle: job j4 \"distjob\" is blocked and its session is not running; last named 30h ago"
has "dead job: its own last cwd no longer holds" "$plan" \
  "~ idle: job j11 \"entered\" is blocked and its session is not running; its transcript $T11 names $D/deadcwd"
has "dead job: a live session carrying its resumeSessionId holds" "$plan" "skip (Claude session: job j5 \"resumed\" is blocked): deadlive"
has "dead job: a live session carrying its sessionId holds" "$plan" "skip (Claude session: job j16 \"livesid\" is blocked): deadlive2"
has "dead job: a live session carrying its transcript's id holds" "$plan" "skip (Claude session: job j17 \"ownerid\" is blocked): deadlive3"
has "dead job: a session a fresh job resumes keeps its last cwd's hold" "$plan" \
  "its session last recorded its cwd at $D/sharedid): sharedid"
has "dead job: a record written inside the window holds" "$plan" "skip (Claude session: job j6 \"fresh\" is blocked): deadfresh"
has "dead job: dirty keeps it, never WIP-committed" "$plan" "skip (Claude session, idle but not clean on a branch: job j7"
has "dead job: an ignored .wrangler/ keeps it" "$plan" "idle but keeps ignored .wrangler"
has "dead job: an ignored .venv/ keeps it" "$plan" "idle but keeps ignored .venv"
has "dead job: pushed but unmerged keeps it" "$plan" "=> SKIP (idle, but not proven shipped"
has "dead job: a live session's own last cwd still holds" "$plan" "its session last recorded its cwd at $D/sharedcwd): sharedcwd"
has "dead job: counts" "$plan" "released-idle:3"
out=$(sweep "$D" 0 "$H2")
chk "dead job: the apply removes what the plan named" "$DEADREL" "$(removals "$out")"
for n in deadown deaddist deadcwd; do gone "dead job: $n released" "$D/$n"; done
for n in deadlive deadlive2 deadlive3 deadfresh deaddirty deadwrangler deadvenv deadunship sharedcwd sharedid; do kept "dead job: $n kept" "$D/$n"; done
chk "dead job: the dirty worktree's HEAD is untouched" "$dirty_head" "$(git -C "$D/deaddirty" rev-parse HEAD)"
[ -f "$D/deaddirty/new.txt" ] && ok "dead job: its untracked file is untouched" || no "dead job: its untracked file is untouched"

# --- 7. a record or transcript that cannot be read stops an idle answer (#660) ------
# Each would otherwise read as "nothing names it here". The helper directly, on a
# worktree held only by a mention 30 hours old, whose job's record is fresh.
Q="$TMP/q"; mkrepo "$Q" cw
H3="$TMP/h3"; C3="$TMP/hold-cache-3"; TQ="$H3/projects/-launch/sq.jsonl"
mkdir -p "$H3/jobs/jq" "$H3/sessions" "$(dirname "$TQ")"
printf '{"state":"blocked","name":"q","sessionId":"sq","cwd":"%s","linkScanPath":"%s"}\n' "$TMP" "$TQ" >"$H3/jobs/jq/state.json"
{ readrec "$TMP" "$Q/cw/base.txt" "$(ago '30 hours')"; rec "$TMP" "$(ago '30 hours')"; } >"$TQ"; touch -d '-30 hours' "$TQ"
hold3(){ python3 "$HELPER" --claude-home "$H3" --cache-dir "$C3" --active-min 0 "$@"; }
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>/dev/null); rc=$?
chk "unreadable: the control is idle (exit 3)" 3 "$rc"

mkdir -p "$H3/jobs/jbad"; printf '{"state": "work' >"$H3/jobs/jbad/state.json"   # half-written
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
chk "unreadable job record: held, not idle (exit 0)" 0 "$rc"
has "unreadable job record: says why" "$out" "not called idle: 1 record(s) or transcript(s) could not be read"
has "unreadable job record: noted on stderr" "$(cat "$TMP/err3")" "skipped unreadable $H3/jobs/jbad/state.json"
rm -r "$H3/jobs/jbad"

sh -c 'exit 0' & deadpid=$!; wait "$deadpid"
: >"$H3/sessions/$deadpid.json"
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
chk "empty record of a pid that is gone: still idle (exit 3)" 3 "$rc"
hasnot "empty record of a pid that is gone: no note" "$(cat "$TMP/err3")" "skipped unreadable"
rm "$H3/sessions/$deadpid.json"
: >"$H3/sessions/$$.json"
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
chk "empty record of a running pid: held, not idle (exit 0)" 0 "$rc"
has "empty record of a running pid: noted on stderr" "$(cat "$TMP/err3")" "skipped unreadable $H3/sessions/$$.json"
rm "$H3/sessions/$$.json"

# Cached, then grown, then unreadable: the cached mention still holds, and the unread
# tail may name it inside the window, so it is not idle either.
rec "$TMP" "$(ago '1 minute')" >>"$TQ"; touch -d '-30 hours' "$TQ"; chmod 000 "$TQ"
if [ -r "$TQ" ]; then
  ok "unreadable transcript: skipped (this user can read a mode-000 file)"
else
  out=$(hold3 -- "$Q/cw" 2>/dev/null); rc=$?
  chk "unreadable transcript: its cached mention still holds (exit 0)" 0 "$rc"
  has "unreadable transcript: the holder is named" "$out" "job jq \"q\" is blocked; its transcript $TQ names $Q/cw"
  out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
  chk "unreadable transcript: held, not idle (exit 0)" 0 "$rc"
  has "unreadable transcript: says why" "$out" "not called idle: 1 record(s) or transcript(s) could not be read"
  # A fresh transcript makes the next run rewrite the cache while TQ is still
  # unreadable; a run without the window then holds only if TQ's entry was kept.
  mkdir -p "$H3/projects/-other"; rec "$TMP" "$(ago '1 minute')" >"$H3/projects/-other/o.jsonl"
  before=$(cat "$C3"/*.v2.json | md5sum)
  hold3 --idle-hours 24 -- "$Q/cw" >/dev/null 2>&1
  after=$(cat "$C3"/*.v2.json | md5sum)
  [ "$before" != "$after" ] && ok "unreadable transcript: the cache was rewritten meanwhile" \
    || no "unreadable transcript: the cache was rewritten meanwhile"
  out=$(hold3 -- "$Q/cw" 2>/dev/null); rc=$?
  chk "unreadable transcript: its cache entry survives that rewrite (exit 0)" 0 "$rc"
fi
chmod 644 "$TQ"
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>/dev/null); rc=$?
chk "unreadable transcript: readable again, idle again (exit 3)" 3 "$rc"

# --- 8. a directory that cannot be listed is not an empty one (hov-stack#695) --------
# A missing directory reads as empty; one that exists but cannot be listed may hold
# the record that names the worktree, so nothing is idle while it stays unlisted.
mkdir -p "$H3/projects/-launch/sq/tool-results"   # a session dir with no subagents/
printf '{}\n' >"$H3/jobs/pins.json"                # a plain file beside the job dirs
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
chk "unlisted: a missing subagents/ and a plain file in jobs/ leave it idle (exit 3)" 3 "$rc"
hasnot "unlisted: neither is noted on stderr" "$(cat "$TMP/err3")" "could not list"
mkdir -p "$H3/projects/-locked" "$H3/projects/$(slug "$Q/cw")/sz/tool-results"
for d in "$H3/projects/-locked" "$H3/projects/-launch/sq/subagents" "$H3/projects/$(slug "$Q/cw")/sz/tool-results"; do
  mkdir -p "$d"; chmod 000 "$d"
  if [ -r "$d" ]; then
    ok "unlisted $d: skipped (this user can list a mode-000 directory)"
  else
    out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
    chk "unlisted $d: held, not idle (exit 0)" 0 "$rc"
    has "unlisted $d: says why" "$out" "not called idle"
    has "unlisted $d: noted on stderr" "$(cat "$TMP/err3")" "could not list $d"
  fi
  chmod 755 "$d"
done
# jobs/ unlisted: the one record that holds it goes unread, and an unread record never
# makes a hold, so it is unheld (the sweep's normal path, as before) and never idle.
chmod 000 "$H3/jobs"
if [ -r "$H3/jobs" ]; then
  ok "unlisted jobs/: skipped (this user can list a mode-000 directory)"
else
  out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>"$TMP/err3"); rc=$?
  chk "unlisted jobs/: unheld, never idle (exit 1)" 1 "$rc"
  has "unlisted jobs/: noted on stderr" "$(cat "$TMP/err3")" "could not list $H3/jobs"
fi
chmod 755 "$H3/jobs"
out=$(hold3 --idle-hours 24 -- "$Q/cw" 2>/dev/null); rc=$?
chk "unlisted: listable again, idle again (exit 3)" 3 "$rc"

# A stale blocked job whose session is live is held by it. With sessions/ unlisted,
# no session can be proven stopped, so the job must not lapse (it used to: a glob
# read the failed listing as "no session runs" and the worktree went idle).
H4="$TMP/h4"; C4="$TMP/hold-cache-4"; mkdir -p "$TMP/r4/dl" "$H4/jobs/jl" "$H4/sessions" "$H4/projects"
printf '{"state":"blocked","name":"dl","sessionId":"sl","worktreePath":"%s"}\n' "$TMP/r4/dl" >"$H4/jobs/jl/state.json"
touch -d '-30 hours' "$H4/jobs/jl/state.json"
printf '{"pid":%s,"procStart":"%s","sessionId":"sl","cwd":"%s","name":"livel"}\n' "$$" "$(starttime $$)" "$TMP" >"$H4/sessions/livel.json"
hold4(){ python3 "$HELPER" --claude-home "$H4" --cache-dir "$C4" --active-min 0 "$@"; }
out=$(hold4 --idle-hours 24 -- "$TMP/r4/dl" 2>/dev/null); rc=$?
chk "unlisted sessions/: the control is held by the live session (exit 0)" 0 "$rc"
chk "unlisted sessions/: the control names the job" 'job jl "dl" is blocked' "$out"
rm "$H4/sessions/livel.json"
out=$(hold4 --idle-hours 24 -- "$TMP/r4/dl" 2>/dev/null); rc=$?
chk "unlisted sessions/: with the session gone the job lapses (exit 3)" 3 "$rc"
printf '{"pid":%s,"procStart":"%s","sessionId":"sl","cwd":"%s","name":"livel"}\n' "$$" "$(starttime $$)" "$TMP" >"$H4/sessions/livel.json"
chmod 000 "$H4/sessions"
if [ -r "$H4/sessions" ]; then
  ok "unlisted sessions/: skipped (this user can list a mode-000 directory)"
else
  out=$(hold4 --idle-hours 24 -- "$TMP/r4/dl" 2>"$TMP/err4"); rc=$?
  chk "unlisted sessions/: the stale job still holds (exit 0)" 0 "$rc"
  chk "unlisted sessions/: and is not called stopped" 'job jl "dl" is blocked' "$out"
  has "unlisted sessions/: noted on stderr" "$(cat "$TMP/err4")" "could not list $H4/sessions"
fi
chmod 755 "$H4/sessions"

echo
echo "wt-sweep-idle-release: $pass passed, $fail failed"
[ "$fail" = 0 ]
