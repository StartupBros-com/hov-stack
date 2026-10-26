#!/usr/bin/env bash
# Tests for scripts/gh-repo-settings.sh (dotfiles#854). Hermetic: a
# PATH-prepended gh stub serves canned per-repo settings and logs every call;
# no network, no real gh, no ~/.claude.
#
# PLANTED NEGATIVE: fixture `folded` is on COMMIT_MESSAGES, fixture `conform`
# already matches. DRY_RUN=0 must PATCH exactly `folded` and leave `conform`
# alone; drop the drift comparison and the call log shows both (or neither)
# PATCHed. A dry run must issue zero PATCH calls. A PATCH whose response does
# not carry the wanted values is a failure, never a silent success.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
# GH_REPO_SETTINGS lets the inverted-state proof point at a doctored copy.
SCRIPT="${GH_REPO_SETTINGS:-$HERE/scripts/gh-repo-settings.sh}"
TMP=$(mktemp -d /tmp/gh-repo-settings.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: not found: $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/repos"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:?}"
case "$1 $2" in
  "repo list") printf '%s\n' "$GH_STUB_NAMES" ;;
  "api -X")
    # PATCH repos/ORG/NAME ... : answer with the wanted shape unless the repo is
    # marked stubborn, which models a 200 whose values did not change.
    name=${4##*/}
    if [ "$name" = "$GH_STUB_STUBBORN" ]; then cat "$GH_STUB_DIR/$name.json"; else cat "$GH_STUB_DIR/want.json"; fi ;;
  api*)
    name=${2##*/}
    cat "$GH_STUB_DIR/$name.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALLS="$TMP/gh-calls.log"
export GH_STUB_DIR="$TMP/repos"
export GH_STUB_NAMES=$'conform\nfolded\nnoissues'
export GH_STUB_STUBBORN=""

# The stub cannot run jq, so it answers the --jq'd shape directly: the script
# asks for "title message delete issues" joined by spaces.
printf '%s\n' 'PR_TITLE PR_BODY true true' > "$TMP/repos/want.json"
printf '%s\n' 'PR_TITLE PR_BODY true true' > "$TMP/repos/conform.json"
printf '%s\n' 'COMMIT_OR_PR_TITLE COMMIT_MESSAGES true true' > "$TMP/repos/folded.json"
printf '%s\n' 'PR_TITLE PR_BODY true false' > "$TMP/repos/noissues.json"

# C1: dry run reports the two drifted repos and issues zero PATCH calls.
: > "$GH_CALLS"
out=$(DRY_RUN=1 ORG=acme bash "$SCRIPT" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "C1 dry run exit $status: $out"
case "$out" in *"gh-repo-settings: ok:1 drifted:2 patched:0 failed:0"*) ok ;; *) bad "C1 summary: $out" ;; esac
case "$out" in *"folded: drift [COMMIT_OR_PR_TITLE COMMIT_MESSAGES true true] -> [PR_TITLE PR_BODY true true] (dry)"*) ok ;; *) bad "C1 folded line: $out" ;; esac
if grep -q -- '-X PATCH' "$GH_CALLS"; then bad "C1 dry run issued a PATCH"; else ok; fi

# C2: DRY_RUN=0 PATCHes exactly the drifted repos with exactly the four fields.
: > "$GH_CALLS"
out=$(DRY_RUN=0 ORG=acme bash "$SCRIPT" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "C2 exit $status: $out"
case "$out" in *"gh-repo-settings: ok:1 drifted:2 patched:2 failed:0"*) ok ;; *) bad "C2 summary: $out" ;; esac
patches=$(grep -c -- '-X PATCH' "$GH_CALLS")
[ "$patches" -eq 2 ] && ok || bad "C2 expected 2 PATCH calls, got $patches"
if grep -- '-X PATCH' "$GH_CALLS" | grep -q 'repos/acme/conform'; then bad "C2 PATCHed a conforming repo"; else ok; fi
if grep -- '-X PATCH' "$GH_CALLS" | grep -q 'repos/acme/folded'; then ok; else bad "C2 did not PATCH folded"; fi
if grep -- '-X PATCH' "$GH_CALLS" | grep 'repos/acme/folded' | grep -q -- 'squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY -F delete_branch_on_merge=true -F has_issues=true'; then ok; else bad "C2 PATCH fields wrong: $(grep -- '-X PATCH' "$GH_CALLS")"; fi

# C3: ONLY=<repo> touches one repo and never lists.
: > "$GH_CALLS"
out=$(DRY_RUN=0 ORG=acme ONLY=folded bash "$SCRIPT" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "C3 exit $status: $out"
if grep -q '^repo list' "$GH_CALLS"; then bad "C3 listed repos despite ONLY"; else ok; fi
[ "$(grep -c -- '-X PATCH' "$GH_CALLS")" -eq 1 ] && ok || bad "C3 PATCH count: $(grep -c -- '-X PATCH' "$GH_CALLS")"

# C4: a PATCH whose response does not carry the wanted values is a failure (exit 1, failed:1).
: > "$GH_CALLS"
out=$(DRY_RUN=0 ORG=acme ONLY=folded GH_STUB_STUBBORN=folded bash "$SCRIPT" 2>&1); status=$?
[ "$status" -ne 0 ] && ok || bad "C4 stubborn PATCH must fail the run: $out"
case "$out" in *"folded: PATCH did not take"*) ok ;; *) bad "C4 message: $out" ;; esac
case "$out" in *"patched:0 failed:1"*) ok ;; *) bad "C4 summary: $out" ;; esac

# C5: the real jq filter, lifted verbatim from the script, over synthetic JSON.
# The gh stub answers pre-shaped strings, so without this a typo in the --jq
# expression would pass every case above and only surface on a live run.
filter=$(grep -o -- "--jq '[^']*'" "$SCRIPT" | head -1 | sed "s/^--jq '//; s/'\$//")
[ -n "$filter" ] && ok || bad "C5 could not lift the --jq filter from the script"
got=$(printf '%s' '{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY","delete_branch_on_merge":true,"has_issues":true,"has_wiki":true}' | jq -r "$filter")
[ "$got" = "PR_TITLE PR_BODY true true" ] && ok || bad "C5 conforming JSON rendered as [$got]"
got=$(printf '%s' '{"squash_merge_commit_title":"COMMIT_OR_PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES","delete_branch_on_merge":true,"has_issues":false}' | jq -r "$filter")
[ "$got" = "COMMIT_OR_PR_TITLE COMMIT_MESSAGES true false" ] && ok || bad "C5 drifted JSON rendered as [$got]"
got=$(printf '%s' '{}' | jq -r "$filter")
[ "$got" != "PR_TITLE PR_BODY true true" ] && ok || bad "C5 empty JSON must never read as conforming"

echo "gh-repo-settings.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
