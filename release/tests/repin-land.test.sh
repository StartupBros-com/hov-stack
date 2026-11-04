#!/usr/bin/env bash
set -euo pipefail

# Tests for release/scripts/repin-land.sh.
#
# Landing is the step that lets a bot change what every client installs, so the
# properties worth proving are: it requests auto-merge only on the bot's own,
# same-repository PR whose single changed file is byte-identical to the
# reconciler's output; it never touches anyone else's PR; it closes only the
# repin PRs a newer one or main superseded; and it is safe to run again.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"
export FIX="$TMP/fix" CALLS="$TMP/calls"
mkdir -p "$FIX"

# Stub gh: serves PR metadata from $FIX and records every merge and close in
# $CALLS. It honours --jq, as the real gh does.
cat > "$TMP/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
set -e
cmd="$1 $2"; shift 2
jqexpr='' num='' head=''
case "$cmd" in 'pr view'|'pr merge'|'pr close') num="$1"; shift ;; esac
path=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    --match-head-commit) head="$2"; shift 2 ;;
    --repo|--json|--state|--limit|--comment) shift 2 ;;
    -*) shift ;;
    *) path="$1"; shift ;;
  esac
done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
case "$cmd" in
  'pr list')
    [ -s "$FIX/prs.json" ] || { printf 'HTTP 502\n' >&2; exit 1; }
    emit < "$FIX/prs.json" ;;
  'pr view') emit < "$FIX/files-$num.json" ;;
  'api repos/acme/market/contents/.claude-plugin/marketplace.json?ref='*)
    printf '{"sha":"%s"}\n' "$(cat "$FIX/blob")" | emit ;;
  'api repos/acme/market/contents/tools/pins.sh?ref='*)
    printf '{"sha":"%s"}\n' "$(cat "$FIX/pins-blob")" | emit ;;
  'pr merge') printf 'merge %s %s\n' "$num" "$head" >> "$CALLS" ;;
  'pr close') printf 'close %s\n' "$num" >> "$CALLS" ;;
  *) printf 'unexpected gh: %s\n' "$cmd" >&2; exit 1 ;;
esac
STUBGH
chmod +x "$TMP/bin/gh"

# The App's real slug, and the author shape `gh pr list --json author` returned for the
# bot's repin PRs #205-#207: {"is_bot": true, "login": "app/<slug>"}.
SLUG=startupbros-hov-marketplace-bot
BOT="app/$SLUG"
HEAD_SHA=cccccccccccccccccccccccccccccccccccccccc
BLOB=dddddddddddddddddddddddddddddddddddddddd

# One open PR per row: number, head branch, author, cross-repo, auto-merge already on.
pr() { # $1 number $2 branch $3 author $4 cross $5 automerge(true|false)
  jq -n --argjson n "$1" --arg b "$2" --arg a "$3" --argjson x "$4" --argjson m "$5" --arg h "$HEAD_SHA" \
    '{number: $n, headRefName: $b, headRefOid: $h,
      author: {login: $a, is_bot: ($a | startswith("app/") or endswith("[bot]"))},
      isCrossRepository: $x, autoMergeRequest: (if $m then {mergeMethod: "SQUASH"} else null end)}'
}

# The usual world: #10 is this run's PR, #9 an older bot repin, and #8 a fork PR, #7 a
# human PR and #5 another App's PR that all happen to use a repin/auto- branch name.
standard_prs() { # $1 = whether #10 already has auto-merge
  {
    pr 10 repin/auto-new "$BOT" false "$1"
    pr 9 repin/auto-old "$BOT" false false
    pr 8 repin/auto-fork "$BOT" true false
    pr 7 repin/auto-human someone false false
    pr 6 feature/x "$BOT" false false
    pr 5 repin/auto-otherapp app/other-bot false false
  } | jq -s . > "$FIX/prs.json"
}

printf '{"files":[{"path":".claude-plugin/marketplace.json"}]}\n' > "$FIX/files-10.json"
printf '%s\n' "$BLOB" > "$FIX/blob"

run_land() { # extra env as arguments
  : > "$CALLS"
  env PATH="$TMP/bin:$PATH" REPO=acme/market BOT_SLUG="$SLUG" "$@" \
    bash "$ROOT/release/scripts/repin-land.sh" >"$TMP/out" 2>"$TMP/err"
}

# --- the reconciler's own PR is queued, and only the bot's older repin is closed -
standard_prs false
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "landing a valid PR failed: $(cat "$TMP/err")"
grep -qx "merge 10 $HEAD_SHA" "$CALLS" || die "auto-merge was not requested on #10 at its head: $(cat "$CALLS")"
pass 'auto-merge is requested on the PR at the head that was checked'
[ "$(grep '^close' "$CALLS")" = 'close 9' ] \
  || die "expected only #9 closed, got: $(grep '^close' "$CALLS" || true)"
pass 'only the bot older same-repository repin PR is closed; fork, human, other-App and other PRs are untouched'

# --- the REST spelling of the same App account is the same author ---------------
jq --arg a "${SLUG}[bot]" 'map(if .number == 10 then .author.login = $a else . end)' "$FIX/prs.json" \
  > "$FIX/prs2.json" && mv "$FIX/prs2.json" "$FIX/prs.json"
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "a <slug>[bot] author was refused: $(cat "$TMP/err")"
grep -qx "merge 10 $HEAD_SHA" "$CALLS" || die "auto-merge was not requested for a <slug>[bot] author: $(cat "$CALLS")"
pass 'a PR whose author is spelled <slug>[bot] is the bot too'

# --- idempotent: auto-merge already requested ---------------------------------
standard_prs true
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die 'a second run failed'
if grep -q '^merge' "$CALLS"; then die 'auto-merge was requested twice'; fi
grep -q 'already has auto-merge requested' "$TMP/out" || die 'the second run did not say so'
pass 'a PR that already has auto-merge requested is not requested again'

# --- a PR that is not provably the reconciler's output is refused --------------
standard_prs false
printf '{"files":[{"path":".claude-plugin/marketplace.json"},{"path":".github/workflows/x.yml"}]}\n' > "$FIX/files-10.json"
if run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB"; then die 'a PR changing a second file was landed'; fi
[ ! -s "$CALLS" ] || die "a PR changing a second file triggered: $(cat "$CALLS")"
grep -q 'changes more than' "$TMP/err" || die 'the extra file was not named'
pass 'a PR that changes any other file is refused, and nothing is closed'
printf '{"files":[{"path":".claude-plugin/marketplace.json"}]}\n' > "$FIX/files-10.json"

printf '%s\n' eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee > "$FIX/blob"
if run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB"; then die 'a PR with a different manifest was landed'; fi
[ ! -s "$CALLS" ] || die "a PR with a different manifest triggered: $(cat "$CALLS")"
grep -q "not the reconciler's" "$TMP/err" || die 'the manifest mismatch was not named'
pass 'a PR whose manifest differs from the reconciler output is refused'
printf '%s\n' "$BLOB" > "$FIX/blob"

if run_land DESIRED_BRANCH=repin/auto-fork EXPECTED_BLOB="$BLOB"; then die 'a fork PR was landed'; fi
[ ! -s "$CALLS" ] || die "a fork PR triggered: $(cat "$CALLS")"
pass 'a cross-repository PR on the desired branch name is never landed'

if run_land DESIRED_BRANCH=repin/auto-human EXPECTED_BLOB="$BLOB"; then die 'a human PR was landed'; fi
[ ! -s "$CALLS" ] || die "a human PR triggered: $(cat "$CALLS")"
if run_land DESIRED_BRANCH=repin/auto-otherapp EXPECTED_BLOB="$BLOB"; then die 'another App PR was landed'; fi
[ ! -s "$CALLS" ] || die "another App PR triggered: $(cat "$CALLS")"
pass 'a PR by anyone but the bot, human or another App, on the desired branch name is never landed'

# --- no drift: every bot repin PR is superseded by main ------------------------
standard_prs false
run_land DESIRED_BRANCH= || die 'a no-drift run failed'
if grep -q '^merge' "$CALLS"; then die 'a no-drift run requested a merge'; fi
[ "$(grep '^close' "$CALLS" | sort | tr '\n' ' ')" = 'close 10 close 9 ' ] \
  || die "a no-drift run should close exactly #10 and #9, got: $(cat "$CALLS")"
pass 'with no drift, every open bot repin PR is closed and nothing else'

# --- a targeted run closes nothing --------------------------------------------
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" ONLY_PLUGIN=widget || die 'a targeted run failed'
grep -qx "merge 10 $HEAD_SHA" "$CALLS" || die 'a targeted run did not request auto-merge'
if grep -q '^close' "$CALLS"; then die 'a targeted run closed a PR'; fi
pass 'a targeted run lands its PR and closes nothing'

# --- a list failure is a failure ----------------------------------------------
rm "$FIX/prs.json"
if run_land DESIRED_BRANCH= ; then die 'a failed PR list was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a failed PR list still closed or merged something'
grep -q 'could not list open pull requests' "$TMP/err" || die 'the list failure was not named'
pass 'a failed PR list exits nonzero and touches nothing'

# --- the pins family: LAND_PATH, BRANCH_PREFIX and REQUEST_AUTO_MERGE ----------
PINS=tools/pins.sh
PINS_BLOB=ffffffffffffffffffffffffffffffffffffffff
printf '%s\n' "$PINS_BLOB" > "$FIX/pins-blob"
mixed_prs() {
  {
    pr 20 pins/auto-new "$BOT" false false
    pr 19 pins/auto-old "$BOT" false false
    pr 10 repin/auto-new "$BOT" false false
    pr 9 repin/auto-old "$BOT" false false
  } | jq -s . > "$FIX/prs.json"
}
printf '{"files":[{"path":"%s"}]}\n' "$PINS" > "$FIX/files-20.json"
run_pins() { run_land LAND_PATH="$PINS" BRANCH_PREFIX=pins/auto- "$@"; }

mixed_prs
run_pins DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" || die "landing a pins PR failed: $(cat "$TMP/err")"
grep -qx "merge 20 $HEAD_SHA" "$CALLS" || die "auto-merge was not requested on the pins PR: $(cat "$CALLS")"
[ "$(grep '^close' "$CALLS")" = 'close 19' ] \
  || die "a pins run should close only #19, got: $(grep '^close' "$CALLS" || true)"
pass 'a pins run proves LAND_PATH, lands its PR and closes only pins/auto- PRs, never a repin PR'

mixed_prs
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "a repin run beside pins PRs failed: $(cat "$TMP/err")"
[ "$(grep '^close' "$CALLS")" = 'close 9' ] \
  || die "a repin run should close only #9, got: $(grep '^close' "$CALLS" || true)"
pass 'a default run beside open pins PRs closes only repin/auto- PRs'

mixed_prs
run_pins DESIRED_BRANCH= || die 'a no-drift pins run failed'
[ "$(grep '^close' "$CALLS" | sort | tr '\n' ' ')" = 'close 19 close 20 ' ] \
  || die "a no-drift pins run should close #20 and #19, got: $(cat "$CALLS")"
pass 'with no drift, a pins run closes every pins PR and no repin PR'

# the proof uses LAND_PATH: a PR touching the manifest instead is refused, and so is a wrong blob
mixed_prs
printf '{"files":[{"path":".claude-plugin/marketplace.json"}]}\n' > "$FIX/files-20.json"
if run_pins DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB"; then die 'a pins PR changing the manifest was landed'; fi
[ ! -s "$CALLS" ] || die "a wrong-file pins PR triggered: $(cat "$CALLS")"
grep -q 'changes more than tools/pins.sh' "$TMP/err" || die 'the LAND_PATH was not named in the refusal'
printf '{"files":[{"path":"%s"}]}\n' "$PINS" > "$FIX/files-20.json"
if run_pins DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$BLOB"; then die 'a pins PR with a different blob was landed'; fi
[ ! -s "$CALLS" ] || die "a wrong-blob pins PR triggered: $(cat "$CALLS")"
pass 'the pins proof reads LAND_PATH: another file or another blob is refused'

# a PR with the default prefix is not selectable by a pins run, and the reverse
if run_pins DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$PINS_BLOB"; then die 'a pins run landed a repin PR'; fi
[ ! -s "$CALLS" ] || die "a pins run touched a repin PR: $(cat "$CALLS")"
if run_land DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB"; then die 'a repin run landed a pins PR'; fi
[ ! -s "$CALLS" ] || die "a repin run touched a pins PR: $(cat "$CALLS")"
pass 'a pins run cannot land a repin PR and a repin run cannot land a pins PR'

# REQUEST_AUTO_MERGE=false: same proof, no merge, one line saying why, own prefix still pruned
mixed_prs
run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" \
  || die "a no-auto-merge run failed: $(cat "$TMP/err")"
if grep -q '^merge' "$CALLS"; then die 'auto-merge was requested with REQUEST_AUTO_MERGE=false'; fi
{ [ "$(grep -c 'auto-merge is off' "$TMP/out")" = 1 ] && grep -q "waits for the owner to merge it" "$TMP/out"; } \
  || die "REQUEST_AUTO_MERGE=false did not say so once: $(cat "$TMP/out")"
[ "$(grep '^close' "$CALLS")" = 'close 19' ] || die "a no-auto-merge run should still close #19, got: $(cat "$CALLS")"
if run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$BLOB"; then
  die 'REQUEST_AUTO_MERGE=false skipped the proof'
fi
grep -q "not the reconciler's" "$TMP/err" || die 'the proof did not fail on a wrong blob with auto-merge off'
if run_pins REQUEST_AUTO_MERGE=maybe DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB"; then
  die 'a non-boolean REQUEST_AUTO_MERGE was accepted'
fi
pass 'REQUEST_AUTO_MERGE=false still proves the PR, requests no merge and prunes its own prefix'

printf '%s repin land checks passed\n' "$PASS"
