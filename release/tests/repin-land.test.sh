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
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"
export FIX="$TMP/fix" CALLS="$TMP/calls" READS="$TMP/reads"
mkdir -p "$FIX"

# Stub gh: serves PR metadata from $FIX and records every merge, close and branch
# update in $CALLS, and the refresh reads, with the token each used, in $READS. It
# honours --jq, as the real gh does.
cat > "$TMP/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
set -e
cmd="$1 $2"; shift 2
jqexpr='' num='' head='' disable='' method='' field=''
case "$cmd" in 'pr view'|'pr merge'|'pr close') num="$1"; shift ;; esac
path=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    --match-head-commit) head="$2"; shift 2 ;;
    --disable-auto) disable=1; shift ;;
    -X) method="$2"; shift 2 ;;
    -f) field="$2"; shift 2 ;;
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
  'pr merge')
    if [ -n "$disable" ]; then
      [ ! -e "$FIX/disable-fails" ] || { printf 'HTTP 502\n' >&2; exit 1; }
      printf 'disable-auto %s\n' "$num" >> "$CALLS"
    else
      printf 'merge %s %s\n' "$num" "$head" >> "$CALLS"
    fi ;;
  'pr close') printf 'close %s\n' "$num" >> "$CALLS" ;;
  'api repos/acme/market/rules/branches/main?per_page=100')
    printf 'rules %s\n' "${GH_TOKEN:-}" >> "$READS"
    emit < "$FIX/rules.json" ;;
  'api repos/acme/market/commits/'*'/check-runs?filter=latest&per_page=100')
    sha="${cmd#api repos/acme/market/commits/}"; sha="${sha%%/*}"
    printf 'checks %s %s\n' "$sha" "${GH_TOKEN:-}" >> "$READS"
    [ ! -e "$FIX/checks-fail" ] || { printf 'HTTP 403: Resource not accessible by integration\n' >&2; exit 1; }
    emit < "$FIX/checks.json" ;;
  'api repos/acme/market/compare/'*)
    printf 'compare %s %s\n' "${cmd#api repos/acme/market/compare/}" "${GH_TOKEN:-}" >> "$READS"
    printf '{"ahead_by":%s}\n' "$(cat "$FIX/ahead")" | emit ;;
  'api repos/acme/market/pulls/'*'/update-branch')
    [ "$method" = PUT ] || { printf 'update-branch is a PUT\n' >&2; exit 1; }
    [ ! -e "$FIX/update-fails" ] || { printf 'HTTP 422\n' >&2; exit 1; }
    num="${cmd#api repos/acme/market/pulls/}"; num="${num%%/*}"
    printf 'update %s %s %s\n' "$num" "$field" "${GH_TOKEN:-}" >> "$CALLS" ;;
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
# The auto-merge request's enabledBy has the shape `gh pr list --json autoMergeRequest`
# returned for a request a person enabled (#406): {"login": ..., "is_bot": false, ...}.
pr() { # $1 number $2 branch $3 author $4 cross $5 automerge(false|true=bot-requested|person|unknown)
  jq -n --argjson n "$1" --arg b "$2" --arg a "$3" --argjson x "$4" --arg m "$5" --arg h "$HEAD_SHA" \
    --arg slug "$SLUG" \
    '{number: $n, headRefName: $b, headRefOid: $h, baseRefName: "main",
      author: {login: $a, is_bot: ($a | startswith("app/") or endswith("[bot]"))},
      isCrossRepository: $x,
      autoMergeRequest: (if $m == "false" then null
        elif $m == "person" then {mergeMethod: "SQUASH", enabledBy: {login: "owner", is_bot: false}}
        elif $m == "unknown" then {mergeMethod: "SQUASH"}
        else {mergeMethod: "SQUASH", enabledBy: {login: $slug, is_bot: true}} end)}'
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

# main's required checks, as GET rules/branches/main returns them beside other rules.
jq -n '[{type: "pull_request"},
        {type: "required_status_checks", parameters: {required_status_checks:
          [{context: "ci"}, {context: "setup, hooks, suites, secrets"}]}}]' > "$FIX/rules.json"
# The check runs at the head, one name:status:conclusion per argument.
checks() {
  local spec name status conclusion
  for spec in "$@"; do
    IFS=: read -r name status conclusion <<<"$spec"
    jq -n --arg n "$name" --arg s "$status" --arg c "$conclusion" \
      '{name: $n, status: $s, conclusion: (if $c == "" then null else $c end)}'
  done | jq -s '{total_count: length, check_runs: .}' > "$FIX/checks.json"
}
passing_checks() {
  checks 'ci:completed:success' 'setup, hooks, suites, secrets:completed:success' 'CodeQL:completed:success'
}
passing_checks
printf '3\n' > "$FIX/ahead"

# The bot's token and the job's own; the stub records which one made each call.
run_land() { # extra env as arguments
  : > "$CALLS"; : > "$READS"
  env PATH="$TMP/bin:$PATH" REPO=acme/market BOT_SLUG="$SLUG" GH_TOKEN=bot-token CHECKS_TOKEN=job-token "$@" \
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
mixed_prs() { # $1 = #20's auto-merge request (as pr's $5), default none
  {
    pr 20 pins/auto-new "$BOT" false "${1:-false}"
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

# REQUEST_AUTO_MERGE=false after a run that had it on: the bot's pending request would still
# merge the PR as the bot, so it is cancelled; one a person made is left alone; a request with
# no reported requester counts as the bot's; a failed cancel fails the run.
mixed_prs true
run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" \
  || die "cancelling a bot's auto-merge failed: $(cat "$TMP/err")"
grep -qx 'disable-auto 20' "$CALLS" || die "the bot's auto-merge request on #20 was not cancelled: $(cat "$CALLS")"
if grep -q '^merge' "$CALLS"; then die 'auto-merge was requested while cancelling'; fi
grep -q 'cancelled the request an earlier run made, so the PR waits for the owner to merge it' "$TMP/out" \
  || die "the cancel was not reported: $(cat "$TMP/out")"
pass "REQUEST_AUTO_MERGE=false cancels an auto-merge request the bot made on an earlier run"

mixed_prs unknown
run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" \
  || die "cancelling an unattributed auto-merge failed: $(cat "$TMP/err")"
grep -qx 'disable-auto 20' "$CALLS" || die "a request with no reported requester was left: $(cat "$CALLS")"
pass 'a request whose requester GitHub did not report is cancelled as the bot one'

mixed_prs person
run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" \
  || die "a person's auto-merge request broke the run: $(cat "$TMP/err")"
if grep -q -e '^disable-auto' -e '^merge' "$CALLS"; then die "a person's auto-merge request was touched: $(cat "$CALLS")"; fi
grep -q 'leaving the auto-merge owner requested' "$TMP/out" || die "the kept request was not reported: $(cat "$TMP/out")"
pass 'an auto-merge request a person made stays'

mixed_prs true
: > "$FIX/disable-fails"
if run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB"; then
  die 'a failed cancel of the bot auto-merge exited 0'
fi
grep -q 'could not cancel the auto-merge request on #20' "$TMP/err" || die "the failed cancel was not named: $(cat "$TMP/err")"
if grep -q '^close' "$CALLS"; then die 'a failed cancel still closed PRs'; fi
rm "$FIX/disable-fails"
pass 'a failed cancel fails the run before anything is closed'

mixed_prs true
run_pins DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" || die "an auto-merge-on rerun failed: $(cat "$TMP/err")"
if grep -q -e '^disable-auto' -e '^merge' "$CALLS"; then die "an auto-merge-on rerun changed the request: $(cat "$CALLS")"; fi
pass 'with auto-merge on, an existing request is kept and not requested again'

# --- a failed card is refreshed from main, and only then -------------------------
# A card is kept while main moves, so a fix main gains reaches a failed card only if
# the bot merges main into it. The refresh comes last, pinned to the proved head, made
# with the bot's token; the check runs are read with the job's.
standard_prs false
checks 'ci:completed:failure' 'setup, hooks, suites, secrets:completed:success'
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "refreshing a failed card failed: $(cat "$TMP/err")"
[ "$(cut -d' ' -f1-2 "$CALLS" | tr '\n' ';')" = 'merge 10;close 9;update 10;' ] \
  || die "expected merge, close, then refresh of #10, got: $(cat "$CALLS")"
grep -qx "update 10 expected_head_sha=$HEAD_SHA bot-token" "$CALLS" \
  || die "the refresh was not pinned to the proved head or not made as the bot: $(cat "$CALLS")"
grep -qx "checks $HEAD_SHA job-token" "$READS" || die "the check runs were not read at the head with the job token: $(cat "$READS")"
grep -qx "compare $HEAD_SHA...main bot-token" "$READS" || die "main was not compared with the head: $(cat "$READS")"
grep -q "#10: ci failed at ${HEAD_SHA:0:12}; merged 3 new commit(s) from main" "$TMP/out" \
  || die "the refresh did not name the failed check: $(cat "$TMP/out")"
pass 'a card whose required check failed is refreshed from main last, at its proved head, as the bot'

checks 'ci:completed:timed_out' 'setup, hooks, suites, secrets:completed:cancelled'
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" ONLY_PLUGIN=widget \
  || die "a targeted refresh failed: $(cat "$TMP/err")"
grep -qx "update 10 expected_head_sha=$HEAD_SHA bot-token" "$CALLS" || die "a targeted run did not refresh: $(cat "$CALLS")"
if grep -q '^close' "$CALLS"; then die 'a targeted run closed a PR'; fi
grep -q 'ci, setup, hooks, suites, secrets failed' "$TMP/out" || die "both failed checks were not named: $(cat "$TMP/out")"
pass 'a targeted run refreshes its failed card too and still closes nothing; timed out and cancelled count as failed'

checks 'ci:completed:failure'
run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "a refresh with an unreported check failed: $(cat "$TMP/err")"
grep -q '^update 10 ' "$CALLS" || die "a required check with no run yet blocked the refresh: $(cat "$CALLS")"
pass 'a required check with no run yet decides nothing'

run_land CHECKS_TOKEN= DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "a run without CHECKS_TOKEN failed: $(cat "$TMP/err")"
grep -qx "checks $HEAD_SHA bot-token" "$READS" || die "without CHECKS_TOKEN the bot token did not read: $(cat "$READS")"
pass 'without CHECKS_TOKEN the check runs are read with the bot token'

# Left alone: passing, still running (a rerun of the failed check, or another check),
# a failure only outside the required set, and a failure with nothing newer on main.
no_refresh() { # $1 why
  run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB" || die "$1: the run failed: $(cat "$TMP/err")"
  if grep -q '^update' "$CALLS"; then die "$1: the card was refreshed: $(cat "$CALLS")"; fi
}
checks 'ci:completed:success' 'setup, hooks, suites, secrets:completed:skipped' 'CodeQL:completed:neutral'
no_refresh 'passing'
if grep -q '^compare' "$READS"; then die "a passing card was compared with main: $(cat "$READS")"; fi
grep -qx "#10: 2 required check(s), 2 reported, none failed at ${HEAD_SHA:0:12}" "$TMP/out" \
  || die "a passing card's read was not counted in the log: $(cat "$TMP/out")"
checks 'ci:completed:success' 'setup, hooks, suites, secrets:completed:success' 'CodeQL:completed:failure'
no_refresh 'a failure outside the required checks'
checks 'CodeQL:completed:failure'
no_refresh 'no required check reported yet'
grep -qx "#10: 2 required check(s), 0 reported, none failed at ${HEAD_SHA:0:12}" "$TMP/out" \
  || die "a card with no required check reported did not say so: $(cat "$TMP/out")"
pass 'a passing card is left behind main with its checks counted in the log, and a failure outside the required checks refreshes nothing'

checks 'ci:in_progress:' 'setup, hooks, suites, secrets:completed:success'
no_refresh 'a rerun still going'
checks 'ci:completed:failure' 'setup, hooks, suites, secrets:queued:'
no_refresh 'another required check still queued'
grep -q 'required checks are still running' "$TMP/out" || die "the wait was not reported: $(cat "$TMP/out")"
if grep -q '^compare' "$READS"; then die "a card with checks running was compared with main: $(cat "$READS")"; fi
pass 'a card whose required checks are still running is left, whether the running one is a rerun or another check'

checks 'ci:completed:failure' 'setup, hooks, suites, secrets:completed:success'
printf '0\n' > "$FIX/ahead"
no_refresh 'main has nothing newer'
grep -q 'ci failed at .*, and main has nothing newer to retry it with' "$TMP/out" || die "the hold was not reported: $(cat "$TMP/out")"
printf '3\n' > "$FIX/ahead"
pass 'a failed card is left when main has nothing newer, so one refresh waits for the next move of main'

# The pins family, with auto-merge off: the owner's PR is refreshed too, and nothing merges.
mixed_prs
run_pins REQUEST_AUTO_MERGE=false DESIRED_BRANCH=pins/auto-new EXPECTED_BLOB="$PINS_BLOB" \
  || die "refreshing a failed pins PR failed: $(cat "$TMP/err")"
[ "$(cut -d' ' -f1-2 "$CALLS" | tr '\n' ';')" = 'close 19;update 20;' ] \
  || die "expected #19 closed then #20 refreshed, got: $(cat "$CALLS")"
pass 'a failed pins PR is refreshed from main with auto-merge off, and nothing is merged'

# Failures are loud, and come after the merge request and the closes, which stand.
standard_prs false
: > "$FIX/checks-fail"
if run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB"; then die 'an unreadable check-runs list exited 0'; fi
rm "$FIX/checks-fail"
[ "$(cut -d' ' -f1-2 "$CALLS" | tr '\n' ';')" = 'merge 10;close 9;' ] \
  || die "the merge request and the close did not stand before the failed read: $(cat "$CALLS")"
grep -q "could not read the check runs of #10 at ${HEAD_SHA:0:12}" "$TMP/err" || die "the failed read was not named: $(cat "$TMP/err")"
grep -q 'Resource not accessible by integration' "$TMP/err" || die "gh's own error was hidden: $(cat "$TMP/err")"
pass "an unreadable check-runs list fails the run with gh's error, after the merge request and the closes"

: > "$FIX/update-fails"
if run_land DESIRED_BRANCH=repin/auto-new EXPECTED_BLOB="$BLOB"; then die 'a failed refresh exited 0'; fi
rm "$FIX/update-fails"
grep -q 'could not merge main into #10' "$TMP/err" || die "the failed refresh was not named: $(cat "$TMP/err")"
pass 'a refresh GitHub refuses fails the run'
passing_checks

printf '%s repin land checks passed\n' "$PASS"
