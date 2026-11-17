#!/usr/bin/env bash
# tests/setup-upgrade.test.sh: an install seeded at any earlier revision keeps working once its
# checkout moves to this one and setup runs again (`git pull && ./setup`, which is also what
# `./setup --update` does after its fast-forward).
#
# A seed is one distinct pair of (the template's hooks, lib/settings-seed.js) in the history of
# those two files, plus main's tip when origin/main exists, so an install from any day the
# template changed is covered and a new template revision adds itself. For each seed: clone this
# repository, check out that revision and run ITS ./setup --no-dcg on a clean HOME (the install a
# member got that day), move the checkout to HEAD plus this working tree's own edits (none in CI),
# run HEAD's ./setup --no-dcg, then run every hook command the resulting settings.json registers,
# with `{}` and with the armed payload tests/repo/setup.test.sh uses, under its registered timeout.
# It fails on either setup run exiting non-zero, on "Cannot find module", ENOENT or "No such file"
# from a hook, on run-with-flags.js reporting its script missing (it prints "[Hook] Script not
# found" and exits 0), and on a hook outliving its timeout.
#
# An install seeded before setup kept a record of its seed is never merged, so its settings.json
# still registers what the template registered then: this is where a deleted hook file shows up
# (hooks/PostToolUse/pr-record.js, deleted 2026-11-14 while installs seeded 10-26..11-02 still
# ran it). Planted negatives, on the newest seed that registers pr-record.js: with that file
# removed the check must fail and name it, and with PostToolUse/auto-format.js (registered through
# run-with-flags.js) removed instead it must fail and name that.
#
# ./setup --sync (#670, step 3), two more hops after the per-seed ones: a checkout moved by hand
# is merged by the next session start (bootstrap; an install with no record is left alone and
# told how to adopt), and a checkout that follows its origin moves and merges by itself
# (steady state: a bare origin, a successor commit adding a hook and its registration, a session
# start with the interval at 0). Planted negatives: a settings.json that cannot be merged leaves
# HEAD unmoved, and a successor registering a file it does not ship fails the hook check by name.
# HOV_UPDATE=off in every run_clean keeps a session start from pulling unless a case asks for it.
#
# Commands that name no ~/.claude/ path (dcg, an external binary --no-dcg leaves out) are
# counted, not run: tests/repo/setup.test.sh owns dcg's hook.
#
# Offline as tests/repo/setup.test.sh is: curl and minisign are stubs, claude is not on PATH, so
# no plugin or dcg step reaches the network. Needs the full history (fetch-depth 0).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = false ] \
  || fail "a shallow clone hides the template's history; fetch it in full (fetch-depth: 0)"

mkdir -p "$WORK/bin" "$WORK/stub"
real_node=$(mise which node 2>/dev/null || command -v node)
ln -s "$(readlink -f "$real_node")" "$WORK/bin/node"
ln -s "$(readlink -f "$(command -v git)")" "$WORK/bin/git"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:?}/curl"
echo "curl: (6) Could not resolve host: github.com" >&2
exit 6
EOF
printf '#!/bin/sh\necho "minisign stub: no case in this test verifies a signature" >&2\nexit 1\n' > "$WORK/bin/minisign"
chmod +x "$WORK/bin/curl" "$WORK/bin/minisign"
BASE_PATH=$WORK/bin:/usr/bin:/bin
# run_clean <home> <cmd...>: a fresh machine's environment, nothing inherited.
run_clean() {
  local h=$1; shift
  env -i HOME="$h" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" STUB_LOG="$WORK/stub" LANG=C.UTF-8 HOV_UPDATE=off "$@"
}
mkdir -p "$WORK/tmp"

# The seeds, oldest first: one revision per distinct (hooks, renderer) pair.
seeds=()
declare -A seen_pair=()
while read -r rev; do
  hooks=$(git -C "$ROOT" show "$rev:settings.json" | node -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      process.stdout.write(require("crypto").createHash("sha1").update(JSON.stringify(JSON.parse(s).hooks || {})).digest("hex"));
    });')
  renderer=$(git -C "$ROOT" rev-parse "$rev:lib/settings-seed.js")
  [ -z "${seen_pair[$hooks.$renderer]:-}" ] || continue
  seen_pair[$hooks.$renderer]=1
  seeds+=("$rev")
done < <(git -C "$ROOT" log --reverse --format=%H HEAD -- settings.json lib/settings-seed.js)
[ "${#seeds[@]}" -ge 10 ] || fail "found ${#seeds[@]} seeds in the template's history; 10 existed on 2026-11-16, so the history is cut short"
# Main's tip is a seed already when its own commit changed the template (#707 did), and in a
# merge-queue run HEAD sits on top of it: a second copy would clone into the first one's directory.
if main_tip=$(git -C "$ROOT" rev-parse -q --verify origin/main 2>/dev/null) && [ "$(git -C "$ROOT" rev-parse HEAD)" != "$main_tip" ] \
  && ! printf '%s\n' "${seeds[@]}" | grep -qxF "$main_tip"; then
  seeds+=("$main_tip")
fi
echo "# ${#seeds[@]} seeds: $(for s in "${seeds[@]}"; do printf '%s ' "${s:0:7}"; done)"

head_sha=$(git -C "$ROOT" rev-parse HEAD)
# move_to_head <checkout>: what a pull does, plus this working tree's uncommitted edits, staged
# or not, so a local run tests what is on disk. --no-renames lists a rename's old path (gone) and
# new path (copied) both.
move_to_head() {
  local c=$1 f
  git -C "$c" checkout -q --detach "$head_sha"
  while IFS= read -r -d '' f; do
    if [ -e "$ROOT/$f" ]; then mkdir -p "$c/$(dirname "$f")"; cp -p "$ROOT/$f" "$c/$f"; else rm -f "$c/$f"; fi
  done < <(cd "$ROOT" && git diff -z --no-renames --name-only HEAD && git ls-files -z -o --exclude-standard)
}
# What a hook prints when a file it needs is gone: node's own error, a shell's, or
# run-with-flags.js's (which exits 0 after it).
MISSING='Cannot find module|ENOENT|No such file|\[Hook\] Script not found|\[Hook\] Path traversal rejected'

bs=$(printf '\134')
armed_payload="{\"a\":\"${bs}u0020${bs}u0061\"}"
# check_hooks <home> <label>: run every registered command that names a ~/.claude/ path, twice,
# under its timeout; print one line per problem, and the counts on stdout's last line.
check_hooks() {
  local h=$1 label=$2 t cmd out rc n=0 skipped=0 problems=0 payload
  while IFS=$'\t' read -r t cmd; do
    case $cmd in *'/.claude/'*) ;; *) skipped=$((skipped + 1)); continue ;; esac
    n=$((n + 1))
    for payload in '{}' "$armed_payload"; do
      set +e
      out=$(cd "$h" && printf '%s' "$payload" | run_clean "$h" CLAUDE_LOOP_GUARD=1 timeout "$t" bash -c "$cmd" 2>&1)
      rc=$?
      set -e
      if [ "$rc" -eq 124 ]; then
        echo "  $label: outlived its ${t}s timeout: $cmd"; problems=$((problems + 1))
      elif grep -q -E "$MISSING" <<<"$out"; then
        echo "  $label: missing module or file: $cmd :: $(head -c 300 <<<"$out")"; problems=$((problems + 1))
      fi
    done
  done < <(node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const groups of Object.values(s.hooks || {})) for (const g of groups || []) for (const x of (g && g.hooks) || [])
      if (x && typeof x.command === "string") console.log(`${x.timeout || 60}\t${x.command.replace(/\n/g, " ")}`);
  ' "$h/.claude/settings.json")
  echo "counts $n $skipped $problems"
}

planted_seed=
for rev in "${seeds[@]}"; do
  short=${rev:0:7}
  h=$WORK/home-$short
  c=$WORK/checkout-$short
  mkdir -p "$h"
  git clone -q --shared "$ROOT" "$c"
  git -C "$c" checkout -q --detach "$rev"
  run_clean "$h" bash "$c/setup" --no-dcg > "$WORK/seed-$short.log" 2>&1 < /dev/null \
    || { sed 's/^/    | /' "$WORK/seed-$short.log"; fail "$short's own ./setup --no-dcg exited non-zero on a clean HOME"; }
  [ -f "$h/.claude/settings.json" ] || fail "$short's setup seeded no settings.json"
  grep -q -F 'pr-record.js' "$h/.claude/settings.json" && planted_seed=$short
  move_to_head "$c"
  run_clean "$h" bash "$c/setup" --no-dcg > "$WORK/up-$short.log" 2>&1 < /dev/null \
    || { sed 's/^/    | /' "$WORK/up-$short.log"; fail "HEAD's ./setup --no-dcg exited non-zero over the install $short seeded"; }
  report=$(check_hooks "$h" "$short")
  last=${report##*$'\n'}
  read -r _ n skipped problems <<<"$last"
  [ "$problems" -eq 0 ] || { printf '%s\n' "$report" | sed '$d'; fail "the install seeded at $short breaks after moving to HEAD"; }
  [ "$n" -ge 1 ] || fail "the install seeded at $short registers no hook command naming ~/.claude/; the check examined nothing"
  record=no; [ -f "$h/.claude/.hov-stack/setup-settings-base.json" ] && record=yes
  ok "seeded at $short ($(git -C "$ROOT" log -1 --format=%ad --date=short "$rev"), record: $record): $n hook commands run twice after moving to HEAD, none missing a file or outliving its timeout ($skipped external not run)"
done

# Planted negative: the newest seed that still registers pr-record.js, with the file gone.
[ -n "$planted_seed" ] || fail "no seed registers hooks/PostToolUse/pr-record.js, so the planted negative has nothing to break"
rm "$WORK/checkout-$planted_seed/hooks/PostToolUse/pr-record.js"
report=$(check_hooks "$WORK/home-$planted_seed" "$planted_seed")
last=${report##*$'\n'}
read -r _ n skipped problems <<<"$last"
[ "$problems" -ge 1 ] && grep -q -F 'pr-record.js' <<<"$report" \
  || { printf '%s\n' "$report"; fail "removing pr-record.js did not break the install seeded at $planted_seed; the check is blind"; }
ok "planted: with hooks/PostToolUse/pr-record.js removed, the install seeded at $planted_seed fails and names it"

# Planted negative for hooks registered through run-with-flags.js, which exits 0 on a missing
# script: put pr-record.js back, remove auto-format.js, and the same install must fail on it alone.
cp -p "$ROOT/hooks/PostToolUse/pr-record.js" "$WORK/checkout-$planted_seed/hooks/PostToolUse/pr-record.js"
grep -q -F 'PostToolUse/auto-format.js' "$WORK/home-$planted_seed/.claude/settings.json" \
  || fail "the install seeded at $planted_seed no longer registers auto-format.js through run-with-flags.js; pick another planted hook"
rm "$WORK/checkout-$planted_seed/hooks/PostToolUse/auto-format.js"
report=$(check_hooks "$WORK/home-$planted_seed" "$planted_seed")
last=${report##*$'\n'}
read -r _ n skipped problems <<<"$last"
[ "$problems" -ge 1 ] && grep -q -F 'auto-format.js' <<<"$report" && ! grep -q -F 'pr-record.js' <<<"$report" \
  || { printf '%s\n' "$report"; fail "removing auto-format.js did not break the install seeded at $planted_seed by name; run-with-flags hooks are unchecked"; }
ok "planted: with hooks/PostToolUse/auto-format.js removed, run-with-flags.js's 'Script not found' fails the install seeded at $planted_seed"


# ==== ./setup --sync (#670, step 3) ============================================================
# The two hops an install takes to get from "a checkout somebody moved by hand" and "a checkout
# that follows its origin" to "kept current by hov-stack itself".

# session_start <home> [VAR=val...]: what a new session runs, every registered SessionStart
# command, in order, each under its registered timeout, stdin a SessionStart payload from the
# home directory (not a repository). Prints their output.
session_start() {
  local h=$1 t cmd; shift
  while IFS=$'\t' read -r t cmd; do
    case $cmd in *'/.claude/'*) ;; *) continue ;; esac
    ( cd "$h" && printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$h" \
        | run_clean "$h" CLAUDE_LOOP_GUARD=1 "$@" timeout "$t" bash -c "$cmd" 2>&1 ) || :
  done < <(node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const g of (s.hooks || {}).SessionStart || []) for (const x of (g && g.hooks) || [])
      if (x && typeof x.command === "string") console.log(`${x.timeout || 60}\t${x.command.replace(/\n/g, " ")}`);
  ' "${SESSION_SETTINGS:-$h/.claude/settings.json}")
}
gate_hash() {  # gate_hash <home> <checkout>: the hash the session-start gate compares its stamp with
  run_clean "$1" CLAUDE_HOME="$1/.claude" node -e '
    const { gateHash } = require(process.argv[1]);
    process.stdout.write(gateHash({ cfg: process.argv[2], home: process.env.HOME, env: process.env }));
  ' "$2/lib/settings-apply.js" "$1/.claude"
}

# ---- bootstrap hop: the checkout is moved by hand, the next session start does the rest -------
# An install that ./setup created (it has a record) is moved to HEAD by a plain `git pull`. Its
# settings.json still registers what its old template did. The next session start must run
# `./setup --sync --no-pull` through the gate, which merges the new template and stamps the
# result. An install with no record (a settings.json setup did not create) must be left alone,
# and told how to adopt.
# No seed above keeps a record: setup began keeping one with the commit that introduced
# setup-settings-base.json (2026-11-16), after the newest seed's setup. The record installs are
# that commit and its first parent on HEAD's line when it keeps one too; the record-less one is
# the newest seed whose setup keeps none.
# (grep -c reads all of git's output; grep -q would end the pipe early and fail under pipefail.)
has_record() { [ "$(git -C "$ROOT" show "$1:setup" | grep -c -F 'setup-settings-base.json')" != 0 ]; }
first_record=$(git -C "$ROOT" log --reverse --format=%H -S'setup-settings-base.json' -- setup | head -n 1)
[ -n "$first_record" ] || fail "no commit in the history introduced setup's record of settings.json"
boot_revs=("$first_record")
parent=$(git -C "$ROOT" rev-parse -q --verify "$head_sha~1" 2>/dev/null) || parent=
if [ -n "$parent" ] && [ "$parent" != "$first_record" ] \
  && has_record "$parent"; then
  boot_revs+=("$parent")
fi
for ((i = ${#seeds[@]} - 1; i >= 0; i--)); do
  if ! has_record "${seeds[i]}"; then
    boot_revs+=("${seeds[i]}")
    break
  fi
done
boot_done=0 boot_norecord=
for rev in "${boot_revs[@]}"; do
  short=${rev:0:7}
  h=$WORK/bh-$short c=$WORK/bc-$short
  mkdir -p "$h"
  git clone -q --shared "$ROOT" "$c"
  git -C "$c" checkout -q --detach "$rev"
  run_clean "$h" bash "$c/setup" --no-dcg > "$WORK/bseed-$short.log" 2>&1 < /dev/null \
    || { sed 's/^/    | /' "$WORK/bseed-$short.log"; fail "$short's own ./setup --no-dcg exited non-zero on a clean HOME"; }
  if [ ! -f "$h/.claude/.hov-stack/setup-settings-base.json" ]; then
    boot_norecord=$short
    continue
  fi
  grep -q -F 'settings-apply.js' "$h/.claude/settings.json" || { ok "bootstrap, seeded at $short: settings-apply.js was not registered yet, so no session start could run the gate (skipped)"; continue; }
  move_to_head "$c"
  rm -f "$h/.claude/.hov-stack/settings-apply.stamp"
  session_start "$h" HOV_UPDATE=off > "$WORK/boot-$short.out" 2>&1
  [ -f "$h/.claude/.hov-stack/settings-apply.stamp" ] \
    || { sed 's/^/    | /' "$WORK/boot-$short.out"; fail "bootstrap, seeded at $short: the session start did not run ./setup --sync --no-pull (no gate stamp)"; }
  [ "$(cat "$h/.claude/.hov-stack/settings-apply.stamp")" = "$(gate_hash "$h" "$c")" ] \
    || fail "bootstrap, seeded at $short: the stamp is not the hash the gate compares with, so every session would merge again"
  report=$(check_hooks "$h" "boot-$short")
  last=${report##*$'\n'}
  read -r _ n skipped problems <<<"$last"
  [ "$problems" -eq 0 ] || { printf '%s\n' "$report" | sed '$d'; fail "bootstrap, seeded at $short: a registered hook breaks after the session-start merge"; }
  boot_done=$((boot_done + 1))
  ok "bootstrap, seeded at $short: a hand-moved checkout is merged by the next session start (stamp written), $n hook commands run clean"
done
[ "$boot_done" -ge 1 ] || fail "no seed with a record exercised the bootstrap hop"
[ -n "$boot_norecord" ] || fail "no seed without a record, so the adopt path was not exercised"
# The no-record install: nothing moves, settings.json is byte-identical, the notice names the commands.
h=$WORK/bh-$boot_norecord
c=$(git -C "$WORK/bc-$boot_norecord" rev-parse --show-toplevel)
move_to_head "$c"
sum=$(cksum < "$h/.claude/settings.json")
# HOV_UPDATE=off asked for no background update, so the notice (whose point is to enable one) is held.
out=$(session_start "$h" HOV_UPDATE=off)
if grep -q -F -- "--adopt --yes" <<<"$out"; then printf '%s\n' "$out"; fail "bootstrap, no record: the adopt notice was shown under HOV_UPDATE=off"; fi
out=$(session_start "$h" HOV_UPDATE=on)
[ "$(cksum < "$h/.claude/settings.json")" = "$sum" ] || fail "bootstrap, no record: settings.json was changed"
grep -q -F "$c/setup --adopt --yes" <<<"$out" || { printf '%s\n' "$out"; fail "bootstrap, no record: the session start did not name ./setup --adopt --yes"; }
ok "bootstrap, seeded at $boot_norecord (no record): settings.json is untouched and the session start names setup --adopt and --adopt --yes"

# ---- steady state: the checkout follows its origin by itself ----------------------------------
# A bare origin at HEAD, an install from it, then a successor commit that adds a hook and its
# registration. A session start with the sync interval at 0 starts the detached ./setup --sync;
# within a bounded wait HEAD is the successor, the registration is merged and every hook runs.
# steady <name>: sets SO (origin), SC (checkout), SH (home), SW (a writer clone).
steady() {
  local n=$1
  SO=$WORK/$n-origin.git SC=$WORK/$n-checkout SH=$WORK/$n-home SW=$WORK/$n-writer
  mkdir -p "$SH"
  git clone -q --bare "$ROOT" "$SO"
  git -C "$SO" branch -f main "$head_sha"
  git -C "$SO" symbolic-ref HEAD refs/heads/main
  git clone -q "$SO" "$SC"
  git -C "$SC" checkout -q main
  # What is on disk here, as move_to_head does for a detached checkout.
  local f
  while IFS= read -r -d '' f; do
    if [ -e "$ROOT/$f" ]; then mkdir -p "$SC/$(dirname "$f")"; cp -p "$ROOT/$f" "$SC/$f"; else rm -f "$SC/$f"; fi
  done < <(cd "$ROOT" && git diff -z --no-renames --name-only HEAD && git ls-files -z -o --exclude-standard)
  run_clean "$SH" bash "$SC/setup" --no-dcg > "$WORK/$n-install.log" 2>&1 < /dev/null \
    || { sed 's/^/    | /' "$WORK/$n-install.log"; fail "$n: the install failed"; }
  [ -f "$SH/.claude/.hov-stack/setup-settings-base.json" ] || fail "$n: setup kept no record"
  git clone -q "$SO" "$SW"
}
# successor <hook-file> <ship|noship>: push a commit registering hooks/SessionStart/<hook-file>.
successor() {
  if [ "$2" = ship ]; then
    printf '// added upstream\n' > "$SW/hooks/SessionStart/$1"
  fi
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.hooks.SessionStart.push({ hooks: [{ type: "command", command: `"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/SessionStart/${process.argv[2]}"`, timeout: 5 }] });
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$SW/settings.json" "$1"
  git -C "$SW" add -A
  git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -C "$SW" commit -q -m "successor $1"
  git -C "$SW" push -q origin main
  succ_sha=$(git -C "$SW" rev-parse HEAD)
}
# wait_for <seconds> <command...>: poll until it succeeds.
wait_for() {
  local limit=$(( $1 * 10 )) i=0; shift
  until "$@" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
sync_log_has() { grep -q -F "$1" "$SH/.claude/.hov-stack/sync.log" 2>/dev/null; }
# sync_done <text>: the detached sync printed its line and has exited. The line comes before the
# result file is written and the lock is released, so it alone does not mean the run is over; the
# session-start hook shows nothing while the lock is held.
sync_done() { sync_log_has "$1" && [ ! -e "$SH/.claude/.hov-stack/sync.lock" ]; }
head_is_successor() { [ "$(git -C "$SC" rev-parse HEAD)" = "$succ_sha" ]; }

steady good
successor successor-hook.js ship
session_start "$SH" HOV_UPDATE=on HOV_SYNC_INTERVAL=0 > "$WORK/good-session.out" 2>&1
wait_for 90 head_is_successor || { cat "$WORK/good-session.out"; cat "$SH/.claude/.hov-stack/sync.log" 2>/dev/null; fail "steady: HEAD never reached the successor"; }
wait_for 30 sync_done 'sync: moved' || { cat "$SH/.claude/.hov-stack/sync.log"; fail "steady: the detached sync did not finish with a moved result"; }
grep -q 'successor-hook.js' "$SH/.claude/settings.json" || fail "steady: the successor's registration was not merged"
[ -f "$SH/.claude/hooks/SessionStart/successor-hook.js" ] || fail "steady: the successor's hook file is not reachable"
# (Before check_hooks, which runs every hook and so claims the result.) The next session start shows the result once.
out=$(session_start "$SH" HOV_UPDATE=off)
grep -q '^\[hov-stack\] hov-stack updated ' <<<"$out" || { printf '%s\n' "$out"; fail "steady: the next session start did not show what the sync did"; }
out=$(session_start "$SH" HOV_UPDATE=off)
! grep -q '^\[hov-stack\] hov-stack updated ' <<<"$out" || fail "steady: the result was shown twice"
report=$(check_hooks "$SH" good)
last=${report##*$'\n'}; read -r _ n skipped problems <<<"$last"
[ "$problems" -eq 0 ] || { printf '%s\n' "$report" | sed '$d'; fail "steady: a hook breaks after the background sync"; }
ok "steady state: a successor adding a hook and its registration is pulled and merged in the background, shown once, and every hook runs"

# Planted negative: a settings.json the merge cannot plan keeps the checkout where it was.
steady blocked
cp "$SH/.claude/settings.json" "$SH/registered-settings.json"
printf '[1, 2]\n' > "$SH/.claude/settings.json"
successor never-moved.js ship
before=$(git -C "$SC" rev-parse HEAD)
rm -f "$SH/.claude/.hov-stack/sync.log"
SESSION_SETTINGS="$SH/registered-settings.json" session_start "$SH" HOV_UPDATE=on HOV_SYNC_INTERVAL=0 > "$WORK/blocked-session.out" 2>&1
wait_for 60 sync_done 'sync: blocked' || { cat "$SH/.claude/.hov-stack/sync.log" 2>/dev/null; fail "steady, unmergeable: the detached sync never reported a refusal"; }
[ "$(git -C "$SC" rev-parse HEAD)" = "$before" ] || fail "steady, unmergeable: the checkout moved under a settings.json that cannot be merged"
ok "planted: an unmergeable settings.json leaves the checkout where it was, and the sync says so"

# Planted negative: a successor that registers a hook file it does not ship fails the hook check by name.
steady ghost
successor ghost-hook.js noship
session_start "$SH" HOV_UPDATE=on HOV_SYNC_INTERVAL=0 > "$WORK/ghost-session.out" 2>&1
wait_for 90 head_is_successor || fail "steady, ghost: HEAD never reached the successor"
wait_for 30 sync_done 'sync: warning' || { cat "$SH/.claude/.hov-stack/sync.log"; fail "steady, ghost: the detached sync did not finish with a warning"; }
sync_log_has 'hook(s) skipped' || fail "steady, ghost: the result does not name the skipped hook"
grep -q -P '^[0-9]+\twarning\t' "$SH/.claude/.hov-stack/sync-result" || fail "steady, ghost: the result file is not a warning"
# The merge refuses to register a hook whose file is missing, so the install stays whole...
if grep -q -F 'ghost-hook.js' "$SH/.claude/settings.json"; then fail "steady, ghost: the merge registered a hook file the successor does not ship"; fi
report=$(check_hooks "$SH" ghost)
last=${report##*$'\n'}; read -r _ n skipped problems <<<"$last"
[ "$problems" -eq 0 ] || { printf '%s\n' "$report" | sed '$d'; fail "steady, ghost: the install breaks although the merge skipped the missing hook"; }
# ...and the check itself is not blind: the same registration made by hand is found by name.
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  s.hooks.SessionStart.push({ hooks: [{ type: "command", command: "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/SessionStart/ghost-hook.js\"", timeout: 5 }] });
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
' "$SH/.claude/settings.json"
report=$(check_hooks "$SH" ghost)
last=${report##*$'\n'}; read -r _ n skipped problems <<<"$last"
[ "$problems" -ge 1 ] && grep -q -F 'ghost-hook.js' <<<"$report" \
  || { printf '%s\n' "$report"; fail "a registered hook with no file did not fail the check by name; the check is blind to a successor's mistake"; }
ok "planted: a successor registering ghost-hook.js without shipping it is skipped by the merge, and a hand registration of it fails the hook check by name"

echo "setup-upgrade: $pass passed"
