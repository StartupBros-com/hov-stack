#!/usr/bin/env bash
# Create or repair the pinned Python venv that a bundled data command runs from.
#
#   gsc     ~/.local/share/gsc-cli/venv with google-api-python-client and
#           google-auth. bin/gsc needs it; bin/ga4 uses it when it is there.
#   vastai  ~/.local/share/vastai-cli/venv with vastai. bin/vastai runs
#           <venv>/bin/vastai; VASTAI_VENV moves the venv, as it does for the wrapper.
#
# Usage:  venv-install.sh <gsc|vastai> [install|check] [--uv PATH]
#   install  make the venv hold the pins (a no-op when it already does). A venv
#            whose python is missing or does not run is moved to
#            ~/.local/lib/tool-backups/<name>-venv.<time> first; a working venv
#            gets the pinned versions installed into it. One install at a time
#            per venv: a lock beside it (flock, or a lock directory where flock
#            is absent, as on macOS); a second run waits, then rechecks.
#   check    exit 0 when the venv holds the pins, 1 otherwise (no lock, no network)
#
# Holding the pins means: <venv>/bin/python runs, every pinned distribution
# reports its pinned version, the listed modules import, and for vastai
# <venv>/bin/vastai is executable. The vendor vastai binary is never run here:
# it contacts console.vast.ai when it starts.
#
# Credentials stay outside this script: it reads no key and no service-account
# file. uv is the one found on PATH unless --uv names another; uv's own
# configuration (index, cooldown) applies unchanged.
#
# Test seams (production sets none): VENV_INSTALL_TEST_MODE=1 with
# VENV_INSTALL_TEST_ROOT below /tmp stands in for $HOME; VENV_INSTALL_FLOCK=none
# forces the lock-directory fallback; VENV_INSTALL_LOCK_WAIT bounds the wait.

set -euo pipefail

usage() {
  echo "usage: venv-install.sh <gsc|vastai> [install|check] [--uv PATH]" >&2
  exit 64
}

fail() {
  echo "venv-install: $*" >&2
  exit 1
}

NAME=
MODE=
UV=
while [ $# -gt 0 ]; do
  case $1 in
    --uv) [ $# -ge 2 ] || usage; UV=$2; shift 2 ;;
    --uv=*) UV=${1#--uv=}; shift ;;
    install|--install) [ -z "$MODE" ] || usage; MODE=install; shift ;;
    check|--check) [ -z "$MODE" ] || usage; MODE=check; shift ;;
    gsc|vastai) [ -z "$NAME" ] || usage; NAME=$1; shift ;;
    *) usage ;;
  esac
done
[ -n "$NAME" ] || usage
MODE=${MODE:-install}

TEST_MODE=${VENV_INSTALL_TEST_MODE:-0}
ROOT=$HOME
if [ "$TEST_MODE" = 1 ]; then
  ROOT=${VENV_INSTALL_TEST_ROOT:?VENV_INSTALL_TEST_ROOT is required in test mode}
  ROOT=$(realpath -m "$ROOT")
  case $ROOT in
    /tmp/*) ;;
    *) fail "test root must stay below /tmp (got $ROOT)" ;;
  esac
fi

# The pins. vastai's must equal PINNED_VERSION in bin/vastai_wrap.py
# (tests/venv-install.test.sh checks it).
PYTHON=3.12
MODULES=()
BIN_CHECK=
case $NAME in
  gsc)
    VENV=$ROOT/.local/share/gsc-cli/venv
    PINS=(google-api-python-client==2.201.0 google-auth==2.62.0)
    MODULES=(googleapiclient.discovery google.oauth2.service_account)
    ;;
  vastai)
    VENV=${VASTAI_VENV:-$ROOT/.local/share/vastai-cli/venv}
    PINS=(vastai==1.8.3)
    BIN_CHECK=bin/vastai
    ;;
esac
case $VENV in
  /*) ;;
  *) fail "the venv path must be absolute (got $VENV)" ;;
esac
while [ "${VENV%/}" != "$VENV" ]; do VENV=${VENV%/}; done
if [ "$TEST_MODE" = 1 ]; then
  VENV=$(realpath -m "$VENV")
  case $VENV in
    "$ROOT"/*) ;;
    *) fail "in test mode the venv must stay below the test root (got $VENV)" ;;
  esac
fi
BACKUP_ROOT=$ROOT/.local/lib/tool-backups
LOCK=${VENV%/*}/.${VENV##*/}.install.lock
LOCK_WAIT=${VENV_INSTALL_LOCK_WAIT:-600}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/venv-install.XXXXXX") || fail "no scratch dir"
LOCK_DIR=
cleanup() {
  rm -rf "$SCRATCH"
  if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; fi
}
trap cleanup EXIT

# python_runs: the venv's interpreter exists and starts.
python_runs() {
  [ -x "$VENV/bin/python" ] && (cd "$SCRATCH" && "$VENV/bin/python" -I -c 'pass' >/dev/null 2>&1 9>&-)
}

# converged: python runs, each pin is installed at its version, each module
# imports, and the checked binary (if any) is executable.
converged() {
  python_runs || return 1
  if [ -n "$BIN_CHECK" ] && [ ! -x "$VENV/$BIN_CHECK" ]; then return 1; fi
  # ${MODULES[@]+...}: bash 3.2 (macOS) treats an empty array as unset under set -u.
  (cd "$SCRATCH" && "$VENV/bin/python" -I - "${PINS[@]}" -- ${MODULES[@]+"${MODULES[@]}"} >/dev/null 2>&1 9>&-) <<'PY'
import importlib
import importlib.metadata as metadata
import sys

args = sys.argv[1:]
split = args.index("--")
for pin in args[:split]:
    name, want = pin.split("==")
    if metadata.version(name) != want:
        sys.exit(1)
for module in args[split + 1:]:
    importlib.import_module(module)
PY
}

# show_log <file>: the tail of uv's output, credentials in index URLs masked.
show_log() {
  tail -n 20 "$1" | sed -E -e 's#(://)[^/@[:space:]]+@#\1[redacted]@#g' -e 's/^/    /' >&2
}

if [ "$MODE" = check ]; then
  if converged; then
    echo "$NAME venv holds ${PINS[*]} at $VENV"
    exit 0
  fi
  echo "$NAME venv at $VENV does not hold ${PINS[*]}; run venv-install.sh $NAME install" >&2
  exit 1
fi

# Install: from the first check to the last, everything touches $VENV, so it
# runs under one lock. Without it, two runs that both saw a missing venv would
# both create it, and the one whose install failed would remove what the other
# had just made. A waiting run rechecks once it holds the lock.
mkdir -p "${VENV%/*}" || fail "cannot create ${VENV%/*}"
FLOCK=$(command -v flock 2>/dev/null || true)
if [ "$TEST_MODE" = 1 ] && [ "${VENV_INSTALL_FLOCK:-}" = none ]; then FLOCK=; fi
if [ -n "$FLOCK" ]; then
  exec 9>"$LOCK" || fail "cannot open the install lock $LOCK"
  "$FLOCK" -w "$LOCK_WAIT" 9 || fail "another install has held $LOCK for over ${LOCK_WAIT}s; retry when it finishes"
else
  started=$SECONDS
  until mkdir "$LOCK.d" 2>/dev/null; do
    holder=$(cat "$LOCK.d/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LOCK.d"
      continue
    fi
    [ $((SECONDS - started)) -lt "$LOCK_WAIT" ] || fail "another install has held $LOCK.d for over ${LOCK_WAIT}s; retry when it finishes"
    sleep 1
  done
  LOCK_DIR=$LOCK.d
  echo $$ > "$LOCK_DIR/pid"
fi

if converged; then
  echo "$NAME venv already holds ${PINS[*]} at $VENV"
  exit 0
fi

# A bare name (the offer line passes plain `uv` when /hov-setup found none) is looked up on PATH.
UV=${UV:-uv}
case $UV in
  */*) ;;
  *) UV=$(command -v "$UV" 2>/dev/null || true) ;;
esac
[ -n "$UV" ] && [ -x "$UV" ] || fail "uv is required to build the $NAME venv; install it first (/hov-setup offers it)"

created=0
if ! python_runs; then
  if [ -e "$VENV" ] || [ -L "$VENV" ]; then
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$BACKUP_ROOT" || fail "cannot create $BACKUP_ROOT"
    mv "$VENV" "$BACKUP_ROOT/$NAME-venv.$ts" || fail "could not set aside the broken venv $VENV"
    echo "set aside broken $VENV -> $BACKUP_ROOT/$NAME-venv.$ts"
  fi
  if ! (cd "$SCRATCH" && "$UV" venv --python "$PYTHON" "$VENV" >"$SCRATCH/uv.log" 2>&1 9>&-); then
    show_log "$SCRATCH/uv.log"
    rm -rf "$VENV"
    fail "uv could not create a Python $PYTHON venv at $VENV; nothing was installed"
  fi
  created=1
fi

if ! (cd "$SCRATCH" && "$UV" pip install --python "$VENV/bin/python" "${PINS[@]}" >"$SCRATCH/uv.log" 2>&1 9>&-); then
  show_log "$SCRATCH/uv.log"
  if [ "$created" = 1 ]; then
    rm -rf "$VENV"
    fail "uv could not install ${PINS[*]}; removed the venv this run created"
  fi
  fail "uv could not install ${PINS[*]} into $VENV; the venv may be partly changed, rerun to repair it"
fi

if ! converged; then
  if [ "$created" = 1 ]; then
    rm -rf "$VENV"
    fail "the $NAME venv did not hold ${PINS[*]} after install; removed the venv this run created"
  fi
  fail "the $NAME venv at $VENV did not hold ${PINS[*]} after install"
fi
echo "installed ${PINS[*]} into the $NAME venv at $VENV"
