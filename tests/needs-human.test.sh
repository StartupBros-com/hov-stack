#!/usr/bin/env bash
# Hermetic regression tests for needs-human.sh. Every case uses a fake HOME and
# a PATH-prepended gh stub; never use the operator's credential store or gh.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$HERE/scripts/needs-human.sh"
TABLE="$HERE/scripts/escalation-exceptions.json"
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The script may run within a Claude Code session, so isolate HOME before any
# invocation. This prevents future bookkeeping additions from leaking fixtures
# into the operator's real ~/.claude tree.
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/repo"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "FAIL: table not found at $TABLE" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

# Use a local repository solely to exercise owner_repo_of() without a network
# remote. Its GitHub-shaped origin makes the helper resolve fake/fake.
git init -q "$TMP/repo"
git -C "$TMP/repo" remote add origin git@github.com:fake/fake.git

# gh logs every call and exposes failure toggles for the boundary cases.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "auth status")
    if [ "${GH_STUB_AUTH_RC:-0}" != 0 ]; then
      echo "not logged into any GitHub hosts" >&2
      exit "$GH_STUB_AUTH_RC"
    fi
    ;;
  "label create")
    if [ "${GH_STUB_LABEL_RC:-0}" != 0 ]; then
      echo "label already exists" >&2
      exit "$GH_STUB_LABEL_RC"
    fi
    ;;
  "issue create")
    if [ "${GH_STUB_ISSUE_RC:-0}" != 0 ]; then
      echo "issue create failed" >&2
      exit "$GH_STUB_ISSUE_RC"
    fi
    echo "${GH_STUB_ISSUE_URL:-https://github.com/fake/fake/issues/99}"
    ;;
  "issue view")
    # GH_STUB_VIEW_FAIL_FIRST_N counts calls via VIEW_COUNT_FILE so a case can
    # fail exactly the first N read-backs and succeed after (dotfiles#1202,
    # pstack vet 2026-09-18: needs-human.sh retries a failed read-back once).
    COUNT=0
    if [ -n "${VIEW_COUNT_FILE:-}" ] && [ -f "$VIEW_COUNT_FILE" ]; then
      COUNT=$(<"$VIEW_COUNT_FILE")
    fi
    COUNT=$((COUNT + 1))
    if [ -n "${VIEW_COUNT_FILE:-}" ]; then
      printf '%s' "$COUNT" >"$VIEW_COUNT_FILE"
    fi
    if [ "$COUNT" -le "${GH_STUB_VIEW_FAIL_FIRST_N:-0}" ]; then
      echo "gh issue view transient failure" >&2
      exit "${GH_STUB_VIEW_FAIL_RC:-1}"
    fi
    if [ "${GH_STUB_VIEW_RC:-0}" != 0 ]; then
      echo "gh issue view failed" >&2
      exit "$GH_STUB_VIEW_RC"
    fi
    STATE_OUT=${GH_STUB_VIEW_STATE:-OPEN}
    LABELS_OUT=${GH_STUB_VIEW_LABELS:-'[{"name":"needs-human"}]'}
    printf '{"state":"%s","labels":%s}\n' "$STATE_OUT" "$LABELS_OUT"
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

reset_stub() {
  unset GH_STUB_AUTH_RC GH_STUB_LABEL_RC GH_STUB_ISSUE_RC GH_STUB_ISSUE_URL \
    GH_STUB_VIEW_RC GH_STUB_VIEW_STATE GH_STUB_VIEW_LABELS \
    GH_STUB_VIEW_FAIL_FIRST_N GH_STUB_VIEW_FAIL_RC
}

run_script() {
  CASE_OUT="$TMP/case.out"
  CASE_ERR="$TMP/case.err"
  bash "$SCRIPT" "$@" >"$CASE_OUT" 2>"$CASE_ERR"
  CASE_RC=$?
}

new_case() {
  GH_CALLS="$TMP/gh-calls.$1"
  : >"$GH_CALLS"
  export GH_CALLS
  # Per-case call counter for the retry-then-succeed read-back case.
  VIEW_COUNT_FILE="$TMP/view-count.$1"
  rm -f "$VIEW_COUNT_FILE"
  export VIEW_COUNT_FILE
  reset_stub
}

assert_call() {
  local needle=$1 message=$2
  # Counts on success too (inward vet on dotfiles#1419): the summary ratio used
  # to exclude every passing assert_call, so N/N read as complete when it was not.
  if grep -Fq -- "$needle" "$GH_CALLS"; then
    ok
  else
    bad "$message: $(<"$GH_CALLS")"
  fi
}

assert_no_issue_create() {
  if grep -Fq -- "issue create" "$GH_CALLS"; then
    bad "$1: $(<"$GH_CALLS")"
  else
    ok
  fi
}

echo "-- table integrity: exactly the closed six category ids, none proof-gated --"
python3 - "$TABLE" <<'PY'
import json
import sys

expected = [
    "external-send",
    "prod-data-mutation",
    "persistence-change",
    "credentials",
    "mcp-plugin-enable",
    "permission-surface-edit",
]
with open(sys.argv[1]) as f:
    table = json.load(f)
assert table["version"] == 1
assert set(table) == {"version", "note", "categories"}
assert [entry["id"] for entry in table["categories"]] == expected
assert len(table["categories"]) == len(expected)
for entry in table["categories"]:
    assert {"id", "label", "applies_when"} <= set(entry) <= {"id", "label", "applies_when", "proof"}
    assert entry["label"]
    assert "\n" not in entry["applies_when"]
# No category is proof-gated since review-gate-exhausted retired (2026-10-05).
# A proof kind needs a branch in needs-human.sh before a table entry may cite it.
assert not [entry["id"] for entry in table["categories"] if "proof" in entry]
PY
[ "$?" = 0 ] && ok || bad "table integrity failed"

echo "-- happy: valid category files a labeled issue referencing the gated PR --"
new_case happy
(
  cd "$TMP/repo" || exit 1
  run_script --category external-send --pr 42 --reason "Message requires operator approval"
  printf '%s\n' "$CASE_RC" >"$TMP/happy.rc"
  cp "$CASE_OUT" "$TMP/happy.out"
)
CASE_RC=$(<"$TMP/happy.rc")
CASE_OUT="$TMP/happy.out"
[ "$CASE_RC" = 0 ] || bad "happy: expected exit 0, got $CASE_RC: $(<"$TMP/case.err")"
[ "$(<"$CASE_OUT")" = "https://github.com/fake/fake/issues/99" ] || bad "happy: did not print issue URL: $(<"$CASE_OUT")"
assert_call "auth status" "happy: did not verify gh authentication"
assert_call "label create needs-human --repo fake/fake" "happy: did not ensure needs-human label"
assert_call "issue create --repo fake/fake" "happy: did not create issue in resolved repo"
assert_call "--label needs-human" "happy: issue was not labeled needs-human"
assert_call "Category: external-send" "happy: issue body did not cite category"
assert_call "Gated PR: #42" "happy: issue body did not reference gated PR"
assert_call "issue view https://github.com/fake/fake/issues/99 --json state,labels" \
  "happy: did not read back the created issue (dotfiles#1202, pstack vet 2026-09-18)"

echo "-- error: a read-back missing the needs-human label fails the escalation --"
new_case readback-label-missing
export GH_STUB_VIEW_LABELS='[]'
(
  cd "$TMP/repo" || exit 1
  run_script --category external-send --pr 11 --reason "Label check"
  printf '%s\n' "$CASE_RC" >"$TMP/readback-label-missing.rc"
  cp "$CASE_ERR" "$TMP/readback-label-missing.err"
)
CASE_RC=$(<"$TMP/readback-label-missing.rc")
CASE_ERR="$TMP/readback-label-missing.err"
[ "$CASE_RC" != 0 ] || bad "readback-label-missing: expected non-zero exit"
grep -Fq -- "https://github.com/fake/fake/issues/99" "$CASE_ERR" || bad "readback-label-missing: stderr did not name the issue URL: $(<"$CASE_ERR")"
grep -Fq -- "read-back mismatch" "$CASE_ERR" || bad "readback-label-missing: stderr did not diagnose the mismatch: $(<"$CASE_ERR")"
assert_call "issue view" "readback-label-missing: did not attempt a read-back"

echo "-- edge: a transient read-back failure is retried once and then succeeds --"
new_case readback-retry-succeeds
export GH_STUB_VIEW_FAIL_FIRST_N=1
(
  cd "$TMP/repo" || exit 1
  run_script --category external-send --pr 12 --reason "Retry check"
  printf '%s\n' "$CASE_RC" >"$TMP/readback-retry-succeeds.rc"
  cp "$CASE_OUT" "$TMP/readback-retry-succeeds.out"
)
CASE_RC=$(<"$TMP/readback-retry-succeeds.rc")
CASE_OUT="$TMP/readback-retry-succeeds.out"
[ "$CASE_RC" = 0 ] || bad "readback-retry-succeeds: expected exit 0 after one retry, got $CASE_RC: $(<"$TMP/case.err")"
[ "$(<"$CASE_OUT")" = "https://github.com/fake/fake/issues/99" ] || bad "readback-retry-succeeds: did not print issue URL after retry: $(<"$CASE_OUT")"
VIEW_CALLS=$(grep -c -- "issue view" "$GH_CALLS")
[ "$VIEW_CALLS" = 2 ] || bad "readback-retry-succeeds: expected exactly 2 issue view calls (one failure, one retry), got $VIEW_CALLS: $(<"$GH_CALLS")"

echo "-- planted negative: an issue-create failure never attempts a read-back --"
new_case create-failure
export GH_STUB_ISSUE_RC=1
(
  cd "$TMP/repo" || exit 1
  run_script --category external-send --pr 13 --reason "Create failure check"
  printf '%s\n' "$CASE_RC" >"$TMP/create-failure.rc"
  cp "$CASE_ERR" "$TMP/create-failure.err"
)
CASE_RC=$(<"$TMP/create-failure.rc")
CASE_ERR="$TMP/create-failure.err"
[ "$CASE_RC" != 0 ] || bad "create-failure: expected non-zero exit"
grep -Fq -- "gh issue create failed" "$CASE_ERR" || bad "create-failure: stderr did not report create failure: $(<"$CASE_ERR")"
if grep -Fq -- "issue view" "$GH_CALLS"; then
  bad "create-failure: read-back was attempted despite a failed create: $(<"$GH_CALLS")"
else
  ok
fi

echo "-- planted negative: unknown category cannot create an issue --"
new_case unknown
(
  cd "$TMP/repo" || exit 1
  run_script --category money-path --pr 42 --reason "Invented exception"
  printf '%s\n' "$CASE_RC" >"$TMP/unknown.rc"
  cp "$CASE_ERR" "$TMP/unknown.err"
)
CASE_RC=$(<"$TMP/unknown.rc")
CASE_ERR="$TMP/unknown.err"
[ "$CASE_RC" != 0 ] || bad "unknown: expected non-zero exit"
grep -Fq -- "unknown escalation category: money-path" "$CASE_ERR" || bad "unknown: error did not name rejected category: $(<"$CASE_ERR")"
assert_no_issue_create "unknown: rejected category still created an issue"
[ -s "$GH_CALLS" ] && bad "unknown: rejected category made a gh call of any kind (closed-table guard must precede every gh invocation): $(<"$GH_CALLS")" || ok

# A failed create is the expected "already exists" response. The helper must
# remain idempotent and still file the escalation.
echo "-- edge: an existing needs-human label remains idempotent --"
new_case existing-label
export GH_STUB_LABEL_RC=1
(
  cd "$TMP/repo" || exit 1
  run_script --category credentials --pr 7 --reason "Credential rotation needs approval"
  printf '%s\n' "$CASE_RC" >"$TMP/existing-label.rc"
)
CASE_RC=$(<"$TMP/existing-label.rc")
[ "$CASE_RC" = 0 ] || bad "existing-label: expected exit 0, got $CASE_RC: $(<"$TMP/case.err")"
assert_call "label create needs-human --repo fake/fake" "existing-label: did not attempt label ensure"
assert_call "issue create --repo fake/fake" "existing-label: did not file issue after existing label"

echo "-- error: unauthenticated gh cannot claim success --"
new_case unauthenticated
export GH_STUB_AUTH_RC=1
(
  cd "$TMP/repo" || exit 1
  run_script --category persistence-change --pr 9 --reason "System service change"
  printf '%s\n' "$CASE_RC" >"$TMP/unauthenticated.rc"
  cp "$CASE_ERR" "$TMP/unauthenticated.err"
)
CASE_RC=$(<"$TMP/unauthenticated.rc")
CASE_ERR="$TMP/unauthenticated.err"
[ "$CASE_RC" != 0 ] || bad "unauthenticated: expected non-zero exit"
grep -Fq -- "gh is unauthenticated or unavailable" "$CASE_ERR" || bad "unauthenticated: stderr did not report auth failure: $(<"$CASE_ERR")"
assert_no_issue_create "unauthenticated: auth failure still created an issue"

# ---- review-gate-exhausted retired (operator ruling 2026-10-04) ----
# An owned PR's governor stop now merges or parks by itself (pr-owner.sh
# merge_at_stop), so the category is gone from the closed table.

echo "-- retired: review-gate-exhausted is an unknown category, refused before any gh call --"
new_case retired-category
(
  cd "$TMP/repo" || exit 1
  run_script --category review-gate-exhausted --pr 21 --reason "Round 12 left 2 open P1s, 0 P0"
  printf '%s\n' "$CASE_RC" >"$TMP/retired-category.rc"
  cp "$CASE_ERR" "$TMP/retired-category.err"
)
CASE_RC=$(<"$TMP/retired-category.rc")
[ "$CASE_RC" = 1 ] || bad "retired-category: expected exit 1, got $CASE_RC: $(<"$TMP/retired-category.err")"
grep -Fq -- "unknown escalation category: review-gate-exhausted" "$TMP/retired-category.err" || bad "retired-category: stderr did not refuse the retired id: $(<"$TMP/retired-category.err")"
[ -s "$GH_CALLS" ] && bad "retired-category: made a gh call for a retired category: $(<"$GH_CALLS")" || ok

echo "-- proof guard: a table entry citing an unimplemented proof refuses before any gh call --"
new_case proof-unimplemented
mkdir -p "$TMP/proofcopy/lib"
cp "$SCRIPT" "$TMP/proofcopy/needs-human.sh"
cp "$HERE/scripts/lib/gh-repo-helpers.sh" "$TMP/proofcopy/lib/"
jq '.categories[0].proof = "made-up-proof"' "$TABLE" >"$TMP/proofcopy/escalation-exceptions.json"
(
  cd "$TMP/repo" || exit 1
  bash "$TMP/proofcopy/needs-human.sh" --category external-send --pr 21 --reason "Proof-gated send" >"$TMP/proof-unimplemented.out" 2>"$TMP/proof-unimplemented.err"
  printf '%s\n' "$?" >"$TMP/proof-unimplemented.rc"
)
CASE_RC=$(<"$TMP/proof-unimplemented.rc")
[ "$CASE_RC" = 1 ] || bad "proof-unimplemented: expected exit 1, got $CASE_RC: $(<"$TMP/proof-unimplemented.err")"
grep -Fq -- "unknown proof kind 'made-up-proof' on category external-send" "$TMP/proof-unimplemented.err" || bad "proof-unimplemented: stderr did not refuse the proof: $(<"$TMP/proof-unimplemented.err")"
[ -s "$GH_CALLS" ] && bad "proof-unimplemented: made a gh call before refusing: $(<"$GH_CALLS")" || ok

echo "-- usage: a non-numeric --pr is rejected before any gh call --"
new_case pr-not-numeric
(
  cd "$TMP/repo" || exit 1
  run_script --category external-send --pr "21; rm -rf x" --reason "Bad PR arg"
  printf '%s\n' "$CASE_RC" >"$TMP/pr-not-numeric.rc"
  cp "$CASE_ERR" "$TMP/pr-not-numeric.err"
)
CASE_RC=$(<"$TMP/pr-not-numeric.rc")
[ "$CASE_RC" = 2 ] || bad "pr-not-numeric: expected usage exit 2, got $CASE_RC: $(<"$TMP/pr-not-numeric.err")"
grep -Fq -- "--pr must be a PR number" "$TMP/pr-not-numeric.err" || bad "pr-not-numeric: stderr did not name the bad --pr: $(<"$TMP/pr-not-numeric.err")"
[ -s "$GH_CALLS" ] && bad "pr-not-numeric: gh was called with a non-numeric PR: $(<"$GH_CALLS")" || ok

echo "-- ordering: no origin remote refuses before gh (owner/repo resolves first) --"
new_case no-origin
mkdir -p "$TMP/norepo"
git init -q "$TMP/norepo"
(
  cd "$TMP/norepo" || exit 1
  run_script --category external-send --pr 21 --reason "No remote here"
  printf '%s\n' "$CASE_RC" >"$TMP/no-origin.rc"
  cp "$CASE_ERR" "$TMP/no-origin.err"
)
CASE_RC=$(<"$TMP/no-origin.rc")
[ "$CASE_RC" != 0 ] || bad "no-origin: expected non-zero exit without an origin remote"
grep -Fq -- "no origin remote" "$TMP/no-origin.err" || bad "no-origin: stderr did not name the missing remote: $(<"$TMP/no-origin.err")"
[ -s "$GH_CALLS" ] && bad "no-origin: gh called without a resolved repo: $(<"$GH_CALLS")" || ok

if [ "$fail" -eq 0 ]; then
  echo "ok — needs-human.sh: $pass/$((pass + fail)) assertions passed"
else
  # The success line is never printed on a failing run (inward vet on #1419: it
  # used to print "ok" unconditionally and rely on the exit code alone).
  echo "FAIL — needs-human.sh: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
