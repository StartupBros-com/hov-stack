#!/usr/bin/env bash
# Tests for scripts/lib/floor-assert.sh and its two call sites in
# scripts/dcg-update.sh (dotfiles#394).
#
# THE DEFECT: check() returns "<cases> <failures>". An emptied or truncated
# expect-*.txt made it return "0 0" -- zero cases, zero failures -- and both
# call sites read fails==0 as a pass. The CONTRACT_ONLY path printed
# "contract OK (0 cases)" and exited 0; the promote path promoted a new guard
# binary having verified nothing, unattended, from dcg-auto-update.timer.
#
# Hermetic: HOME is redirected to a scratch dir holding a stub `dcg` and its
# required `minisign` command. The former answers --version and
# `test -c <config> <cmdline>`; the corpus is generated per-case. No network, no
# real dcg, no writes outside $TMP. The stub decides BLOCKED vs ALLOWED from a
# marker in the command text, so a fixture line's expected verdict is visible in
# the fixture itself.
#
# COVERAGE NOTE, stated plainly: cases (a)-(d) exercise the CONTRACT_ONLY path
# end-to-end, which is the path harness-weekly runs. The promote path shares
# the identical floor() call but reaching it requires a real download+extract,
# so case (e) asserts structurally that its guard precedes the symlink swap.
# That one assertion is source-order, not behavioral, and is marked as such.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
SCRIPT="$HERE/dcg-update.sh"
LIB="$HERE/lib/floor-assert.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
[ -f "$LIB" ]    || { echo "FAIL: lib not found at $LIB" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }
bash -n "$LIB"    || { echo "FAIL: $LIB does not parse" >&2; exit 1; }

# ---- fixture home: stub dcg on the path dcg-update.sh hardcodes under $HOME.
FAKEHOME="$TMP/home"
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEHOME/.local/bin" "$FAKEHOME/.config/dcg" "$FAKEBIN"
cat >"$FAKEHOME/.local/bin/dcg" <<'STUB'
#!/usr/bin/env bash
# Stub dcg. `--version` for the banner; `test -c <config> <cmdline>` returns a
# verdict chosen by a marker in the command text so fixtures are self-describing.
case "${1:-}" in
  --version) echo "dcg 0.0.0-test"; exit 0 ;;
esac
cmd="${!#}"
case "$cmd" in
  *BLOCKME*) echo "Result: BLOCKED" ;;
  *)         echo "Result: ALLOWED" ;;
esac
exit 0
STUB
cat >"$FAKEBIN/minisign" <<'STUB'
#!/usr/bin/env bash
# CONTRACT_ONLY must not reach signature verification; it only requires that the
# new mandatory verifier exists before exercising the floor logic.
exit 0
STUB
chmod +x "$FAKEHOME/.local/bin/dcg" "$FAKEBIN/minisign"
: >"$FAKEHOME/.config/dcg/config.toml"

# ---- a runnable copy of the script, so $HERE/dcg-contract is a fixture we own.
# The script resolves CONTRACT and its lib relative to its own location, and
# neither is env-overridable; copying is how we point it at a corpus we control
# without adding a test-only knob to production code.
RUN="$TMP/run"
mkdir -p "$RUN/lib" "$RUN/dcg-contract"
cp "$SCRIPT" "$RUN/dcg-update.sh"
cp "$LIB" "$RUN/lib/floor-assert.sh"

# corpus <n_blocked> <n_allowed>: regenerate the fixture corpus.
corpus() {
  local nb="$1" na="$2" i
  { echo "# generated fixture"; for ((i = 0; i < nb; i++)); do echo "rm -rf /BLOCKME/$i"; done; } \
    >"$RUN/dcg-contract/expect-blocked.txt"
  { echo "# generated fixture"; for ((i = 0; i < na; i++)); do echo "ls -la /safe/$i"; done; } \
    >"$RUN/dcg-contract/expect-allowed.txt"
}

# run_contract: CONTRACT_ONLY against the fixture. Sets $OUT and $RC as globals
# rather than echoing -- a command substitution would run it in a subshell and
# strand $OUT there.
OUT="" RC=0
run_contract() {
  OUT=$(PATH="$FAKEBIN:$PATH" HOME="$FAKEHOME" DCG_CONFIG="$FAKEHOME/.config/dcg/config.toml" \
        CONTRACT_ONLY=1 bash "$RUN/dcg-update.sh" 2>&1)
  RC=$?
}

# ---- (a) healthy corpus above the floor: still passes, no false positive.
# 120 cases, comfortably over the production default of 50. Note the units:
# these are CASES, not lines — the first cut of this floor was set from the
# corpus line count (137) and would have failed every healthy nightly run,
# because check() skips blanks and comments and the real corpus is 65 cases.
corpus 60 60
run_contract; rc=$RC
[ "$rc" = "0" ] || bad "(a) healthy 120-case corpus should exit 0, got $rc: $OUT"
[ "$rc" = "0" ] && ok
case "$OUT" in
  *"contract OK (120 cases)"*) ok ;;
  *) bad "(a) expected 'contract OK (120 cases)', got: $OUT" ;;
esac
case "$OUT" in
  *WARN*) bad "(a) healthy corpus must not WARN: $OUT" ;;
  *) ok ;;
esac

# ---- (b) THE BUG: emptied corpus. Was "contract OK (0 cases)" + exit 0.
corpus 0 0
run_contract; rc=$RC
[ "$rc" = "1" ] || bad "(b) emptied corpus must exit 1, got $rc: $OUT"
[ "$rc" = "1" ] && ok
case "$OUT" in
  *"contract OK"*) bad "(b) emptied corpus must NOT report contract OK: $OUT" ;;
  *) ok ;;
esac
case "$OUT" in
  *WARN*"examined 0 item(s)"*) ok ;;
  *) bad "(b) expected a WARN naming 0 items examined, got: $OUT" ;;
esac

# ---- (c) it is a FLOOR, not merely a zero-check: a truncated corpus (the
# realistic half-resolved-merge shape) is also refused.
corpus 10 10
run_contract; rc=$RC
[ "$rc" = "1" ] || bad "(c) truncated 20-case corpus must exit 1, got $rc: $OUT"
[ "$rc" = "1" ] && ok
case "$OUT" in
  *"examined 20 item(s), expected at least 50"*) ok ;;
  *) bad "(c) expected the floor to name 20 vs 50, got: $OUT" ;;
esac

# ---- (d) one file emptied, the other intact but small: total under the floor.
corpus 0 30
run_contract; rc=$RC
[ "$rc" = "1" ] || bad "(d) single emptied file must exit 1, got $rc: $OUT"
[ "$rc" = "1" ] && ok

# ---- (e) STRUCTURAL (not behavioral, see header): the promote path's floor
# must precede the symlink swap, or a short corpus could still promote.
floor_ln=$(grep -n 'floor "\$total"' "$SCRIPT" | head -1 | cut -d: -f1)
promote_ln=$(grep -n 'ln -sfn "\$cand" "\$BIN"' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$floor_ln" ] && [ -n "$promote_ln" ] && [ "$floor_ln" -lt "$promote_ln" ]; then
  ok
else
  bad "(e) promote path: floor (line ${floor_ln:-none}) must precede promote (line ${promote_ln:-none})"
fi

# ---- (f) floor() unit behaviour, including the degenerate inputs that are the
# whole point: an unset/non-numeric count is a silent degradation, not a pass.
# shellcheck source=/dev/null
. "$LIB"
floor 5 3 unit  >/dev/null && ok || bad "(f) floor 5 3 should pass"
floor 3 3 unit  >/dev/null && ok || bad "(f) floor 3 3 (boundary) should pass"
floor 2 3 unit  >/dev/null && bad "(f) floor 2 3 should fail" || ok
floor 0 1 unit  >/dev/null && bad "(f) floor 0 1 should fail" || ok
floor "" 1 unit >/dev/null && bad "(f) empty count should fail, not pass" || ok
floor abc 1 u   >/dev/null && bad "(f) non-numeric count should fail, not pass" || ok

if [ "$fail" -ne 0 ]; then
  echo "FAILED — floor-assert: $pass passed, $fail failed" >&2
  exit 1
fi
echo "ok — floor-assert: $pass/$pass assertions passed"
