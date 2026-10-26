#!/usr/bin/env bash
# tests/repo/run-claude-tests.test.sh: the suite runner reports what ran, fails closed on
# its own skip list, and isolates each suite. Runs the real runner on planted trees.
#
#   - ok / FAIL / xfail lines and the summary count what ran; a failure exits 1 and
#     its log is echoed
#   - an xfail that passes is STALE and exits 2; a listed path that is no suite exits 2
#     before anything runs; an unknown kind exits 2
#   - a skip entry is not run at all and is reported with its reason
#   - each suite sees its own empty scratch HOME, removed afterwards
#   - a hung suite is killed at CLAUDE_TESTS_TIMEOUT and counted as a failure
#   - a Python suite that collects no test cases is a failure, not a pass
#   - --list runs nothing
#   - positional arguments select suites; an unknown one exits 2
#   - a suite runs under umask 022 whatever the caller's umask
#   - the live tests/claude-tests.skips names only suites this repo discovers
#   - an xfail suite must fail for its listed reason: a log that lacks the signature,
#     a timeout, or a signal kill is a plain failure
#   - an xfail entry without a signature, a skip entry with one, or an invalid
#     signature exits 2 before anything runs
#   - a reused -o DIR serves no stale result; a runner child that dies leaves
#     "no result recorded" and a failed run
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
RUNNER=$ROOT/tests/run-claude-tests.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }
command -v python3 >/dev/null || fail "python3 is required (the runner needs it for tests/test_*.py)"

# plant <name>: a fresh tree at $WORK/<name> with the runner in place; prints its path.
plant() {
  local t=$WORK/$1
  mkdir -p "$t/tests"
  cp "$RUNNER" "$t/tests/run-claude-tests.sh"
  : >"$t/tests/claude-tests.skips"
  printf '%s\n' "$t"
}
# suite <tree> <name> <body>: a bash suite tests/<name>.test.sh
suite() { printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/tests/$2.test.sh"; }
# run <tree> [args]: runs the runner there with 2 jobs; output in $OUT, exit code in $RC
run() {
  local t=$1; shift
  set +e
  OUT=$(bash "$t/tests/run-claude-tests.sh" -j 2 -o "$t/logs" "$@" 2>&1)
  RC=$?
  set -e
}
has() { grep -q -- "$1" <<<"$OUT" || { printf '%s\n' "$OUT"; fail "$2"; }; }
lacks() { ! grep -q -- "$1" <<<"$OUT" || { printf '%s\n' "$OUT"; fail "$2"; }; }

echo "== 1: ok, FAIL and xfail lines, the summary, the echoed log, exit 1 =="
T=$(plant mixed)
suite "$T" pass 'echo fine'
suite "$T" fail 'echo broken-on-purpose >&2; exit 3'
suite "$T" xf 'echo "FAIL: the fixture is not here"; exit 1'
suite "$T" also-pass 'exit 0'
printf 'xfail\ttests/xf.test.sh\tfails here on purpose\t^FAIL: the fixture is not here\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "mixed tree: exit $RC, want 1"; }
has '^ok     tests/pass.test.sh' "no ok line for pass.test.sh"
has '^ok     tests/also-pass.test.sh' "no ok line for also-pass.test.sh"
has '^FAIL   tests/fail.test.sh .*rc=3' "no FAIL line with rc=3 for fail.test.sh"
has '^xfail  tests/xf.test.sh .*rc=1' "no xfail line for xf.test.sh"
has '^claude-tests: 4 suites discovered; 4 ran: 2 ok, 1 failed, 1 expected failures; 0 skipped; 0 stale skip entries;' "summary line wrong"
has '^===== tests/fail.test.sh' "the failed suite's log header is missing"
has '^broken-on-purpose$' "the failed suite's log was not echoed"
[ -f "$T/logs/tests__fail.test.sh.log" ] || fail "no log file for fail.test.sh under -o"
ok "a mixed tree reports 2 ok, 1 failed, 1 expected failure, echoes the failure's log and exits 1"

echo "== 2: an xfail that passes is STALE and exits 2 =="
T=$(plant stale)
suite "$T" good 'exit 0'
suite "$T" other 'exit 0'
printf 'xfail\ttests/good.test.sh\tused to fail\t.\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "stale xfail: exit $RC, want 2"; }
has '^STALE  tests/good.test.sh' "no STALE line"
has 'stale entry in tests/claude-tests.skips: tests/good.test.sh passed' "no stale-entry message naming the suite"
has '1 ok, 0 failed, 0 expected failures; 0 skipped; 1 stale skip entries' "summary did not count the stale entry"
ok "an xfail suite that passes is reported STALE and the run exits 2"

echo "== 3: a listed path that is not a suite exits 2 before anything runs =="
T=$(plant ghost)
suite "$T" good 'exit 0'
printf 'skip\ttests/gone.test.sh\tnever existed\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "ghost path: exit $RC, want 2"; }
has 'stale entry in tests/claude-tests.skips: tests/gone.test.sh is not a discovered suite' "no stale-entry message for the ghost path"
lacks '^ok ' "suites ran although the skip list was stale"
[ ! -e "$T/logs" ] || fail "a log dir was created although nothing should have run"
ok "a skip-list path that is no suite exits 2 and runs nothing"

echo "== 4: an unknown kind exits 2 =="
T=$(plant kind)
suite "$T" good 'exit 0'
printf 'maybe\ttests/good.test.sh\twhat\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "unknown kind: exit $RC, want 2"; }
has 'kind must be xfail or skip' "no kind error"
ok "an unknown skip kind exits 2"

echo "== 5: a skip entry is not run and is reported with its reason =="
T=$(plant skipped)
suite "$T" good 'exit 0'
suite "$T" nope "touch '$T/nope-ran'; exit 1"
printf 'skip\ttests/nope.test.sh\tneeds the author host\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "skip tree: exit $RC, want 0"; }
[ ! -e "$T/nope-ran" ] || fail "the skipped suite ran"
has '^skip   tests/nope.test.sh .*needs the author host' "no skip line with the reason"
has '^claude-tests: 2 suites discovered; 1 ran: 1 ok, 0 failed, 0 expected failures; 1 skipped; 0 stale skip entries;' "summary did not count the skip"
ok "a skip suite is not run, is listed with its reason, and the run exits 0"

echo "== 6: each suite gets its own empty scratch HOME, removed afterwards =="
T=$(plant home)
suite "$T" home "[ \"\$HOME\" != '$HOME' ] && [ -d \"\$HOME\" ] && [ -z \"\$(ls -A \"\$HOME\")\" ] && printf '%s\n' \"\$HOME\" >'$T/seen-home'"
run "$T"
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "home tree: exit $RC, want 0 (the suite saw the caller's HOME or a non-empty one)"; }
[ -s "$T/seen-home" ] || fail "the suite did not record its HOME"
[ ! -d "$(cat "$T/seen-home")" ] || fail "the scratch HOME $(cat "$T/seen-home") was not removed"
ok "a suite runs under its own empty scratch HOME, which is removed afterwards"

echo "== 7: a hung suite is killed at CLAUDE_TESTS_TIMEOUT and counted as a failure =="
T=$(plant hang)
suite "$T" hang 'exec sleep 30'
CLAUDE_TESTS_TIMEOUT=2 run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "hang tree: exit $RC, want 1"; }
has '^FAIL   tests/hang.test.sh .*rc=124' "no FAIL line with rc=124"
has 'killed after 2s' "the timeout was not named in the echoed log"
ok "a hung suite is killed at the timeout and reported as a failure"

echo "== 8: a Python suite that collects no test cases is a failure =="
T=$(plant vacuous)
printf 'import unittest\n' >"$T/tests/test_nothing.py"
printf 'import unittest\n\nclass T(unittest.TestCase):\n    def test_one(self):\n        self.assertTrue(True)\n' >"$T/tests/test_one.py"
run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "vacuous tree: exit $RC, want 1"; }
has '^FAIL   tests/test_nothing.py' "the suite with no cases passed"
has 'collected no test cases' "the vacuity reason was not echoed"
has '^ok     tests/test_one.py' "the one-case suite did not pass under discovery"
ok "a Python suite with no test cases fails; one with a case passes under unittest discovery"

echo "== 9: --list runs nothing =="
T=$(plant list)
suite "$T" good "touch '$T/ran'; exit 0"
run "$T" --list
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "--list: exit $RC, want 0"; }
[ ! -e "$T/ran" ] || fail "--list ran a suite"
has '^sh    run    tests/good.test.sh' "--list did not list the suite"
ok "--list prints the discovered suites and runs none"

echo "== 10: positional arguments select suites; an unknown one exits 2 =="
T=$(plant pick)
suite "$T" a "touch '$T/a-ran'; exit 0"
suite "$T" b "touch '$T/b-ran'; exit 0"
run "$T" tests/a.test.sh
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "selected suite: exit $RC, want 0"; }
[ -e "$T/a-ran" ] || fail "the selected suite did not run"
[ ! -e "$T/b-ran" ] || fail "an unselected suite ran"
has '^claude-tests: 1 of 2 suites selected; 1 ran: 1 ok, 0 failed' "summary did not say 1 of 2 selected"
run "$T" tests/zzz.test.sh
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "unknown suite: exit $RC, want 2"; }
has 'tests/zzz.test.sh is not a discovered suite' "no message for the unknown suite"
ok "a positional argument selects one suite; an unknown one exits 2"

echo "== 11: a suite runs under umask 022 whatever the caller's umask =="
T=$(plant umask)
suite "$T" um "umask >'$T/seen-umask'"
old_umask=$(umask)
umask 0002
run "$T"
umask "$old_umask"
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "umask tree: exit $RC, want 0"; }
[ "$(cat "$T/seen-umask")" = 0022 ] || fail "the suite saw umask $(cat "$T/seen-umask"), want 0022"
ok "a suite runs under umask 022 although the caller set 0002"

echo "== 12: the live skip list names only suites this repo discovers =="
set +e
OUT=$(bash "$RUNNER" --list 2>&1); RC=$?
set -e
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "the live --list exited $RC: tests/claude-tests.skips names a path that is not a suite"; }
if grep -q 'tests/repo/' <<<"$OUT"; then
  grep 'tests/repo/' <<<"$OUT"
  fail "the runner discovered a suite under tests/repo/; those run from ci.yml directly and must not run twice"
fi
for s in "$ROOT"/tests/repo/*.test.sh; do
  grep -qF "tests/repo/$(basename "$s")" "$ROOT/.github/workflows/ci.yml" \
    || fail "ci.yml does not run tests/repo/$(basename "$s")"
done
n=$(grep -c . <<<"$OUT")
[ "$n" -ge 150 ] || fail "the live tree lists only $n suites; discovery is not seeing tests"
n_x=$(grep -c ' xfail  ' <<<"$OUT"); n_s=$(grep -c ' skip   ' <<<"$OUT")
n_listed=$(grep -c -E '^(xfail|skip)'$'\t' "$ROOT/tests/claude-tests.skips")
[ $((n_x + n_s)) = "$n_listed" ] || fail "the live skip list has $n_listed entries but --list marks $n_x xfail + $n_s skip"
ok "the live tree discovers $n suites, none under tests/repo/ (ci.yml runs each of those); all $n_listed skip-list entries are among them ($n_x xfail, $n_s skip)"

echo "== 13: an xfail suite must fail for its listed reason =="
T=$(plant reason)
suite "$T" other-reason 'echo "FAIL: something new broke"; exit 1'
suite "$T" good 'exit 0'
printf 'xfail\ttests/other-reason.test.sh\tthe fixture is missing\t^FAIL: the fixture is not here\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "other-reason tree: exit $RC, want 1"; }
has '^FAIL   tests/other-reason.test.sh .*rc=1, listed as xfail, but failed for another reason' "the mismatched xfail was not reported as a failure"
has 'does not match the listed signature /\^FAIL: the fixture is not here/' "the echoed log does not name the signature it lacks"
has '1 ok, 1 failed, 0 expected failures' "summary counted the mismatch as an expected failure"
ok "an xfail suite whose log lacks its signature is a failure, not an expected one"

echo "== 14: an xfail suite that times out or is killed is a failure, whatever its signature =="
T=$(plant infra)
suite "$T" hang 'echo starting; exec sleep 30'
suite "$T" killed 'echo starting; kill -KILL $$'
printf 'xfail\ttests/hang.test.sh\thangs\t.\nxfail\ttests/killed.test.sh\tdies\t.\n' >"$T/tests/claude-tests.skips"
CLAUDE_TESTS_TIMEOUT=2 run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "infra tree: exit $RC, want 1"; }
has '^FAIL   tests/hang.test.sh .*rc=124, listed as xfail, but killed after 2s' "a timed-out xfail was not a failure"
has '^FAIL   tests/killed.test.sh .*rc=137, listed as xfail, but did not run to completion' "a signal-killed xfail was not a failure"
has '0 ok, 2 failed, 0 expected failures' "summary counted a timeout or a kill as an expected failure"
ok "an xfail suite that times out or dies by signal is a failure even with a match-anything signature"

echo "== 15: an xfail entry needs a valid signature; a skip entry takes none =="
T=$(plant format)
suite "$T" good "touch '$T/ran'; exit 0"
suite "$T" bad 'exit 1'
printf 'xfail\ttests/bad.test.sh\tno signature\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "xfail without signature: exit $RC, want 2"; }
has 'an xfail entry needs a fourth field' "no message for the missing signature"
printf 'skip\ttests/good.test.sh\tnot run\t^x\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "skip with signature: exit $RC, want 2"; }
has 'a skip entry is not run, so it takes no signature' "no message for the skip signature"
printf 'xfail\ttests/bad.test.sh\tbroken pattern\t(\n' >"$T/tests/claude-tests.skips"
run "$T"
[ "$RC" = 2 ] || { printf '%s\n' "$OUT"; fail "invalid signature: exit $RC, want 2"; }
has 'not a valid grep -E pattern' "no message for the invalid pattern"
[ ! -e "$T/ran" ] || fail "a suite ran although the skip list was malformed"
ok "a malformed skip list exits 2 before anything runs"

echo "== 16: a reused -o DIR serves no stale result =="
T=$(plant reuse)
suite "$T" flip 'exit 0'
run "$T"
[ "$RC" = 0 ] || { printf '%s\n' "$OUT"; fail "first run: exit $RC, want 0"; }
has '^ok     tests/flip.test.sh' "the suite did not pass on the first run"
suite "$T" flip 'echo now-broken; exit 1'
run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "second run in the same -o DIR: exit $RC, want 1"; }
has '^FAIL   tests/flip.test.sh .*rc=1' "the earlier ok result was served again"
has '^now-broken$' "the second run's log was not the one echoed"
ok "a second run in the same -o DIR reports the new result, not the earlier one"

echo "== 17: a runner child that dies leaves no result and fails the run =="
T=$(plant orphan)
# $PPID is timeout; its parent (field 4 of /proc/<pid>/stat) is the runner's child for this suite.
suite "$T" orphan 'read -r _ _ _ gp _ </proc/$PPID/stat; kill -KILL "$gp"; sleep 1; exit 0'
TMPDIR=$T run "$T"
[ "$RC" = 1 ] || { printf '%s\n' "$OUT"; fail "orphan tree: exit $RC, want 1"; }
has '^FAIL   tests/orphan.test.sh  (no result recorded by this run' "the suite without a result was not a failure"
has 'the launcher (xargs) exited 125' "the launcher's exit was not reported"
ok "a suite whose runner child dies is reported as having no result, and the run fails"

echo "all $pass checks passed"
