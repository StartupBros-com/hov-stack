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

echo
echo "wt-sweep-idle-release: $pass passed, $fail failed"
[ "$fail" = 0 ]
