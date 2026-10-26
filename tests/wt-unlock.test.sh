#!/usr/bin/env bash
# wt-unlock.test.sh — the staleness proof behind scripts/wt-unlock.sh (dotfiles#1590).
#
# THE DEFECT THIS GUARDS (2026-10-05 and nine more on 2026-10-19)
#   A git probe killed at its final index write-back leaves a 0-byte index.lock
#   with no process behind it; every later commit, fetch or reset on that
#   checkout fails, dcg refuses the rm, and the session stops to ask a human.
#   The helper may remove such a lock ONLY with proof: older than 60 s, no
#   process holding it open, no git process on its scope. Both directions are
#   pinned here — a stale lock goes, and a fresh, held, or git-attended lock
#   stays — or the fix would degenerate into "rm every lock".
#
# Hermetic: a repo plus one worktree under mktemp; holders are real child
# processes on the real /proc; the git-process cases use a fake procfs through
# WT_UNLOCK_PROCFS so no real git has to be kept alive. Lock paths are never
# exported: a child inherits the environment, and the lib's environ signal
# would then read the helper's own shell as the holder.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-unlock.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }
[ -f "$HERE/../scripts/lib/proc_liveness.py" ] || { echo "FAIL: cannot find proc_liveness.py"; exit 1; }

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3'; got: $2)";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }
exists(){ if [ -e "$2" ]; then ok "$1"; else no "$1 (missing: $2)"; fi; }
gone(){ if [ -e "$2" ]; then no "$1 (still present: $2)"; else ok "$1"; fi; }
# agemask <output>: the proof's second count read as Ns. plant() stamps the lock
# with one `date` and the helper reads another, so a second boundary between
# the two prints 121s for a 120 s plant; the wording is what the test pins.
agemask(){ sed -E 's/\(([0-9]+)s old, /(Ns old, /' <<<"$1"; }

TMP=$(mktemp -d)
holders=()
cleanup(){
  local p
  for p in "${holders[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

g(){ git -c user.email=t@t -c user.name=t "$@"; }
{
  g init -q -b main "$TMP/repo"
  echo base >"$TMP/repo/base.txt"
  g -C "$TMP/repo" add -A && g -C "$TMP/repo" commit -qm base
  g -C "$TMP/repo" worktree add -q "$TMP/wt" -b feat main
} >/dev/null 2>&1
CD=$(realpath "$TMP/repo/.git")
GD=$(realpath "$TMP/repo/.git/worktrees/wt")
[ -d "$GD" ] || { echo "FAIL: fixture has no worktree gitdir at $GD"; exit 1; }

# plant <path> [age-seconds]: a 0-byte lock whose mtime is that many seconds ago.
plant(){ : >"$1"; touch -d "@$(( $(date +%s) - ${2:-0} ))" "$1"; }

# fake_git_proc <dir> <pid> <comm> <cwd> [fd-target]: one entry in a fake procfs.
fake_proc(){
  local root="$1" pid="$2" comm="$3" cwd="$4" fdt="${5:-}"
  mkdir -p "$root/$pid/fd"
  printf '%s\n' "$comm" >"$root/$pid/comm"
  ln -s "$cwd" "$root/$pid/cwd"
  printf '%s\0status\0' "$comm" >"$root/$pid/cmdline"
  : >"$root/$pid/environ"
  [ -n "$fdt" ] && ln -s "$fdt" "$root/$pid/fd/3"
  return 0
}

echo "wt-unlock.sh — provably stale git locks only"

echo "-- 1. nothing to do is silent and exits 0 --"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "no locks: exit 0" 0 "$rc"
chk "no locks: no output" "" "$out"

echo "-- 2. dry run (the default) plans and touches nothing --"
plant "$GD/index.lock" 120
out=$(bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "dry run: exit 0" 0 "$rc"
has "dry run: prints the plan with its proof" "$(agemask "$out")" "would: rm $GD/index.lock (Ns old, 0 bytes, no process holds it open, no git on this worktree)"
exists "dry run: the lock is still there" "$GD/index.lock"

echo "-- 3. stale locks in both dirs are cleared, out-of-scope files are not --"
plant "$CD/packed-refs.lock" 300
mkdir -p "$CD/refs/heads" "$GD/refs/bisect"
plant "$CD/refs/heads/feat.lock" 90
plant "$GD/refs/bisect/bad.lock" 61
printf 'x' >"$CD/config.lock"; touch -d "@$(( $(date +%s) - 999 ))" "$CD/config.lock"
printf 'probe\n' >"$GD/locked"; touch -d "@$(( $(date +%s) - 999 ))" "$GD/locked"
plant "$CD/shallow.lock" 999
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "stale: exit 0" 0 "$rc"
has "stale: index.lock cleared with its proof" "$(agemask "$out")" "cleared: $GD/index.lock (Ns old, 0 bytes, no process holds it open, no git on this worktree)"
has "stale: packed-refs.lock cleared on the repo-wide proof" "$(agemask "$out")" "cleared: $CD/packed-refs.lock (Ns old, 0 bytes, no process holds it open, no git on any checkout of this repo)"
has "stale: a branch ref lock cleared" "$out" "cleared: $CD/refs/heads/feat.lock ("
has "stale: a worktree-private ref lock cleared" "$out" "cleared: $GD/refs/bisect/bad.lock ("
gone "stale: index.lock removed" "$GD/index.lock"
gone "stale: packed-refs.lock removed" "$CD/packed-refs.lock"
gone "stale: ref lock removed" "$CD/refs/heads/feat.lock"
gone "stale: worktree ref lock removed" "$GD/refs/bisect/bad.lock"
exists "scope: config.lock untouched" "$CD/config.lock"
exists "scope: shallow.lock untouched" "$CD/shallow.lock"
exists "scope: the worktree 'locked' marker untouched" "$GD/locked"
hasnot "scope: no mention of out-of-scope files" "$out" "config.lock"
rm -f "$CD/config.lock" "$CD/shallow.lock" "$GD/locked"
if g -C "$TMP/wt" commit -q --allow-empty -m unblocked >/dev/null 2>&1; then
  ok "stale: the worktree commits again"
else
  no "stale: the worktree still cannot commit"
fi

echo "-- 4. PLANTED NEGATIVE: a fresh lock is kept --"
plant "$GD/index.lock" 0
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "fresh: exit 1" 1 "$rc"
has "fresh: kept with its age" "$out" "kept: $GD/index.lock (fresh: "
exists "fresh: still present" "$GD/index.lock"
# 55 s, not 59: plant() and the helper read `date` separately, and a second
# boundary between the two would push a 59 s plant over the 60 s threshold.
plant "$GD/index.lock" 55
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "fresh under the threshold: exit 1" 1 "$rc"
exists "fresh under the threshold: still present" "$GD/index.lock"
rm -f "$GD/index.lock"

echo "-- 5. PLANTED NEGATIVE: a lock some process holds open is kept, however old --"
( exec sleep 60 ) 3>"$GD/index.lock" &
holders+=("$!")
sleep 0.3
touch -d "@$(( $(date +%s) - 400 ))" "$GD/index.lock"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "held: exit 1" 1 "$rc"
has "held: kept, naming the fd holder" "$out" "kept: $GD/index.lock (held open: $GD/index.lock fd pid:"
exists "held: still present" "$GD/index.lock"
kill "${holders[0]}" 2>/dev/null; wait "${holders[0]}" 2>/dev/null; holders=()
sleep 0.3
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "held: once the holder exits the same lock clears" 0 "$rc"
gone "held: removed after the holder exited" "$GD/index.lock"

echo "-- 6. PLANTED NEGATIVE: a git process on the worktree keeps its lock (fake procfs) --"
FAKE="$TMP/proc-git-wt"; fake_proc "$FAKE" 4242 git "$TMP/wt"
plant "$GD/index.lock" 500
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "git on worktree: exit 1" 1 "$rc"
has "git on worktree: kept on the first positive probe, naming the pid" "$out" "kept: $GD/index.lock (a git process is on this worktree (probe 1 of 3): $TMP/wt cwd pid:4242)"
exists "git on worktree: still present" "$GD/index.lock"

echo "-- 7. the filter is the program name: a bash with the same cwd keeps nothing --"
FAKE="$TMP/proc-bash-wt"; fake_proc "$FAKE" 4343 bash "$TMP/wt"
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "bash on worktree: exit 0" 0 "$rc"
has "bash on worktree: cleared" "$out" "cleared: $GD/index.lock ("
gone "bash on worktree: removed" "$GD/index.lock"

echo "-- 8. scope: a git in the common dir keeps a shared lock but not a worktree-private one --"
FAKE="$TMP/proc-git-common"; mkdir -p "$CD/objects/pack"; : >"$CD/objects/pack/tmp_pack"
fake_proc "$FAKE" 4444 git / "$CD/objects/pack/tmp_pack"
plant "$GD/index.lock" 500
plant "$CD/packed-refs.lock" 500
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "git in common: exit 1 (one lock kept)" 1 "$rc"
has "git in common: the worktree's index.lock clears" "$out" "cleared: $GD/index.lock ("
has "git in common: packed-refs.lock kept" "$out" "kept: $CD/packed-refs.lock (a git process is on any checkout of this repo (probe 1 of 3): $CD fd pid:4444)"
gone "git in common: index.lock removed" "$GD/index.lock"
exists "git in common: packed-refs.lock still present" "$CD/packed-refs.lock"
rm -f "$CD/packed-refs.lock" "$CD/objects/pack/tmp_pack"

echo "-- 9. PLANTED NEGATIVE: a liveness scan that cannot answer keeps the lock --"
mkdir -p "$TMP/proc-empty"
plant "$GD/index.lock" 500
out=$(WT_UNLOCK_PROCFS="$TMP/proc-empty" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "no answer: exit 1" 1 "$rc"
has "no answer: kept as unavailable" "$out" "kept: $GD/index.lock (liveness unavailable (rc 2)"
exists "no answer: still present" "$GD/index.lock"
out=$(WT_UNLOCK_LIB="$TMP/no-such-lib" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "missing lib: exit 2" 2 "$rc"
has "missing lib: says what is missing" "$out" "wt-unlock: missing $TMP/no-such-lib/proc_liveness.py"
exists "missing lib: still present" "$GD/index.lock"
rm -f "$GD/index.lock"

echo "-- 10. the main checkout (gitdir is the common dir) --"
plant "$CD/index.lock" 200
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/repo" 2>&1); rc=$?
chk "main checkout: exit 0" 0 "$rc"
has "main checkout: cleared on the main checkout's proof" "$(agemask "$out")" "cleared: $CD/index.lock (Ns old, 0 bytes, no process holds it open, no git on the main checkout)"
gone "main checkout: removed" "$CD/index.lock"
chk "main checkout: one line per lock, no duplicate for the shared dir" 1 "$(grep -c '' <<<"$out")"

echo "-- 11. usage --"
out=$(bash "$SCRIPT" 2>&1); rc=$?
chk "no argument: exit 2" 2 "$rc"
mkdir -p "$TMP/plain"
out=$(bash "$SCRIPT" "$TMP/plain" 2>&1); rc=$?
chk "not a checkout: exit 2" 2 "$rc"
has "not a checkout: says so" "$out" "not a git checkout"

echo "-- 12. PLANTED NEGATIVE: a git in another linked worktree keeps the shared locks (review P1) --"
g -C "$TMP/repo" worktree add -q "$TMP/other" -b other main >/dev/null 2>&1
[ -d "$TMP/other" ] || { echo "FAIL: fixture has no second worktree at $TMP/other"; exit 1; }
FAKE="$TMP/proc-git-other"; fake_proc "$FAKE" 4545 git "$TMP/other"
plant "$GD/index.lock" 500
plant "$CD/packed-refs.lock" 500
mkdir -p "$CD/refs/heads"; plant "$CD/refs/heads/zz.lock" 500
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "git in other: exit 1 (the shared locks are kept)" 1 "$rc"
has "git in other: this worktree's index.lock clears" "$out" "cleared: $GD/index.lock ("
has "git in other: packed-refs.lock kept on the repo-wide scope" "$out" "kept: $CD/packed-refs.lock (a git process is on any checkout of this repo (probe 1 of 3): $TMP/other cwd pid:4545)"
has "git in other: the ref lock kept on the repo-wide scope" "$out" "kept: $CD/refs/heads/zz.lock (a git process is on any checkout of this repo (probe 1 of 3): $TMP/other cwd pid:4545)"
gone "git in other: index.lock removed" "$GD/index.lock"
exists "git in other: packed-refs.lock still present" "$CD/packed-refs.lock"
exists "git in other: ref lock still present" "$CD/refs/heads/zz.lock"
plant "$CD/index.lock" 500
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/repo" 2>&1); rc=$?
chk "git in other, main checkout: exit 1" 1 "$rc"
has "git in other, main checkout: its own index.lock clears" "$out" "cleared: $CD/index.lock ("
has "git in other, main checkout: packed-refs.lock kept" "$out" "kept: $CD/packed-refs.lock (a git process is on any checkout of this repo (probe 1 of 3): $TMP/other cwd pid:4545)"
gone "git in other, main checkout: index.lock removed" "$CD/index.lock"
FAKE="$TMP/proc-bash-other"; fake_proc "$FAKE" 4646 bash "$TMP/other"
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "bash in other: exit 0 (the program name still gates)" 0 "$rc"
has "bash in other: packed-refs.lock cleared on the repo-wide proof" "$(agemask "$out")" "cleared: $CD/packed-refs.lock (Ns old, 0 bytes, no process holds it open, no git on any checkout of this repo)"
gone "bash in other: packed-refs.lock removed" "$CD/packed-refs.lock"
gone "bash in other: ref lock removed" "$CD/refs/heads/zz.lock"

echo "-- 13. three negative samples are required; a git seen on any probe keeps the lock (review P2) --"
mkdir -p "$TMP/fakelib"
cat >"$TMP/fakelib/proc_liveness.py" <<'PY'
import os, sys
# Stand-in for the lib: the holder check (no --comm) is never held; each
# --comm probe counts itself in FAKE_COUNTER and exits with the next code
# in FAKE_SEQ (the last code repeats).
argv = sys.argv[1:]
if "--comm" not in argv:
    sys.exit(1)
counter = os.environ["FAKE_COUNTER"]
n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
with open(counter, "w") as fh:
    fh.write(str(n))
codes = os.environ["FAKE_SEQ"].split(",")
code = int(codes[min(n, len(codes)) - 1])
if code == 0:
    print("/x\tcwd\tpid:4747")
sys.exit(code)
PY
plant "$GD/index.lock" 500
rm -f "$TMP/count"
out=$(FAKE_SEQ=1,1,1 FAKE_COUNTER="$TMP/count" WT_UNLOCK_LIB="$TMP/fakelib" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "three negatives: exit 0" 0 "$rc"
has "three negatives: cleared" "$out" "cleared: $GD/index.lock ("
chk "three negatives: the git probe ran three times" 3 "$(cat "$TMP/count")"
plant "$GD/index.lock" 500
rm -f "$TMP/count"
out=$(FAKE_SEQ=1,0 FAKE_COUNTER="$TMP/count" WT_UNLOCK_LIB="$TMP/fakelib" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "git on probe 2: exit 1" 1 "$rc"
has "git on probe 2: kept, naming the probe" "$out" "kept: $GD/index.lock (a git process is on this worktree (probe 2 of 3): /x cwd pid:4747)"
chk "git on probe 2: no further sampling after the positive" 2 "$(cat "$TMP/count")"
exists "git on probe 2: still present" "$GD/index.lock"
rm -f "$TMP/count"
out=$(FAKE_SEQ=1,1,2 FAKE_COUNTER="$TMP/count" WT_UNLOCK_LIB="$TMP/fakelib" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "unanswerable probe 3: exit 1" 1 "$rc"
has "unanswerable probe 3: kept as unavailable" "$out" "kept: $GD/index.lock (liveness unavailable (rc 2)"
chk "unanswerable probe 3: three probes ran" 3 "$(cat "$TMP/count")"
exists "unanswerable probe 3: still present" "$GD/index.lock"
rm -f "$GD/index.lock"

echo "-- 14. PLANTED NEGATIVE: a git in the main root keeps the main index.lock when the helper runs from a worktree --"
# wt-done runs the helper from a linked worktree; the main checkout's
# index.lock must still scope to the main root, not to that worktree.
FAKE="$TMP/proc-git-main"; fake_proc "$FAKE" 4848 git "$TMP/repo"
plant "$CD/index.lock" 500
plant "$GD/index.lock" 500
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "git in main, from the worktree: exit 1" 1 "$rc"
has "git in main, from the worktree: the main index.lock kept on the main checkout's scope" "$out" "kept: $CD/index.lock (a git process is on the main checkout (probe 1 of 3): $TMP/repo cwd pid:4848)"
has "git in main, from the worktree: this worktree's index.lock clears" "$out" "cleared: $GD/index.lock ("
exists "git in main, from the worktree: main index.lock still present" "$CD/index.lock"
gone "git in main, from the worktree: worktree index.lock removed" "$GD/index.lock"
FAKE="$TMP/proc-bash-main"; fake_proc "$FAKE" 4949 bash "$TMP/repo"
out=$(WT_UNLOCK_PROCFS="$FAKE" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "bash in main, from the worktree: exit 0" 0 "$rc"
has "bash in main, from the worktree: the main index.lock cleared on the main checkout's proof" "$(agemask "$out")" "cleared: $CD/index.lock (Ns old, 0 bytes, no process holds it open, no git on the main checkout)"
gone "bash in main, from the worktree: main index.lock removed" "$CD/index.lock"

echo "-- 15. PLANTED NEGATIVE: an unreadable worktree list keeps every lock in the common dir --"
# A stand-in git whose `worktree list` fails and that is otherwise real: the
# helper cannot know a shared lock's scope, so it keeps the lock rather than
# narrowing the scope to the invoking checkout.
REAL_GIT=$(command -v git)
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/git" <<EOF
#!/usr/bin/env bash
[ "\$3" = worktree ] && [ "\$4" = list ] && exit 128
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/fakebin/git"
plant "$GD/index.lock" 500
plant "$CD/index.lock" 500
plant "$CD/packed-refs.lock" 500
out=$(PATH="$TMP/fakebin:$PATH" DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "no worktree list: exit 1" 1 "$rc"
has "no worktree list: this worktree's index.lock still clears" "$out" "cleared: $GD/index.lock ("
has "no worktree list: the main index.lock kept as unknown scope" "$out" "kept: $CD/index.lock (cannot list this repo's worktrees, so its scope is unknown)"
has "no worktree list: packed-refs.lock kept as unknown scope" "$out" "kept: $CD/packed-refs.lock (cannot list this repo's worktrees, so its scope is unknown)"
gone "no worktree list: worktree index.lock removed" "$GD/index.lock"
exists "no worktree list: main index.lock still present" "$CD/index.lock"
exists "no worktree list: packed-refs.lock still present" "$CD/packed-refs.lock"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/wt" 2>&1); rc=$?
chk "worktree list readable again: exit 0" 0 "$rc"
gone "worktree list readable again: main index.lock removed" "$CD/index.lock"
gone "worktree list readable again: packed-refs.lock removed" "$CD/packed-refs.lock"

echo
echo "wt-unlock: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
