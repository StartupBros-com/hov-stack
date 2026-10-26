#!/usr/bin/env bash
# marketplace-repin-merge.sh against a stubbed gh (dotfiles#1832). Every gh call is logged; the
# eligible cases assert exactly one merge of the exact head, and every planted negative asserts
# no merge call at all. No network, no real GitHub.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_SRC="$ROOT/scripts/marketplace-repin-merge.sh"
TMP=$(mktemp -d /tmp/marketplace-repin-merge-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
check() { local name=$1; shift; if "$@"; then ok; else bad "$name"; fi; }
[ -f "$SCRIPT_SRC" ] || { echo "missing $SCRIPT_SRC" >&2; exit 1; }

H=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
M=3333333333333333333333333333333333333333
OLD=4444444444444444444444444444444444444444
NEW=5555555555555555555555555555555555555555
R=StartupBros-com/hov-stack
export H B M FIX="$TMP/fix" GH_LOG="$TMP/gh.log"
mkdir -p "$TMP/bin" "$FIX"

cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serve fixtures by exact argument shape; apply --jq like gh does (raw output).
printf '%s\n' "$*" >>"$GH_LOG"
R=StartupBros-com/hov-stack
MF=.claude-plugin/marketplace.json
jqexpr="" args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --jq ]; then jqexpr=$2; shift 2; else args+=("$1"); shift; fi
done
set -- "${args[@]}"
serve() {
  [ -f "$1" ] || { echo "fixture missing: $1" >&2; exit 1; }
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi
}
case "$*" in
  "pr view 7 --repo $R --json state,isDraft,author,baseRefName,headRefOid,files")
    [ "${STUB_PR_READ_FAIL:-0}" = 0 ] || { echo 'HTTP 502' >&2; exit 1; }
    serve "$FIX/pr.json" ;;
  "api repos/$R/compare/main...$H") serve "$FIX/compare.json" ;;
  "api -H Accept: application/vnd.github.raw+json repos/$R/contents/$MF?ref=$B") serve "$FIX/base.json" ;;
  "api -H Accept: application/vnd.github.raw+json repos/$R/contents/$MF?ref=$H") serve "$FIX/head.json" ;;
  "api -H Accept: application/vnd.github.raw+json repos/$R/contents/$MF?ref=main")
    [ "${STUB_LIVE_FAIL:-0}" = 0 ] || { echo 'HTTP 502' >&2; exit 1; }
    serve "$FIX/live.json" ;;
  "api repos/$R/rules/branches/main") serve "$FIX/rules.json" ;;
  "pr view 7 --repo $R --json headRefOid,statusCheckRollup")
    n=$(($(cat "$FIX/checks.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FIX/checks.count"
    if [ -f "$FIX/checks.$n.json" ]; then serve "$FIX/checks.$n.json"; else serve "$FIX/checks.json"; fi ;;
  "pr merge 7 --repo $R --squash --match-head-commit $H")
    if [ "${STUB_MERGE_RC:-0}" != 0 ]; then
      [ "${STUB_MERGE_LANDED:-0}" = 0 ] || touch "$FIX/merged"   # GitHub merged, the client errored
      echo 'merge blocked by ruleset' >&2; exit 1
    fi
    [ "${STUB_MERGE_UNCONFIRMED:-0}" = 1 ] || touch "$FIX/merged" ;;
  "pr view 7 --repo $R --json state,mergeStateStatus")
    if [ -f "$FIX/merged" ]; then printf '{"state":"MERGED","mergeStateStatus":"UNKNOWN"}\n' >"$FIX/mstate.json"
    else printf '{"state":"OPEN","mergeStateStatus":"%s"}\n' "${STUB_MERGE_STATE:-BLOCKED}" >"$FIX/mstate.json"; fi
    serve "$FIX/mstate.json" ;;
  "pr view 7 --repo $R --json state,mergeCommit")
    if [ -f "$FIX/merged" ]; then printf '{"state":"MERGED","mergeCommit":{"oid":"%s"}}\n' "$M" >"$FIX/state.json"
    else printf '{"state":"OPEN","mergeCommit":null}\n' >"$FIX/state.json"; fi
    serve "$FIX/state.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 91 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
# Closed PATH: only the tools the script and the stub use.
for name in bash jq mktemp rm cat sleep touch; do ln -s "$(command -v "$name")" "$TMP/bin/$name"; done
cp "$SCRIPT_SRC" "$TMP/marketplace-repin-merge.sh"
SCRIPT="$TMP/marketplace-repin-merge.sh"

# The base manifest: two plugins, the first about to be repinned.
base_manifest() {
  jq -n --arg old "$OLD" '{
    name: "hov", owner: {name: "StartupBros"},
    plugins: [
      {name: "pro-gate", source: {source: "url", url: "https://github.com/StartupBros-com/pro-gate.git", sha: $old},
       description: "Final review", metadata: {version: "0.62.0", releaseId: 100, releaseTag: "v0.62.0"},
       card: {rows: ["deep review"], run: "Then run /pro-gate"}},
      {name: "skill-tuner", source: {source: "url", url: "https://github.com/StartupBros-com/skill-tuner.git", sha: "6666666666666666666666666666666666666666"},
       description: "Tune skills", metadata: {version: "0.9.1", releaseId: 50, releaseTag: "v0.9.1"}, card: {rows: ["tune"]}}
    ]}'
}
# The bot's repin: only the first plugin's pin fields move.
repin() { jq --arg new "$NEW" '.plugins[0].source.sha = $new | .plugins[0].metadata = {version: "0.63.2", releaseId: 200, releaseTag: "v0.63.2"}'; }
check_run() { jq -nc --arg n "$1" --arg s "$2" --arg c "$3" '{__typename: "CheckRun", name: $n, status: $s, conclusion: (if $c == "" then null else $c end)}'; }
rollup() { jq -s --arg h "${1:-$H}" '{headRefOid: $h, statusCheckRollup: .[1:]}' <(echo null) "${@:2}"; }

reset_case() {
  rm -rf "$FIX"; mkdir -p "$FIX"; : >"$GH_LOG"
  unset STUB_MERGE_RC STUB_PR_READ_FAIL STUB_MERGE_LANDED STUB_MERGE_UNCONFIRMED STUB_MERGE_STATE STUB_LIVE_FAIL
  export REPIN_MERGE_POLL_SECONDS=0
  jq -n --arg h "$H" '{state: "OPEN", isDraft: false, author: {login: "app/startupbros-hov-marketplace-bot", is_bot: true},
    baseRefName: "main", headRefOid: $h, files: [{path: ".claude-plugin/marketplace.json"}]}' >"$FIX/pr.json"
  jq -n --arg b "$B" '{merge_base_commit: {sha: $b}, status: "diverged"}' >"$FIX/compare.json"
  base_manifest >"$FIX/base.json"
  repin <"$FIX/base.json" >"$FIX/head.json"
  cp "$FIX/head.json" "$FIX/live.json"
  jq -n '[{type: "deletion"}, {type: "required_status_checks", parameters: {required_status_checks: [{context: "Trusted syntax and policy"}, {context: "Pinned sources"}]}}]' >"$FIX/rules.json"
  rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Public PR data check' COMPLETED SKIPPED) \
    <(check_run 'Pinned sources' COMPLETED SUCCESS) >"$FIX/checks.json"
}
run() { OUT=$(PATH="$TMP/bin" bash "$SCRIPT" 7 "$@" 2>&1); RC=$?; }
merges() { grep -c -F -- 'pr merge' "$GH_LOG" || true; }
refused_no_merge() {
  local name=$1 want_rc=$2 reason=$3; shift 3
  run "$@"
  check "$name: exit $want_rc (got $RC)" test "$RC" -eq "$want_rc"
  check "$name: names the reason" bash -c '[[ "$1" == *"$2"* ]]' _ "$OUT" "$reason"
  check "$name: no merge call" test "$(merges)" = 0
}

# --- Positive: the bot's pin-only repin with both required checks green merges the exact head.
reset_case
run
check 'eligible repin merges: exit 0' test "$RC" -eq 0
check 'exactly one merge call, squash, pinned to the head' test "$(grep -c -x -F -- "pr merge 7 --repo $R --squash --match-head-commit $H" "$GH_LOG")" = 1
check 'merge comes after the check read' bash -c 'grep -n -F -- "--json headRefOid,statusCheckRollup" "$1" | head -1 | cut -d: -f1 | { read -r c; m=$(grep -n -F -- "pr merge" "$1" | cut -d: -f1); [ "$c" -lt "$m" ]; }' _ "$GH_LOG"
check 'reports the merge commit and confirmed card' bash -c '[[ "$1" == *"merged PR #7 as $2; main'"'"'s card carries the new pins"* ]]' _ "$OUT" "$M"
check 'points at the reconciler publish for the repinned plugin only' bash -c '[[ "$1" == *"next: repin-reconcile publishes StartupBros-com/pro-gate v0.63.2 after this merge; if it is still a draft, run gh workflow run repin-reconcile.yml --repo StartupBros-com/hov-stack"* && "$1" != *skill-tuner* && "$1" != *"Publish staged release"* ]]' _ "$OUT"
check 'names the repinned plugin and version' bash -c '[[ "$1" == *"bot repin at $2: pro-gate 0.63.2"* ]]' _ "$OUT" "$H"

# --check-only stops after identity and diff: no rules read, no merge.
reset_case
run --check-only
check 'check-only on an eligible repin: exit 0' test "$RC" -eq 0
check 'check-only reads no required checks' bash -c '! grep -q -F rules/branches "$1"' _ "$GH_LOG"
check 'check-only never merges' test "$(merges)" = 0

# Pending, then green on the next poll: waits and merges.
reset_case
rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Pinned sources' IN_PROGRESS '') >"$FIX/checks.1.json"
run --wait 60
check 'pending then green: merges after waiting' test "$RC" -eq 0
check 'pending then green: read the checks twice' test "$(cat "$FIX/checks.count")" = 2
check 'pending then green: one merge' test "$(merges)" = 1

# A legacy status context named by the ruleset counts the same as a check run.
reset_case
rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) \
  <(jq -nc '{__typename: "StatusContext", context: "Pinned sources", state: "SUCCESS"}') >"$FIX/checks.json"
run
check 'status-context SUCCESS satisfies a required check' test "$RC" -eq 0

# --- Planted negatives: each differs from the positive only in the forbidden dimension.
reset_case; jq '.plugins[0].description = "Final review, now cheaper"' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'description copy changed' 1 'changes more than plugin pins'
reset_case; jq '.plugins[0].card.rows = ["the deepest review"]' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'card copy changed' 1 'changes more than plugin pins'
reset_case; jq '.plugins[0].source.url = "https://github.com/Someone/pro-gate.git"' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'source url changed' 1 'changes more than plugin pins'
reset_case; jq '.plugins += [{name: "new-plugin", source: {source: "url", url: "https://github.com/x/y.git", sha: "7777777777777777777777777777777777777777"}}]' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'plugin added' 1 'changes more than plugin pins'
reset_case; jq '.plugins |= reverse' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'plugins reordered' 1 'changes more than plugin pins'
reset_case; jq '.owner.name = "Someone"' "$FIX/head.json" >"$FIX/h" && mv "$FIX/h" "$FIX/head.json"
refused_no_merge 'top-level field changed' 1 'changes more than plugin pins'
reset_case; cp "$FIX/base.json" "$FIX/head.json"
refused_no_merge 'nothing changed' 1 'changes more than plugin pins'
reset_case; jq '.author = {login: "StartupBros", is_bot: false}' "$FIX/pr.json" >"$FIX/p" && mv "$FIX/p" "$FIX/pr.json"
refused_no_merge 'opened by a person' 1 'is not by app/startupbros-hov-marketplace-bot'
reset_case; jq '.files += [{path: ".github/workflows/validate.yml"}]' "$FIX/pr.json" >"$FIX/p" && mv "$FIX/p" "$FIX/pr.json"
refused_no_merge 'a second file' 1 'changes files other than'
reset_case; jq '.baseRefName = "release"' "$FIX/pr.json" >"$FIX/p" && mv "$FIX/p" "$FIX/pr.json"
refused_no_merge 'not targeting main' 1 'does not target main'
reset_case; jq '.state = "CLOSED"' "$FIX/pr.json" >"$FIX/p" && mv "$FIX/p" "$FIX/pr.json"
refused_no_merge 'closed PR' 1 'is not open'
reset_case; jq '.isDraft = true' "$FIX/pr.json" >"$FIX/p" && mv "$FIX/p" "$FIX/pr.json"
refused_no_merge 'draft PR' 1 'is a draft'
reset_case; rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Pinned sources' COMPLETED FAILURE) >"$FIX/checks.json"
refused_no_merge 'Pinned sources failed' 1 'required check failed'
reset_case; rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Pinned sources' COMPLETED SKIPPED) >"$FIX/checks.json"
refused_no_merge 'Pinned sources skipped is not a pass' 1 'required check failed'
reset_case; rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Pinned sources' IN_PROGRESS '') >"$FIX/checks.json"
refused_no_merge 'Pinned sources pending past --wait 0' 2 'still pending' --wait 0
reset_case; rollup "$H" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) >"$FIX/checks.json"
refused_no_merge 'Pinned sources missing from the rollup' 2 'still pending' --wait 0
reset_case; rollup "$NEW" <(check_run 'Trusted syntax and policy' COMPLETED SUCCESS) <(check_run 'Pinned sources' COMPLETED SUCCESS) >"$FIX/checks.json"
refused_no_merge 'head moved before the check read' 2 'head moved'
reset_case; jq -n '[{type: "deletion"}]' >"$FIX/rules.json"
refused_no_merge 'ruleset names no required checks' 2 'names no required checks'
reset_case; export STUB_PR_READ_FAIL=1
refused_no_merge 'PR read failed' 2 'read failed'
reset_case; jq -n '[{type: "required_status_checks", parameters: {required_status_checks: [{context: "Trusted syntax and policy"}]}}]' >"$FIX/rules.json"
refused_no_merge 'ruleset no longer requires Pinned sources' 1 'no longer requires "Pinned sources"'

# GitHub refusing the merge is a refusal, not success.
reset_case; export STUB_MERGE_RC=1
run
check 'merge refused by GitHub: exit 1' test "$RC" -eq 1
check 'merge refused by GitHub: says so' bash -c '[[ "$1" == *"GitHub refused the merge"* ]]' _ "$OUT"
check 'merge refused by GitHub: read the state before refusing' grep -q -F -- "pr view 7 --repo $R --json state,mergeStateStatus" "$GH_LOG"
# Behind main under strict required checks: safe to re-run once the branch is updated.
reset_case; export STUB_MERGE_RC=1 STUB_MERGE_STATE=BEHIND
run
check 'behind main: exit 2' test "$RC" -eq 2
check 'behind main: says to update the branch' bash -c '[[ "$1" == *"behind main"* ]]' _ "$OUT"
# The merge command failed but GitHub merged anyway (client timeout): confirm, do not refuse.
reset_case; export STUB_MERGE_RC=1 STUB_MERGE_LANDED=1
run
check 'merge landed despite a failed command: exit 0' test "$RC" -eq 0
check 'merge landed despite a failed command: confirms the card' bash -c '[[ "$1" == *"carries the new pins"* ]]' _ "$OUT"
# Once a merge was requested, an unconfirmed outcome is exit 3, never the safe-to-re-run exit 2.
reset_case; export STUB_MERGE_UNCONFIRMED=1
run
check 'merge not confirmed: exit 3' test "$RC" -eq 3
check 'merge not confirmed: does not say re-run' bash -c '[[ "$1" != *"not merged, re-run"* ]]' _ "$OUT"
reset_case; export STUB_LIVE_FAIL=1
run
check 'main manifest unreadable after merge: exit 3' test "$RC" -eq 3
check 'main manifest unreadable after merge: names the merge' bash -c '[[ "$1" == *"merged as $2"* ]]' _ "$OUT" "$M"
# Merged, but main's card does not show the new pin: not reported as success.
reset_case; cp "$FIX/base.json" "$FIX/live.json"
run
check 'card unchanged after merge: exit 3' test "$RC" -eq 3
check 'card unchanged after merge: says so' bash -c '[[ "$1" == *"does not carry every new pin"* ]]' _ "$OUT"

printf 'marketplace-repin-merge: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
