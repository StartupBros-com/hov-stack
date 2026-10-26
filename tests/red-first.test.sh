#!/usr/bin/env bash
# red-first.test.sh -- agent-free, hermetic tests for scripts/red-first.sh
# (dotfiles#1362, plan docs/plans/2026-09-23-1741-feat-review-round-red-gate-and-breaker-plan.md,
# unit U2).
#
# CREATION GATE (KTD7): consumers are the adversarial-first workflow's
# RedFirst/Record stages and any session closing a finding; it gates whether a
# finding may close and whether another review round runs. The observed defect
# class is one never-red regression test on PR #1294 plus three review loops
# only the operator ended. Delete this suite with the round/RED apparatus under
# the deletion condition in harness/evidence-regime.md section 8 (the
# entry tier retired, or three qualifying calendar months with no never-red
# finding and no freeze).
#
# Builds one fixture git repository under its own /tmp dir (mirroring the
# whole-script section of review-adversarial-first.test.sh's scratch-repo
# technique). The main suite, tests/suite.test.sh, carries TWO cases added in
# the SAME fix commit -- red_case (fails on the defect commit, passes on the
# fix) and unreached_case (passes on both) -- inside the SAME file, so a
# runner that judges whole files (would report the suite red at the defect
# commit and never even see unreached_case) or that only runs at head (would
# report both cases identically) cannot pass this suite by accident. That is
# the Execution Note's "a runner that cannot distinguish the two fixture cases
# inside one file proves nothing" bar, asserted below as `rc != uc`.
#
# Separate small fixtures in the same repo cover: a case whose suite aborts at
# pre-fix before naming it (missing helper) -> unresolved then pass, never
# fail; a case that passes at pre-fix and regresses at head -> fails-at-head;
# the Red-first-exempt trailer; the Red-first-base trailer, both in-range
# (moves the pre-fix revision) and out-of-range (unverifiable); an unsupported
# extension; a node fixture whose case names cannot be extracted (file-level);
# a hook-suite fixture that writes under $HOME (sandboxing); a suite that
# exceeds --timeout. A second, separate invocation covers a pre-fix SHA that
# does not exist and cannot be fetched (unverifiable, exit 0, no worktree
# left behind).
#
# Python fixtures use real unittest subprocess output. An argv-checking uv
# adapter below uses the host Python without network dependency resolution;
# it is not proof of live uv provisioning. Production retains the exact CI
# command. Parser assertions also pin non-pass/non-fail result vocabulary.
#
# Hermetic: no network, GIT_CONFIG_GLOBAL/NOSYSTEM pinned to /dev/null so the
# operator's git config can't leak in, every write confined to a /tmp scratch
# dir removed on EXIT via trap.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/scripts/red-first.sh"

TMP=$(mktemp -d /tmp/red-first-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Unit-level checks on the shipped script's pure functions, sourced directly
# out of the REAL file (never a hand-copied reimplementation). red-first.sh
# guards its own main() behind a BASH_SOURCE==$0 check, so sourcing it here
# only defines functions -- it does not parse arguments or touch git.
#
# `source` runs in THIS shell, not a subshell: red-first.sh's own
# `set -euo pipefail` therefore leaks `-e` into this script the instant it's
# sourced, even though this file deliberately runs without `-e` (see the top
# of the file). Left unchecked, the very first later command that legitimately
# returns non-zero -- e.g. one of the usage-error checks below, which is
# SUPPOSED to exit 2 -- kills this whole script on the spot (errexit fires on
# the plain command, the EXIT trap runs, and every assertion after it,
# including the final summary line, silently never happens). Restore this
# file's own invariant right after sourcing.
source "$SCRIPT"
set +e

is_candidate_path "tests/x.test.sh" && ok || bad "tests/x.test.sh should be a candidate path"
is_candidate_path "tests/x.test.js" && ok || bad "tests/x.test.js should be a candidate path"
is_candidate_path "tests/test_x.py" && ok || bad "tests/test_x.py should be a candidate path"
if is_candidate_path "lib/test_x.py"; then bad "test_*.py outside tests must not be a candidate"; else ok; fi
is_candidate_path "tests/x.test.py" && ok || bad "a .test.py suffix should still be a candidate path (unsupported family, not excluded)"
if is_candidate_path "src/thing.sh"; then bad "a non-test path must not be a candidate"; else ok; fi
if is_candidate_path "README.md"; then bad "a doc path must not be a candidate"; else ok; fi

[ "$(family_for_path tests/x.test.sh)" = "bash-suite" ] && ok || bad "family_for_path tests/x.test.sh"
[ "$(family_for_path hooks/tests/x.test.js)" = "hook-node" ] && ok || bad "family_for_path hooks/tests/x.test.js"
[ "$(family_for_path tests/x.test.js)" = "plain-node" ] && ok || bad "family_for_path tests/x.test.js"
[ "$(family_for_path tests/x.test.mjs)" = "plain-node" ] && ok || bad "family_for_path tests/x.test.mjs"
[ "$(family_for_path tests/test_x.py)" = "python-unittest" ] && ok || bad "family_for_path tests/test_x.py"
[ "$(family_for_path tests/x.test.py)" = "unsupported" ] && ok || bad "family_for_path tests/x.test.py must be unsupported"

names=$(printf '+echo "FAIL: red_case" >&2\n+echo "FAIL: unreached_case" >&2\n-echo "FAIL: stale_case" >&2\n' | extract_names_bash)
[ "$names" = "$(printf 'red_case\nunreached_case')" ] && ok || bad "extract_names_bash got: [$names]"

names=$(printf '+bad "detects the source defect"\n+echo "PASS: multiword control case"\n+bad "$interpolated_name"\n' | extract_names_bash)
[ "$names" = "$(printf 'detects the source defect\nmultiword control case')" ] \
  && ok || bad "extract_names_bash must preserve literal multiword names and reject interpolation, got: [$names]"

names=$(printf "+test('alpha', () => {})\n+it('beta', () => {})\n+test(dynamicName, () => {})\n" | extract_names_node)
[ "$names" = "$(printf 'alpha\nbeta')" ] && ok || bad "extract_names_node got: [$names]"

names=$(printf '+def test_gamma(self):\n+  def test_delta(self):\n' | extract_names_python)
[ "$names" = "$(printf 'test_delta\ntest_gamma')" ] && ok || bad "extract_names_python got: [$names]"

for combo in "fail:pass:verified" "pass:pass:never-red" "unresolved:pass:inconclusive" \
             "unresolved:fail:inconclusive" "pass:unresolved:inconclusive" "fail:unresolved:inconclusive" \
             "pass:fail:fails-at-head" "fail:fail:fails-at-head" \
             "unsupported:unsupported:unsupported" "unsupported:pass:unsupported"; do
  pf=${combo%%:*}
  rest=${combo#*:}
  hd=${rest%%:*}
  want=${rest#*:}
  got=$(derive_case_status "$pf" "$hd")
  [ "$got" = "$want" ] && ok || bad "derive_case_status $pf $hd -> $got, want $want"
done

PY_STATUS_DIR="$TMP/python-status"
mkdir -p "$PY_STATUS_DIR"
cat > "$PY_STATUS_DIR/test_status.py" <<'EOF'
import unittest

class First(unittest.TestCase):
    def test_fail(self):
        self.fail("real failure")

    def test_error(self):
        raise RuntimeError("real error")

    @unittest.skip("source unavailable")
    def test_skip(self):
        pass

    @unittest.expectedFailure
    def test_expected(self):
        self.fail("expected")

class Second(unittest.TestCase):
    def test_ok(self):
        pass

    @unittest.expectedFailure
    def test_surprise(self):
        pass
EOF
# subTest failures print the parent with an empty result, then one indented
# line per failing subtest (live PR #1390 round 4 scored such RED cases as
# unresolved).
cat > "$PY_STATUS_DIR/test_subtests.py" <<'EOF'
import unittest

class Sub(unittest.TestCase):
    def test_all_ok(self):
        for i in (1, 2):
            with self.subTest(i=i):
                self.assertTrue(i)

    def test_one_fail(self):
        for i in (1, 2):
            with self.subTest(i=i):
                self.assertEqual(i, 1)

    def test_fail_and_error(self):
        for i in (1, 2):
            with self.subTest(i=i):
                if i == 1:
                    self.fail("assertion")
                raise RuntimeError("not an assertion")

    def test_fail_and_skip(self):
        for i in (1, 2):
            with self.subTest(i=i):
                if i == 1:
                    self.skipTest("unavailable")
                self.fail("assertion")
EOF
# unittest labels a subtest "[msg]", "(params)", "[msg] (params)" or
# "(<subtest>)", and a message may span lines (Pro gate round 3 on PR #1390: a
# labelled ERROR beside a parameter-only FAIL was dropped and read as RED).
cat > "$PY_STATUS_DIR/test_labelled.py" <<'EOF'
import sys
import unittest

class Labelled(unittest.TestCase):
    def test_fail_and_labelled_error(self):
        with self.subTest(i=1):
            self.fail("assertion")
        with self.subTest("broken"):
            {}["missing"]

    def test_fail_and_labelled_skip(self):
        with self.subTest(i=1):
            self.fail("assertion")
        with self.subTest("gone", k=2):
            self.skipTest("unavailable")

    def test_fail_and_multiline_error(self):
        with self.subTest(i=1):
            self.fail("assertion")
        with self.subTest("line one\nline two"):
            raise RuntimeError("not an assertion")

    def test_fail_then_stray_line(self):
        with self.subTest(i=1):
            self.fail("assertion")
        print("  test_other (test_labelled.Labelled.test_other) (k=1) ... FAIL", file=sys.stderr)

    def test_fail_then_stray_case_line(self):
        with self.subTest(i=1):
            self.fail("assertion")
        print("stray_leaf (other_mod.Other.stray_leaf) ... ok", file=sys.stderr)
        with self.subTest("broken"):
            {}["missing"]
        with self.subTest(k=2):
            self.skipTest("unavailable")

    def test_fail_then_stray_case_multiline_error(self):
        with self.subTest(i=1):
            self.fail("assertion")
        print("stray_leaf (other_mod.Other.stray_leaf) ... ok", file=sys.stderr)
        with self.subTest("line one\nline two"):
            raise RuntimeError("not an assertion")

    def test_fail_then_stray_id_line(self):
        with self.subTest(i=1):
            self.fail("assertion")
        print("stray_leaf (other_mod.Other.stray_leaf)", file=sys.stderr)
        with self.subTest(i=2):
            raise RuntimeError("not an assertion")

    def test_fails_then_trailing_stray_case_line(self):
        for i in (1, 2):
            with self.subTest(i=i):
                self.fail("assertion")
        print("stray_leaf (other_mod.Other.stray_leaf) ... ok", file=sys.stderr)

    def test_labelled_fail(self):
        with self.subTest("labelled"):
            self.fail("assertion")

    def test_labelled_param_fail(self):
        with self.subTest("labelled", k=1):
            self.fail("assertion")

    def test_labelled_param_fail_then_docstring(self):
        """Prints its case id alone, which must end the RED case's block above."""

    def test_default_fail(self):
        with self.subTest():
            self.fail("assertion")
EOF
python3 -m unittest discover -s "$PY_STATUS_DIR" -p 'test_*.py' -v \
  >"$TMP/python-status.log" 2>&1
py_status_rc=$?
[ "$py_status_rc" -ne 0 ] && ok || bad "real unittest status fixture must contain failures"
py_out=$(parse_python_unittest_output test_status < "$TMP/python-status.log")
py_expected=$(printf 'First.test_error\tERROR\nFirst.test_expected\texpected failure\nFirst.test_fail\tFAIL\nFirst.test_skip\tskipped '\''source unavailable'\''\nSecond.test_ok\tok\nSecond.test_surprise\tunexpected success')
[ "$py_out" = "$py_expected" ] && ok || bad "parse_python_unittest_output qualified attribution got: [$py_out]"
for py_case in \
  "First.test_error:unresolved" \
  "First.test_expected:unresolved" \
  "First.test_fail:fail" \
  "First.test_skip:unresolved" \
  "Second.test_ok:pass" \
  "Second.test_surprise:unresolved"; do
  py_name=${py_case%%:*}
  py_want=${py_case#*:}
  py_got=$(python_case_status test_status "$py_name" "$TMP/python-status.log")
  [ "$py_got" = "$py_want" ] && ok || bad "python_case_status $py_name -> $py_got, want $py_want"
done
for py_case in \
  "Sub.test_all_ok:pass" \
  "Sub.test_one_fail:fail" \
  "Sub.test_fail_and_error:unresolved" \
  "Sub.test_fail_and_skip:unresolved"; do
  py_name=${py_case%%:*}
  py_want=${py_case#*:}
  py_got=$(python_case_status test_subtests "$py_name" "$TMP/python-status.log")
  [ "$py_got" = "$py_want" ] && ok || bad "subTest python_case_status $py_name -> $py_got, want $py_want"
done
for py_case in \
  "Labelled.test_fail_and_labelled_error:unresolved" \
  "Labelled.test_fail_and_labelled_skip:unresolved" \
  "Labelled.test_fail_and_multiline_error:unresolved" \
  "Labelled.test_fail_then_stray_line:unresolved" \
  "Labelled.test_fail_then_stray_case_line:unresolved" \
  "Labelled.test_fail_then_stray_case_multiline_error:unresolved" \
  "Labelled.test_fail_then_stray_id_line:unresolved" \
  "Labelled.test_fails_then_trailing_stray_case_line:fail" \
  "Labelled.test_labelled_fail:fail" \
  "Labelled.test_labelled_param_fail:fail" \
  "Labelled.test_default_fail:fail"; do
  py_name=${py_case%%:*}
  py_want=${py_case#*:}
  py_got=$(python_case_status test_labelled "$py_name" "$TMP/python-status.log")
  [ "$py_got" = "$py_want" ] && ok || bad "labelled subTest python_case_status $py_name -> $py_got, want $py_want"
done
py_dup=$(python_case_status test_subtests Sub.test_one_fail "$TMP/python-status.log" "$TMP/python-status.log")
[ "$py_dup" = "unresolved" ] && ok || bad "a subTest case reported by two logs must be unresolved, got $py_dup"
# One early ERROR, second of 20,000 results; every other one is an assertion
# failure. The check must read every outcome: an early-exit grep fed by a pipe
# under pipefail returned 141 once it stopped reading, and that selected fail.
PY_LARGE_DIR="$TMP/python-large"
mkdir -p "$PY_LARGE_DIR"
cat > "$PY_LARGE_DIR/test_large.py" <<'EOF'
import unittest

class Large(unittest.TestCase):
    def test_error_then_failures(self):
        for i in range(20000):
            with self.subTest(i=i):
                if i == 1:
                    raise RuntimeError("not an assertion")
                self.fail("assertion")
EOF
python3 -m unittest discover -s "$PY_LARGE_DIR" -p 'test_*.py' -v >"$TMP/python-large.log" 2>&1
large_status=$(python_case_status test_large Large.test_error_then_failures "$TMP/python-large.log")
[ "$large_status" = "unresolved" ] && ok || bad "an early subTest ERROR among 20,000 results must be unresolved, got $large_status"
printf 'test_unknown (test_status.Second.test_unknown) ... MYSTERY\n' > "$TMP/python-unknown.log"
unknown_status=$(python_case_status test_status Second.test_unknown "$TMP/python-unknown.log")
[ "$unknown_status" = "unresolved" ] && ok || bad "unknown unittest result must be unresolved, got $unknown_status"

: > "$TMP/bash-nonzero.out"
: > "$TMP/bash-nonzero.err"
unnamed_status=$(case_verdict bash-suite 1 unnamed_case ignored "$TMP/bash-nonzero.out" "$TMP/bash-nonzero.err")
[ "$unnamed_status" = "unresolved" ] && ok || bad "nonzero bash suite without exact case evidence must be unresolved, got $unnamed_status"
printf 'PASS: named_case\n' > "$TMP/bash-positive.out"
named_status=$(case_verdict bash-suite 1 named_case ignored "$TMP/bash-positive.out" "$TMP/bash-nonzero.err")
[ "$named_status" = "pass" ] && ok || bad "nonzero bash suite with exact positive evidence should preserve pass, got $named_status"
printf 'FAIL: detects the source defect\n' > "$TMP/bash-multiword.err"
multiword_status=$(case_verdict bash-suite 1 "detects the source defect" ignored "$TMP/bash-nonzero.out" "$TMP/bash-multiword.err")
[ "$multiword_status" = "fail" ] && ok || bad "multiword Bash case must retain exact FAIL evidence, got $multiword_status"

# ---------------------------------------------------------------------------
# Fixture git repository.
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE"
GIT_ENV_GLOBAL=/dev/null
GIT_ENV_NOSYSTEM=1
git_c() { env GIT_CONFIG_GLOBAL="$GIT_ENV_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_ENV_NOSYSTEM" git -C "$FIXTURE" "$@"; }
commit_q() { git_c -c user.email=t@example.com -c user.name=t commit -q -m "$1"; }

git_c init -q -b main
mkdir -p "$FIXTURE/lib" "$FIXTURE/tests" "$FIXTURE/hooks/tests"

# --- ROOT: minimal common ancestor, no defect yet ---
printf 'root\n' > "$FIXTURE/README.md"
git_c add README.md
commit_q "chore: root"
ROOT_SHA=$(git_c rev-parse HEAD)

git_c checkout -q -b feature

# --- commit A: defect ---
cat > "$FIXTURE/lib/greet.sh" <<'EOF'
#!/usr/bin/env bash
greet() { echo "wrong"; }
EOF
printf 'old\n' > "$FIXTURE/lib/legacy_flag"
printf 'bad\n' > "$FIXTURE/lib/base_flag"
cat > "$FIXTURE/tests/suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
pass=0
fail=0
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF
printf 'bad\n' > "$FIXTURE/lib/body_flag"
printf 'bad\n' > "$FIXTURE/lib/cross_flag"
printf 'slow\n' > "$FIXTURE/lib/timeout_mode"
cat > "$FIXTURE/tests/identical.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: identical_case"
exit 0
EOF
cat > "$FIXTURE/tests/body-bash.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$(cat "$SUITE_DIR/../lib/body_flag")" = "good" ]; then
  note="old body"
  echo "PASS: bash_body_case"
else
  echo "FAIL: bash_body_case" >&2
  exit 1
fi
EOF
cat > "$FIXTURE/tests/body-node.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
test('node_body_case', () => {
  const flag = fs.readFileSync(path.join(__dirname, '../lib/body_flag'), 'utf8').trim();
  assert.equal(flag, 'good', 'old body');
});
EOF
cat > "$FIXTURE/tests/timeout-one-side.test.js" <<'EOF'
const { test } = require('node:test');
const fs = require('fs');
const path = require('path');
const dynamicName = ['timeout', 'one', 'side'].join('_');
test(dynamicName, async () => {
  const mode = fs.readFileSync(path.join(__dirname, '../lib/timeout_mode'), 'utf8').trim();
  if (mode === 'slow') await new Promise(resolve => setTimeout(resolve, 8000));
});
EOF
cat > "$FIXTURE/tests/test_body.py" <<'EOF'
import unittest

class BodyTest(unittest.TestCase):
    def test_python_body(self):
        value = "old body"
        self.assertTrue(value)
EOF
git_c add lib tests hooks
commit_q "feat: add greet (defect)"
A_SHA=$(git_c rev-parse HEAD)

# --- commit C: unrelated, base_flag still buggy; gives Red-first-base a
#     distinct, resolvable SHA to move a path's pre-fix revision to. ---
printf '# notes\n' > "$FIXTURE/NOTES.md"
git_c add NOTES.md
commit_q "docs: notes (unrelated, base_flag still buggy)"
C_SHA=$(git_c rev-parse HEAD)

# --- commit B: fix + tests ---
cat > "$FIXTURE/lib/greet.sh" <<'EOF'
#!/usr/bin/env bash
greet() { echo "hi"; }
EOF
printf 'new\n' > "$FIXTURE/lib/legacy_flag"
printf 'good\n' > "$FIXTURE/lib/base_flag"
printf 'good\n' > "$FIXTURE/lib/body_flag"
printf 'good\n' > "$FIXTURE/lib/cross_flag"
printf 'fast\n' > "$FIXTURE/lib/timeout_mode"

cat > "$FIXTURE/tests/suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SUITE_DIR/../lib/greet.sh"
pass=0
fail=0
if [ "$(greet)" = "hi" ]; then pass=$((pass + 1)); echo "PASS: red_case"; else fail=$((fail + 1)); echo "FAIL: red_case" >&2; fi
if [ 1 -eq 1 ]; then pass=$((pass + 1)); echo "PASS: unreached_case"; else fail=$((fail + 1)); echo "FAIL: unreached_case" >&2; fi
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF

cat > "$FIXTURE/tests/body-bash.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$(cat "$SUITE_DIR/../lib/body_flag")" = "good" ]; then
  note="new body"
  echo "PASS: bash_body_case"
else
  echo "FAIL: bash_body_case" >&2
  exit 1
fi
EOF
cat > "$FIXTURE/tests/body-node.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
test('node_body_case', () => {
  const flag = fs.readFileSync(path.join(__dirname, '../lib/body_flag'), 'utf8').trim();
  assert.equal(flag, 'good', 'new body');
});
EOF
cat > "$FIXTURE/tests/timeout-one-side.test.js" <<'EOF'
const { test } = require('node:test');
const fs = require('fs');
const path = require('path');
const dynamicName = ['timeout', 'one', 'side'].join('_');
test(dynamicName, async () => {
  const mode = fs.readFileSync(path.join(__dirname, '../lib/timeout_mode'), 'utf8').trim();
  if (mode === 'slow') await new Promise(resolve => setTimeout(resolve, 8000));
  // Head-side body change keeps this file in the changed candidate set.
});
EOF
cat > "$FIXTURE/tests/test_body.py" <<'EOF'
import unittest

class BodyTest(unittest.TestCase):
    def test_python_body(self):
        value = "new body"
        self.assertTrue(value)
EOF
cat > "$FIXTURE/tests/cross-helper.test.sh" <<'EOF'
#!/usr/bin/env bash
cross_ok() {
  local suite_dir=$1
  [ "$(cat "$suite_dir/../lib/cross_flag")" = "good" ]
}
EOF
cat > "$FIXTURE/tests/cross-a.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SUITE_DIR/cross-helper.test.sh"
if cross_ok "$SUITE_DIR"; then echo "PASS: cross_a_case"; else echo "FAIL: cross_a_case" >&2; exit 1; fi
EOF
cat > "$FIXTURE/tests/cross-c.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SUITE_DIR/cross-helper.test.sh"
if cross_ok "$SUITE_DIR"; then echo "PASS: cross_c_case"; else echo "FAIL: cross_c_case" >&2; exit 1; fi
EOF
cat > "$FIXTURE/tests/manifest-only.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: manifest_only_case"
EOF

cat > "$FIXTURE/tests/regress-suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pass=0
fail=0
if [ "$(cat "$SUITE_DIR/../lib/legacy_flag")" = "old" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: regress_case" >&2; fi
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF

cat > "$FIXTURE/tests/helper.sh" <<'EOF'
#!/usr/bin/env bash
helper_says_ok() { return 0; }
EOF

cat > "$FIXTURE/tests/helper-suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -f "$SUITE_DIR/helper.sh" ]; then
  echo "helper.sh missing, aborting before unresolved_case" >&2
  exit 3
fi
. "$SUITE_DIR/helper.sh"
pass=0
fail=0
if helper_says_ok; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: unresolved_case" >&2; fi
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF

cat > "$FIXTURE/tests/exempt-suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
pass=0
fail=0
if [ 1 -eq 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: exempt_never_red_case" >&2; fi
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF

cat > "$FIXTURE/tests/base-suite.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pass=0
fail=0
if [ "$(cat "$SUITE_DIR/../lib/base_flag")" = "good" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: base_verified_case" >&2; fi
echo "ok $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
EOF

cat > "$FIXTURE/tests/outrange-suite.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok 0/0"
exit 0
EOF

cat > "$FIXTURE/tests/foo.test.py" <<'EOF'
# not the test_*.py naming convention -- exercises the unsupported-extension fallback
print("noop")
EOF

cat > "$FIXTURE/tests/dynamic.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
const names = ['alpha', 'beta'];
for (const n of names) {
  test(n, () => { assert.ok(true); });
}
EOF

cat > "$FIXTURE/tests/slow.test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 8
echo "FAIL: slow_case"
exit 1
EOF

cat > "$FIXTURE/hooks/tests/sandbox.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
test('writes_under_sandbox', () => {
  const home = process.env.HOME || process.env.USERPROFILE;
  fs.writeFileSync(path.join(home, 'sentinel-home.txt'), 'x');
  fs.writeFileSync(path.join(process.env.CLAUDE_SEAM_DIR, 'sentinel-seam.txt'), 'x');
  assert.ok(true);
});
EOF

git_c add lib tests hooks
cat > "$TMP/commit-b-msg.txt" <<EOF
feat: fix greet/base_flag/legacy_flag, add regression and auxiliary tests

These are quoted body examples, not authoritative trailers:
Red-first-exempt: tests/suite.test.sh -- body prose must be ignored
Red-first-base: tests/suite.test.sh -- $ROOT_SHA
The real trailer block follows this separate prose paragraph.

Red-first-exempt: tests/exempt-suite.test.sh -- fixture rename, not a regression test
Red-first-base: tests/base-suite.test.sh -- $C_SHA
Red-first-base: tests/outrange-suite.test.sh -- $ROOT_SHA
EOF
git_c -c user.email=t@example.com -c user.name=t commit -q -F "$TMP/commit-b-msg.txt"
HEAD_SHA=$(git_c rev-parse HEAD)

bash_body_names=$(extract_changed_case_names "$FIXTURE" "$A_SHA" "$HEAD_SHA" tests/body-bash.test.sh bash-suite)
[ "$bash_body_names" = "bash_body_case" ] && ok || bad "body-only Bash edit should map to bash_body_case, got [$bash_body_names]"
node_body_names=$(extract_changed_case_names "$FIXTURE" "$A_SHA" "$HEAD_SHA" tests/body-node.test.js plain-node)
[ "$node_body_names" = "node_body_case" ] && ok || bad "body-only Node edit should map to node_body_case, got [$node_body_names]"
python_body_names=$(extract_changed_case_names "$FIXTURE" "$A_SHA" "$HEAD_SHA" tests/test_body.py python-unittest)
[ "$python_body_names" = "BodyTest.test_python_body" ] && ok || bad "body-only Python edit should map to BodyTest.test_python_body, got [$python_body_names]"

# ---------------------------------------------------------------------------
# Run 1: the comprehensive invocation.
FILES1="$TMP/files1.txt"
cat > "$FILES1" <<'EOF'
lib/greet.sh
tests/suite.test.sh
tests/regress-suite.test.sh
tests/helper-suite.test.sh
tests/exempt-suite.test.sh
tests/base-suite.test.sh
tests/outrange-suite.test.sh
tests/foo.test.py
tests/dynamic.test.js
tests/slow.test.sh
tests/identical.test.sh
tests/body-bash.test.sh
tests/body-node.test.js
tests/timeout-one-side.test.js
tests/cross-helper.test.sh
tests/cross-a.test.sh
tests/cross-c.test.sh
hooks/tests/sandbox.test.js
EOF

MANIFEST1="$TMP/manifest1.json"
python3 -c '
import json, sys
files_path, out_path, a_sha, c_sha = sys.argv[1:]
with open(files_path) as f:
    paths = [line.strip() for line in f if line.strip() and line.startswith(("tests/", "hooks/"))]
entries = [{"path": p, "pre_fix": c_sha if p in {"tests/cross-helper.test.sh", "tests/cross-c.test.sh"} else a_sha} for p in paths]
entries.append({"path": "tests/manifest-only.test.sh", "pre_fix": a_sha})
with open(out_path, "w") as f:
    json.dump(entries, f)
' "$FILES1" "$MANIFEST1" "$A_SHA" "$C_SHA"

OUTER_HOME="$TMP/outer-home"
OUTER_SEAM="$TMP/outer-seam"
mkdir -p "$OUTER_HOME" "$OUTER_SEAM"
OUT1="$TMP/out1.json"
ERR1="$TMP/err1.log"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$OUTER_HOME" USERPROFILE="$OUTER_HOME" CLAUDE_SEAM_DIR="$OUTER_SEAM" \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --manifest "$MANIFEST1" --files "$FILES1" \
  --base-branch main --timeout 3 >"$OUT1" 2>"$ERR1"
run1_rc=$?
[ "$run1_rc" -eq 0 ] && ok || bad "run 1 exited $run1_rc; stderr: $(cat "$ERR1")"

[ -z "$(find "$OUTER_HOME" -mindepth 1 -print -quit)" ] && ok || bad "hook-suite run wrote under controlled outer HOME"
[ -z "$(find "$OUTER_SEAM" -mindepth 1 -print -quit)" ] && ok || bad "hook-suite run wrote under controlled outer seam"

wt_count1=$(git_c worktree list | wc -l | tr -d ' ')
[ "$wt_count1" -eq 1 ] && ok || bad "expected exactly 1 worktree (the fixture) after run 1, got $wt_count1: $(git_c worktree list)"

cat > "$TMP/assert1.py" <<'PYEOF'
import json
import sys

path, A_SHA, C_SHA, ROOT_SHA, HEAD_SHA, manifest_path, files_path = sys.argv[1:8]

with open(path) as f:
    doc = json.load(f)

p = 0
n = 0


def ok(cond, msg):
    global p, n
    if cond:
        p += 1
    else:
        n += 1
        print(f"FAIL: {msg}")


CASE_STATUSES = {"verified", "never-red", "inconclusive", "fails-at-head", "unsupported"}
REV_STATUSES = {"pass", "fail", "unresolved", "unsupported"}
PATH_STATUSES = {"ran", "file-level", "unsupported", "unverifiable"}

ok(doc.get("head") == HEAD_SHA, f"doc.head == HEAD_SHA (got {doc.get('head')})")
ok(doc.get("base_branch") == "main", f"doc.base_branch == main (got {doc.get('base_branch')})")

tests = {t["path"]: t for t in doc.get("tests", [])}
selected_files = set(open(files_path).read().splitlines())
expected_requested = [item for item in json.load(open(manifest_path)) if item["path"] in selected_files]
requested = doc.get("requested")
ok(isinstance(requested, list) and
   sorted(requested, key=lambda item: item["path"]) == sorted(expected_requested, key=lambda item: item["path"]),
   f"requested must bind the exact intersected manifest, including unchanged/unsupported/unverifiable paths: {requested}")
ok(isinstance(requested, list) and len({item["path"] for item in requested}) == len(requested),
   f"requested paths cannot duplicate: {requested}")
ok(isinstance(requested, list) and
   next((item["pre_fix"] for item in requested if item["path"] == "tests/base-suite.test.sh"), None) == A_SHA and
   tests.get("tests/base-suite.test.sh", {}).get("pre_fix") == C_SHA,
   "requested baseline must remain A_SHA even when Red-first-base corrects effective pre_fix to C_SHA")

ok("lib/greet.sh" not in tests, "lib/greet.sh must not be a candidate (not a test-pattern path)")

t = tests.get("tests/suite.test.sh")
ok(t is not None, "tests/suite.test.sh present")
if t:
    ok(t["status"] == "ran", f"tests/suite.test.sh status == ran (got {t.get('status')})")
    ok(t.get("pre_fix") == A_SHA, f"body Red-first-base prose must not move suite baseline (got {t.get('pre_fix')})")
    ok(t.get("exempt") is False and t.get("exempt_reason") is None,
       f"body Red-first-exempt prose must not exempt suite (got {t.get('exempt')}, {t.get('exempt_reason')})")
    cases = {c["name"]: c for c in t.get("cases", [])}
    rc = cases.get("red_case")
    ok(rc is not None and rc["status"] == "verified", f"red_case verified (got {rc})")
    ok(rc is not None and rc["pre_fix"] == "fail" and rc["head"] == "pass", f"red_case pre_fix=fail head=pass (got {rc})")
    uc = cases.get("unreached_case")
    ok(uc is not None and uc["status"] == "never-red", f"unreached_case never-red (got {uc})")
    ok(uc is not None and uc["pre_fix"] == "pass" and uc["head"] == "pass", f"unreached_case pre_fix=pass head=pass (got {uc})")
    ok(rc != uc, "planted negative: red_case and unreached_case must differ, not be reported identically")

t = tests.get("tests/regress-suite.test.sh")
ok(t is not None, "tests/regress-suite.test.sh present")
if t:
    cases = {c["name"]: c for c in t.get("cases", [])}
    rg = cases.get("regress_case")
    ok(rg is not None and rg["status"] == "fails-at-head", f"regress_case fails-at-head (got {rg})")
    ok(rg is not None and rg["pre_fix"] == "pass" and rg["head"] == "fail", f"regress_case pre_fix=pass head=fail (got {rg})")

t = tests.get("tests/helper-suite.test.sh")
ok(t is not None, "tests/helper-suite.test.sh present")
if t:
    cases = {c["name"]: c for c in t.get("cases", [])}
    hc = cases.get("unresolved_case")
    ok(hc is not None and hc["pre_fix"] == "unresolved", f"unresolved_case pre_fix unresolved (got {hc})")
    ok(hc is not None and hc["head"] == "pass", f"unresolved_case head pass, never fail (got {hc})")
    ok(hc is not None and hc["status"] == "inconclusive", f"unresolved_case status inconclusive (got {hc})")

t = tests.get("tests/exempt-suite.test.sh")
ok(t is not None, "tests/exempt-suite.test.sh present")
if t:
    reason = "fixture rename, not a regression test"
    ok(t.get("exempt") is True, f"exempt-suite exempt True (got {t.get('exempt')})")
    ok(t.get("exempt_reason") == reason, f"exempt-suite exact reason (got {t.get('exempt_reason')})")
    ok({"path": "tests/exempt-suite.test.sh", "reason": reason} in doc.get("exempt", []),
       f"exempt-suite listed with exact reason (got {doc.get('exempt')})")
    cases = {c["name"]: c for c in t.get("cases", [])}
    ec = cases.get("exempt_never_red_case")
    ok(ec is not None and ec.get("pre_fix") == "pass" and ec.get("head") == "pass" and ec.get("status") == "never-red",
       f"exempt-suite per-case result intact (got {ec})")

t = tests.get("tests/base-suite.test.sh")
ok(t is not None, "tests/base-suite.test.sh present")
if t:
    ok(t.get("pre_fix") == C_SHA, f"base-suite pre_fix moved to C_SHA (got {t.get('pre_fix')}, A_SHA={A_SHA})")
    ok(t.get("pre_fix") != A_SHA, "base-suite pre_fix must differ from the flat default")
    cases = {c["name"]: c for c in t.get("cases", [])}
    bc = cases.get("base_verified_case")
    ok(bc is not None and bc["status"] == "verified", f"base_verified_case verified (got {bc})")

t = tests.get("tests/outrange-suite.test.sh")
ok(t is not None, "tests/outrange-suite.test.sh present")
if t:
    ok(t.get("status") == "unverifiable", f"outrange-suite status unverifiable (got {t.get('status')})")
    ok(bool(t.get("reason")), "outrange-suite reason present")

t = tests.get("tests/foo.test.py")
ok(t is not None, "tests/foo.test.py present")
if t:
    ok(t.get("status") == "unsupported", f"foo.test.py status unsupported (got {t.get('status')})")
    ok(not t.get("command"), f"foo.test.py no command run (got {t.get('command')})")
    ok(t.get("cases") == [{"name": "tests/foo.test.py", "pre_fix": "unsupported", "head": "unsupported", "status": "unsupported"}],
       f"foo.test.py exact unsupported case result (got {t.get('cases')})")

t = tests.get("tests/dynamic.test.js")
ok(t is not None, "tests/dynamic.test.js present")
if t:
    ok(t.get("status") == "file-level", f"dynamic.test.js status file-level (got {t.get('status')})")
    ok(bool(t.get("command")) and "node --test" in t.get("command", ""), f"dynamic.test.js command recorded (got {t.get('command')})")
    ok(t.get("cases") == [{"name": "tests/dynamic.test.js", "pre_fix": "pass", "head": "pass", "status": "never-red"}],
       f"dynamic.test.js exact file-level result (got {t.get('cases')})")

ok("tests/identical.test.sh" not in tests, "identical listed test must be omitted")
ok(doc.get("unchanged") == [{"path": "tests/identical.test.sh", "pre_fix": A_SHA}],
   f"equal-blob exclusions must be explicit with their baseline (got {doc.get('unchanged')})")
ok("tests/manifest-only.test.sh" not in tests, "manifest-only path absent from --files must be omitted")

for path, case_name in [("tests/body-bash.test.sh", "bash_body_case"), ("tests/body-node.test.js", "node_body_case")]:
    t = tests.get(path)
    ok(t is not None, f"{path} present")
    if t:
        c = {item["name"]: item for item in t.get("cases", [])}.get(case_name)
        ok(c is not None and c.get("pre_fix") == "fail" and c.get("head") == "pass" and c.get("status") == "verified",
           f"{path} body-only case verified (got {c})")

for path, expected_sha, case_name in [
    ("tests/cross-a.test.sh", A_SHA, "cross_a_case"),
    ("tests/cross-c.test.sh", C_SHA, "cross_c_case"),
]:
    t = tests.get(path)
    ok(t is not None and t.get("pre_fix") == expected_sha, f"{path} uses expected distinct baseline (got {t})")
    if t:
        c = {item["name"]: item for item in t.get("cases", [])}.get(case_name)
        ok(c is not None and c.get("pre_fix") == "fail" and c.get("head") == "pass" and c.get("status") == "verified",
           f"{path} sees complete head test overlay (got {c})")

one_side = tests.get("tests/timeout-one-side.test.js")
ok(one_side is not None, "tests/timeout-one-side.test.js present")
if one_side:
    ok(one_side.get("status") == "file-level", f"one-sided timeout path is file-level (got {one_side.get('status')})")
    ok("timeout" in (one_side.get("reason") or "").lower(), f"one-sided timeout reason names timeout (got {one_side.get('reason')})")
    ok(one_side.get("cases") == [{"name": "tests/timeout-one-side.test.js", "pre_fix": "unresolved", "head": "pass", "status": "inconclusive"}],
       f"one-sided timeout preserves known head result (got {one_side.get('cases')})")

t = tests.get("hooks/tests/sandbox.test.js")
ok(t is not None, "hooks/tests/sandbox.test.js present")
if t:
    ok(bool(t.get("command")) and "node --test" in t.get("command", ""), f"hook command recorded (got {t.get('command')})")
    hc = {c["name"]: c for c in t.get("cases", [])}.get("writes_under_sandbox")
    ok(hc is not None and hc.get("pre_fix") == "pass" and hc.get("head") == "pass" and hc.get("status") == "never-red",
       f"hook exact passing case result (got {hc})")

t = tests.get("tests/slow.test.sh")
ok(t is not None, "tests/slow.test.sh present")
if t:
    ok("timeout" in (t.get("reason") or "").lower(), f"slow.test.sh reason names timeout (got {t.get('reason')})")
    cases = {c["name"]: c for c in t.get("cases", [])}
    slow = cases.get("slow_case")
    ok(slow is not None and slow.get("pre_fix") == "unresolved" and slow.get("head") == "unresolved" and slow.get("status") == "inconclusive",
       f"slow_case exact timeout result (got {slow})")

for t in doc.get("tests", []):
    ok(t["status"] in PATH_STATUSES, f"{t['path']} path status {t['status']} not in closed vocabulary")
    for c in t.get("cases", []):
        ok(c["status"] in CASE_STATUSES, f"{t['path']}::{c['name']} case status {c['status']} not in closed vocabulary")
        ok(c["pre_fix"] in REV_STATUSES, f"{t['path']}::{c['name']} pre_fix {c['pre_fix']} not in closed vocabulary")
        ok(c["head"] in REV_STATUSES, f"{t['path']}::{c['name']} head {c['head']} not in closed vocabulary")

print(f"RESULT {p} {n}")
sys.exit(1 if n else 0)
PYEOF

assert1_out=$(python3 "$TMP/assert1.py" "$OUT1" "$A_SHA" "$C_SHA" "$ROOT_SHA" "$HEAD_SHA" "$MANIFEST1" "$FILES1" 2>&1)
echo "$assert1_out" | grep '^FAIL:' >&2 || true
result1_line=$(echo "$assert1_out" | grep '^RESULT ' || echo "RESULT 0 1")
p1=$(echo "$result1_line" | awk '{print $2}')
f1=$(echo "$result1_line" | awk '{print $3}')
pass=$((pass + p1))
fail=$((fail + f1))

# Cross-layer fixture proof: REAL runner output -> extracted production mapper
# -> U1's real record validator. No stubbed runner or fabricated report here.
WORKFLOW="$REPO/workflows/review-adversarial-first.js"
# A moved or renamed marker must fail by name, not as a mapper ReferenceError.
# Exactly one BEGIN and one END: a lost END would extract to end of file.
extract_block() {
  [ "$(grep -cF "=== $1:BEGIN ===" "$WORKFLOW")" = 1 ] &&
    [ "$(grep -cF "=== $1:END ===" "$WORKFLOW")" = 1 ] &&
    sed -n "/=== $1:BEGIN ===/,/=== $1:END ===/p" "$WORKFLOW" | sed '1d;$d'
}
[ -s "$WORKFLOW" ] && ok || bad "mapper source $WORKFLOW is missing or empty"
judge_block=$(extract_block JUDGE)
rounds_block=$(extract_block ROUNDS)
[ -n "$judge_block" ] && ok || bad "extraction of JUDGE from $WORKFLOW produced nothing -- its BEGIN/END markers may have moved or been renamed"
[ -n "$rounds_block" ] && ok || bad "extraction of ROUNDS from $WORKFLOW produced nothing -- its BEGIN/END markers may have moved or been renamed"
{
  printf '%s\n' "$judge_block"
  printf '%s\n' "$rounds_block"
  cat <<'NODE'
const fs = require('fs')
const [,, input, manifestPath, filesPath, out, priorSha, headSha] = process.argv
const report = JSON.parse(fs.readFileSync(input, 'utf8'))
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const files = fs.readFileSync(filesPath, 'utf8').trim().split('\n')
const selected = manifest.filter((entry) => files.includes(entry.path) && isTestPath(entry.path))
checkRedReport(report, selected, headSha, 'main')
const findings = redFirstFindings(report)
const verified = report.tests.find((t) => t.path === 'tests/suite.test.sh')
  ?.cases.some((c) => c.name === 'red_case' && c.status === 'verified')
const neverRed = findings.find((f) => f.title.includes('::unreached_case'))
if (!verified || !neverRed || neverRed.severity !== 'P1' ||
    neverRed.rationale.indexOf(priorSha) === -1 ||
    report.unchanged.length !== 1) throw new Error('real RED case mapping lost evidence')
const prior = [{ round: 1, rerun: false, comment_id: 1, author_id: 12,
  created_at: '2026-09-24T00:00:00Z', record: {
    schema: 'review-adversarial-first/round/v1', round: 1, head: priorSha,
    patch_id: priorSha, diff_lines: 1, verdict: 'CLEAN', underlying_verdict: 'CLEAN',
    live: { P1: 0, P2: 0, P3: 0 }, findings: [], red_first: { status: 'not-applicable', tests: [] },
    streak: 0, override: false, rerun: false, ledger_errors: [],
  } }]
const red = composeRedFirst(report, findings, true)
const merged = mergeRedFindings([], findings)
const composed = composeRecord(prior, { head_sha: headSha,
  patch_id: headSha, diff_lines: 10, ledger: { ledger_errors: [] } },
  merged, computeVerdict(merged), red, false).record
if (composed.verdict !== 'DIRTY' || composed.red_first.unchanged.length !== 1 ||
    JSON.stringify(composed.red_first.requested) !== JSON.stringify(selected))
  throw new Error('composed verdict did not preserve RED/unchanged/requested inputs')
fs.writeFileSync(out, JSON.stringify(composed))
NODE
} > "$TMP/integrated.js"
if [ -n "$judge_block" ] && [ -n "$rounds_block" ]; then
  node "$TMP/integrated.js" "$OUT1" "$MANIFEST1" "$FILES1" "$TMP/integrated-record.json" "$A_SHA" "$HEAD_SHA"
  integration_rc=$?
  [ "$integration_rc" -eq 0 ] && ok || bad "real runner -> pure mapper failed (exit $integration_rc)"
  python3 - "$REPO" "$TMP/integrated-record.json" <<'PY'
import importlib.util
import json
import pathlib
import sys
spec = importlib.util.spec_from_file_location("review_rounds", pathlib.Path(sys.argv[1]) / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
errors = module.validate_record(json.loads(pathlib.Path(sys.argv[2]).read_text()))
if errors:
    raise SystemExit("FAIL: real fixture RED record rejected by U1: " + str(errors))
PY
  integration_rc=$?
  [ "$integration_rc" -eq 0 ] && ok || bad "U1 rejected the real-runner mapped record (exit $integration_rc)"
fi

# ---------------------------------------------------------------------------
# Usage errors.
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --files "$FILES1" >/dev/null 2>"$TMP/usage1.err"
urc1=$?
[ "$urc1" -eq 2 ] && ok || bad "missing --head should exit 2 (usage), got $urc1"

env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --manifest /dev/null --pre-fix "$A_SHA" --files "$FILES1" \
  >/dev/null 2>"$TMP/usage2.err"
urc2=$?
[ "$urc2" -eq 2 ] && ok || bad "--manifest and --pre-fix together should exit 2 (usage), got $urc2"

env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --files "$FILES1" >/dev/null 2>"$TMP/usage3.err"
urc3=$?
[ "$urc3" -eq 2 ] && ok || bad "neither --manifest nor --pre-fix should exit 2 (usage), got $urc3"

expect_usage() {
  local name=$1
  shift
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$FIXTURE" "$@" >/dev/null 2>"$TMP/usage-extra.err"
  local rc=$?
  [ "$rc" -eq 2 ] && ok || bad "$name should exit 2 (usage), got $rc"
}

expect_usage "dangling --head" --head
expect_usage "dangling --manifest" --head "$HEAD_SHA" --files "$FILES1" --manifest
expect_usage "dangling --pre-fix" --head "$HEAD_SHA" --files "$FILES1" --pre-fix
expect_usage "dangling --files" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files
expect_usage "dangling --base-branch" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES1" --base-branch
expect_usage "dangling --timeout" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES1" --timeout
expect_usage "nonnumeric --timeout" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES1" --timeout soon
expect_usage "zero --timeout" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES1" --timeout 0
expect_usage "negative --timeout" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES1" --timeout -2

# ---------------------------------------------------------------------------
# Run 2: a nonexistent, unfetchable pre-fix SHA -> unverifiable, exit 0, no
# leftover worktree.
MANIFEST2="$TMP/manifest2.json"
cat > "$MANIFEST2" <<'EOF'
[{"path": "tests/suite.test.sh", "pre_fix": "dead000000000000000000000000000000000000"}]
EOF
FILES2="$TMP/files2.txt"
printf 'tests/suite.test.sh\n' > "$FILES2"
OUT2="$TMP/out2.json"
ERR2="$TMP/err2.log"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --manifest "$MANIFEST2" --files "$FILES2" \
  --base-branch main >"$OUT2" 2>"$ERR2"
run2_rc=$?
[ "$run2_rc" -eq 0 ] && ok || bad "run 2 (nonexistent sha) exited $run2_rc; stderr: $(cat "$ERR2")"

python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
tests = {t["path"]: t for t in doc["tests"]}
t = tests.get("tests/suite.test.sh")
assert t is not None, "missing test entry"
status = t["status"]
assert status == "unverifiable", f"expected unverifiable, got {status}"
assert t.get("reason"), "missing reason"
assert doc.get("requested") == [{"path": "tests/suite.test.sh", "pre_fix": "dead000000000000000000000000000000000000"}], doc.get("requested")
' "$OUT2"
py2_rc=$?
[ "$py2_rc" -eq 0 ] && ok || bad "run 2 unverifiable assertions failed (python exit $py2_rc)"

wt_count2=$(git_c worktree list | wc -l | tr -d ' ')
[ "$wt_count2" -eq 1 ] && ok || bad "leftover worktrees after run 2: $(git_c worktree list)"

# ---------------------------------------------------------------------------
# Run 3: a resolvable revision whose detached checkout cannot be created is
# the runner's only operational exit-1 path. The Git wrapper delegates every
# other operation, so this cannot accidentally test revision resolution.
GIT_STUB_DIR="$TMP/git-stub"
mkdir -p "$GIT_STUB_DIR"
cat > "$GIT_STUB_DIR/git" <<'EOF'
#!/usr/bin/env bash
# Runtime-only fixture for KTD7's checkout-failure defect class; delete with
# red-first.test.sh under the same three-month/entry-tier deletion condition.
if [[ " $* " == *" worktree add "* ]]; then
  echo "stubbed worktree add failure" >&2
  exit 73
fi
exec "$RED_FIRST_REAL_GIT" "$@"
EOF
chmod +x "$GIT_STUB_DIR/git"
REAL_GIT_BIN=$(command -v git)
OUT3="$TMP/out3.json"
ERR3="$TMP/err3.log"
env PATH="$GIT_STUB_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES2" \
  --base-branch main >"$OUT3" 2>"$ERR3"
run3_rc=$?
[ "$run3_rc" -eq 1 ] && ok || bad "checkout creation failure should exit 1, got $run3_rc"
grep -qF "could not create detached checkout" "$ERR3" && ok || bad "checkout failure stderr must explain detached checkout failure: $(cat "$ERR3")"
wt_count3=$(git_c worktree list | wc -l | tr -d ' ')
[ "$wt_count3" -eq 1 ] && ok || bad "leftover worktrees after checkout failure: $(git_c worktree list)"

# ---------------------------------------------------------------------------
# Pre-fix execution trust: a baseline outside head's history is code nobody
# reviewed. SIDE forks from the defect commit and changes a source file that
# head's suite sources, so executing that tree leaves TRUST_MARKER behind. A
# logging Git wrapper shows which trees were checked out or fetched.
TRUST_MARKER="$TMP/trust-marker"
git_c checkout -q -b side "$A_SHA"
cat > "$FIXTURE/lib/greet.sh" <<EOF
#!/usr/bin/env bash
printf 'executed\n' > "$TRUST_MARKER"
greet() { echo "wrong"; }
EOF
git_c add lib/greet.sh
commit_q "chore: unreviewed side-branch source"
SIDE_SHA=$(git_c rev-parse HEAD)
git_c checkout -q feature
TRUST_GIT_DIR="$TMP/trust-git"
mkdir -p "$TRUST_GIT_DIR"
cat > "$TRUST_GIT_DIR/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RED_FIRST_GIT_LOG"
exec "$RED_FIRST_REAL_GIT" "$@"
EOF
chmod +x "$TRUST_GIT_DIR/git"
run_trust() {
  local label=$1
  shift
  rm -f "$TRUST_MARKER"
  : > "$TMP/trust-$label.git.log"
  env PATH="$TRUST_GIT_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" RED_FIRST_GIT_LOG="$TMP/trust-$label.git.log" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" "$@" --base-branch main \
    > "$TMP/trust-$label.out" 2> "$TMP/trust-$label.err"
}

# A manifest names only full SHAs; a ref name or abbreviation is refused by
# path before any revision lookup, checkout or suite runs.
for trust_case in "ref:refs/heads/side" "short:${SIDE_SHA:0:12}"; do
  trust_label=${trust_case%%:*}
  trust_rev=${trust_case#*:}
  printf '[{"path":"tests/suite.test.sh","pre_fix":"%s"}]\n' "$trust_rev" > "$TMP/trust-$trust_label.json"
  run_trust "$trust_label" --manifest "$TMP/trust-$trust_label.json" --files "$FILES2"
  trust_rc=$?
  [ "$trust_rc" -eq 2 ] && ok || bad "manifest $trust_label pre_fix $trust_rev must exit 2, got $trust_rc"
  grep -qF "invalid --manifest: pre_fix for tests/suite.test.sh is not a full 40-hex commit SHA" "$TMP/trust-$trust_label.err" \
    && ok || bad "manifest $trust_label pre_fix error must name the path: $(cat "$TMP/trust-$trust_label.err")"
  [ ! -s "$TMP/trust-$trust_label.out" ] && ok || bad "manifest $trust_label pre_fix refusal wrote a report"
  [ ! -e "$TRUST_MARKER" ] && ok || bad "manifest $trust_label pre_fix executed the side-branch tree"
  grep -qF -e "$trust_rev" -e "$SIDE_SHA" -e "worktree add" "$TMP/trust-$trust_label.git.log" \
    && bad "manifest $trust_label pre_fix reached Git before refusal: $(cat "$TMP/trust-$trust_label.git.log")" || ok
done

# A full SHA outside head's history is unverifiable and never checked out, even
# when its blob equals head's; an ancestor in the same run keeps Run 1's result.
TRUST_FILES="$TMP/trust-files.txt"
printf 'tests/suite.test.sh\ntests/identical.test.sh\ntests/regress-suite.test.sh\n' > "$TRUST_FILES"
printf '[{"path":"tests/suite.test.sh","pre_fix":"%s"},{"path":"tests/identical.test.sh","pre_fix":"%s"},{"path":"tests/regress-suite.test.sh","pre_fix":"%s"}]\n' \
  "$SIDE_SHA" "$SIDE_SHA" "$A_SHA" > "$TMP/trust-side.json"
run_trust side --manifest "$TMP/trust-side.json" --files "$TRUST_FILES"
trust_rc=$?
[ "$trust_rc" -eq 0 ] && ok || bad "non-ancestor manifest run exited $trust_rc; stderr: $(cat "$TMP/trust-side.err")"
[ ! -e "$TRUST_MARKER" ] && ok || bad "non-ancestor manifest pre_fix executed the side-branch tree"
grep -F "worktree add" "$TMP/trust-side.git.log" | grep -qF "$SIDE_SHA" \
  && bad "non-ancestor manifest pre_fix was checked out: $(cat "$TMP/trust-side.git.log")" || ok
grep -F "worktree add" "$TMP/trust-side.git.log" | grep -qF "$A_SHA" \
  && ok || bad "ancestor control was never checked out: $(cat "$TMP/trust-side.git.log")"

# The standalone default takes a ref name, but the resolved tree obeys the same
# ancestry rule and is reported by its full SHA.
run_trust default --pre-fix side --files "$FILES2"
trust_rc=$?
[ "$trust_rc" -eq 0 ] && ok || bad "non-ancestor --pre-fix run exited $trust_rc; stderr: $(cat "$TMP/trust-default.err")"
[ ! -e "$TRUST_MARKER" ] && ok || bad "non-ancestor --pre-fix executed the side-branch tree"
grep -F "worktree add" "$TMP/trust-default.git.log" | grep -qF "$SIDE_SHA" \
  && bad "non-ancestor --pre-fix was checked out: $(cat "$TMP/trust-default.git.log")" || ok

# merge-base --is-ancestor's exit 1 is its ordinary "no" answer, not a Git
# failure: a non-ancestor run's stderr carries no generic exited-1 wrapper line
# for it (the injected exit-128 case below still names the failure).
ancestry_wrapper_line() { grep -F -- "--is-ancestor" "$1" | grep -F "exited 1"; }
for noise_label in side default; do
  ancestry_wrapper_line "$TMP/trust-$noise_label.err" \
    && bad "non-ancestor $noise_label run printed a merge-base --is-ancestor exited-1 wrapper line: $(cat "$TMP/trust-$noise_label.err")" || ok
done

# An ancestry check that errors proves nothing either way: fail closed.
ANCESTRY_GIT_DIR="$TMP/ancestry-git"
mkdir -p "$ANCESTRY_GIT_DIR"
cat > "$ANCESTRY_GIT_DIR/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" merge-base --is-ancestor "* ]]; then
  echo "diagnostic: injected ancestry failure" >&2
  exit 128
fi
exec "$RED_FIRST_REAL_GIT" "$@"
EOF
chmod +x "$ANCESTRY_GIT_DIR/git"
env PATH="$ANCESTRY_GIT_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$FILES2" --base-branch main \
  > "$TMP/ancestry-error.out" 2> "$TMP/ancestry-error.err"
ancestry_rc=$?
[ "$ancestry_rc" -eq 2 ] && ok || bad "failed ancestry check should exit 2, got $ancestry_rc"
grep -qF "diagnostic: injected ancestry failure" "$TMP/ancestry-error.err" \
  && grep -qF "cannot check whether pre-fix $A_SHA is an ancestor of head $HEAD_SHA" "$TMP/ancestry-error.err" \
  && ok || bad "failed ancestry check must keep Git's diagnostic and name both revisions: $(cat "$TMP/ancestry-error.err")"
[ ! -s "$TMP/ancestry-error.out" ] && ok || bad "failed ancestry check wrote a report"

cat > "$TMP/assert-trust.py" <<'PYEOF'
import json
import sys

side_report, default_report, run1_report, side_sha, a_sha, head_sha = sys.argv[1:]
checks = []


def check(condition, message):
    checks.append(bool(condition))
    if not condition:
        print(f"FAIL: {message}")


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError) as exc:
        check(False, f"{path} is not a JSON report: {exc}")
        return {"tests": [], "unchanged": []}


def untrusted(doc, path, label):
    item = next((t for t in doc["tests"] if t["path"] == path), None)
    reason = (item or {}).get("reason") or ""
    check(item is not None and item["status"] == "unverifiable" and item["cases"] == [] and item["command"] is None,
          f"{label} {path} must be unverifiable with no cases or command, got {item}")
    check(item is not None and item["pre_fix"] == side_sha, f"{label} {path} must report the resolved side SHA, got {item}")
    # A non-shallow exit 1 keeps exactly this reason (the shallow reason is Contract SH's).
    check(reason == f"pre-fix {side_sha} is not an ancestor of head {head_sha}",
          f"{label} {path} reason must be exactly the non-shallow ancestry reason, got {reason!r}")


side = load(side_report)
untrusted(side, "tests/suite.test.sh", "manifest")
untrusted(side, "tests/identical.test.sh", "manifest")
check(side["unchanged"] == [], f"a non-ancestor baseline must never be listed unchanged, got {side['unchanged']}")
control = next((t for t in side["tests"] if t["path"] == "tests/regress-suite.test.sh"), None)
before = next(t for t in load(run1_report)["tests"] if t["path"] == "tests/regress-suite.test.sh")


def stable(item):
    # The command names this run's scratch checkout; the rest must be identical.
    return {key: value for key, value in item.items() if key != "command"}


check(control is not None and control["pre_fix"] == a_sha and stable(control) == stable(before),
      f"ancestor manifest entry must keep Run 1's result, got {control} vs {before}")
check(control is not None and control["command"].split("/wt-", 1)[-1] == before["command"].split("/wt-", 1)[-1],
      f"ancestor manifest entry must run the same command, got {control}")
default = load(default_report)
untrusted(default, "tests/suite.test.sh", "--pre-fix")
print(f"RESULT {sum(checks)} {len(checks) - sum(checks)}")
sys.exit(not all(checks))
PYEOF
trust_assert=$(python3 "$TMP/assert-trust.py" "$TMP/trust-side.out" "$TMP/trust-default.out" "$OUT1" "$SIDE_SHA" "$A_SHA" "$HEAD_SHA" 2>&1)
printf '%s\n' "$trust_assert" | grep -v '^RESULT ' >&2
trust_result=$(printf '%s\n' "$trust_assert" | grep '^RESULT ' || echo 'RESULT 0 1')
pass=$((pass + $(echo "$trust_result" | awk '{print $2}')))
fail=$((fail + $(echo "$trust_result" | awk '{print $3}')))
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "pre-fix trust runs left scratch worktrees"

# An out-of-range Red-first-base trailer naming a ref (not a SHA) comes back
# unverifiable with that raw value and runs nothing. The workflow records the
# entry, so the real report must map through the production blocks and pass
# U1's validator: a refusal there would make every such round unrecordable.
printf 'chore: out-of-range ref trailer\n\nRed-first-base: tests/suite.test.sh -- refs/heads/side\n' \
  > "$TMP/raw-trailer-msg.txt"
RAW_TRAILER_HEAD=$(git_c -c user.email=t@example.com -c user.name=t commit-tree "$HEAD_SHA^{tree}" \
  -p "$HEAD_SHA" -F "$TMP/raw-trailer-msg.txt")
printf '[{"path":"tests/suite.test.sh","pre_fix":"%s"}]\n' "$A_SHA" > "$TMP/raw-trailer.json"
printf 'tests/suite.test.sh\n' > "$TMP/raw-trailer-files.txt"
rm -f "$TRUST_MARKER"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$SCRIPT" "$FIXTURE" --head "$RAW_TRAILER_HEAD" \
  --manifest "$TMP/raw-trailer.json" --files "$TMP/raw-trailer-files.txt" --base-branch main \
  > "$TMP/raw-trailer.out" 2> "$TMP/raw-trailer.err"
raw_rc=$?
[ "$raw_rc" -eq 0 ] && ok || bad "out-of-range ref trailer run exited $raw_rc; stderr: $(cat "$TMP/raw-trailer.err")"
[ ! -e "$TRUST_MARKER" ] && ok || bad "out-of-range ref trailer executed the side-branch tree"
if [ -n "$judge_block" ] && [ -n "$rounds_block" ]; then
  {
    printf '%s\n' "$judge_block"
    printf '%s\n' "$rounds_block"
    cat <<'NODE'
const fs = require('fs')
const [,, input, manifestPath, out, priorSha, headSha] = process.argv
const report = JSON.parse(fs.readFileSync(input, 'utf8'))
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
checkRedReport(report, manifest, headSha, 'main')
const entry = report.tests.find((t) => t.path === 'tests/suite.test.sh')
if (!entry || entry.status !== 'unverifiable' || entry.pre_fix !== 'refs/heads/side' ||
    entry.command !== null || entry.cases.length || !String(entry.reason).includes('outside merge-base..head')) {
  throw new Error(`out-of-range ref trailer entry is not the raw unexecuted shape: ${JSON.stringify(entry)}`)
}
const findings = redFirstFindings(report)
const prior = [{ round: 1, rerun: false, comment_id: 1, author_id: 12,
  created_at: '2026-09-24T00:00:00Z', record: {
    schema: 'review-adversarial-first/round/v1', round: 1, head: priorSha,
    patch_id: priorSha, diff_lines: 1, verdict: 'CLEAN', underlying_verdict: 'CLEAN',
    live: { P1: 0, P2: 0, P3: 0 }, findings: [], red_first: { status: 'not-applicable', tests: [] },
    streak: 0, override: false, rerun: false, ledger_errors: [],
  } }]
const merged = mergeRedFindings([], findings)
const composed = composeRecord(prior, { head_sha: headSha, patch_id: headSha, diff_lines: 10,
  ledger: { ledger_errors: [] } }, merged, computeVerdict(merged), composeRedFirst(report, findings, true),
  false).record
fs.writeFileSync(out, JSON.stringify(composed))
NODE
  } > "$TMP/raw-trailer-map.js"
  node "$TMP/raw-trailer-map.js" "$TMP/raw-trailer.out" "$TMP/raw-trailer.json" "$TMP/raw-trailer-record.json" \
    "$A_SHA" "$RAW_TRAILER_HEAD"
  raw_map_rc=$?
  [ "$raw_map_rc" -eq 0 ] && ok || bad "real out-of-range ref trailer report -> pure mapper failed (exit $raw_map_rc)"
  python3 - "$REPO" "$TMP/raw-trailer-record.json" <<'PY'
import importlib.util
import json
import pathlib
import sys
spec = importlib.util.spec_from_file_location("review_rounds", pathlib.Path(sys.argv[1]) / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
errors = module.validate_record(json.loads(pathlib.Path(sys.argv[2]).read_text()))
if errors:
    raise SystemExit("FAIL: real out-of-range ref trailer record rejected by U1: " + str(errors))
PY
  raw_u1_rc=$?
  [ "$raw_u1_rc" -eq 0 ] && ok || bad "U1 rejected the real out-of-range ref trailer record (exit $raw_u1_rc)"
fi
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "out-of-range ref trailer run left scratch worktrees"

# Contract U: an in-range Red-first-base trailer naming a revision at which the
# test already equals head names no defect revision. It is unverifiable, never an
# unchanged exclusion, and nothing runs for it. U_HEAD is an unreferenced
# commit-tree child of HEAD_SHA (every earlier section's HEAD_SHA stands); its
# trailer abbreviates HEAD_SHA, which lies in merge-base(main, U_HEAD)..U_HEAD.
# The manifest control (identical.test.sh at A_SHA) keeps today's exclusion.
printf 'chore: trailer names a revision where the test already matches head\n\nRed-first-base: tests/suite.test.sh -- %s\n' \
  "${HEAD_SHA:0:12}" > "$TMP/unchanged-trailer-msg.txt"
U_HEAD=$(git_c -c user.email=t@example.com -c user.name=t commit-tree "$HEAD_SHA^{tree}" \
  -p "$HEAD_SHA" -F "$TMP/unchanged-trailer-msg.txt")
[ "$(git_c rev-parse "$HEAD_SHA:tests/suite.test.sh")" = "$(git_c rev-parse "$U_HEAD:tests/suite.test.sh")" ] \
  && [ "$(git_c rev-parse "$A_SHA:tests/suite.test.sh")" != "$(git_c rev-parse "$U_HEAD:tests/suite.test.sh")" ] \
  && ok || bad "fixture: suite.test.sh must equal head at the trailer revision and differ at the manifest baseline"
printf '[{"path":"tests/suite.test.sh","pre_fix":"%s"},{"path":"tests/identical.test.sh","pre_fix":"%s"}]\n' \
  "$A_SHA" "$A_SHA" > "$TMP/unchanged-trailer.json"
printf 'tests/suite.test.sh\ntests/identical.test.sh\n' > "$TMP/unchanged-trailer-files.txt"
: > "$TMP/unchanged-trailer.git.log"
env PATH="$TRUST_GIT_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" RED_FIRST_GIT_LOG="$TMP/unchanged-trailer.git.log" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$U_HEAD" --manifest "$TMP/unchanged-trailer.json" \
  --files "$TMP/unchanged-trailer-files.txt" --base-branch main \
  > "$TMP/unchanged-trailer.out" 2> "$TMP/unchanged-trailer.err"
u_rc=$?
[ "$u_rc" -eq 0 ] && ok || bad "unchanged-trailer run exited $u_rc; stderr: $(cat "$TMP/unchanged-trailer.err")"
grep -F "worktree add" "$TMP/unchanged-trailer.git.log" | grep -qF "$HEAD_SHA" \
  && bad "unchanged-trailer revision $HEAD_SHA was checked out: $(cat "$TMP/unchanged-trailer.git.log")" || ok
grep -F "worktree add" "$TMP/unchanged-trailer.git.log" | grep -qF "$A_SHA" \
  && ok || bad "manifest control baseline was never checked out: $(cat "$TMP/unchanged-trailer.git.log")"
python3 - "$TMP/unchanged-trailer.out" "$HEAD_SHA" "$A_SHA" "$TMP/unchanged-trailer.json" <<'PY'
import json
import sys
report, trailer_sha, a_sha, manifest = sys.argv[1:]
try:
    doc = json.load(open(report))
except (OSError, ValueError) as exc:
    raise SystemExit(f"FAIL: unchanged-trailer report is not JSON: {exc}")
failures = []
entry = next((t for t in doc["tests"] if t["path"] == "tests/suite.test.sh"), None)
want = {"path": "tests/suite.test.sh", "pre_fix": trailer_sha, "status": "unverifiable", "command": None,
        "reason": f"Red-first-base {trailer_sha} leaves tests/suite.test.sh unchanged at head; "
                  "name the defect revision from before the test changed",
        "exempt": False, "exempt_reason": None, "cases": []}
if entry != want:
    failures.append(f"trailer-unchanged path must be this exact unverifiable entry, got {entry}")
if any(item["path"] == "tests/suite.test.sh" for item in doc["unchanged"]):
    failures.append(f"a Red-first-base trailer must never produce an unchanged exclusion, got {doc['unchanged']}")
if doc["unchanged"] != [{"path": "tests/identical.test.sh", "pre_fix": a_sha}]:
    failures.append(f"manifest baseline must keep its unchanged exclusion, got {doc['unchanged']}")
if any(t["path"] == "tests/identical.test.sh" for t in doc["tests"]):
    failures.append(f"manifest-unchanged path must not run, got {doc['tests']}")
if doc["requested"] != json.load(open(manifest)):
    failures.append(f"requested must keep the manifest baselines, got {doc['requested']}")
for message in failures:
    print(f"FAIL: {message}", file=sys.stderr)
sys.exit(bool(failures))
PY
[ "$?" -eq 0 ] && ok || bad "an in-range Red-first-base trailer leaving the test unchanged must be unverifiable, not unchanged"
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "unchanged-trailer run left scratch worktrees"
# The same trailer spelled as a full SHA takes trailer resolution's exact-match
# branch, not the abbreviation branch above; it must be reported the same way.
printf 'chore: full-SHA trailer names a revision where the test already matches head\n\nRed-first-base: tests/suite.test.sh -- %s\n' \
  "$HEAD_SHA" > "$TMP/unchanged-trailer-full-msg.txt"
U_FULL_HEAD=$(git_c -c user.email=t@example.com -c user.name=t commit-tree "$HEAD_SHA^{tree}" \
  -p "$HEAD_SHA" -F "$TMP/unchanged-trailer-full-msg.txt")
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$U_FULL_HEAD" --manifest "$TMP/unchanged-trailer.json" \
  --files "$TMP/unchanged-trailer-files.txt" --base-branch main \
  > "$TMP/unchanged-trailer-full.out" 2> "$TMP/unchanged-trailer-full.err"
u_full_rc=$?
[ "$u_full_rc" -eq 0 ] && ok || bad "full-SHA unchanged-trailer run exited $u_full_rc; stderr: $(cat "$TMP/unchanged-trailer-full.err")"
python3 - "$TMP/unchanged-trailer-full.out" "$HEAD_SHA" <<'PY'
import json
import sys
report, trailer_sha = sys.argv[1:]
try:
    doc = json.load(open(report))
except (OSError, ValueError) as exc:
    raise SystemExit(f"FAIL: full-SHA unchanged-trailer report is not JSON: {exc}")
entry = next((t for t in doc["tests"] if t["path"] == "tests/suite.test.sh"), None)
want = {"path": "tests/suite.test.sh", "pre_fix": trailer_sha, "status": "unverifiable", "command": None,
        "reason": f"Red-first-base {trailer_sha} leaves tests/suite.test.sh unchanged at head; "
                  "name the defect revision from before the test changed",
        "exempt": False, "exempt_reason": None, "cases": []}
failures = []
if entry != want:
    failures.append(f"full-SHA trailer-unchanged path must be this exact unverifiable entry, got {entry}")
if any(item["path"] == "tests/suite.test.sh" for item in doc["unchanged"]):
    failures.append(f"a full-SHA Red-first-base trailer must never produce an unchanged exclusion, got {doc['unchanged']}")
for message in failures:
    print(f"FAIL: {message}", file=sys.stderr)
sys.exit(bool(failures))
PY
[ "$?" -eq 0 ] && ok || bad "a full-SHA in-range trailer leaving the test unchanged must be unverifiable, not unchanged"
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "full-SHA unchanged-trailer run left scratch worktrees"
# The abbreviated trailer ahead of 4,000 in-range commits. The range is listed
# oldest first, so the resolved revision matches early: an early-exit grep fed
# by a pipe stopped reading long before the writer finished, and under pipefail
# the in-range revision read as out of range. The abbreviation never matches the
# exact check, which reads the whole range first; a full SHA that failed there
# falls through to this same resolved check. Over two 64 KB pipe buffers follow
# the match, so the old failure is deterministic. red-first.sh reads each
# commit's message, so this run costs about 20 ms per commit.
awk -v base="$HEAD_SHA" 'BEGIN {
  for (i = 1; i <= 4000; i++) {
    print "commit refs/heads/red-first-filler"
    print "committer t <t@example.com> 1700000000 +0000"
    print "data 7"
    print "filler"
    if (i == 1) print "from " base
    print ""
  }
}' | git_c fast-import --quiet
L_PARENT=$(git_c rev-parse refs/heads/red-first-filler)
git_c update-ref -d refs/heads/red-first-filler
L_HEAD=$(git_c -c user.email=t@example.com -c user.name=t commit-tree "$HEAD_SHA^{tree}" \
  -p "$L_PARENT" -F "$TMP/unchanged-trailer-msg.txt")
[ "$(git_c rev-list --count "$HEAD_SHA..$L_HEAD")" -eq 4001 ] && ok || bad "fixture: 4,001 commits must follow the trailer revision"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$L_HEAD" --manifest "$TMP/unchanged-trailer.json" \
  --files "$TMP/unchanged-trailer-files.txt" --base-branch main \
  > "$TMP/long-range-trailer.out" 2> "$TMP/long-range-trailer.err"
long_rc=$?
[ "$long_rc" -eq 0 ] && ok || bad "long-range trailer run exited $long_rc; stderr: $(cat "$TMP/long-range-trailer.err")"
python3 - "$TMP/long-range-trailer.out" "$HEAD_SHA" <<'PY'
import json
import sys
report, trailer_sha = sys.argv[1:]
try:
    doc = json.load(open(report))
except (OSError, ValueError) as exc:
    raise SystemExit(f"FAIL: long-range trailer report is not JSON: {exc}")
entry = next((t for t in doc["tests"] if t["path"] == "tests/suite.test.sh"), None)
want = {"path": "tests/suite.test.sh", "pre_fix": trailer_sha, "status": "unverifiable", "command": None,
        "reason": f"Red-first-base {trailer_sha} leaves tests/suite.test.sh unchanged at head; "
                  "name the defect revision from before the test changed",
        "exempt": False, "exempt_reason": None, "cases": []}
if entry != want:
    raise SystemExit(f"FAIL: an in-range trailer before 4,000 commits must stay in range, got {entry}")
PY
[ "$?" -eq 0 ] && ok || bad "an in-range trailer ahead of a long commit range must not read as out of range"
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "long-range trailer run left scratch worktrees"
# The inward vet's P1 end to end: the round at HEAD_SHA recorded a never-red P1 on
# suite.test.sh (its RED run from A_SHA named the case, as a real round's does),
# and U_HEAD's trailer names that head. The real report must keep
# the carried P1 live through the production blocks (the round stays DIRTY, not
# CLEAN) and the composed record must pass U1's validator.
if [ -n "$judge_block" ] && [ -n "$rounds_block" ]; then
  {
    printf '%s\n' "$judge_block"
    printf '%s\n' "$rounds_block"
    cat <<'NODE'
const fs = require('fs')
const [,, input, manifestPath, filesPath, out, priorSha, headSha, flaggedFrom] = process.argv
const report = JSON.parse(fs.readFileSync(input, 'utf8'))
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const files = fs.readFileSync(filesPath, 'utf8').trim().split('\n')
checkRedReport(report, manifest, headSha, 'main')
const title = 'never-red regression test: tests/suite.test.sh::red_case'
const prior = [{ round: 1, rerun: false, comment_id: 1, author_id: 12,
  created_at: '2026-09-24T00:00:00Z', record: {
    schema: 'review-adversarial-first/round/v1', round: 1, head: priorSha,
    patch_id: priorSha, diff_lines: 1, verdict: 'DIRTY', underlying_verdict: 'DIRTY',
    live: { P1: 1, P2: 0, P3: 0 }, findings: [{ file: 'tests/suite.test.sh', severity: 'P1', title }],
    red_first: { status: 'never-red', unchanged: [], tests: [{ path: 'tests/suite.test.sh', pre_fix: flaggedFrom,
      status: 'ran', command: 'bash tests/suite.test.sh', reason: null, exempt: false, exempt_reason: null,
      cases: [{ name: 'red_case', pre_fix: 'pass', head: 'pass', status: 'never-red' }] }] },
    streak: 0, override: false, rerun: false, ledger_errors: [],
  } }]
const carried = carriedNeverRed(prior, report, files, new Set())
if (carried.length !== 1 || carried[0].title !== title || carried[0].severity !== 'P1') {
  throw new Error(`the trailer cleared the carried never-red P1: ${JSON.stringify(carried)}`)
}
const findings = [...redFirstFindings(report), ...carried]
if (!findings.some((f) => f.severity === 'P2' && f.title === 'red-first not verifiable: tests/suite.test.sh')) {
  throw new Error(`the trailer-unchanged path lost its unverifiable P2: ${JSON.stringify(findings)}`)
}
const merged = mergeRedFindings([], findings)
const composed = composeRecord(prior, { head_sha: headSha, patch_id: headSha, diff_lines: 10,
  ledger: { ledger_errors: [] } }, merged, computeVerdict(merged), composeRedFirst(report, findings, true),
  false).record
if (composed.verdict !== 'DIRTY' || composed.live.P1 !== 1 ||
    !composed.findings.some((f) => f.title === title)) {
  throw new Error(`the round must stay DIRTY with the carried P1 live: ${JSON.stringify(composed)}`)
}
fs.writeFileSync(out, JSON.stringify(composed))
NODE
  } > "$TMP/unchanged-trailer-map.js"
  node "$TMP/unchanged-trailer-map.js" "$TMP/unchanged-trailer.out" "$TMP/unchanged-trailer.json" \
    "$TMP/unchanged-trailer-files.txt" "$TMP/unchanged-trailer-record.json" "$HEAD_SHA" "$U_HEAD" "$A_SHA"
  u_map_rc=$?
  [ "$u_map_rc" -eq 0 ] && ok || bad "real unchanged-trailer report -> pure mapper did not keep the carried never-red P1 (exit $u_map_rc)"
  python3 - "$REPO" "$TMP/unchanged-trailer-record.json" <<'PY'
import importlib.util
import json
import pathlib
import sys
spec = importlib.util.spec_from_file_location("review_rounds", pathlib.Path(sys.argv[1]) / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
errors = module.validate_record(json.loads(pathlib.Path(sys.argv[2]).read_text()))
if errors:
    raise SystemExit("FAIL: real unchanged-trailer record rejected by U1: " + str(errors))
PY
  u_u1_rc=$?
  [ "$u_u1_rc" -eq 0 ] && ok || bad "U1 rejected the real unchanged-trailer record (exit $u_u1_rc)"
fi

# Contract C3 end to end (inward re-vet at 01d60f20): a trailer that moves a
# path's baseline past a flagged case leaves that case out of a `ran` entry's
# cases, which cleared its carried never-red P1. V edits only red_case's line on
# top of HEAD_SHA and names HEAD_SHA, where unreached_case already exists; the
# manifest keeps the first-sight baseline A_SHA the case was flagged against.
C3_MODE=$(git_c ls-tree "$HEAD_SHA" tests/suite.test.sh | cut -d' ' -f1)
C3_BLOB=$(git_c show "$HEAD_SHA:tests/suite.test.sh" \
  | sed 's/echo "FAIL: red_case" >&2; fi$/echo "FAIL: red_case" >\&2; fi # reworded/' \
  | git_c hash-object -w --stdin)
env GIT_INDEX_FILE="$TMP/c3.index" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$FIXTURE" read-tree "$HEAD_SHA"
env GIT_INDEX_FILE="$TMP/c3.index" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$FIXTURE" update-index --cacheinfo "$C3_MODE,$C3_BLOB,tests/suite.test.sh"
C3_TREE=$(env GIT_INDEX_FILE="$TMP/c3.index" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$FIXTURE" write-tree)
printf 'test: reword red_case\n\nRed-first-base: tests/suite.test.sh -- %s\n' "$HEAD_SHA" > "$TMP/c3-msg.txt"
C3_HEAD=$(git_c -c user.email=t@example.com -c user.name=t commit-tree "$C3_TREE" -p "$HEAD_SHA" -F "$TMP/c3-msg.txt")
git_c diff "$HEAD_SHA" "$C3_HEAD" -- tests/suite.test.sh > "$TMP/c3.diff"
grep -c '^+[^+]' "$TMP/c3.diff" | grep -qx 1 && grep -q '^+.*FAIL: red_case.*# reworded$' "$TMP/c3.diff" \
  && ok || bad "fixture: C3 head must change only red_case's line: $(cat "$TMP/c3.diff")"
printf '[{"path":"tests/suite.test.sh","pre_fix":"%s"}]\n' "$A_SHA" > "$TMP/c3.json"
printf 'tests/suite.test.sh\n' > "$TMP/c3-files.txt"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FIXTURE" --head "$C3_HEAD" --manifest "$TMP/c3.json" \
  --files "$TMP/c3-files.txt" --base-branch main > "$TMP/c3.out" 2> "$TMP/c3.err"
c3_rc=$?
[ "$c3_rc" -eq 0 ] && ok || bad "C3 trailer run exited $c3_rc; stderr: $(cat "$TMP/c3.err")"
python3 - "$TMP/c3.out" "$HEAD_SHA" "$TMP/c3.json" <<'PY'
import json
import sys
report, trailer_sha, manifest = sys.argv[1:]
try:
    doc = json.load(open(report))
except (OSError, ValueError) as exc:
    raise SystemExit(f"FAIL: C3 report is not JSON: {exc}")
entry = next((t for t in doc["tests"] if t["path"] == "tests/suite.test.sh"), None)
failures = []
if entry is None or entry["pre_fix"] != trailer_sha or entry["status"] != "ran" or \
        [c["name"] for c in entry["cases"]] != ["red_case"]:
    failures.append(f"the trailer must move the baseline and attribute only red_case, got {entry}")
if doc["requested"] != json.load(open(manifest)):
    failures.append(f"requested must keep the first-sight baseline, got {doc['requested']}")
for message in failures:
    print(f"FAIL: {message}", file=sys.stderr)
sys.exit(bool(failures))
PY
[ "$?" -eq 0 ] && ok || bad "a trailer past the flagged case must run the path without naming that case"
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "C3 trailer run left scratch worktrees"
if [ -n "$judge_block" ] && [ -n "$rounds_block" ]; then
  {
    printf '%s\n' "$judge_block"
    printf '%s\n' "$rounds_block"
    cat <<'NODE'
const fs = require('fs')
const [,, input, manifestPath, filesPath, out, firstSha, flaggedSha, headSha] = process.argv
const report = JSON.parse(fs.readFileSync(input, 'utf8'))
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const files = fs.readFileSync(filesPath, 'utf8').trim().split('\n')
checkRedReport(report, manifest, headSha, 'main')
const title = 'never-red regression test: tests/suite.test.sh::unreached_case'
const record = (round, head, extra) => ({ round, rerun: false, comment_id: round, author_id: 12,
  created_at: '2026-09-24T00:00:00Z', record: {
    schema: 'review-adversarial-first/round/v1', round, head, patch_id: head, diff_lines: 1,
    verdict: 'DIRTY', underlying_verdict: 'DIRTY', live: { P1: 1, P2: 0, P3: 0 },
    streak: 0, override: false, rerun: false, ledger_errors: [], ...extra } })
const prior = [
  record(1, firstSha, { findings: [], red_first: { status: 'not-applicable', tests: [] } }),
  record(2, flaggedSha, { findings: [{ file: 'tests/suite.test.sh', severity: 'P1', title }],
    red_first: { status: 'never-red', unchanged: [], tests: [{ path: 'tests/suite.test.sh', pre_fix: firstSha,
      status: 'ran', command: 'bash tests/suite.test.sh', reason: null, exempt: false, exempt_reason: null,
      cases: [{ name: 'red_case', pre_fix: 'fail', head: 'pass', status: 'verified' },
        { name: 'unreached_case', pre_fix: 'pass', head: 'pass', status: 'never-red' }] }] } }),
]
if (sameData(manifest, [{ path: 'tests/suite.test.sh', pre_fix: firstSha }]) !== true ||
    carriedBaseline('tests/suite.test.sh', prior) !== firstSha) {
  throw new Error('fixture: the manifest must request the first-sight baseline')
}
const carried = carriedNeverRed(prior, report, files, new Set())
if (carried.length !== 1 || carried[0].title !== title || carried[0].severity !== 'P1') {
  throw new Error(`the trailer past the case cleared its carried never-red P1: ${JSON.stringify(carried)}`)
}
const findings = [...redFirstFindings(report), ...carried]
const merged = mergeRedFindings([], findings)
const composed = composeRecord(prior, { head_sha: headSha, patch_id: headSha, diff_lines: 10,
  ledger: { ledger_errors: [] } }, merged, computeVerdict(merged), composeRedFirst(report, findings, true),
  false).record
if (composed.verdict !== 'DIRTY' || !composed.findings.some((f) => f.title === title && f.severity === 'P1')) {
  throw new Error(`the round must stay DIRTY with the carried P1 live: ${JSON.stringify(composed)}`)
}
fs.writeFileSync(out, JSON.stringify(composed))
NODE
  } > "$TMP/c3-map.js"
  node "$TMP/c3-map.js" "$TMP/c3.out" "$TMP/c3.json" "$TMP/c3-files.txt" "$TMP/c3-record.json" \
    "$A_SHA" "$HEAD_SHA" "$C3_HEAD"
  c3_map_rc=$?
  [ "$c3_map_rc" -eq 0 ] && ok || bad "real C3 trailer report -> pure mapper did not keep the carried never-red P1 (exit $c3_map_rc)"
  python3 - "$REPO" "$TMP/c3-record.json" <<'PY'
import importlib.util
import json
import pathlib
import sys
spec = importlib.util.spec_from_file_location("review_rounds", pathlib.Path(sys.argv[1]) / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
errors = module.validate_record(json.loads(pathlib.Path(sys.argv[2]).read_text()))
if errors:
    raise SystemExit("FAIL: real C3 trailer record rejected by U1: " + str(errors))
PY
  c3_u1_rc=$?
  [ "$c3_u1_rc" -eq 0 ] && ok || bad "U1 rejected the real C3 trailer record (exit $c3_u1_rc)"
fi

# Contract SH: a shallow graft cuts head's walk, so merge-base --is-ancestor's
# exit 1 there is "unproven", not "no". A real depth-1 clone of the fixture at
# HEAD_SHA plus a depth-1 fetch that makes A_SHA present locally leaves the
# ancestry probe, not resolution, to decide. The graft also hides main's merge
# base, so the (empty) trailer range is based on head itself.
SHALLOW="$TMP/shallow-clone"
git_sh() { env GIT_CONFIG_GLOBAL="$GIT_ENV_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_ENV_NOSYSTEM" git -C "$SHALLOW" "$@"; }
env GIT_CONFIG_GLOBAL="$GIT_ENV_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_ENV_NOSYSTEM" \
  git clone -q --depth 1 "file://$FIXTURE" "$SHALLOW"
git_sh fetch -q --depth 1 origin "$A_SHA"
[ "$(git_sh rev-parse --is-shallow-repository)" = true ] && ok || bad "fixture: the clone must be shallow"
[ "$(git_sh rev-parse HEAD)" = "$HEAD_SHA" ] && ok || bad "fixture: the shallow clone must check out HEAD_SHA"
git_sh cat-file -e "$A_SHA^{commit}" && ok || bad "fixture: A_SHA must be present locally in the shallow clone"
git_c merge-base --is-ancestor "$A_SHA" "$HEAD_SHA" && ok || bad "fixture: A_SHA must be a real ancestor of HEAD_SHA"
git_sh merge-base --is-ancestor "$A_SHA" "$HEAD_SHA"
[ "$?" -eq 1 ] && ok || bad "fixture: the shallow graft must hide A_SHA from HEAD_SHA's walk"
: > "$TMP/shallow.git.log"
env PATH="$TRUST_GIT_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" RED_FIRST_GIT_LOG="$TMP/shallow.git.log" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$SHALLOW" --head "$HEAD_SHA" --pre-fix "$A_SHA" --files "$TMP/unchanged-trailer-files.txt" \
  --base-branch "$HEAD_SHA" > "$TMP/shallow.out" 2> "$TMP/shallow.err"
shallow_rc=$?
[ "$shallow_rc" -eq 0 ] && ok || bad "shallow-clone run exited $shallow_rc; stderr: $(cat "$TMP/shallow.err")"
grep -F "worktree add" "$TMP/shallow.git.log" | grep -qF "$A_SHA" \
  && bad "shallow-unproven baseline was checked out: $(cat "$TMP/shallow.git.log")" || ok
ancestry_wrapper_line "$TMP/shallow.err" \
  && bad "shallow run printed a merge-base --is-ancestor exited-1 wrapper line: $(cat "$TMP/shallow.err")" || ok
python3 - "$TMP/shallow.out" "$A_SHA" "$HEAD_SHA" <<'PY'
import json
import sys
report, a_sha, head_sha = sys.argv[1:]
try:
    doc = json.load(open(report))
except (OSError, ValueError) as exc:
    raise SystemExit(f"FAIL: shallow report is not JSON: {exc}")
failures = []
reason = (f"pre-fix {a_sha} cannot be proven an ancestor of head {head_sha} in a shallow clone; "
          "fetch full history (git fetch --unshallow)")
tests = {t["path"]: t for t in doc["tests"]}
# identical.test.sh's blob equals head's at A_SHA: unproven ancestry still never lists it unchanged.
for path in ("tests/suite.test.sh", "tests/identical.test.sh"):
    want = {"path": path, "pre_fix": a_sha, "status": "unverifiable", "command": None, "reason": reason,
            "exempt": False, "exempt_reason": None, "cases": []}
    if tests.get(path) != want:
        failures.append(f"shallow {path} must be {want}, got {tests.get(path)}")
if doc["unchanged"] != []:
    failures.append(f"a shallow-unproven baseline must never be listed unchanged, got {doc['unchanged']}")
for message in failures:
    print(f"FAIL: {message}", file=sys.stderr)
sys.exit(bool(failures))
PY
[ "$?" -eq 0 ] && ok || bad "shallow-clone ancestry must be unverifiable with the unshallow reason"
[ "$(git_sh worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "shallow-clone run left scratch worktrees"

# A shallow probe that fails, or answers neither true nor false (an old Git
# echoes the unknown rev-parse option), proves nothing: exit 2 by name.
SHALLOW_PROBE_DIR="$TMP/shallow-probe-git"
mkdir -p "$SHALLOW_PROBE_DIR"
cat > "$SHALLOW_PROBE_DIR/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" rev-parse --is-shallow-repository "* ]]; then
  if [ "$SHALLOW_PROBE_MODE" = fail ]; then
    echo "diagnostic: injected shallow probe failure" >&2
    exit 73
  fi
  echo "--is-shallow-repository"
  exit 0
fi
exec "$RED_FIRST_REAL_GIT" "$@"
EOF
chmod +x "$SHALLOW_PROBE_DIR/git"
for probe_mode in fail garbled; do
  rm -f "$TRUST_MARKER"
  env PATH="$SHALLOW_PROBE_DIR:$PATH" RED_FIRST_REAL_GIT="$REAL_GIT_BIN" SHALLOW_PROBE_MODE="$probe_mode" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$FIXTURE" --head "$HEAD_SHA" --pre-fix side --files "$FILES2" --base-branch main \
    > "$TMP/shallow-probe-$probe_mode.out" 2> "$TMP/shallow-probe-$probe_mode.err"
  probe_rc=$?
  [ "$probe_rc" -eq 2 ] && ok || bad "$probe_mode shallow probe should exit 2, got $probe_rc"
  grep -qF "cannot determine whether" "$TMP/shallow-probe-$probe_mode.err" \
    && grep -qF "is a shallow clone" "$TMP/shallow-probe-$probe_mode.err" \
    && ok || bad "$probe_mode shallow probe must be named: $(cat "$TMP/shallow-probe-$probe_mode.err")"
  [ ! -s "$TMP/shallow-probe-$probe_mode.out" ] && ok || bad "$probe_mode shallow probe wrote a report"
  [ ! -e "$TRUST_MARKER" ] && ok || bad "$probe_mode shallow probe executed the side-branch tree"
done
grep -qF "diagnostic: injected shallow probe failure" "$TMP/shallow-probe-fail.err" \
  && ok || bad "failed shallow probe must keep Git's diagnostic: $(cat "$TMP/shallow-probe-fail.err")"
[ "$(git_c worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "shallow probe runs left scratch worktrees"

# ---------------------------------------------------------------------------
# Run 4: real subprocess evidence for duplicate identities, Python's exact
# result vocabulary, Bash checkout cwd/multiword names, and mixed Node
# attribution completeness.
IDENTITY="$TMP/identity-fixture"
mkdir -p "$IDENTITY"
git_i() { env GIT_CONFIG_GLOBAL="$GIT_ENV_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_ENV_NOSYSTEM" git -C "$IDENTITY" "$@"; }
commit_i() { git_i -c user.email=t@example.com -c user.name=t commit -q -m "$1"; }
git_i init -q -b main
printf 'root\n' > "$IDENTITY/README.md"
git_i add README.md
commit_i "chore: root"
git_i checkout -q -b feature
mkdir -p "$IDENTITY/tests" "$IDENTITY/tests"
printf 'bad\n' > "$IDENTITY/source.txt"
printf 'bad\n' > "$IDENTITY/multiword-source.txt"
printf 'bad\n' > "$IDENTITY/node-source.txt"
printf 'bad\n' > "$IDENTITY/mixed-source.txt"
printf 'bad\n' > "$IDENTITY/python-source.txt"
cat > "$IDENTITY/tests/deleted-helper.test.sh" <<'EOF'
#!/usr/bin/env bash
return 0
EOF
cat > "$IDENTITY/tests/test_decorated.py" <<'EOF'
from pathlib import Path
import unittest
STATE = (Path(__file__).resolve().parents[1] / "python-source.txt").read_text().strip()
class Decorated(unittest.TestCase):
    def test_a(self):
        self.assertTrue(True)

    def test_b(self):
        self.assertTrue(True)
EOF
git_i add .
commit_i "feat: plant source defects"
IDENTITY_A=$(git_i rev-parse HEAD)
printf 'second baseline\n' > "$IDENTITY/baseline.txt"
git_i add baseline.txt
commit_i "chore: establish distinct deletion baseline"
IDENTITY_C=$(git_i rev-parse HEAD)

printf 'good\n' > "$IDENTITY/source.txt"
printf 'good\n' > "$IDENTITY/multiword-source.txt"
printf 'good\n' > "$IDENTITY/node-source.txt"
printf 'good\n' > "$IDENTITY/mixed-source.txt"
printf 'good\n' > "$IDENTITY/python-source.txt"
cat > "$IDENTITY/tests/relative-cwd.test.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$(cat ./source.txt)" = "good" ]; then
  echo "PASS: reads relative source"
else
  echo "FAIL: reads relative source" >&2
  exit 1
fi
EOF
cat > "$IDENTITY/tests/multiword.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pass=0
fail=0
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
if [ "$(cat "$SUITE_DIR/../multiword-source.txt")" = "good" ]; then
  pass=$((pass + 1)); echo "PASS: detects the source defect"
else
  bad "detects the source defect"
fi
if [ 1 -eq 1 ]; then
  pass=$((pass + 1)); echo "PASS: multiword control case"
else
  bad "multiword control case"
fi
[ "$fail" -eq 0 ]
EOF
cat > "$IDENTITY/tests/duplicate-node.test.js" <<'EOF'
const { describe, test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
describe('always passing parent', () => {
  test('duplicate leaf', () => assert.ok(true));
});
describe('source dependent parent', () => {
  test('duplicate leaf', () => {
    const state = fs.readFileSync(path.join(__dirname, '../node-source.txt'), 'utf8').trim();
    assert.equal(state, 'good');
  });
});
EOF
cat > "$IDENTITY/tests/mixed-node.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
test('literal source case', () => {
  const state = fs.readFileSync(path.join(__dirname, '../mixed-source.txt'), 'utf8').trim();
  assert.equal(state, 'good');
});
const dynamicName = ['dynamic', 'control', 'case'].join(' ');
test(dynamicName, () => assert.ok(true));
EOF
cat > "$IDENTITY/tests/test_identity.py" <<'EOF'
from pathlib import Path
import unittest

STATE = (Path(__file__).resolve().parents[1] / "python-source.txt").read_text().strip()


class AlwaysPassing(unittest.TestCase):
    def test_duplicate(self):
        self.assertTrue(True)


class SourceDependent(unittest.TestCase):
    def test_duplicate(self):
        self.assertEqual(STATE, "good")


class ErrorUntilSourceFixed(unittest.TestCase):
    def test_source_error(self):
        if STATE != "good":
            raise RuntimeError("source defect prevents execution")
        self.assertEqual(STATE, "good")


class SkipUntilSourceFixed(unittest.TestCase):
    @unittest.skipUnless(STATE == "good", "source defect hides this case")
    def test_source_case(self):
        self.assertEqual(STATE, "good")
EOF
cat > "$IDENTITY/tests/deletion-consumer.test.sh" <<'EOF'
#!/usr/bin/env bash
SUITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -e "$SUITE_DIR/deleted-helper.test.sh" ]; then
  echo "FAIL: deleted helper stays absent" >&2
  exit 1
fi
echo "PASS: deleted helper stays absent"
EOF
cat > "$IDENTITY/tests/test_decorated.py" <<'EOF'
from pathlib import Path
import unittest
STATE = (Path(__file__).resolve().parents[1] / "python-source.txt").read_text().strip()
class Decorated(unittest.TestCase):
    def test_a(self):
        self.assertTrue(True)

    @unittest.skipUnless(STATE == "good", "source hides b")
    def test_b(self):
        self.assertTrue(True)
EOF
cp "$IDENTITY/tests/deletion-consumer.test.sh" "$IDENTITY/tests/deletion-second.test.sh"
git_i rm -q tests/deleted-helper.test.sh
git_i add .
commit_i "fix: add identity and completeness regressions"
IDENTITY_HEAD=$(git_i rev-parse HEAD)

IDENTITY_FILES="$TMP/identity-files.txt"
cat > "$IDENTITY_FILES" <<'EOF'
tests/relative-cwd.test.sh
tests/multiword.test.sh
tests/duplicate-node.test.js
tests/mixed-node.test.js
tests/test_identity.py
tests/test_decorated.py
EOF
IDENTITY_MANIFEST="$TMP/identity-manifest.json"
python3 -c '
import json, sys
files, out, sha = sys.argv[1:]
paths = [line.strip() for line in open(files) if line.strip()]
json.dump([{"path": path, "pre_fix": sha} for path in paths], open(out, "w"))
' "$IDENTITY_FILES" "$IDENTITY_MANIFEST" "$IDENTITY_A"
UV_BIN="$TMP/uv-bin"
mkdir -p "$UV_BIN"
cat > "$UV_BIN/uv" <<'EOF'
#!/usr/bin/env bash
expected=(run --python 3.12 --with pyyaml python3 -m unittest discover -s tests -p 'test_*.py' -v)
[ "$*" = "${expected[*]}" ] || { echo "unexpected uv argv: $*" >&2; exit 99; }
shift 6
exec python3 "$@"
EOF
chmod +x "$UV_BIN/uv"
IDENTITY_OUT="$TMP/identity-out.json"
IDENTITY_ERR="$TMP/identity-err.log"
(
  cd "$IDENTITY" || exit 1
  env PATH="$UV_BIN:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --manifest "$IDENTITY_MANIFEST" \
    --files "$IDENTITY_FILES" --base-branch main --timeout 20 > "$IDENTITY_OUT" 2> "$IDENTITY_ERR"
)
identity_rc=$?
[ "$identity_rc" -eq 0 ] && ok || bad "identity/completeness run exited $identity_rc; stderr: $(cat "$IDENTITY_ERR")"
if [ "$identity_rc" -eq 0 ]; then
  cat > "$TMP/assert-identity.py" <<'PYEOF'
import json
import sys

doc = json.load(open(sys.argv[1]))
tests = {item["path"]: item for item in doc["tests"]}
failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def cases(path):
    return {item["name"]: item for item in tests[path]["cases"]}

relative = cases("tests/relative-cwd.test.sh").get("reads relative source")
check(relative and relative["pre_fix"] == "fail" and relative["head"] == "pass" and relative["status"] == "verified",
      f"Bash runner must use each checkout as cwd, got {relative}")
multiword = cases("tests/multiword.test.sh")
source_case = multiword.get("detects the source defect")
control_case = multiword.get("multiword control case")
check(source_case and source_case["status"] == "verified", f"multiword source case must be verified, got {source_case}")
check(control_case and control_case["status"] == "never-red", f"multiword control must stay never-red, got {control_case}")

python_cases = cases("tests/test_identity.py")
always = python_cases.get("AlwaysPassing.test_duplicate")
source = python_cases.get("SourceDependent.test_duplicate")
skipped = python_cases.get("SkipUntilSourceFixed.test_source_case")
check(always and always["status"] == "never-red", f"first duplicate Python method must stay never-red, got {always}")
check(source and source["status"] == "verified", f"second duplicate Python method must be verified independently, got {source}")
check(skipped and skipped["pre_fix"] == "unresolved" and skipped["head"] == "pass" and skipped["status"] == "inconclusive",
      f"source-dependent skip must not be verified, got {skipped}")

error_case = python_cases.get("ErrorUntilSourceFixed.test_source_error")
check(error_case and error_case["pre_fix"] == "unresolved" and error_case["head"] == "pass" and error_case["status"] == "inconclusive",
      f"source-dependent ERROR must not verify, got {error_case}")
decorated = cases("tests/test_decorated.py")
check(set(decorated) == {"Decorated.test_b"}, f"decorator change must select only test_b, got {decorated}")
check(decorated.get("Decorated.test_b", {}).get("status") == "inconclusive",
      f"decorated source-dependent skip must be inconclusive, got {decorated}")

node_duplicate = tests["tests/duplicate-node.test.js"]
check(node_duplicate["status"] == "file-level", f"duplicate Node leaf path must be file-level, got {node_duplicate}")
check("duplicate" in (node_duplicate.get("reason") or "").lower() or "ambiguous" in (node_duplicate.get("reason") or "").lower(),
      f"duplicate Node reason must name ambiguity, got {node_duplicate.get('reason')}")
check(any(item["status"] == "inconclusive" for item in node_duplicate["cases"]),
      f"duplicate Node attribution must be inconclusive, got {node_duplicate['cases']}")
check(not any(item["name"] == "duplicate leaf" and item["status"] == "verified" for item in node_duplicate["cases"]),
      f"duplicate Node leaf must not borrow sibling evidence, got {node_duplicate['cases']}")

mixed = tests["tests/mixed-node.test.js"]
check(mixed["status"] == "file-level", f"mixed Node path must carry file-level completeness, got {mixed}")
check("dynamic" in (mixed.get("reason") or "").lower() or "incomplete" in (mixed.get("reason") or "").lower(),
      f"mixed Node reason must name dynamic/incomplete attribution, got {mixed.get('reason')}")
check(cases("tests/mixed-node.test.js").get("literal source case", {}).get("status") == "verified",
      f"mixed Node path must retain honest literal evidence, got {mixed['cases']}")
check(any(item["status"] == "inconclusive" for item in mixed["cases"]),
      f"mixed Node path must represent the unaccounted case, got {mixed['cases']}")

for message in failures:
    print(f"FAIL: {message}")
print(f"RESULT {checks - len(failures)} {len(failures)}")
sys.exit(bool(failures))
PYEOF
  identity_assert=$(python3 "$TMP/assert-identity.py" "$IDENTITY_OUT" 2>&1)
  echo "$identity_assert" | grep '^FAIL:' >&2 || true
  identity_result=$(echo "$identity_assert" | grep '^RESULT ' || echo "RESULT 0 17")
  pass=$((pass + $(echo "$identity_result" | awk '{print $2}')))
  fail=$((fail + $(echo "$identity_result" | awk '{print $3}')))
fi

# Run 5: --files is PR-wide while the manifest selects only the current-round
# test. The deleted test-pattern helper must still be deleted in every baseline
# overlay, otherwise it manufactures a false RED for the consumer.
DELETION_FILES="$TMP/deletion-files.txt"
cat > "$DELETION_FILES" <<'EOF'
tests/deletion-consumer.test.sh
tests/deletion-second.test.sh
tests/deleted-helper.test.sh
tests/relative-cwd.test.sh
EOF
DELETION_MANIFEST="$TMP/deletion-manifest.json"
printf '[{"path":"tests/deletion-consumer.test.sh","pre_fix":"%s"},{"path":"tests/deletion-second.test.sh","pre_fix":"%s"}]\n' "$IDENTITY_A" "$IDENTITY_C" > "$DELETION_MANIFEST"
DELETION_OUT="$TMP/deletion-out.json"
DELETION_ERR="$TMP/deletion-err.log"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --manifest "$DELETION_MANIFEST" \
  --files "$DELETION_FILES" --base-branch main > "$DELETION_OUT" 2> "$DELETION_ERR"
deletion_rc=$?
[ "$deletion_rc" -eq 0 ] && ok || bad "subset-manifest/deletion run exited $deletion_rc; stderr: $(cat "$DELETION_ERR")"
if [ "$deletion_rc" -eq 0 ]; then
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert [item["path"] for item in doc["tests"]] == ["tests/deletion-consumer.test.sh", "tests/deletion-second.test.sh"], doc["tests"]
assert {item["pre_fix"] for item in doc["tests"]} == set(sys.argv[2:]), doc["tests"]
assert doc.get("requested") == [{"path": "tests/deletion-consumer.test.sh", "pre_fix": sys.argv[2]},
                                 {"path": "tests/deletion-second.test.sh", "pre_fix": sys.argv[3]}], doc.get("requested")
for item in doc["tests"]:
    case = item["cases"][0]
    assert case == {"name": "deleted helper stays absent", "pre_fix": "pass", "head": "pass", "status": "never-red"}, case
assert "tests/deleted-helper.test.sh" in doc["overlay"], doc["overlay"]
' "$DELETION_OUT" "$IDENTITY_A" "$IDENTITY_C"
  deletion_assert_rc=$?
  [ "$deletion_assert_rc" -eq 0 ] && ok || bad "subset manifest or deletion overlay assertions failed"
fi

# Run 6: containment under tracked symlinks. All external targets live under
# this suite's scratch directory, making any escaped write observable without
# touching host state.
SAFE="$TMP/symlink-fixture"
EXT_PARENT="$TMP/external-parent"
EXT_SOURCE="$TMP/external-source"
EXT_ANCESTOR="$TMP/external-ancestor"
mkdir -p "$SAFE" "$EXT_PARENT" "$EXT_SOURCE" "$EXT_ANCESTOR"
printf 'PARENT_SENTINEL\n' > "$EXT_PARENT/parent-safe.test.sh"
printf 'SOURCE_SENTINEL\n' > "$EXT_SOURCE/sentinel"
printf 'ANCESTOR_SENTINEL\n' > "$EXT_ANCESTOR/sentinel"
cat > "$EXT_SOURCE/source-link.test.sh" <<EOF
#!/usr/bin/env bash
printf 'SOURCE_EXECUTED\\n' > "$EXT_SOURCE/sentinel"
echo "PASS: external source link"
EOF
cat > "$EXT_ANCESTOR/deleted.test.sh" <<EOF
#!/usr/bin/env bash
printf 'ANCESTOR_EXECUTED\\n' > "$EXT_ANCESTOR/sentinel"
echo "PASS: external ancestor link"
EOF
git_s() { env GIT_CONFIG_GLOBAL="$GIT_ENV_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_ENV_NOSYSTEM" git -C "$SAFE" "$@"; }
commit_s() { git_s -c user.email=t@example.com -c user.name=t commit -q -m "$1"; }
git_s init -q -b main
printf 'root\n' > "$SAFE/README.md"
git_s add README.md
commit_s "chore: root"
git_s checkout -q -b feature
mkdir -p "$SAFE/tests" "$SAFE/source-parent"
ln -s "$EXT_PARENT" "$SAFE/linked-tests"
cat > "$SAFE/tests/source-link.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: baseline source link"
EOF
cat > "$SAFE/source-parent/deleted.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: baseline ancestor path"
EOF
git_s add .
commit_s "feat: baseline symlink shapes"
SAFE_A=$(git_s rev-parse HEAD)
rm "$SAFE/linked-tests"
mkdir -p "$SAFE/linked-tests"
cat > "$SAFE/linked-tests/parent-safe.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: parent symlink case"
EOF
rm "$SAFE/tests/source-link.test.sh"
ln -s "$EXT_SOURCE/source-link.test.sh" "$SAFE/tests/source-link.test.sh"
rm -r "$SAFE/source-parent"
ln -s "$EXT_ANCESTOR" "$SAFE/source-parent"
git_s add -A
commit_s "fix: replace symlink shapes"
SAFE_HEAD=$(git_s rev-parse HEAD)

run_safe_case() {
  local label=$1 path=$2 out=$3 err=$4
  local files="$TMP/safe-$label-files.txt"
  local manifest="$TMP/safe-$label-manifest.json"
  printf '%s\n' "$path" > "$files"
  printf '[{"path":"%s","pre_fix":"%s"}]\n' "$path" "$SAFE_A" > "$manifest"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$SAFE" --head "$SAFE_HEAD" --manifest "$manifest" --files "$files" \
    --base-branch main > "$out" 2> "$err"
}

SAFE_PARENT_OUT="$TMP/safe-parent.json"
SAFE_PARENT_ERR="$TMP/safe-parent.err"
run_safe_case parent linked-tests/parent-safe.test.sh "$SAFE_PARENT_OUT" "$SAFE_PARENT_ERR"
safe_parent_rc=$?
[ "$safe_parent_rc" -eq 0 ] && ok || bad "target-parent symlink run exited $safe_parent_rc; stderr: $(cat "$SAFE_PARENT_ERR")"
[ "$(cat "$EXT_PARENT/parent-safe.test.sh")" = "PARENT_SENTINEL" ] && ok || bad "overlay followed baseline parent symlink and overwrote external sentinel"
if [ "$safe_parent_rc" -eq 0 ]; then
  python3 -c '
import json, sys
item = json.load(open(sys.argv[1]))["tests"][0]
case = item["cases"][0]
assert case["name"] == "parent symlink case" and case["status"] == "never-red", item
' "$SAFE_PARENT_OUT"
  [ "$?" -eq 0 ] && ok || bad "safe replacement of baseline parent symlink was not verified"
fi

printf 'SOURCE_SENTINEL\n' > "$EXT_SOURCE/sentinel"
SAFE_SOURCE_OUT="$TMP/safe-source.json"
SAFE_SOURCE_ERR="$TMP/safe-source.err"
run_safe_case source tests/source-link.test.sh "$SAFE_SOURCE_OUT" "$SAFE_SOURCE_ERR"
safe_source_rc=$?
[ "$safe_source_rc" -eq 0 ] && ok || bad "source symlink run exited $safe_source_rc; stderr: $(cat "$SAFE_SOURCE_ERR")"
[ "$(cat "$EXT_SOURCE/sentinel")" = "SOURCE_SENTINEL" ] && ok || bad "runner executed through a source test symlink"
if [ "$safe_source_rc" -eq 0 ]; then
  python3 -c '
import json, sys
item = json.load(open(sys.argv[1]))["tests"][0]
assert item["status"] == "unverifiable" and "symlink" in item["reason"].lower(), item
' "$SAFE_SOURCE_OUT"
  [ "$?" -eq 0 ] && ok || bad "source test symlink must be named unverifiable"
fi

printf 'ANCESTOR_SENTINEL\n' > "$EXT_ANCESTOR/sentinel"
SAFE_ANCESTOR_OUT="$TMP/safe-ancestor.json"
SAFE_ANCESTOR_ERR="$TMP/safe-ancestor.err"
run_safe_case ancestor source-parent/deleted.test.sh "$SAFE_ANCESTOR_OUT" "$SAFE_ANCESTOR_ERR"
safe_ancestor_rc=$?
[ "$safe_ancestor_rc" -eq 0 ] && ok || bad "source ancestor symlink run exited $safe_ancestor_rc; stderr: $(cat "$SAFE_ANCESTOR_ERR")"
[ "$(cat "$EXT_ANCESTOR/sentinel")" = "ANCESTOR_SENTINEL" ] && ok || bad "runner followed a source symlink ancestor during deletion overlay"
if [ "$safe_ancestor_rc" -eq 0 ]; then
  python3 -c '
import json, sys
item = json.load(open(sys.argv[1]))["tests"][0]
assert item["status"] == "unverifiable" and "symlink" in item["reason"].lower(), item
' "$SAFE_ANCESTOR_OUT"
  [ "$?" -eq 0 ] && ok || bad "source symlink ancestor must be named unverifiable"
fi

# Non-canonical paths and malformed manifests are usage errors with named
# diagnostics, never Python tracebacks or Bash associative-array failures.
printf 'TRAVERSAL_SENTINEL\n' > "$TMP/escape.test.sh"
TRAVERSAL_FILES="$TMP/traversal-files.txt"
printf '../escape.test.sh\n' > "$TRAVERSAL_FILES"
TRAVERSAL_MANIFEST="$TMP/traversal-manifest.json"
printf '[{"path":"../escape.test.sh","pre_fix":"%s"}]\n' "$SAFE_A" > "$TRAVERSAL_MANIFEST"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$SAFE" --head "$SAFE_HEAD" --manifest "$TRAVERSAL_MANIFEST" \
  --files "$TRAVERSAL_FILES" --base-branch main > "$TMP/traversal.out" 2> "$TMP/traversal.err"
traversal_rc=$?
[ "$traversal_rc" -eq 2 ] && ok || bad "traversal path should exit 2, got $traversal_rc"
grep -qF "non-canonical --files path: ../escape.test.sh" "$TMP/traversal.err" \
  && ok || bad "traversal usage error must name the rejected path: $(cat "$TMP/traversal.err")"
[ "$(cat "$TMP/escape.test.sh")" = "TRAVERSAL_SENTINEL" ] && ok || bad "traversal validation wrote outside scratch checkout"

MALFORMED_MANIFEST="$TMP/malformed-manifest.json"
printf '{not json}\n' > "$MALFORMED_MANIFEST"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --manifest "$MALFORMED_MANIFEST" \
  --files "$IDENTITY_FILES" --base-branch main > "$TMP/malformed.out" 2> "$TMP/malformed.err"
malformed_rc=$?
[ "$malformed_rc" -eq 2 ] && ok || bad "malformed manifest should exit 2, got $malformed_rc"
grep -qF "invalid --manifest" "$TMP/malformed.err" \
  && ok || bad "malformed manifest error must be named: $(cat "$TMP/malformed.err")"

EMPTY_REV_MANIFEST="$TMP/empty-revision-manifest.json"
printf '[{"path":"tests/relative-cwd.test.sh","pre_fix":""}]\n' > "$EMPTY_REV_MANIFEST"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --manifest "$EMPTY_REV_MANIFEST" \
  --files "$IDENTITY_FILES" --base-branch main > "$TMP/empty-revision.out" 2> "$TMP/empty-revision.err"
empty_revision_rc=$?
[ "$empty_revision_rc" -eq 2 ] && ok || bad "empty manifest revision should exit 2, got $empty_revision_rc"
grep -qF "empty pre_fix revision" "$TMP/empty-revision.err" \
  && ok || bad "empty revision error must be named: $(cat "$TMP/empty-revision.err")"

EMPTY_HEAD_MANIFEST="$TMP/empty-head-manifest.json"
printf '[]\n' > "$EMPTY_HEAD_MANIFEST"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "" --manifest "$EMPTY_HEAD_MANIFEST" \
  --files "$IDENTITY_FILES" --base-branch main > "$TMP/empty-head.out" 2> "$TMP/empty-head.err"
empty_head_rc=$?
[ "$empty_head_rc" -eq 2 ] && ok || bad "empty head revision should exit 2, got $empty_head_rc"
grep -qF "empty --head revision" "$TMP/empty-head.err" \
  && ok || bad "empty head error must be named: $(cat "$TMP/empty-head.err")"


# Git failures preserve original stderr and do not masquerade as an empty report.
GIT_BIN="$TMP/git-failure-bin"
mkdir -p "$GIT_BIN"
REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$GIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${1:-}" = "-C" ]; then shift 2; fi
if [ "${1:-}" = "$FAILURE_OP" ]; then
  echo "diagnostic: injected $FAILURE_OP refused" >&2
  exit 73
fi
exec "$REAL_GIT" "${args[@]}"
EOF
chmod +x "$GIT_BIN/git"
for failure_op in rev-parse diff show; do
  env PATH="$GIT_BIN:$PATH" FAILURE_OP="$failure_op" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --pre-fix "$IDENTITY_A" \
    --files "$IDENTITY_FILES" --base-branch main > "$TMP/git-$failure_op.out" 2> "$TMP/git-$failure_op.err"
  failure_rc=$?
  grep -qF "diagnostic: injected $failure_op refused" "$TMP/git-$failure_op.err" \
    && ok || bad "git $failure_op diagnostic lost: $(cat "$TMP/git-$failure_op.err")"
  if [ "$failure_rc" -eq 0 ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["tests"] and all(t["status"] == "unverifiable" for t in d["tests"]), d' "$TMP/git-$failure_op.out"
    [ "$?" -eq 0 ] && ok || bad "git $failure_op failure became successful evidence"
  else
    [ ! -s "$TMP/git-$failure_op.out" ] && ok || bad "git $failure_op failure polluted JSON stdout"
  fi
done
git_i remote add origin "$TMP/nonexistent-origin"
env PATH="$GIT_BIN:$PATH" FAILURE_OP=fetch GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "$IDENTITY_HEAD" --pre-fix 9999999999999999999999999999999999999999 \
  --files "$IDENTITY_FILES" --base-branch main > "$TMP/git-fetch.out" 2> "$TMP/git-fetch.err"
fetch_rc=$?
[ "$fetch_rc" -eq 0 ] && ok || bad "unfetchable baseline should produce JSON, got $fetch_rc"
grep -qF 'diagnostic: injected fetch refused' "$TMP/git-fetch.err" && ok || bad "fetch diagnostic lost"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["tests"] and all(t["status"] == "unverifiable" for t in d["tests"]), d' "$TMP/git-fetch.out"
[ "$?" -eq 0 ] && ok || bad "fetch failure did not mark candidates unverifiable"

for invalid_path in /absolute.test.sh ./relative.test.sh tests/../escape.test.sh tests//empty.test.sh tests/./dot.test.sh; do
  printf '%s\n' "$invalid_path" > "$TMP/invalid-path-files"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$SAFE" --head "$SAFE_HEAD" --pre-fix "$SAFE_A" \
    --files "$TMP/invalid-path-files" > "$TMP/invalid-path.out" 2> "$TMP/invalid-path.err"
  invalid_rc=$?
  [ "$invalid_rc" -eq 2 ] && ok || bad "noncanonical path $invalid_path exited $invalid_rc instead of 2"
done
for invalid_manifest in '{}' '[null]' '[{"path":"tests/a.test.sh"}]' '[{"path":"tests/a.test.sh","pre_fix":42}]' '[{"path":"../escape.test.sh","pre_fix":"HEAD"}]'; do
  printf '%s\n' "$invalid_manifest" > "$TMP/invalid-manifest.json"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$SCRIPT" "$SAFE" --head "$SAFE_HEAD" --manifest "$TMP/invalid-manifest.json" \
    --files "$IDENTITY_FILES" > "$TMP/invalid-manifest.out" 2> "$TMP/invalid-manifest.err"
  invalid_rc=$?
  [ "$invalid_rc" -eq 2 ] && ok || bad "malformed manifest shape $invalid_manifest exited $invalid_rc instead of 2"
done


# Deletion must unlink only the scratch ancestor, never its external referent.
DELETE_HEAD="$TMP/delete-head"
DELETE_TARGET="$TMP/delete-target"
DELETE_EXTERNAL="$TMP/delete-external"
mkdir -p "$DELETE_HEAD" "$DELETE_TARGET" "$DELETE_EXTERNAL"
printf 'DELETE_SENTINEL\n' > "$DELETE_EXTERNAL/deleted.test.sh"
ln -s "$DELETE_EXTERNAL" "$DELETE_TARGET/tests"
delete_reason=$(overlay_path "$DELETE_HEAD" "$DELETE_TARGET" tests/deleted.test.sh)
delete_rc=$?
[ "$delete_rc" -eq 0 ] && ok || bad "contained deletion failed: $delete_reason"
[ "$(cat "$DELETE_EXTERNAL/deleted.test.sh")" = "DELETE_SENTINEL" ] && ok || bad "deletion followed baseline ancestor outside checkout"
[ ! -L "$DELETE_TARGET/tests" ] && ok || bad "deletion left an external ancestor reachable"

# Exact Node leaf matching must not borrow a longer sibling's status or choose
# the first of duplicate runtime IDs (including dynamically generated names).
printf 'ok 1 - duplicate\nnot ok 2 - duplicate\n' > "$TMP/duplicate-tap.log"
node_duplicate_status=$(node_case_status duplicate "$TMP/duplicate-tap.log")
[ "$node_duplicate_status" = unresolved ] && ok || bad "duplicate runtime TAP identities must be unresolved, got $node_duplicate_status"
printf 'not ok 1 - shorter sibling\nok 2 - shorter\n' > "$TMP/prefix-tap.log"
node_prefix_status=$(node_case_status shorter "$TMP/prefix-tap.log")
[ "$node_prefix_status" = pass ] && ok || bad "Node name prefix borrowed sibling result: $node_prefix_status"

# Interpolated Bash names remain incomplete while useful literal evidence stays.
cat > "$IDENTITY/tests/mixed-bash.test.sh" <<'EOF'
#!/usr/bin/env bash
label="dynamic bash control"
echo "PASS: $label"
if [ "$(cat ./source.txt)" = good ]; then
  echo "PASS: literal bash source case"
else
  echo "FAIL: literal bash source case" >&2
  exit 1
fi
EOF
git_i add tests/mixed-bash.test.sh
commit_i "fix: add mixed Bash attribution regression"
MIXED_BASH_HEAD=$(git_i rev-parse HEAD)
printf 'tests/mixed-bash.test.sh\n' > "$TMP/mixed-bash-files"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$IDENTITY" --head "$MIXED_BASH_HEAD" --pre-fix "$IDENTITY_A" \
  --files "$TMP/mixed-bash-files" > "$TMP/mixed-bash.json" 2> "$TMP/mixed-bash.err"
mixed_bash_rc=$?
[ "$mixed_bash_rc" -eq 0 ] && ok || bad "mixed Bash runner failed: $(cat "$TMP/mixed-bash.err")"
python3 -c '
import json,sys
t=json.load(open(sys.argv[1]))["tests"][0]
assert t["status"] == "file-level" and "incomplete" in t["reason"], t
cases={c["name"]:c for c in t["cases"]}
assert cases["literal bash source case"]["status"] == "verified", t
assert any(c["status"] == "inconclusive" for c in t["cases"]), t
' "$TMP/mixed-bash.json"
[ "$?" -eq 0 ] && ok || bad "mixed Bash attribution lost literal evidence or hid the interpolated case"


# Final U2 review regressions: real processes and full runner invocations.
FOLLOW="$TMP/followup"
mkdir -p "$FOLLOW/tests"
git_f() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$FOLLOW" "$@"; }
commit_f() { git_f -c user.email=t@example.com -c user.name=t commit -q -F -; }
git_f init -q -b main
printf 'root\n' > "$FOLLOW/root"
git_f add root
commit_f <<'EOF'
chore: root
EOF
git_f checkout -q -b feature
printf 'bad\n' > "$FOLLOW/state"
cat > "$FOLLOW/tests/parameters.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const values = [1];
for (const value of values) {
  test(`parameter ${value}`, () => {
    if (value === 1) assert.equal(fs.readFileSync('../state', 'utf8').trim(), 'good');
    else assert.ok(true);
  });
}
EOF
# The literal declaration's approximate span covers the setup edit below it;
# its genuine RED must not hide the new, never-red dynamic parameter case.
python3 - "$FOLLOW/tests/parameters.test.js" <<'EOF'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.with_name('neighbor-parameters.test.js').write_text(p.read_text().replace(
    'const values = [1];',
    "test('existing', () => assert.equal(fs.readFileSync('../state', 'utf8').trim(), 'good'));\nconst values = [1];",
))
EOF
git_f add state tests/parameters.test.js tests/neighbor-parameters.test.js
commit_f <<'EOF'
feat: plant unchanged failing parameter

Red-first-base: tests/assertion.test.js -- 0000000000000000000000000000000000000000
Red-first-exempt: tests/assertion.test.js -- stale exemption
Red-first-exempt: tests/malformed.test.sh -- old valid reason
EOF
FOLLOW_A=$(git_f rev-parse HEAD)
printf 'good\n' > "$FOLLOW/state"
python3 - "$FOLLOW/tests/parameters.test.js" "$FOLLOW/tests/neighbor-parameters.test.js" <<'EOF'
from pathlib import Path
import sys
for path in sys.argv[1:]:
    p = Path(path)
    p.write_text(p.read_text().replace('const values = [1];', 'const values = [1, 2];'))
EOF
cat > "$FOLLOW/tests/hook.test.js" <<'EOF'
const { test, before } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
before(() => assert.equal(fs.readFileSync('../state', 'utf8').trim(), 'good', 'setup assertion before body'));
test('hook body never executed', () => assert.ok(true));
EOF
cat > "$FOLLOW/tests/assertion.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
test('real assertion control', () => assert.equal(fs.readFileSync('../state', 'utf8').trim(), 'good'));
test('passing named control', () => assert.ok(true));
test('ordinary error', () => { if (fs.readFileSync('../state', 'utf8').trim() !== 'good') throw new Error('not an assertion'); });
EOF
for malformed in malformed empty whitespace; do
  printf '#!/usr/bin/env bash\necho "PASS: trailer control"\n' > "$FOLLOW/tests/$malformed.test.sh"
done
# Both branches must retain suite stderr before their scratch logs disappear.
cat > "$FOLLOW/tests/file-diagnostic.test.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$(cat state)" != good ]; then
  echo "file-level setup helper missing" >&2
  exit 3
fi
EOF
cat > "$FOLLOW/tests/named-diagnostic.test.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$(cat state)" != good ]; then
  python3 -c 'import sys; print("setup-prefix " * 400, file=sys.stderr)'
  echo "named setup helper missing" >&2
  exit 3
fi
echo "PASS: diagnostic control"
EOF
git_f add state tests
# Newest trailer replaces old per type/path; multipart reason is not truncated.
{
  printf 'fix: add review regressions\n\n'
  printf 'Red-first-base: tests/assertion.test.js -- %s\n' "$FOLLOW_A"
  printf 'Red-first-exempt: tests/assertion.test.js -- current reason -- with details\n'
  printf 'Red-first-exempt: tests/malformed.test.sh\n'
  printf 'Red-first-exempt: tests/empty.test.sh -- \n'
  printf 'Red-first-exempt: tests/whitespace.test.sh --    \n'
} | commit_f
FOLLOW_HEAD=$(git_f rev-parse HEAD)
git_f diff --name-only "$FOLLOW_A" "$FOLLOW_HEAD" > "$TMP/follow-files"
parameter_metadata=$(extract_changed_case_metadata "$FOLLOW" "$FOLLOW_A" "$FOLLOW_HEAD" tests/parameters.test.js plain-node)
python3 -c 'import json,sys; m=json.loads(sys.argv[1]); assert m["names"] == [] and m["incomplete"], m' "$parameter_metadata"
[ "$?" -eq 0 ] && ok || bad "changed parameter setup above unchanged dynamic declaration must be incomplete"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  bash "$SCRIPT" "$FOLLOW" --head "$FOLLOW_HEAD" --pre-fix "$FOLLOW_A" --files "$TMP/follow-files" \
  > "$TMP/follow.json" 2> "$TMP/follow.err"
[ "$?" -eq 0 ] && ok || bad "followup runner failed: $(cat "$TMP/follow.err")"
cat > "$TMP/assert-follow.py" <<'EOF'
import json
from pathlib import Path
import sys
report, stderr, baseline, head, original, original_err, original_baseline = sys.argv[1:]
doc = json.load(open(report))
tests = {t['path']: t for t in doc['tests']}
checks = []
def check(condition, message):
    checks.append(bool(condition))
    if not condition:
        print('FAIL: ' + message)
def case(path, name):
    return next((c for c in tests[path]['cases'] if c['name'] == name), {})
check({(item['path'], item['pre_fix']) for item in doc.get('requested', [])} ==
      {(path, baseline) for path in tests} | {(item['path'], baseline) for item in doc['unchanged']},
      'default --pre-fix must preserve the raw requested baseline for every candidate')
hook = case('tests/hook.test.js', 'hook body never executed')
check(hook.get('pre_fix') == 'unresolved' and hook.get('head') == 'pass' and hook.get('status') == 'inconclusive', f'before-hook assertion cannot prove RED: {hook}')
assertion = case('tests/assertion.test.js', 'real assertion control')
check(assertion.get('status') == 'verified', f'genuine assertion must verify: {assertion}')
check(case('tests/assertion.test.js', 'passing named control').get('status') == 'never-red', 'normal named control remains never-red')
check(case('tests/assertion.test.js', 'ordinary error').get('status') == 'inconclusive', 'ordinary Node error is not assertion RED')
parameter = tests['tests/parameters.test.js']
check(parameter['status'] == 'file-level' and parameter['cases'][0]['status'] == 'inconclusive', f'new passing parameter must not borrow unchanged RED: {parameter}')
check('incomplete' in (parameter.get('reason') or ''), 'changed parameter range explains incomplete attribution')
neighbor = tests['tests/neighbor-parameters.test.js']
check(neighbor['status'] == 'file-level', f'neighboring literal cannot make dynamic setup attribution complete: {neighbor}')
check('dynamic' in (neighbor.get('reason') or '') and 'incomplete' in (neighbor.get('reason') or ''), f'neighboring literal needs explicit dynamic attribution limitation: {neighbor}')
check(case('tests/neighbor-parameters.test.js', 'existing') == {'name': 'existing', 'pre_fix': 'fail', 'head': 'pass', 'status': 'verified'}, f'known neighboring literal keeps attributable RED: {neighbor}')
check(case('tests/neighbor-parameters.test.js', 'tests/neighbor-parameters.test.js') == {'name': 'tests/neighbor-parameters.test.js', 'pre_fix': 'unresolved', 'head': 'unresolved', 'status': 'inconclusive'}, f'new never-red parameter needs an inconclusive remainder beside the verified literal: {neighbor}')
check(tests['tests/assertion.test.js']['pre_fix'] == baseline, 'new valid baseline must supersede old invalid baseline')
reason = 'current reason -- with details'
check(tests['tests/assertion.test.js']['exempt_reason'] == reason and {'path': 'tests/assertion.test.js', 'reason': reason} in doc['exempt'], 'new exemption keeps entire reason after first separator')
for suffix in ('malformed', 'empty', 'whitespace'):
    path = f'tests/{suffix}.test.sh'
    check(tests[path]['exempt'] is False and not any(e['path'] == path for e in doc['exempt']), f'{suffix} trailer grants no exemption (latest malformed clears older reason)')
    check(path in Path(stderr).read_text() and 'malformed Red-first-exempt' in Path(stderr).read_text(), f'{suffix} trailer must be diagnosed')
for kind in ('named', 'file'):
    path = f'tests/{kind}-diagnostic.test.sh'
    text = Path(stderr).read_text()
    check(path in text and baseline in text and f'{kind}' in text and 'setup helper missing' in text, f'{kind} suite stderr needs path/revision labels')
t = tests['tests/named-diagnostic.test.sh']
check('named setup helper missing' in (t.get('reason') or '') and 'exit 3' in t['reason'] and baseline in t['reason'] and len(t['reason']) < 2300 and Path(stderr).read_text().count('setup-prefix') == 400, 'inconclusive reason is bounded while full stderr, exit and revision survive')
orig = next(t for t in json.load(open(original))['tests'] if t['path'] == 'tests/helper-suite.test.sh')
check('helper.sh missing' in (orig.get('reason') or '') and 'exit 3' in orig['reason'] and original_baseline in orig['reason'], 'existing missing-helper fixture retains actionable reason')
check('helper.sh missing' in Path(original_err).read_text(), 'existing missing-helper stderr survives cleanup')
# Every command checkout has been disposed; JSON parsing above rejects stdout noise.
check(all(not Path(t['command'].split()[1]).exists() for t in tests.values() if (t.get('command') or '').startswith('bash ')), 'runner checkouts removed after diagnostic retention')
print(f'RESULT {sum(checks)} {len(checks) - sum(checks)}')
sys.exit(not all(checks))
EOF
follow_assert=$(python3 "$TMP/assert-follow.py" "$TMP/follow.json" "$TMP/follow.err" "$FOLLOW_A" "$FOLLOW_HEAD" "$OUT1" "$ERR1" "$A_SHA" 2>&1)
printf '%s\n' "$follow_assert" | grep '^FAIL:' >&2 || true
follow_result=$(printf '%s\n' "$follow_assert" | grep '^RESULT ' || echo 'RESULT 0 1')
pass=$((pass + $(echo "$follow_result" | awk '{print $2}')))
fail=$((fail + $(echo "$follow_result" | awk '{print $3}')))
[ "$(git_f worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "followup left scratch worktrees"

# Exercise real spec AND TAP failure diagnostics. Reporters are selected only in
# these parser probes; the full runner above still executes exact node --test.
cat > "$TMP/status-node.test.js" <<'EOF'
const { test, before } = require('node:test');
const assert = require('node:assert/strict');
before(() => assert.fail('setup is not a test-body assertion'));
test('before case', () => assert.ok(true));
EOF
cat > "$TMP/control-node.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert/strict');
test('assertion case', () => assert.equal(1, 2));
test('error case', () => { throw new Error('ordinary error'); });
test('cancel case', { signal: AbortSignal.timeout(30) }, () => new Promise(() => {}));
test('skip case', { skip: true }, () => assert.fail());
EOF
for reporter in spec tap; do
  timeout --kill-after=2s 5s node --test --test-reporter="$reporter" "$TMP/status-node.test.js" > "$TMP/node-hook-$reporter.log" 2>&1
  [ "$?" -eq 1 ] && ok || bad "real $reporter hook fixture must exit 1"
  [ "$(node_case_status 'before case' "$TMP/node-hook-$reporter.log")" = unresolved ] && ok || bad "$reporter hook failure must not be assertion RED"
  timeout --kill-after=2s 5s node --test --test-reporter="$reporter" "$TMP/control-node.test.js" > "$TMP/node-control-$reporter.log" 2>&1
  [ "$?" -eq 1 ] && ok || bad "real $reporter assertion fixture must exit 1"
  [ "$(node_case_status 'assertion case' "$TMP/node-control-$reporter.log")" = fail ] && ok || bad "$reporter genuine assertion must remain RED"
  for name in 'error case' 'cancel case' 'skip case'; do
    [ "$(node_case_status "$name" "$TMP/node-control-$reporter.log")" = unresolved ] && ok || bad "$reporter $name must be unresolved"
  done
done

# TERM-ignoring children are independently self-bounded at 8s, and an outer
# watchdog bounds the runner too. The runner's 0.4s + 2s kill grace must win.
cat > "$FOLLOW/tests/ignore-named.test.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$(cat state)" != good ]; then
  trap '' TERM
  python3 -c 'import os,signal,sys,time; print("ignoring TERM pid", os.getpid(), file=sys.stderr, flush=True); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(8)'
fi
echo 'PASS: ignores TERM'
EOF
cat > "$FOLLOW/tests/ignore-file.test.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$(cat state)" != good ]; then
  trap '' TERM
  python3 -c 'import os,signal,sys,time; print("ignoring TERM pid", os.getpid(), file=sys.stderr, flush=True); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(8)'
fi
EOF
git_f add tests/ignore-named.test.sh tests/ignore-file.test.sh
commit_f <<'EOF'
fix: add bounded termination regressions
EOF
TIMEOUT_HEAD=$(git_f rev-parse HEAD)
printf 'tests/ignore-named.test.sh\ntests/ignore-file.test.sh\n' > "$TMP/ignore-files"
python3 - "$SCRIPT" "$FOLLOW" "$TIMEOUT_HEAD" "$FOLLOW_A" "$TMP" <<'EOF'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
script, repo, head, baseline, tmp = sys.argv[1:]
env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
start = time.monotonic()
with open(tmp + '/ignore.json', 'w') as out, open(tmp + '/ignore.err', 'w') as err:
    result = subprocess.run(['bash', script, repo, '--head', head, '--pre-fix', baseline, '--files', tmp + '/ignore-files', '--timeout', '0.4'], env=env, stdout=out, stderr=err, timeout=35)
elapsed = time.monotonic() - start
assert result.returncode == 0, Path(tmp + '/ignore.err').read_text()
doc = json.load(open(tmp + '/ignore.json'))
assert elapsed < 12, f'TERM-ignoring suites escaped finite kill grace: {elapsed:.2f}s'
assert len(doc['tests']) == 2, doc
for t in doc['tests']:
    assert t['cases'][0]['pre_fix'] == 'unresolved' and t['cases'][0]['head'] == 'pass' and t['cases'][0]['status'] == 'inconclusive', t
    assert 'timeout' in (t['reason'] or '') and '137' in t['reason'] and baseline in t['reason'], t
    assert not Path(t['command'].split()[1]).exists(), t
pids = set(re.findall(r'ignoring TERM pid (\d+)', Path(tmp + '/ignore.err').read_text()))
assert len(pids) == 2, pids
for pid in pids:
    proc = Path('/proc') / pid / 'stat'
    assert not proc.exists() or proc.read_text().split(') ', 1)[1].startswith('Z '), f'child still running: {pid}'
print(f'bounded termination: {elapsed:.2f}s; named and file-level exit 137; checkouts removed; 2 children stopped')
EOF
[ "$?" -eq 0 ] && ok || bad "TERM-ignoring suites must be unresolved within kill grace with scratch removed"
[ "$(git_f worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && ok || bad "timeout left registered scratch worktrees"
for forced_family in bash-suite plain-node hook-node python-unittest; do
  case "$forced_family" in
    bash-suite) forced_name=named_case; forced_module=ignored; forced_log="$TMP/bash-positive.out" ;;
    plain-node|hook-node) forced_name='assertion case'; forced_module=ignored; forced_log="$TMP/node-control-tap.log" ;;
    python-unittest) forced_name=First.test_fail; forced_module=test_status; forced_log="$TMP/python-status.log" ;;
  esac
  [ "$(case_verdict "$forced_family" 137 "$forced_name" "$forced_module" "$forced_log" "$TMP/bash-nonzero.err")" = unresolved ] && ok || bad "$forced_family forced timeout must not retain case evidence"
done

if [ "$fail" -eq 0 ]; then
  echo "ok - red-first: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL - red-first: $fail of $((pass + fail)) assertions failed"
fi
[ "$fail" -eq 0 ]
