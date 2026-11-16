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
  env -i HOME="$h" PATH="$BASE_PATH" TMPDIR="$WORK/tmp" STUB_LOG="$WORK/stub" LANG=C.UTF-8 "$@"
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
if main_tip=$(git -C "$ROOT" rev-parse -q --verify origin/main 2>/dev/null) && [ "$(git -C "$ROOT" rev-parse HEAD)" != "$main_tip" ]; then
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

echo "setup-upgrade: $pass passed"
