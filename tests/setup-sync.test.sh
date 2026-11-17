#!/usr/bin/env bash
# tests/setup-sync.test.sh: `./setup --sync [--no-pull]` (#670, step 3), the one command that
# brings the checkout up to date and merges settings.json right after it, under one lock.
#
# Every case builds its own world on a scratch HOME: a bare origin, a seed working tree that
# pushes successor commits, a clone that ./setup installed from (so settings.json has setup's
# record), and nothing from the real HOME or the real ~/.claude. No network: curl and minisign
# are stubs, claude is not on PATH, and --no-dcg keeps dcg out. Covered:
#   - current, and moved: a successor that adds a hook file and the template's registration of
#     it lands both, the gate stamp is written, the lock is gone, the result file says so
#   - refusals leave HEAD, settings.json and the lock directory as they were, with a result
#     that says the fix: a checkout the config dir does not lead into (identity), a
#     settings.json the merge cannot plan (preflight), a local edit an incoming change
#     collides with, no record of setup creating settings.json (adopt sentence, exit 1)
#   - the lock: a live holder is skipped (exit 0, no result file), waited for under
#     HOV_SYNC_LOCK_WAIT, a dead holder's lock and a 15-minute-old one are taken
#   - HOV_UPDATE=notice reports and moves nothing; HOV_UPDATE=off and --no-pull still link and
#     merge after a hand `git pull`
#   - option conflicts exit 2
#   - a regular file where a link would go is left alone, nothing is backed up; a dangling link
#     is pointed at ours
#   - the owner route (sync.sh keeps the record): the role is read under set -u, the plan runs
#     before the move and a refusal stops it, apply runs after it; with no role it is blocked
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 022
WORK=$(mktemp -d) || exit 1
cleanup() {
  # Stand-ins for a lock holder, left behind by a failed case.
  [ -z "${holder_pid:-}" ] || kill "$holder_pid" 2>/dev/null || :
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

mkdir -p "$WORK/bin" "$WORK/tmp"
real_node=$(mise which node 2>/dev/null || command -v node)
ln -s "$(readlink -f "$real_node")" "$WORK/bin/node"
ln -s "$(readlink -f "$(command -v git)")" "$WORK/bin/git"
printf '#!/bin/sh\necho "curl: (6) Could not resolve host" >&2\nexit 6\n' > "$WORK/bin/curl"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/minisign"
chmod +x "$WORK/bin/curl" "$WORK/bin/minisign"
BASE_PATH=$WORK/bin:/usr/bin:/bin
# run_clean <home> [VAR=val...] <cmd...>
run_clean() {
  local h=$1; shift
  env -i HOME="$h" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" LANG=C.UTF-8 "$@"
}
gitc() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# world <name> [stub-sync]: sets S (the world), H (home), C (the clone ./setup installed from),
# SEED (the working tree that pushes successors). With stub-sync, sync.sh is a logging stub.
world() {
  local name=$1 f
  S=$WORK/$name H=$WORK/$name/home C=$WORK/$name/clone SEED=$WORK/$name/seed
  mkdir -p "$S" "$H" "$SEED"
  git init -q --bare "$S/origin.git"
  git -C "$S/origin.git" symbolic-ref HEAD refs/heads/main
  # This working tree as it is on disk, tracked and untracked, minus what it lacks.
  while IFS= read -r -d '' f; do
    [ -f "$ROOT/$f" ] || [ -L "$ROOT/$f" ] || continue
    case $f in .claude/*|tests/*|docs/*|release/*) continue ;; esac
    printf '%s\0' "$f"
  done < <(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard) > "$S/files.list"
  # One tar for the whole tree: a mkdir and a cp per file cost half a minute a world.
  (cd "$ROOT" && tar --null -T "$S/files.list" -cf -) | tar -xf - -C "$SEED"
  rm -f "$S/files.list"
  if [ "${2:-}" = stub-sync ]; then
    cat > "$SEED/sync.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "$CLAUDE_HOME" >> "$CLAUDE_HOME/../sync-calls"
case "$*" in *--plan*) exit "${SYNC_PLAN_RC:-0}" ;; esac
echo "settings: ${SYNC_STATUS:-applied 2}"
exit "${SYNC_APPLY_RC:-0}"
EOF
    chmod +x "$SEED/sync.sh"
  fi
  git init -q "$SEED"
  git -C "$SEED" symbolic-ref HEAD refs/heads/main
  gitc -C "$SEED" add -A
  gitc -C "$SEED" commit -q -m seed
  git -C "$SEED" remote add origin "$S/origin.git"
  git -C "$SEED" push -q origin main
  git clone -q "$S/origin.git" "$C"
  run_clean "$H" bash "$C/setup" --no-dcg > "$S/install.log" 2>&1 < /dev/null \
    || { sed 's/^/    | /' "$S/install.log"; fail "$name: the install itself failed"; }
  [ -f "$H/.claude/.hov-stack/setup-settings-base.json" ] || fail "$name: setup kept no record of settings.json"
}
# advance <file> <text>: a successor commit pushed to origin.
advance() {
  mkdir -p "$SEED/$(dirname "$1")"
  printf '%s\n' "$2" >> "$SEED/$1"
  gitc -C "$SEED" add -A
  gitc -C "$SEED" commit -q -m "successor $1"
  git -C "$SEED" push -q origin main
}
# A successor that ships a hook file and registers it in the template.
advance_hook() {
  mkdir -p "$SEED/hooks/SessionStart"
  printf '// a hook added upstream\n' > "$SEED/hooks/SessionStart/successor-hook.js"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.hooks.SessionStart.push({ hooks: [{ type: "command", command: "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/SessionStart/successor-hook.js\"", timeout: 5 }] });
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$SEED/settings.json"
  gitc -C "$SEED" add -A
  gitc -C "$SEED" commit -q -m "successor hook"
  git -C "$SEED" push -q origin main
}
# sy [VAR=val...] <args...>: ./setup --sync from the clone, on the world's home. Output in $OUT, status in $RC.
OUT= RC=0
sy() {
  local envs=()
  while [ "$#" -gt 0 ]; do
    case $1 in *=*) envs+=("$1"); shift ;; *) break ;; esac
  done
  RC=0
  OUT=$(run_clean "$H" ${envs[@]+"${envs[@]}"} bash "$C/setup" "$@" 2>&1 < /dev/null) || RC=$?
}
head_of() { git -C "${1:-$C}" rev-parse HEAD; }
result_state() { cut -f2 "$H/.claude/.hov-stack/sync-result"; }
no_lock() { [ ! -e "$H/.claude/.hov-stack/sync.lock" ] || fail "$1: the lock directory was left behind"; }
settings_sum() { cksum < "$H/.claude/settings.json"; }

# ---- 1. current -------------------------------------------------------------------------------
world current
before=$(head_of)
sy --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "current: exit $RC"; }
grep -q '^sync: current: hov-stack is up to date at ' <<<"$OUT" || { echo "$OUT"; fail "current: no current line"; }
[ "$(result_state)" = current ] || fail "current: result file says $(result_state)"
[ "$(head_of)" = "$before" ] || fail "current: HEAD moved"
[ -f "$H/.claude/.hov-stack/settings-apply.stamp" ] || fail "current: no gate stamp after the merge step"
no_lock current
ok "current: nothing upstream is exit 0, a current result, a gate stamp and no lock"

# ---- 2. moved: a successor adds a hook file and its registration ------------------------------
world moved
before=$(head_of)
advance_hook
sy --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "moved: exit $RC"; }
grep -q '^sync: moved: hov-stack updated ' <<<"$OUT" || { echo "$OUT"; fail "moved: no moved line"; }
[ "$(head_of)" = "$(head_of "$SEED")" ] || fail "moved: HEAD is not the successor"
[ "$(head_of)" != "$before" ] || fail "moved: HEAD did not move"
grep -q 'successor-hook.js' "$H/.claude/settings.json" || fail "moved: the registration did not merge"
[ -f "$H/.claude/hooks/SessionStart/successor-hook.js" ] || fail "moved: the hook file is not reachable through ~/.claude/hooks"
[ "$(result_state)" = moved ] || fail "moved: result file says $(result_state)"
no_lock moved
stamp=$(cat "$H/.claude/.hov-stack/settings-apply.stamp")
want=$(run_clean "$H" CLAUDE_HOME="$H/.claude" node -e '
  const { gateHash } = require(process.argv[1]);
  process.stdout.write(gateHash({ cfg: process.argv[2], home: process.env.HOME, env: process.env }));
' "$C/lib/settings-apply.js" "$H/.claude")
[ "$stamp" = "$want" ] || fail "moved: the gate stamp ($stamp) is not the hash the hook compares with ($want)"
# The session-start gate has nothing left to do: no sync.sh, no setup call.
sy --sync
grep -q '^sync: current: ' <<<"$OUT" || fail "moved: a second sync is not current"
ok "moved: a successor's hook file and registration land together, the stamp is written, the lock is gone"

# ---- 3. identity: a checkout the config dir does not lead into --------------------------------
world identity
git clone -q "$S/origin.git" "$S/other"
advance README.md "an upstream line"
sum=$(settings_sum)
rm -f "$H/.claude/.hov-stack/sync-result"
RC=0
OUT=$(run_clean "$H" bash "$S/other/setup" --sync 2>&1 < /dev/null) || RC=$?
[ "$RC" = 1 ] || { echo "$OUT"; fail "identity: exit $RC, wanted 1"; }
grep -q '^sync: blocked: .*does not lead into this checkout' <<<"$OUT" || { echo "$OUT"; fail "identity: wrong refusal"; }
[ "$(head_of "$S/other")" != "$(head_of "$SEED")" ] || fail "identity: the other clone moved"
[ ! -e "$H/.claude/.hov-stack/sync-result" ] || fail "identity: a result file was written"
no_lock identity
[ "$(settings_sum)" = "$sum" ] || fail "identity: settings.json changed"
ok "identity: a run from a clone the config dir does not lead into is blocked (exit 1) and touches nothing"

# ---- 4. preflight: a settings.json the merge cannot plan leaves HEAD where it was -------------
world preflight
advance README.md "an upstream line"
printf '[1, 2]\n' > "$H/.claude/settings.json"
before=$(head_of)
sum=$(settings_sum)
sy --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "preflight: exit $RC, wanted 1"; }
grep -q '^sync: blocked: .*the checkout was not moved' <<<"$OUT" || { echo "$OUT"; fail "preflight: wrong refusal"; }
[ "$(head_of)" = "$before" ] || fail "preflight: the checkout moved under a settings.json it cannot merge"
[ "$(settings_sum)" = "$sum" ] || fail "preflight: settings.json changed"
[ "$(result_state)" = blocked ] || fail "preflight: result file says $(result_state)"
no_lock preflight
ok "preflight: a settings.json that cannot be merged blocks the move (HEAD unmoved, file untouched)"

# ---- 5. collision: a local edit an incoming change collides with ------------------------------
world collision
advance README.md "an upstream line"
printf 'my own edit\n' >> "$C/README.md"
before=$(head_of)
sum=$(cksum < "$C/README.md")
sy --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "collision: exit $RC, wanted 1"; }
grep -q '^sync: blocked: .*a local change collides' <<<"$OUT" || { echo "$OUT"; fail "collision: wrong refusal"; }
[ "$(head_of)" = "$before" ] || fail "collision: HEAD moved"
[ "$(cksum < "$C/README.md")" = "$sum" ] || fail "collision: the local edit was changed"
if grep -q -e 'error:' -e 'would be overwritten' <<<"$OUT"; then fail "collision: git's own text reached the output: $OUT"; fi
if grep -q -e 'error:' -e 'would be overwritten' "$H/.claude/.hov-stack/sync-result"; then fail "collision: git's own text reached the result file"; fi
no_lock collision
ok "collision: a colliding local edit blocks the move and is left byte-identical"

# ---- 6. no record: blocked with the adopt sentence --------------------------------------------
world norecord
advance README.md "an upstream line"
rm -f "$H/.claude/.hov-stack/setup-settings-base.json"
before=$(head_of)
sum=$(settings_sum)
sy --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "norecord: exit $RC, wanted 1"; }
grep -q '^sync: blocked: hov-stack not updated: .*no record of ./setup creating it.*setup --adopt --yes' <<<"$OUT" \
  || { echo "$OUT"; fail "norecord: the adopt sentence is missing"; }
[ "$(head_of)" = "$before" ] || fail "norecord: HEAD moved"
[ "$(settings_sum)" = "$sum" ] || fail "norecord: settings.json changed"
no_lock norecord
ok "no record: blocked with the adopt sentence, exit 1, nothing moved"

# ---- 7. the lock ------------------------------------------------------------------------------
world lock
mkdir -p "$H/.claude/.hov-stack"
sleep 600 & holder_pid=$!
lock=$H/.claude/.hov-stack/sync.lock
mkdir "$lock"; echo "$holder_pid" > "$lock/pid"
advance README.md "an upstream line"
before=$(head_of)
rm -f "$H/.claude/.hov-stack/sync-result"
sy HOV_SYNC_LOCK_WAIT=0 --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "lock: a live holder exits $RC, wanted 0"; }
grep -q "^sync: skipped (another sync is running, pid $holder_pid)" <<<"$OUT" || { echo "$OUT"; fail "lock: wrong skip line"; }
[ "$(head_of)" = "$before" ] || fail "lock: HEAD moved while another sync held the lock"
[ ! -e "$H/.claude/.hov-stack/sync-result" ] || fail "lock: a skipped run wrote a result"
[ -d "$lock" ] || fail "lock: a live holder's lock was removed"
# Waits for a holder that lets go.
( sleep 2; rm -rf "$lock" ) &
sy HOV_SYNC_LOCK_WAIT=20 --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "lock: the wait ended in exit $RC"; }
grep -q '^sync: moved: ' <<<"$OUT" || { echo "$OUT"; fail "lock: it did not run after the holder let go"; }
no_lock lock
# A holder that died: the lock is stale.
kill "$holder_pid" 2>/dev/null || :; wait "$holder_pid" 2>/dev/null || :
mkdir "$lock"; echo "$holder_pid" > "$lock/pid"
sy HOV_SYNC_LOCK_WAIT=0 --sync
[ "$RC" = 0 ] && grep -q '^sync: current: ' <<<"$OUT" || { echo "$OUT"; fail "lock: a dead holder's lock was not taken"; }
no_lock lock
# A live holder whose lock is 20 minutes old is stale too (a hung run).
sleep 600 & holder_pid=$!
mkdir "$lock"; echo "$holder_pid" > "$lock/pid"
touch -d '20 minutes ago' "$lock"
sy HOV_SYNC_LOCK_WAIT=0 --sync
[ "$RC" = 0 ] && grep -q '^sync: current: ' <<<"$OUT" || { echo "$OUT"; fail "lock: a 20-minute-old lock was not taken"; }
no_lock lock
kill "$holder_pid" 2>/dev/null || :; wait "$holder_pid" 2>/dev/null || :; holder_pid=
ok "lock: a live young holder is skipped without a result, waited for, and a dead or 20-minute-old one is taken"

# ---- 8. HOV_UPDATE=notice ---------------------------------------------------------------------
world notice
advance README.md "an upstream line"
before=$(head_of)
sum=$(settings_sum)
sy HOV_UPDATE=notice --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "notice: exit $RC"; }
grep -q '^sync: notice: hov-stack is 1 commit(s) behind .*: ./setup --update brings it current' <<<"$OUT" || { echo "$OUT"; fail "notice: wrong line"; }
[ "$(head_of)" = "$before" ] || fail "notice: HEAD moved"
[ "$(settings_sum)" = "$sum" ] || fail "notice: settings.json changed"
[ "$(result_state)" = notice ] || fail "notice: result file says $(result_state)"
ok "HOV_UPDATE=notice: says how far behind, moves nothing"

# ---- 9. HOV_UPDATE=off and --no-pull still link and merge -------------------------------------
world nopull
advance_hook
before=$(head_of)
sy HOV_UPDATE=off --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "off: exit $RC"; }
grep -q '(no pull)' <<<"$OUT" || { echo "$OUT"; fail "off: not reported as no pull"; }
[ "$(head_of)" = "$before" ] || fail "off: HEAD moved under HOV_UPDATE=off"
git -C "$C" pull -q --ff-only
sy HOV_UPDATE=off --sync --no-pull
[ "$RC" = 0 ] || { echo "$OUT"; fail "no-pull: exit $RC"; }
grep -q 'successor-hook.js' "$H/.claude/settings.json" || fail "no-pull: the registration did not merge after a hand pull"
grep -q '^sync: current: .*merged 1 change' <<<"$OUT" || { echo "$OUT"; fail "no-pull: wrong result line"; }
ok "HOV_UPDATE=off and --no-pull: no pull, but the hand-pulled template still merges"

# ---- 10. option conflicts ---------------------------------------------------------------------
world conflicts
for combo in "--sync --check" "--sync --update" "--sync --adopt" "--sync --yes" "--no-pull"; do
  # shellcheck disable=SC2086
  sy $combo
  [ "$RC" = 2 ] || { echo "$OUT"; fail "conflicts: '$combo' exits $RC, wanted 2"; }
done
ok "option conflicts: --sync with --check/--update/--adopt/--yes, and --no-pull alone, exit 2"

# ---- 11. links: a file of the user's own stays, a dangling link is repointed ------------------
world links
mine=
dangling=
while IFS= read -r -d '' l; do
  case $l in "$H/.claude/hooks"|*/hooks/*) continue ;; esac
  if [ -z "$mine" ]; then mine=$l; elif [ -z "$dangling" ]; then dangling=$l; break; fi
done < <(find "$H/.claude" -maxdepth 2 -type l -lname "$C/*" -print0)
[ -n "$mine" ] && [ -n "$dangling" ] || fail "links: setup linked fewer than two paths"
target=$(readlink "$dangling")
rm -f "$mine"; printf 'my own file\n' > "$mine"
rm -f "$dangling"; ln -s "$S/nowhere" "$dangling"
ls "$H/.hov-stack-backups" > "$S/backups-before" 2>/dev/null || :
sy --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "links: exit $RC"; }
[ "$(cat "$mine")" = "my own file" ] && [ ! -L "$mine" ] || fail "links: the user's own file at $mine was touched"
grep -q "left alone, not hov-stack's: .*$(basename "$mine")" <<<"$OUT" || { echo "$OUT"; fail "links: the left-alone path is not named"; }
grep -q 'path(s) left alone' <<<"$OUT" || fail "links: the result does not count the left-alone path"
[ "$(readlink "$dangling")" = "$target" ] || fail "links: the dangling link was not pointed at ours"
ls "$H/.hov-stack-backups" > "$S/backups-after" 2>/dev/null || :
cmp -s "$S/backups-before" "$S/backups-after" || fail "links: a sync backed something up under ~/.hov-stack-backups"
ok "links: a regular file at a link destination is left alone and counted, a dangling link is repointed, nothing is backed up"

# ---- 12. the owner route (sync.sh keeps the record) -------------------------------------------
world owner stub-sync
printf '{}\n' > "$H/.claude/.hov-stack/settings-base.json"
roles=$S/hosts.tsv
printf '%s\tworkstation\n' "$(hostname -s)" > "$roles"
advance README.md "an upstream line"
before=$(head_of)
sy DOTFILES_ROLE_FILE="$roles" --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "owner: exit $RC"; }
grep -q '^sync: moved: .*merged 2 change(s) into settings.json' <<<"$OUT" || { echo "$OUT"; fail "owner: wrong result: $OUT"; }
[ "$(head_of)" != "$before" ] || fail "owner: HEAD did not move"
calls=$(cat "$H/sync-calls")
[ "$(grep -c -- '--plan --quiet' <<<"$calls")" -ge 1 ] || fail "owner: the plan did not run before the move"
grep -q -- "^apply-settings --quiet|$H/.claude\$" <<<"$calls" || { echo "$calls"; fail "owner: the apply did not run after the move"; }
# A refused plan stops the move.
advance README.md "another upstream line"
before=$(head_of)
rm -f "$H/sync-calls"
sy DOTFILES_ROLE_FILE="$roles" SYNC_PLAN_RC=3 --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "owner: a refused plan exits $RC, wanted 1"; }
grep -q '^sync: blocked: .*apply-settings --plan exits 3' <<<"$OUT" || { echo "$OUT"; fail "owner: the refusal does not say why"; }
[ "$(head_of)" = "$before" ] || fail "owner: the checkout moved past a refused plan"
grep -q -- '--plan' "$H/sync-calls" && ! grep -q -- '^apply-settings --quiet' "$H/sync-calls" || fail "owner: the apply ran past a refused plan"
# A skipped apply (sync.sh's own lock) is reported as failed.
sy DOTFILES_ROLE_FILE="$roles" SYNC_STATUS="skipped (another apply is running)" --sync
[ "$RC" = 1 ] && grep -q '^sync: failed: .*skipped (another apply' <<<"$OUT" || { echo "$OUT"; fail "owner: a skipped apply is not a failure"; }
# A held-back merge on the owner route is a warning (exit 0), not a quiet success.
sy DOTFILES_ROLE_FILE="$roles" SYNC_STATUS="applied 1; 1 conflict(s), see sync.sh check" --sync
[ "$RC" = 0 ] && grep -q '^sync: warning: .*the merge left something for you: applied 1; 1 conflict(s)' <<<"$OUT" || { echo "$OUT"; fail "owner: a conflict is not a warning"; }
sy DOTFILES_ROLE_FILE="$roles" SYNC_STATUS="applied 1" --sync
grep -q '^sync: current: ' <<<"$OUT" || { echo "$OUT"; fail "owner: a clean apply is not current"; }
# No role on this host: sync.sh's merge does not run here, so neither does setup's.
: > "$S/empty.tsv"
advance README.md "a third upstream line"
before=$(head_of)
sy DOTFILES_ROLE_FILE="$S/empty.tsv" --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "owner: no role exits $RC, wanted 1"; }
grep -q '^sync: blocked: .*no workstation or satellite role' <<<"$OUT" || { echo "$OUT"; fail "owner: no-role refusal missing"; }
[ "$(head_of)" = "$before" ] || fail "owner: no role, and the checkout moved"
ok "owner route: the role is read, the plan runs before the move (a refusal stops it), the apply after it; no role is blocked"

# ---- 13. refusals that need git state: one installed world, put back after each case ----------
world refusals
base=$(head_of)
restore() {  # restore: main at $base with its upstream, origin url as it was
  git -C "$C" checkout -q --detach 2>/dev/null || :
  git -C "$C" branch -q -f main "$base"
  git -C "$C" checkout -q main
  git -C "$C" branch -q --set-upstream-to=origin/main main
  git -C "$C" remote set-url origin "$S/origin.git"
  git -C "$C" config --unset core.sshCommand 2>/dev/null || :
}
expect_refusal() {  # expect_refusal <label> <state> <pattern>
  [ "$RC" = 1 ] || { echo "$OUT"; fail "$1: exit $RC, wanted 1"; }
  grep -q "^sync: $2: .*$3" <<<"$OUT" || { echo "$OUT"; fail "$1: wrong line (wanted $2: $3)"; }
  [ "$(result_state)" = "$2" ] || fail "$1: result file says $(result_state)"
  [ "$(head_of)" = "$4" ] || fail "$1: HEAD moved"
  no_lock "$1"
}
advance README.md "an upstream line"
# detached HEAD
git -C "$C" checkout -q --detach
before=$(head_of)
sy --sync
expect_refusal "detached" blocked 'HEAD is detached' "$before"
restore
# no upstream
git -C "$C" branch -q --unset-upstream main
before=$(head_of)
sy --sync
expect_refusal "no upstream" blocked 'has no upstream branch' "$before"
restore
# diverged: a commit of the user's own, and upstream moved
printf 'mine\n' > "$C/mine.txt"
git -C "$C" add mine.txt
gitc -C "$C" commit -q -m mine
before=$(head_of)
sy --sync
expect_refusal "diverged" blocked 'cannot fast-forward' "$before"
restore
# fetch failure: the credential in the origin URL stays out of everything
git -C "$C" remote set-url origin 'https://user:s3cr3t-token@127.0.0.1:9/x.git'
before=$(head_of)
sy --sync
expect_refusal "fetch failure" failed 'could not fetch' "$before"
if grep -q 's3cr3t-token' <<<"$OUT"; then fail "fetch failure: the URL's credential reached the output"; fi
if grep -q 's3cr3t-token' "$H/.claude/.hov-stack/sync-result"; then fail "fetch failure: the URL's credential reached the result file"; fi
restore
ok "refusals: a detached HEAD, a branch with no upstream and a diverged branch are blocked, a failed fetch is failed, HEAD unmoved each time and no URL credential shown"

# fetch cap: a fetch that hangs ends at HOV_SYNC_FETCH_TIMEOUT, with and without a `timeout` command
# The fake transports sleep through a link in this world, so the checks for a leftover match
# this run's processes only, not a sleep anywhere else on the host.
mkdir -p "$S/bin"
ln -s "$(command -v sleep)" "$S/bin/sleep"
printf '#!/bin/sh\nexec "%s/bin/sleep" 33\n' "$S" > "$S/hang-ssh"
chmod +x "$S/hang-ssh"
FARM=$WORK/farm
mkdir -p "$FARM"
for f in "$WORK/bin"/* /usr/bin/* /bin/*; do
  name=${f##*/}
  [ "$name" != timeout ] || continue
  [ -e "$FARM/$name" ] || [ -L "$FARM/$name" ] || ln -s "$f" "$FARM/$name"
done
[ ! -e "$FARM/timeout" ] || fail "fetch cap: the farm still has timeout"
git -C "$C" remote set-url origin 'ssh://hang.invalid/x.git'
git -C "$C" config core.sshCommand "$S/hang-ssh"
for variant in with-timeout without-timeout; do
  before=$(head_of)
  start=$(date +%s)
  if [ "$variant" = with-timeout ]; then sy HOV_SYNC_FETCH_TIMEOUT=2 --sync
  else sy PATH="$FARM" HOV_SYNC_FETCH_TIMEOUT=2 --sync
  fi
  elapsed=$(( $(date +%s) - start ))
  expect_refusal "fetch cap ($variant)" failed 'could not fetch' "$before"
  [ "$elapsed" -le 15 ] || fail "fetch cap ($variant): took $elapsed s for a 2 s cap"
  n=0; while pgrep -f "$S/bin/sleep" > /dev/null 2>&1 && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  if pgrep -f "$S/bin/sleep" > /dev/null 2>&1; then fail "fetch cap ($variant): the hung fetch's child is still running"; fi
done
# A fetch whose group is stopped, as a hand run's terminal stops it when ssh reads it (SIGTTIN):
# the cap still ends it. The outer timeout keeps a regression from hanging the suite.
printf '#!/bin/sh\nkill -s TTIN 0\nexec "%s/bin/sleep" 34\n' "$S" > "$S/stop-ssh"
chmod +x "$S/stop-ssh"
git -C "$C" config core.sshCommand "$S/stop-ssh"
for variant in with-timeout without-timeout; do
  before=$(head_of)
  p=$BASE_PATH
  [ "$variant" = with-timeout ] || p=$FARM
  RC=0
  OUT=$(timeout 30 env -i HOME="$H" PATH="$p" TMPDIR="$WORK/tmp" LANG=C.UTF-8 HOV_SYNC_FETCH_TIMEOUT=2 \
    bash "$C/setup" --sync 2>&1 < /dev/null) || RC=$?
  if [ "$RC" = 124 ]; then
    pkill -KILL -f "$S/stop-ssh" 2>/dev/null || :
    pkill -KILL -f "$C fetch" 2>/dev/null || :
    fail "fetch cap, stopped ($variant): still waiting after 30 s for a 2 s cap"
  fi
  expect_refusal "fetch cap, stopped ($variant)" failed 'could not fetch' "$before"
  n=0
  while { pgrep -f "$S/stop-ssh" || pgrep -f "$S/bin/sleep"; } > /dev/null 2>&1 && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  if { pgrep -f "$S/stop-ssh" || pgrep -f "$S/bin/sleep"; } > /dev/null 2>&1; then fail "fetch cap, stopped ($variant): the stopped transport is still there"; fi
done
restore
# The cap's value: 08 is eight seconds (not bad octal), and 0 is no cap, as for `timeout`.
for t in 08 0; do
  before=$(head_of)
  sy PATH="$FARM" HOV_SYNC_FETCH_TIMEOUT="$t" --sync
  [ "$RC" = 0 ] || { echo "$OUT"; fail "fetch cap $t: exit $RC, wanted 0"; }
  grep -q '^sync: moved: ' <<<"$OUT" || { echo "$OUT"; fail "fetch cap $t: wanted moved"; }
  [ "$(head_of)" != "$before" ] || fail "fetch cap $t: HEAD did not move"
  restore
done
ok "fetch cap: a hung fetch ends at HOV_SYNC_FETCH_TIMEOUT (2 s) as failed with HEAD unmoved, with and without a timeout command, stopped or not, nothing left running; 08 and 0 fetch"

# ---- 14. a merge that left something: warning, exit 0, the move still in the text --------------
world warning
before=$(head_of)
mkdir -p "$SEED/hooks/SessionStart"
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  s.hooks.SessionStart.push({ hooks: [{ type: "command", command: "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/SessionStart/never-shipped.js\"", timeout: 5 }] });
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
' "$SEED/settings.json"
gitc -C "$SEED" commit -q -am "registers a hook it does not ship"
git -C "$SEED" push -q origin main
sy --sync
[ "$RC" = 0 ] || { echo "$OUT"; fail "warning: exit $RC, wanted 0"; }
grep -q '^sync: warning: hov-stack updated [0-9a-f]* -> [0-9a-f]* (1 commit(s)); .*hook(s) skipped' <<<"$OUT" || { echo "$OUT"; fail "warning: wrong line"; }
[ "$(result_state)" = warning ] || fail "warning: result file says $(result_state)"
[ "$(head_of)" = "$(head_of "$SEED")" ] || fail "warning: HEAD is not the successor"
# Planted negative: the same successor without the missing file is plain moved (a clean merge is not a warning).
world warningclean
advance_hook
sy --sync
grep -q '^sync: moved: ' <<<"$OUT" || { echo "$OUT"; fail "warning: a clean merge is not moved"; }
ok "warning: a merge that skipped a hook is warning (exit 0) and still names the move; a clean one is moved"

# ---- 15. a successor whose own merge fails: failed, and the move is in the text ---------------
world failmove
before=$(head_of)
printf 'process.exit(3);\n' > "$SEED/lib/settings-seed.js"
gitc -C "$SEED" commit -q -am "a seed renderer that fails"
git -C "$SEED" push -q origin main
sy --sync
[ "$RC" = 1 ] || { echo "$OUT"; fail "failmove: exit $RC, wanted 1"; }
grep -q '^sync: failed: hov-stack updated [0-9a-f]* -> [0-9a-f]* (1 commit(s)); hov-stack: settings.json was not merged' <<<"$OUT" || { echo "$OUT"; fail "failmove: wrong line"; }
[ "$(head_of)" = "$(head_of "$SEED")" ] || fail "failmove: the checkout is not at the successor"
[ "$(head_of)" != "$before" ] || fail "failmove: HEAD did not move"
no_lock failmove
ok "failed after a move: a successor whose merge fails leaves the checkout moved, and the failed result says so"

# ---- 16. two syncs racing for a stale lock both finish, none reports a lock it could not make -
world race
mkdir -p "$H/.claude/.hov-stack"
for round in 1 2 3 4 5; do
  # A pid that is certainly dead: a child that has already exited and been reaped.
  true & holder_pid=$!
  wait "$holder_pid" 2>/dev/null || :
  mkdir "$H/.claude/.hov-stack/sync.lock"
  echo "$holder_pid" > "$H/.claude/.hov-stack/sync.lock/pid"
  run_clean "$H" HOV_SYNC_LOCK_WAIT=30 bash "$C/setup" --sync > "$S/race1.out" 2>&1 < /dev/null & p1=$!
  run_clean "$H" HOV_SYNC_LOCK_WAIT=30 bash "$C/setup" --sync > "$S/race2.out" 2>&1 < /dev/null & p2=$!
  r1=0; r2=0
  wait "$p1" || r1=$?
  wait "$p2" || r2=$?
  holder_pid=
  [ "$r1" = 0 ] && [ "$r2" = 0 ] || { cat "$S/race1.out" "$S/race2.out"; fail "race round $round: exits $r1 and $r2"; }
  if grep -q 'could not make the lock' "$S/race1.out" "$S/race2.out"; then fail "race round $round: a run could not make the lock"; fi
  grep -q '^sync: current: ' "$S/race1.out" && grep -q '^sync: current: ' "$S/race2.out" || { cat "$S/race1.out" "$S/race2.out"; fail "race round $round: a run did not finish"; }
  no_lock race
done
ok "lock race: two syncs finding a dead holder's lock both finish (5 rounds), no lock left"

# ---- 17. the two lock races, made deterministic with stand-in mkdir and cat -------------------
# (a) mkdir of the lock fails once and leaves nothing behind: the owner released it in between.
#     The run retries instead of reporting a lock it could not make.
# (b) the pid file read for the stale judgement names a dead process, but by the time of the
#     reap a live run owns the lock: the reap must leave it alone.
world lockrace
real_mkdir=$(command -v mkdir) real_cat=$(command -v cat)
mkdir -p "$WORK/shim-mkdir" "$WORK/shim-cat"
cat > "$WORK/shim-mkdir/mkdir" <<EOF
#!/bin/sh
case "\$*" in *sync.lock) if [ ! -e "\$SHIM_DONE" ]; then : > "\$SHIM_DONE"; exit 1; fi ;; esac
exec $real_mkdir "\$@"
EOF
cat > "$WORK/shim-cat/cat" <<EOF
#!/bin/sh
case "\$*" in *sync.lock/pid) if [ ! -e "\$SHIM_DONE" ]; then : > "\$SHIM_DONE"; echo "\$SHIM_DEAD"; exit 0; fi ;; esac
exec $real_cat "\$@"
EOF
chmod +x "$WORK/shim-mkdir/mkdir" "$WORK/shim-cat/cat"
sy PATH="$WORK/shim-mkdir:$BASE_PATH" SHIM_DONE="$WORK/shim-a.done" HOV_SYNC_LOCK_WAIT=0 --sync
[ "$RC" = 0 ] && grep -q '^sync: current: ' <<<"$OUT" || { echo "$OUT"; fail "lockrace (a): a lock that vanished between mkdir and the check was not retried"; }
[ -e "$WORK/shim-a.done" ] || fail "lockrace (a): the stand-in mkdir never ran, so nothing was tested"
no_lock lockrace
true & dead_pid=$!; wait "$dead_pid" 2>/dev/null || :
mkdir -p "$H/.claude/.hov-stack"
sleep 600 & holder_pid=$!
lock=$H/.claude/.hov-stack/sync.lock
mkdir "$lock"; echo "$holder_pid" > "$lock/pid"
sy PATH="$WORK/shim-cat:$BASE_PATH" SHIM_DONE="$WORK/shim-b.done" SHIM_DEAD="$dead_pid" HOV_SYNC_LOCK_WAIT=0 --sync
[ -e "$WORK/shim-b.done" ] || fail "lockrace (b): the stand-in cat never ran, so nothing was tested"
grep -q "^sync: skipped (another sync is running, pid $holder_pid)" <<<"$OUT" || { echo "$OUT"; fail "lockrace (b): the run did not leave a live owner's lock alone"; }
[ -d "$lock" ] && [ "$($real_cat "$lock/pid")" = "$holder_pid" ] || fail "lockrace (b): the live owner's lock was reaped"
kill "$holder_pid" 2>/dev/null || :; wait "$holder_pid" 2>/dev/null || :; holder_pid=
ok "lock races: a lock gone between mkdir and the check is retried, and a stale judgement is re-checked so a live owner's lock is not reaped"

# ---- no detached sync outlived the run --------------------------------------------------------
if pgrep -f "$WORK/.*/setup --sync" > /dev/null 2>&1; then
  fail "a setup --sync from this suite is still running"
fi
ok "no sync process left running"

echo "# $pass cases passed"
