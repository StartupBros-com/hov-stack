#!/usr/bin/env bash
# Hermetic regression tests for the data-command venv installer: a fake uv
# that builds real interpreters (python3 -m venv --without-pip) and writes real
# package metadata, every path below /tmp, never the network or ~/.local.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER=$REPO/plugins/hov-stack/skills/hov-setup/scripts/venv-install.sh
TMP=$(mktemp -d /tmp/venv-install-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); }
bad() { failures=$((failures + 1)); echo "FAIL: $*" >&2; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ── fake uv ──────────────────────────────────────────────────────────────────
# `uv venv --python V DIR` makes a real venv with the system python3.
# `uv pip install --python PY name==ver...` replaces each named distribution's
# metadata in PY's site-packages, adds stub modules for the gsc imports and a
# bin/vastai for vastai. FAKE_DIR/fail-venv and FAKE_DIR/fail-pip make those
# steps fail (the pip one echoing an index URL with a password, so the masking
# is observable); FAKE_DIR/report installs that version instead of the pin;
# FAKE_DIR/no-bin skips bin/vastai; FAKE_DIR/hold freezes pip install until
# FAKE_DIR/release exists (at most 30 s).
mkdir -p "$TMP/stub"
cat >"$TMP/stub/uv" <<'FAKE'
#!/usr/bin/env bash
F=${FAKE_DIR:?}
printf 'ARGS %s\tCWD %s\n' "$*" "$PWD" >>"$F/log"
if [ -e /proc/$$/fd/9 ]; then echo "FD9 open" >>"$F/log"; else echo "FD9 closed" >>"$F/log"; fi
case "$1 ${2:-}" in
  "venv --python")
    [ -f "$F/fail-venv" ] && { echo "fake uv: no interpreter" >&2; exit 2; }
    exec python3 -m venv --without-pip "$4"
    ;;
  "pip install")
    [ "$3" = --python ] || { echo "fake uv: want --python" >&2; exit 2; }
    py=$4; shift 4
    if [ -f "$F/hold" ]; then
      i=0
      while [ ! -f "$F/release" ]; do
        i=$((i + 1)); [ "$i" -le 600 ] || { echo "fake uv: hold never released" >&2; exit 3; }
        sleep 0.05
      done
    fi
    if [ -f "$F/fail-pip" ]; then
      echo " GET https://ci:s3cr3t@pypi.example.com/simple/x" >&2
      echo " error: fake resolution failure" >&2
      exit 1
    fi
    site=$("$py" -I -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') || exit 4
    bindir=${py%/*}
    for spec in "$@"; do
      name=${spec%%==*}; ver=${spec#*==}
      [ -f "$F/report" ] && ver=$(cat "$F/report")
      norm=$(printf '%s' "$name" | tr '-' '_')
      rm -rf "$site/$norm"-*.dist-info
      mkdir -p "$site/$norm-$ver.dist-info"
      printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$name" "$ver" >"$site/$norm-$ver.dist-info/METADATA"
      case $name in
        google-api-python-client) mkdir -p "$site/googleapiclient"; : >"$site/googleapiclient/__init__.py"; : >"$site/googleapiclient/discovery.py" ;;
        google-auth) mkdir -p "$site/google/oauth2"; : >"$site/google/oauth2/__init__.py"; : >"$site/google/oauth2/service_account.py" ;;
        vastai) [ -f "$F/no-bin" ] || { printf '#!/bin/sh\necho fake-vastai-ran >>"%s/ran"\n' "$F" >"$bindir/vastai"; chmod +x "$bindir/vastai"; } ;;
      esac
    done
    ;;
  *) echo "fake uv: unsupported $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$TMP/stub/uv"

# run <root> <fake-dir> <args...>: sets out and status; HOME is a decoy that must stay untouched.
run() {
  local root=$1 fake=$2; shift 2
  mkdir -p "$fake"
  out=$(VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$root" FAKE_DIR="$fake" \
    PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" "$@" 2>&1)
  status=$?
}
mkdir -p "$TMP/home"

# ── 0. the vastai pin is the wrapper's ───────────────────────────────────────
wrap_pin=$(sed -n 's/^PINNED_VERSION = "\(.*\)"$/\1/p' "$REPO/bin/vastai_wrap.py")
inst_pin=$(sed -n 's/^ *PINS=(vastai==\(.*\))$/\1/p' "$INSTALLER")
[ -n "$wrap_pin" ] && [ "$wrap_pin" = "$inst_pin" ] && ok || bad "venv-install.sh pins vastai '$inst_pin' but bin/vastai_wrap.py pins '$wrap_pin'"
has "$(cat "$REPO/bin/vastai_wrap.py")" "venv-install.sh vastai" && ok || bad "bin/vastai_wrap.py's recreate text should name venv-install.sh vastai"
has "$(cat "$REPO/bin/gsc")" "venv-install.sh gsc" && ok || bad "bin/gsc's recreate text should name venv-install.sh gsc"
has "$(cat "$REPO/bin/ga4")" "venv-install.sh gsc" && ok || bad "bin/ga4's header should name venv-install.sh gsc"

# /hov-setup's detector finds each environment where offers.json says; it must be where this
# installer builds it and where the wrappers run it from.
offer_venvs=$(python3 -I - "$REPO/plugins/hov-stack/skills/hov-setup/scripts/offers.json" <<'PY'
import json, sys
for o in json.load(open(sys.argv[1]))["offers"]:
    v = o.get("venv")
    if v:
        print(o["name"], v["dir"], v.get("env", "-"), v["file"])
PY
)
want_venvs='gsc .local/share/gsc-cli/venv - bin/python
ga4 .local/share/gsc-cli/venv - bin/python
vastai .local/share/vastai-cli/venv VASTAI_VENV bin/vastai'
[ "$offer_venvs" = "$want_venvs" ] && ok || bad "offers.json venv entries are '$offer_venvs'; expected '$want_venvs'"
has "$(cat "$INSTALLER")" 'VENV=$ROOT/.local/share/gsc-cli/venv' && ok || bad "venv-install.sh should build gsc's venv at .local/share/gsc-cli/venv"
has "$(cat "$INSTALLER")" 'VENV=${VASTAI_VENV:-$ROOT/.local/share/vastai-cli/venv}' && ok || bad "venv-install.sh should build vastai's venv at \$VASTAI_VENV or .local/share/vastai-cli/venv"
has "$(cat "$REPO/bin/gsc")" 'VENV="${HOME}/.local/share/gsc-cli/venv"' && ok || bad "bin/gsc should run from .local/share/gsc-cli/venv"
has "$(cat "$REPO/bin/vastai_wrap.py")" 'Path.home() / ".local/share/vastai-cli/venv"' && ok || bad "bin/vastai_wrap.py should run from .local/share/vastai-cli/venv"

# ── 1. usage errors are exit 64 ──────────────────────────────────────────────
for args in "" "nope" "gsc bogus" "gsc check install" "gsc vastai" "gsc --uv"; do
  # shellcheck disable=SC2086
  run "$TMP/root1" "$TMP/fake1" $args
  [ "$status" -eq 64 ] && has "$out" "usage:" && ok || bad "'$args' should be a usage error (64), got $status: $out"
done

# ── 2. check on a missing venv fails and names the install ───────────────────
run "$TMP/root2" "$TMP/fake2" gsc check
[ "$status" -eq 1 ] && has "$out" "run venv-install.sh gsc install" && ok || bad "check without a venv should fail naming install ($status): $out"
[ ! -e "$TMP/fake2/log" ] && ok || bad "check must never run uv"
[ ! -e "$TMP/root2/.local/share/gsc-cli/.venv.install.lock" ] && ok || bad "check must not take the install lock"

# ── 3. install builds the gsc venv; check then passes; a rerun is a no-op ────
ROOT=$TMP/root3; VENV=$ROOT/.local/share/gsc-cli/venv
run "$ROOT" "$TMP/fake3" gsc install
[ "$status" -eq 0 ] && has "$out" "installed google-api-python-client==2.201.0 google-auth==2.62.0 into the gsc venv at $VENV" && ok || bad "gsc install should succeed ($status): $out"
[ -x "$VENV/bin/python" ] && ok || bad "the gsc venv has no python"
has "$(cat "$TMP/fake3/log")" "venv --python 3.12 $VENV" && ok || bad "uv venv should be asked for Python 3.12 at $VENV"
has "$(cat "$TMP/fake3/log")" "pip install --python $VENV/bin/python google-api-python-client==2.201.0 google-auth==2.62.0" && ok || bad "uv pip install should get the exact pins"
! has "$(cat "$TMP/fake3/log")" "FD9 open" && ok || bad "the lock fd must be closed for uv"
! has "$(cat "$TMP/fake3/log")" "CWD $REPO" && ok || bad "uv must run from the scratch dir, not the caller's cwd"
[ -f "$ROOT/.local/share/gsc-cli/.venv.install.lock" ] && [ ! -e "$VENV/.venv.install.lock" ] && ok || bad "the lock must sit beside the venv, not inside it"
run "$ROOT" "$TMP/fake3" gsc check
[ "$status" -eq 0 ] && has "$out" "gsc venv holds" && ok || bad "check after install should pass ($status): $out"
calls=$(grep -c '^ARGS' "$TMP/fake3/log")
run "$ROOT" "$TMP/fake3" gsc
[ "$status" -eq 0 ] && has "$out" "already holds" && ok || bad "a rerun (default mode install) should be a no-op ($status): $out"
[ "$(grep -c '^ARGS' "$TMP/fake3/log")" -eq "$calls" ] && ok || bad "a converged rerun must not run uv"
[ ! -e "$TMP/home/.local" ] && ok || bad "test mode wrote below the real HOME"

# ── 4. a wrong version in a working venv is reinstalled in place ─────────────
ROOT=$TMP/root4; VENV=$ROOT/.local/share/gsc-cli/venv
mkdir -p "$TMP/fake4"; echo 2.0.0 >"$TMP/fake4/report"
run "$ROOT" "$TMP/fake4" gsc install
[ "$status" -eq 1 ] && has "$out" "removed the venv this run created" && ok || bad "an install that misreports its version should fail and remove the new venv ($status): $out"
[ ! -e "$VENV" ] && ok || bad "the venv this run created should be gone"
python3 -m venv --without-pip "$VENV"
FAKE_DIR=$TMP/fake4 PATH="$TMP/stub:$PATH" "$TMP/stub/uv" pip install --python "$VENV/bin/python" google-api-python-client==2.201.0 google-auth==2.62.0 >/dev/null 2>&1
marker=$VENV/keep-me; : >"$marker"
rm -f "$TMP/fake4/report" "$TMP/fake4/log"
run "$ROOT" "$TMP/fake4" gsc check
[ "$status" -eq 1 ] && ok || bad "check should fail while the venv holds 2.0.0 ($status): $out"
run "$ROOT" "$TMP/fake4" gsc install
[ "$status" -eq 0 ] && ok || bad "install should repair the versions in place ($status): $out"
[ -f "$marker" ] && ok || bad "a working venv must be upgraded in place, not replaced"
! has "$(cat "$TMP/fake4/log")" "venv --python" && ok || bad "a working venv must not be recreated"

# ── 5. a broken venv is set aside, then rebuilt ──────────────────────────────
ROOT=$TMP/root5; VENV=$ROOT/.local/share/gsc-cli/venv
mkdir -p "$VENV/bin"; printf '#!/bin/sh\nexit 1\n' >"$VENV/bin/python"; chmod +x "$VENV/bin/python"; : >"$VENV/old-file"
run "$ROOT" "$TMP/fake5" gsc install
[ "$status" -eq 0 ] && has "$out" "set aside broken $VENV" && ok || bad "a venv whose python fails should be set aside ($status): $out"
set -- "$ROOT"/.local/lib/tool-backups/gsc-venv.*
[ -f "$1/old-file" ] && ok || bad "the broken venv should be in tool-backups"
[ -x "$VENV/bin/python" ] && [ ! -e "$VENV/old-file" ] && ok || bad "the venv should be rebuilt fresh"

# ── 6. failures leave nothing half-built, and mask credentials ───────────────
ROOT=$TMP/root6; VENV=$ROOT/.local/share/gsc-cli/venv
mkdir -p "$TMP/fake6"; : >"$TMP/fake6/fail-pip"
run "$ROOT" "$TMP/fake6" gsc install
[ "$status" -eq 1 ] && has "$out" "removed the venv this run created" && ok || bad "a failed pip install should fail typed ($status): $out"
[ ! -e "$VENV" ] && ok || bad "a failed first install must not leave a venv"
! has "$out" "s3cr3t" && has "$out" "[redacted]@pypi.example.com" && ok || bad "an index password in uv's output must be masked: $out"
mkdir -p "$TMP/fake6b"; : >"$TMP/fake6b/fail-venv"
run "$ROOT" "$TMP/fake6b" gsc install
[ "$status" -eq 1 ] && has "$out" "could not create a Python 3.12 venv" && ok || bad "a failed uv venv should fail typed ($status): $out"
[ ! -e "$VENV" ] && ok || bad "a failed uv venv must not leave a directory"

# ── 7. uv is required and resolved by name ───────────────────────────────────
out=$(VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$TMP/root7" FAKE_DIR="$TMP/fake7" \
  PATH=/usr/bin:/bin HOME="$TMP/home" bash "$INSTALLER" gsc install 2>&1); status=$?
[ "$status" -eq 1 ] && has "$out" "uv is required" && ok || bad "a missing uv should be a typed failure ($status): $out"
mkdir -p "$TMP/fake7"
out=$(VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$TMP/root7" FAKE_DIR="$TMP/fake7" \
  PATH=/usr/bin:/bin HOME="$TMP/home" bash "$INSTALLER" gsc install --uv "$TMP/stub/uv" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "--uv with a path should be used when uv is not on PATH ($status): $out"
run "$TMP/root7b" "$TMP/fake7b" gsc install --uv uv
[ "$status" -eq 0 ] && ok || bad "--uv uv (the offer line's fallback) should resolve on PATH ($status): $out"

# ── 8. vastai: the binary, VASTAI_VENV, and the vendor never runs ────────────
ROOT=$TMP/root8
run "$ROOT" "$TMP/fake8" vastai install
[ "$status" -eq 0 ] && has "$out" "installed vastai==$wrap_pin into the vastai venv at $ROOT/.local/share/vastai-cli/venv" && ok || bad "vastai install should succeed ($status): $out"
[ ! -e "$TMP/fake8/ran" ] && ok || bad "the installer must never run the vendor vastai binary"
rm "$ROOT/.local/share/vastai-cli/venv/bin/vastai"
run "$ROOT" "$TMP/fake8" vastai check
[ "$status" -eq 1 ] && ok || bad "vastai check should fail when bin/vastai is missing ($status): $out"
mkdir -p "$TMP/fake8b"; : >"$TMP/fake8b/no-bin"
run "$TMP/root8b" "$TMP/fake8b" vastai install
[ "$status" -eq 1 ] && ok || bad "an install that leaves no bin/vastai should fail ($status): $out"
out=$(VASTAI_VENV="$TMP/root8c/custom/venv/" VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$TMP/root8c" FAKE_DIR="$TMP/fake8c" \
  PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" vastai install 2>&1); status=$?
[ "$status" -eq 0 ] && [ -x "$TMP/root8c/custom/venv/bin/vastai" ] && [ -f "$TMP/root8c/custom/.venv.install.lock" ] && ok || bad "VASTAI_VENV should move the venv and its lock ($status): $out"
out=$(VASTAI_VENV=relative/venv VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$TMP/root8d" FAKE_DIR="$TMP/fake8d" \
  PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" vastai check 2>&1); status=$?
[ "$status" -eq 1 ] && has "$out" "must be absolute" && ok || bad "a relative VASTAI_VENV should be refused ($status): $out"
out=$(VASTAI_VENV=/var/tmp/elsewhere/venv VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$TMP/root8e" FAKE_DIR="$TMP/fake8e" \
  PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" vastai install 2>&1); status=$?
[ "$status" -eq 1 ] && has "$out" "must stay below the test root" && [ ! -e /var/tmp/elsewhere ] && ok || bad "test mode must refuse a venv outside its root ($status): $out"

# ── 9. a test root outside /tmp is refused before anything is made ───────────
run "/var/tmp/venv-install-test-outside.$$" "$TMP/fake9" gsc install
[ "$status" -eq 1 ] && has "$out" "test root must stay below /tmp" && ok || bad "a test root outside /tmp should be refused ($status): $out"
[ ! -e "/var/tmp/venv-install-test-outside.$$" ] && ok || bad "the refused root was created anyway"

# ── 10. the lock: a held lock is a bounded, typed wait, with flock and without ─
for lockkind in flock none; do
  ROOT=$TMP/root10$lockkind
  FAKE_B=$TMP/fake10b$lockkind; mkdir -p "$FAKE_B"; : >"$FAKE_B/hold"
  FAKE_A=$TMP/fake10a$lockkind; mkdir -p "$FAKE_A"
  VENV_INSTALL_FLOCK=$lockkind VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$ROOT" FAKE_DIR="$FAKE_B" \
    PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" gsc install >"$TMP/out10b$lockkind" 2>&1 &
  pid_b=$!
  i=0; until grep -q 'pip install' "$FAKE_B/log" 2>/dev/null; do i=$((i + 1)); [ "$i" -le 200 ] || break; sleep 0.05; done
  grep -q 'pip install' "$FAKE_B/log" 2>/dev/null && ok || bad "[$lockkind] installer B never reached its pip install"
  out=$(VENV_INSTALL_FLOCK=$lockkind VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$ROOT" FAKE_DIR="$FAKE_A" VENV_INSTALL_LOCK_WAIT=1 \
    PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" gsc install 2>&1); status=$?
  [ "$status" -eq 1 ] && has "$out" "another install has held" && ok || bad "[$lockkind] a held lock past the wait should be a typed failure ($status): $out"
  [ ! -e "$FAKE_A/log" ] && ok || bad "[$lockkind] a run that never got the lock must not run uv"
  : >"$FAKE_B/release"
  wait "$pid_b"; status_b=$?
  [ "$status_b" -eq 0 ] && ok || bad "[$lockkind] the lock holder's install should complete ($status_b): $(cat "$TMP/out10b$lockkind")"
  run "$ROOT" "$FAKE_A" gsc install
  [ "$status" -eq 0 ] && has "$out" "already holds" && ok || bad "[$lockkind] after the holder exits, a new run should find the venv converged: $out"
done
[ ! -e "$TMP/root10none/.local/share/gsc-cli/.venv.install.lock.d" ] && ok || bad "the lock directory must be removed on exit"
# A lock directory left by a dead process is taken over.
ROOT=$TMP/root11; mkdir -p "$ROOT/.local/share/gsc-cli/.venv.install.lock.d"
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" >"$ROOT/.local/share/gsc-cli/.venv.install.lock.d/pid"
out=$(VENV_INSTALL_FLOCK=none VENV_INSTALL_LOCK_WAIT=5 VENV_INSTALL_TEST_MODE=1 VENV_INSTALL_TEST_ROOT="$ROOT" FAKE_DIR="$TMP/fake11" \
  PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$INSTALLER" gsc install 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "a stale lock directory (dead pid) should be taken over ($status): $out"

echo "venv-install.test.sh: $pass passed, $failures failed"
[ "$failures" -eq 0 ]
