#!/usr/bin/env bash
# wt-sweep-preserve.test.sh — what a removal must not lose (hov-stack#384).
#
# THE DEFECTS THIS GUARDS (the live sweep of 2026-11-03)
#   1. A Claude Code session idling in a worktree it entered showed in neither the
#      top-dir mtime nor the /proc scan, and its worktree was removed under it.
#   2. `worktree remove` deletes gitignored files, with or without --force, and
#      .claude/deliverables/ is ignored: 168 operator-facing files went with 400
#      worktrees that `git status` called clean.
#   3. On a detached HEAD the preserve path committed the WIP to no ref, so the
#      commit went with the worktree's reflog.
#
#   Each fix has a planted negative: a done job, a reused pid and an old transcript
#   must NOT hold a worktree (or nothing would ever be swept); a copy that cannot be
#   made, a pin that cannot be written, and a missing helper must keep it.
#
#   Hermetic: bare origin + repo + worktrees under mktemp; the Claude home is a
#   fake directory (WT_CLAUDE_HOME); the repo-route resolver is stubbed to a
#   verified empty scan; ROOT points at the fixture. Never touches the operator's
#   tree, remotes, ~/.claude, or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
STAMP=$(date +%Y%m%d)

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
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

# ROOT=$TMP/$1 holding one repo (origin outside the root) whose .gitignore ignores
# .claude/deliverables/, as ~/.gitignore_global does on the operator's machine, and
# one worktree $TMP/$1/repo-wt on branch $1 pushed to origin: clean and shipped,
# so the sweep's clean path removes it unless something holds it.
mkfix(){
  local d="$TMP/$1"
  {
    mkdir -p "$d"
    git init --bare -q -b main "$TMP/$1-origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$TMP/$1-origin.git"
    printf '.claude/deliverables/\n' >"$d/repo/.gitignore"
    echo base >"$d/repo/base.txt"; git -C "$d/repo" add -A; git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    git -C "$d/repo" worktree add -q "$d/repo-wt" -b "$1" main
    git -C "$d/repo-wt" push -q -u origin "$1"
  } >/dev/null 2>&1
}
slug(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
starttime(){ python3 -c 'import sys; print(open(f"/proc/{sys.argv[1]}/stat").read().rsplit(")", 1)[1].split()[19])' "$1"; }
sweep(){ # $1 root  $2 DRY_RUN  $3 claude home  [$4 ACTIVE_MIN]  [$5 lib dir]
  DRY_RUN="$2" ROOT="$1" WT_CLAUDE_HOME="$3" WT_DONE_BIN="$TMP/no-wt-done" \
    REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN="${4:-0}" PUSH=0 \
    WT_SWEEP_LIB="${5:-$HERE/../scripts/lib}" bash "$SCRIPT" 2>&1
}
EMPTY="$TMP/claude-empty"; mkdir -p "$EMPTY"

echo "wt-sweep — what a removal must not lose (#384)"

# --- 1. control: a clean, shipped worktree with nothing holding it is removed ---
mkfix control
out=$(sweep "$TMP/control" 0 "$EMPTY")
gone "control: removed when nothing holds it" "$TMP/control/repo-wt"
hasnot "control: no deliverable copy reported" "$out" "deliverable"

# --- 2. a working job whose transcript lives under the worktree holds it ---------
mkfix jobwork
H="$TMP/h-jobwork"; WT="$TMP/jobwork/repo-wt"
mkdir -p "$H/jobs/j1" "$H/projects/$(slug "$WT")"
printf '{"state":"working","name":"idle ideation","cwd":"%s","linkScanPath":"%s"}\n' \
  "$TMP/jobwork/repo" "$H/projects/$(slug "$WT")/s1.jsonl" >"$H/jobs/j1/state.json"
: >"$H/projects/$(slug "$WT")/s1.jsonl"; touch -d '-1 day' "$H/projects/$(slug "$WT")/s1.jsonl"
out=$(sweep "$TMP/jobwork" 0 "$H")
kept "working job: worktree kept" "$WT"
has "working job: skip names the job" "$out" 'skip (Claude session: job j1 "idle ideation" is working)'

# --- 3. PLANTED NEGATIVE: the same job, done, only warns -------------------------
mkfix jobdone
H="$TMP/h-jobdone"; WT="$TMP/jobdone/repo-wt"
mkdir -p "$H/jobs/j2"
printf '{"state":"done","name":"finished","cwd":"%s","linkScanPath":"%s"}\n' \
  "$TMP/jobdone/repo" "$H/projects/$(slug "$WT")/s2.jsonl" >"$H/jobs/j2/state.json"
out=$(sweep "$TMP/jobdone" 0 "$H")
gone "done job: worktree removed" "$WT"
has "done job: warned as resumable" "$out" 'resumable: job j2 "finished" is done'
has "done job: counted in the totals" "$out" "resumable-warned:1"

# --- 4. a blocked job naming the worktree in worktreePath holds it ---------------
mkfix jobwtp
H="$TMP/h-jobwtp"; WT="$TMP/jobwtp/repo-wt"
mkdir -p "$H/jobs/j3"
printf '{"state":"blocked","name":"waiting","cwd":"%s","worktreePath":"%s","linkScanPath":"%s/projects/elsewhere/s.jsonl"}\n' \
  "$TMP/jobwtp/repo" "$WT" "$H" >"$H/jobs/j3/state.json"
out=$(sweep "$TMP/jobwtp" 0 "$H")
kept "blocked job via worktreePath: worktree kept" "$WT"
has "blocked job: skip names the state" "$out" 'is blocked'

# --- 5. a running session whose cwd is inside the worktree holds it --------------
mkfix sess
H="$TMP/h-sess"; WT="$TMP/sess/repo-wt"
mkdir -p "$H/sessions"
printf '{"pid":%s,"procStart":"%s","cwd":"%s/sub","name":"interactive"}\n' "$$" "$(starttime $$)" "$WT" >"$H/sessions/$$.json"
out=$(sweep "$TMP/sess" 0 "$H")
kept "live session: worktree kept" "$WT"
has "live session: skip names the pid" "$out" "session pid $$ \"interactive\" has its cwd here"

# --- 6. PLANTED NEGATIVE: the same pid with another start time is a reused pid ---
mkfix sessreuse
H="$TMP/h-sessreuse"; WT="$TMP/sessreuse/repo-wt"
mkdir -p "$H/sessions"
printf '{"pid":%s,"procStart":"1","cwd":"%s","name":"long gone"}\n' "$$" "$WT" >"$H/sessions/$$.json"
out=$(sweep "$TMP/sessreuse" 0 "$H")
gone "reused pid: worktree removed" "$WT"

# --- 7. a transcript written within ACTIVE_MIN holds it ---------------------------
mkfix trans
H="$TMP/h-trans"; WT="$TMP/trans/repo-wt"
mkdir -p "$H/projects/$(slug "$WT")/sub/subagents"
: >"$H/projects/$(slug "$WT")/sub/subagents/agent-1.jsonl"
touch -d '-1 day' "$WT"   # the top-dir mtime gate must not be what keeps it
out=$(sweep "$TMP/trans" 0 "$H" 120)
kept "fresh transcript: worktree kept" "$WT"
has "fresh transcript: skip names it" "$out" "a transcript under $H/projects/$(slug "$WT") was written 0m ago"

# --- 8. PLANTED NEGATIVE: an old transcript does not --------------------------------
mkfix transold
H="$TMP/h-transold"; WT="$TMP/transold/repo-wt"
mkdir -p "$H/projects/$(slug "$WT")"
: >"$H/projects/$(slug "$WT")/s.jsonl"; touch -d '-1 day' "$H/projects/$(slug "$WT")/s.jsonl"
touch -d '-1 day' "$WT"
out=$(sweep "$TMP/transold" 0 "$H" 120)
gone "old transcript: worktree removed" "$WT"

# --- 9. a session check that cannot answer reads as held ---------------------------
mkfix nohelper
cp -r "$HERE/../scripts/lib" "$TMP/lib-nohelper"; rm -f "$TMP/lib-nohelper/wt_session_hold.py"
out=$(sweep "$TMP/nohelper" 0 "$EMPTY" 0 "$TMP/lib-nohelper")
kept "missing helper: worktree kept" "$TMP/nohelper/repo-wt"
has "missing helper: says so" "$out" "session check unavailable"

# --- 10. a missing wt-preserve.sh stops the sweep before anything runs ------------
mkfix nolib
cp -r "$HERE/../scripts/lib" "$TMP/lib-nolib"; rm -f "$TMP/lib-nolib/wt-preserve.sh"
out=$(sweep "$TMP/nolib" 0 "$EMPTY" 0 "$TMP/lib-nolib"); rc=$?
[ "$rc" = 1 ] && ok "missing lib: exits 1" || no "missing lib: exits 1 (got $rc)"
has "missing lib: names it" "$out" "cannot load $TMP/lib-nolib/wt-preserve.sh"
kept "missing lib: worktree kept" "$TMP/nolib/repo-wt"

# --- 11. ignored deliverables: planned in a dry run, copied and verified for real --
mkfix res
WT="$TMP/res/repo-wt"; D="$TMP/res/repo/.claude/deliverables/from-worktrees/repo-wt"
mkdir -p "$WT/.claude/deliverables/seo"
printf 'the only copy\n' >"$WT/.claude/deliverables/seo/report.html"
printf 'notes\n' >"$WT/.claude/deliverables/notes.md"
[ -z "$(git -C "$WT" status --porcelain)" ] && ok "fixture: status calls the worktree clean" || no "fixture: status calls the worktree clean"
out=$(sweep "$TMP/res" 1 "$EMPTY")
has "dry run: plans the copy" "$out" "would: copy 2 ignored deliverable file(s) to $D"
[ -e "$D" ] && no "dry run: copied nothing" || ok "dry run: copied nothing"
kept "dry run: worktree kept" "$WT"
out=$(sweep "$TMP/res" 0 "$EMPTY")
has "apply: reports the copy" "$out" "ok: copied 2 ignored deliverable file(s) to $D"
gone "apply: worktree removed after the copy" "$WT"
grep -qx 'the only copy' "$D/seo/report.html" 2>/dev/null && ok "apply: nested deliverable survived" || no "apply: nested deliverable survived"
grep -qx 'notes' "$D/notes.md" 2>/dev/null && ok "apply: top-level deliverable survived" || no "apply: top-level deliverable survived"
[ -z "$(git -C "$TMP/res/repo" status --porcelain)" ] && ok "apply: main checkout still clean (copies are ignored)" || no "apply: main checkout still clean"

# --- 12. an earlier rescue of the same name is never overwritten -------------------
mkfix col
WT="$TMP/col/repo-wt"; R="$TMP/col/repo/.claude/deliverables/from-worktrees"
mkdir -p "$R/repo-wt" "$WT/.claude/deliverables"
printf 'earlier rescue\n' >"$R/repo-wt/report.md"
printf 'new\n' >"$WT/.claude/deliverables/report.md"
out=$(sweep "$TMP/col" 0 "$EMPTY")
grep -qx 'earlier rescue' "$R/repo-wt/report.md" && ok "collision: earlier copy untouched" || no "collision: earlier copy untouched"
grep -qx 'new' "$R/repo-wt-$STAMP/report.md" 2>/dev/null && ok "collision: new copy beside it, dated" || no "collision: new copy beside it, dated"

# --- 13. PLANTED NEGATIVE: a copy that cannot be made keeps the worktree -----------
mkfix resfail
WT="$TMP/resfail/repo-wt"
mkdir -p "$TMP/resfail/repo/.claude/deliverables" "$WT/.claude/deliverables"
: >"$TMP/resfail/repo/.claude/deliverables/from-worktrees"   # a file where the dir must go
printf 'must survive\n' >"$WT/.claude/deliverables/report.md"
out=$(sweep "$TMP/resfail" 0 "$EMPTY")
kept "failed copy: worktree kept" "$WT"
has "failed copy: says why" "$out" "SKIP (ignored deliverables could not be copied out; nothing removed)"
grep -qx 'must survive' "$WT/.claude/deliverables/report.md" && ok "failed copy: deliverable still in place" || no "failed copy: deliverable still in place"

# --- 14. a detached HEAD with WIP is pinned before removal -------------------------
mkfix det
WT="$TMP/det/repo-wt"; REF="refs/heads/recovered/wt-sweep-$STAMP/repo-wt"
{ git -C "$WT" checkout -q --detach; echo unshipped >"$WT/u.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm unshipped; } >/dev/null 2>&1
echo wip >"$WT/wip.txt"
out=$(sweep "$TMP/det" 1 "$EMPTY")
has "detached dry run: plans the pin" "$out" "would: git -C '$TMP/det/repo' update-ref '$REF'"
git -C "$TMP/det/repo" rev-parse -q --verify "$REF" >/dev/null && no "detached dry run: wrote no ref" || ok "detached dry run: wrote no ref"
out=$(sweep "$TMP/det" 0 "$EMPTY")
gone "detached: worktree removed" "$WT"
git -C "$TMP/det/repo" cat-file -e "$REF:wip.txt" 2>/dev/null && ok "detached: pinned ref holds the WIP file" || no "detached: pinned ref holds the WIP file"
git -C "$TMP/det/repo" cat-file -e "$REF:u.txt" 2>/dev/null && ok "detached: pinned ref holds the unshipped commit" || no "detached: pinned ref holds the unshipped commit"
has "detached: counted as preserved" "$out" "preserved-local:1"

# --- 15. PLANTED NEGATIVE: a pin that cannot be written keeps the worktree ---------
mkfix detcol
WT="$TMP/detcol/repo-wt"; REF="refs/heads/recovered/wt-sweep-$STAMP/repo-wt"
{ git -C "$WT" checkout -q --detach; echo unshipped >"$WT/u.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm unshipped; } >/dev/null 2>&1
git -C "$TMP/detcol/repo" update-ref "$REF" main
out=$(sweep "$TMP/detcol" 0 "$EMPTY")
kept "pin collision: worktree kept" "$WT"
has "pin collision: says why" "$out" "SKIP (detached HEAD could not be pinned — nothing removed)"
[ "$(git -C "$TMP/detcol/repo" rev-parse "$REF")" = "$(git -C "$TMP/detcol/repo" rev-parse main)" ] \
  && ok "pin collision: existing ref not overwritten" || no "pin collision: existing ref not overwritten"

echo
echo "wt-sweep-preserve: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
