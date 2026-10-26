#!/usr/bin/env bash
# Hermetic regression tests for the pinned resend-cli installer: a PATH-local
# fake pnpm, every destination below /tmp, never the network, the real pnpm
# store or ~/.local/lib.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER=$REPO/scripts/resend-cli-install.sh
PIN=$(sed -n 's/^PIN_VERSION=//p' "$INSTALLER" | head -1)
TMP=$(mktemp -d /tmp/resend-cli-install-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); }
bad() { failures=$((failures + 1)); echo "FAIL: $*" >&2; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

[ -n "$PIN" ] || { echo "FAIL: could not read PIN_VERSION from the installer" >&2; exit 1; }

# ── fake pnpm ────────────────────────────────────────────────────────────────
# Honors --config.global-dir/--config.global-bin-dir and the exact resend-cli@V
# spec; lays out pnpm's <global-dir>/5/node_modules/<pkg>/package.json plus a
# bin shim. FAKE_DIR/fail makes the add fail (echoing a fake registry token so
# the masking is observable); FAKE_DIR/report overrides the shim's --version;
# FAKE_DIR/hold freezes the add, after its log line and before it touches the
# prefix, until FAKE_DIR/release exists (at most 30 s), so a second installer
# can be started while this one is mid-install.
mkdir -p "$TMP/stub"
cat >"$TMP/stub/pnpm" <<'FAKE'
#!/usr/bin/env bash
F=${FAKE_DIR:?}
gdir="" bdir="" spec=""
for a in "$@"; do
  case "$a" in
    --config.global-dir=*) gdir=${a#*=} ;;
    --config.global-bin-dir=*) bdir=${a#*=} ;;
    resend-cli@*) spec=$a ;;
  esac
done
printf 'ARGS %s\tPATH %s\tCWD %s\n' "$*" "$PATH" "$PWD" >>"$F/log"
[ "${1:-}" = add ] || { echo "fake pnpm: unsupported ${1:-}" >&2; exit 2; }
[ -n "$spec" ] && [ -n "$gdir" ] && [ -n "$bdir" ] || { echo "fake pnpm: missing spec or prefix" >&2; exit 2; }
if [ -f "$F/hold" ]; then
  i=0
  while [ ! -f "$F/release" ]; do
    i=$((i + 1)); [ "$i" -le 600 ] || { echo "fake pnpm: hold never released" >&2; exit 3; }
    sleep 0.05
  done
fi
if [ -f "$F/fail" ]; then
  echo " GET https://ci:s3cr3t@registry.example.com/x Authorization: Bearer tok_ABC123 //registry.example.com/:_authToken=npm_XYZ789" >&2
  echo " ERR_PNPM_TARBALL_INTEGRITY  fake integrity failure" >&2
  exit 1
fi
if [ -e /proc/$$/fd/9 ]; then echo "FD9 open" >>"$F/log"; else echo "FD9 closed" >>"$F/log"; fi
v=${spec#resend-cli@}
pkg="$gdir/5/node_modules/resend-cli"
mkdir -p "$pkg" "$bdir"
printf '{"name":"resend-cli","version":"%s","bin":{"resend":"./dist/cli.cjs"}}\n' "$v" >"$pkg/package.json"
report="resend-cli v$v"
[ -f "$F/report" ] && report=$(cat "$F/report")
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$XDG_CONFIG_HOME" >"%s/shim-xdg"\nenv >"%s/shim-env"\nif [ -e /proc/$$/fd/9 ]; then echo open; else echo closed; fi >"%s/shim-fd9"\ncase "${1:-}" in --version) echo "%s" ;; *) exit 64 ;; esac\n' \
  "$F" "$F" "$F" "$report" >"$bdir/resend"
chmod +x "$bdir/resend"
FAKE
chmod +x "$TMP/stub/pnpm"

run_installer() {
  # run_installer <root> <fake-dir> <mode> -> stdout+stderr in $out, status in $status
  out=$(RESEND_CLI_INSTALL_TEST_MODE=1 RESEND_CLI_INSTALL_TEST_ROOT="$1" FAKE_DIR="$2" \
    PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" "$3" 2>&1)
  status=$?
}
run_installer_bg() {
  # run_installer_bg <root> <fake-dir> <mode> <out-file> -> pid in $bg_pid; bounded
  # so an install lock that never releases fails the test instead of hanging it.
  RESEND_CLI_INSTALL_TEST_MODE=1 RESEND_CLI_INSTALL_TEST_ROOT="$1" FAKE_DIR="$2" \
    PATH="$TMP/stub:$PATH" HOME="$TMP/home" timeout 60 bash "$INSTALLER" "$3" >"$4" 2>&1 &
  bg_pid=$!
}
wait_for() {
  # wait_for <path> [ticks]: poll for <path> every 50 ms, default 10 s; 1 on timeout
  local i=0 n=${2:-200}
  while [ ! -e "$1" ]; do
    i=$((i + 1)); [ "$i" -le "$n" ] || return 1
    sleep 0.05
  done
}
mkdir -p "$TMP/home"

# ── 1. fresh install: exact pnpm argv, bin dir on PATH for the add, converged ──
ROOT=$TMP/root1; FAKE=$TMP/fake1; mkdir -p "$FAKE"
PREFIX=$ROOT/lib/resend-cli/v$PIN
run_installer "$ROOT" "$FAKE" check
[ "$status" -ne 0 ] && has "$out" "not converged" && ok || bad "check on an empty root should fail: $out"
run_installer "$ROOT" "$FAKE" install
[ "$status" -eq 0 ] && has "$out" "installed resend-cli v$PIN at $PREFIX" && ok || bad "fresh install failed ($status): $out"
[ "$(grep -c '^ARGS' "$FAKE/log")" = 1 ] && ok || bad "pnpm should run exactly once on a fresh install"
line=$(grep '^ARGS' "$FAKE/log")
has "$line" "ARGS add -g --config.global-dir=$PREFIX --config.global-bin-dir=$PREFIX/bin resend-cli@$PIN	" && ok \
  || bad "pnpm argv is not the exact pinned global add: $line"
has "$line" "PATH $PREFIX/bin:" && ok || bad "the global bin dir must lead PATH during the add: $line"
case "$line" in *"CWD $PREFIX"*|*"CWD $REPO"*) bad "pnpm must run from a neutral scratch cwd: $line" ;; *) ok ;; esac
[ -x "$PREFIX/bin/resend" ] && ok || bad "no executable shim at $PREFIX/bin/resend"
run_installer "$ROOT" "$FAKE" check
[ "$status" -eq 0 ] && has "$out" "converged at $PREFIX" && ok || bad "check after install should pass: $out"
# The smoke --version ran the shim from an isolated config home with telemetry off.
xdg=$(cat "$FAKE/shim-xdg" 2>/dev/null)
case "$xdg" in /tmp/resend-cli-install.*/xdg) ok ;; *) bad "smoke run did not isolate XDG_CONFIG_HOME: '$xdg'" ;; esac
grep -q '^DO_NOT_TRACK=1$' "$FAKE/shim-env" && grep -q '^RESEND_NO_UPDATE_NOTIFIER=1$' "$FAKE/shim-env" \
  && grep -q '^CI=1$' "$FAKE/shim-env" && ok || bad "smoke run did not switch telemetry, the update check and prompts off"
grep -q '^RESEND_API_KEY=' "$FAKE/shim-env" && bad "smoke run must never carry a credential" || ok
grep -q '^FAKE_DIR=' "$FAKE/shim-env" && bad "smoke run must not inherit the parent environment" || ok

# ── 2. idempotent: a converged prefix runs pnpm zero more times ───────────────
run_installer "$ROOT" "$FAKE" install
[ "$status" -eq 0 ] && has "$out" "already installed" && ok || bad "second install should be a no-op: $out"
[ "$(grep -c '^ARGS' "$FAKE/log")" = 1 ] && ok || bad "second install must not run pnpm again"

# ── 3. pnpm failure: nothing installed, log masked ───────────────────────────
ROOT=$TMP/root3; FAKE=$TMP/fake3; mkdir -p "$FAKE"; : >"$FAKE/fail"
PREFIX=$ROOT/lib/resend-cli/v$PIN
run_installer "$ROOT" "$FAKE" install
[ "$status" -eq 1 ] && has "$out" "nothing was installed" && ok || bad "pnpm failure should exit 1 with nothing installed: $out"
[ ! -e "$PREFIX" ] && ok || bad "a failed install must leave no prefix behind"
has "$out" "ERR_PNPM_TARBALL_INTEGRITY" && ok || bad "the pnpm log tail should be shown on failure"
for secret in s3cr3t tok_ABC123 npm_XYZ789; do
  has "$out" "$secret" && bad "pnpm log leaked $secret" || ok
done

# ── 4. version drift: a shim reporting another version is removed ────────────
ROOT=$TMP/root4; FAKE=$TMP/fake4; mkdir -p "$FAKE"; echo "resend-cli v0.0.1" >"$FAKE/report"
PREFIX=$ROOT/lib/resend-cli/v$PIN
run_installer "$ROOT" "$FAKE" install
[ "$status" -eq 1 ] && has "$out" "did not report v$PIN" && ok || bad "a drifted --version should fail the install: $out"
[ ! -e "$PREFIX" ] && ok || bad "a drifted install must be removed"

# ── 5. broken existing prefix is set aside, then reinstalled ─────────────────
ROOT=$TMP/root5; FAKE=$TMP/fake5; mkdir -p "$FAKE"
PREFIX=$ROOT/lib/resend-cli/v$PIN
mkdir -p "$PREFIX/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$PREFIX/bin/resend"; chmod +x "$PREFIX/bin/resend"
echo marker >"$PREFIX/marker"
run_installer "$ROOT" "$FAKE" install
[ "$status" -eq 0 ] && has "$out" "set aside unconverged $PREFIX" && has "$out" "installed resend-cli v$PIN" && ok \
  || bad "broken prefix should be set aside and reinstalled: $out"
[ "$(find "$ROOT/lib/tool-backups/resend-cli" -name marker | wc -l)" = 1 ] && ok || bad "the broken prefix was not kept under tool-backups"
[ ! -e "$PREFIX/marker" ] && [ -x "$PREFIX/bin/resend" ] && ok || bad "the reinstalled prefix still carries the broken tree"

# ── 6. refusals: test root outside /tmp, bad mode, missing pnpm ──────────────
# /var/tmp is a real directory that is not below /tmp; the refusal fires before any mkdir.
run_installer "/var/tmp/resend-cli-install-test-outside.$$" "$FAKE" install
[ "$status" -eq 1 ] && has "$out" "must stay below /tmp" && ok || bad "a test root outside /tmp must be refused: $out"
[ ! -e "/var/tmp/resend-cli-install-test-outside.$$" ] && ok || bad "the refused root was created anyway"
out=$(bash "$INSTALLER" frobnicate 2>&1); status=$?
[ "$status" -eq 64 ] && has "$out" "usage:" && ok || bad "an unknown mode should exit 64: $out"
ROOT=$TMP/root6; FAKE=$TMP/fake6; mkdir -p "$FAKE"
out=$(RESEND_CLI_INSTALL_TEST_MODE=1 RESEND_CLI_INSTALL_TEST_ROOT="$ROOT" FAKE_DIR="$FAKE" \
  RESEND_CLI_INSTALL_PNPM=/nonexistent/pnpm HOME="$TMP/home" bash "$INSTALLER" install 2>&1); status=$?
[ "$status" -eq 1 ] && has "$out" "pnpm is required" && ok || bad "a missing pnpm should be a typed failure: $out"
[ ! -e "$ROOT/lib/resend-cli/v$PIN" ] && ok || bad "a missing pnpm must not create the prefix"

# ── 7. the wrapper and the installer share one pin ───────────────────────────
WRAPPER_PIN=$(sed -n 's/^VENDOR_PIN = "\(.*\)"$/\1/p' "$REPO/bin/resend_cli.py")
[ "$WRAPPER_PIN" = "$PIN" ] && ok || bad "wrapper pin $WRAPPER_PIN != installer pin $PIN"

# ── 8. pro-gate round 1 P1 (dotfiles#1742): concurrent installs cannot remove
#      each other's install ──────────────────────────────────────────────────
# B starts first and freezes inside a pnpm add that is going to fail; A starts
# while B is frozen. Unlocked, A sees the unconverged prefix, installs, reports
# success, and B's failure cleanup then rm -rf's A's install. Locked, A waits
# for B, B's cleanup removes only its own empty prefix, and A installs into a
# prefix nobody else is touching.
ROOT=$TMP/root8; PREFIX=$ROOT/lib/resend-cli/v$PIN
FAKE_B=$TMP/fake8b; mkdir -p "$FAKE_B"; : >"$FAKE_B/hold"; : >"$FAKE_B/fail"
FAKE_A=$TMP/fake8a; mkdir -p "$FAKE_A"
run_installer_bg "$ROOT" "$FAKE_B" install "$TMP/out8b"; pid_b=$bg_pid
wait_for "$FAKE_B/log" && ok || bad "installer B never reached its pnpm add"
run_installer_bg "$ROOT" "$FAKE_A" install "$TMP/out8a"; pid_a=$bg_pid
if wait_for "$FAKE_A/log" 40; then
  bad "installer A ran pnpm against the prefix while B's install was in progress"
else
  ok
fi
: >"$FAKE_B/release"
wait "$pid_b"; status_b=$?
wait "$pid_a"; status_a=$?
out_b=$(cat "$TMP/out8b"); out_a=$(cat "$TMP/out8a")
[ "$status_b" -eq 1 ] && has "$out_b" "nothing was installed" && ok || bad "B's failed add should exit 1 ($status_b): $out_b"
[ "$status_a" -eq 0 ] && has "$out_a" "installed resend-cli v$PIN at $PREFIX" && ok || bad "A should install after B ($status_a): $out_a"
# Both fd probes come from A's locked run; the check below re-runs the shim
# without any lock fd and would overwrite shim-fd9.
grep -q '^FD9 closed$' "$FAKE_A/log" && ok || bad "the install lock fd must not reach the pnpm child"
[ "$(cat "$FAKE_A/shim-fd9" 2>/dev/null)" = closed ] && ok || bad "the install lock fd must not reach the vendor --version smoke"
run_installer "$ROOT" "$FAKE_A" check
[ "$status" -eq 0 ] && [ -x "$PREFIX/bin/resend" ] && ok || bad "B's cleanup removed A's install; check: $out"
[ "$(grep -c '^ARGS' "$FAKE_A/log")" = 1 ] && [ "$(grep -c '^ARGS' "$FAKE_B/log")" = 1 ] && ok || bad "each installer should run pnpm exactly once"
[ -f "$ROOT/lib/resend-cli/.install.lock" ] && [ ! -e "$PREFIX/.install.lock" ] && ok || bad "the lock must sit beside the versioned prefix, not inside it"

# ── 9. the wait for the install lock is bounded and typed ────────────────────
ROOT=$TMP/root9; PREFIX=$ROOT/lib/resend-cli/v$PIN
FAKE_B=$TMP/fake9b; mkdir -p "$FAKE_B"; : >"$FAKE_B/hold"
FAKE_A=$TMP/fake9a; mkdir -p "$FAKE_A"
run_installer_bg "$ROOT" "$FAKE_B" install "$TMP/out9b"; pid_b=$bg_pid
wait_for "$FAKE_B/log" && ok || bad "installer B never reached its pnpm add"
out=$(RESEND_CLI_INSTALL_TEST_MODE=1 RESEND_CLI_INSTALL_TEST_ROOT="$ROOT" FAKE_DIR="$FAKE_A" RESEND_CLI_INSTALL_LOCK_WAIT=1 \
  PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" install 2>&1); status=$?
[ "$status" -eq 1 ] && has "$out" "another install has held" && ok || bad "a held lock past the wait should be a typed failure ($status): $out"
[ ! -e "$FAKE_A/log" ] && ok || bad "a run that never got the lock must not run pnpm"
: >"$FAKE_B/release"
wait "$pid_b"; status_b=$?
[ "$status_b" -eq 0 ] && has "$(cat "$TMP/out9b")" "installed resend-cli v$PIN" && ok || bad "the lock holder's install should still complete ($status_b)"
run_installer "$ROOT" "$FAKE_A" install
[ "$status" -eq 0 ] && has "$out" "already installed" && ok || bad "after the holder exits, a new run should find the prefix converged: $out"

echo "resend-cli-install.test.sh: $pass passed, $failures failed"
[ "$failures" -eq 0 ]
