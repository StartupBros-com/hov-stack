#!/usr/bin/bash
# Install the pinned official Resend CLI (npm `resend-cli`) into a private pnpm
# prefix that is never on PATH. bin/resend-cli execs
# ~/.local/lib/resend-cli/v<PIN>/bin/resend and refuses any other version, so
# the wrapper's command classification always describes the binary it runs.
#
# Credentials are deliberately outside this path: the installer never reads
# BWS, never runs `resend login`, and runs the vendor only for `--version`
# with telemetry, the update check and interactive prompts switched off and
# an empty throwaway XDG_CONFIG_HOME.
#
# Usage:  resend-cli-install.sh [install|check]
#   install  converge ~/.local/lib/resend-cli/v<PIN> (no-op when already converged;
#            a broken prefix is moved to ~/.local/lib/tool-backups/resend-cli first).
#            One install at a time per lib root: an exclusive flock on
#            ~/.local/lib/resend-cli/.install.lock covers the convergence check,
#            the set-aside, the pnpm add, validation and cleanup, and a second
#            run waits (up to RESEND_CLI_INSTALL_LOCK_WAIT seconds, default 600)
#            and then rechecks, so concurrent sessions bootstrapping the tool
#            cannot remove each other's install. install therefore needs flock
#            and creates the lib root and the lock file even on a no-op run.
#   check    exit 0 when the pinned prefix is converged, 1 otherwise (no lock)
#
# Test seams (production sets none): RESEND_CLI_INSTALL_TEST_MODE=1 with
# RESEND_CLI_INSTALL_TEST_ROOT below /tmp relocates every path;
# RESEND_CLI_INSTALL_PNPM names the pnpm executable;
# RESEND_CLI_INSTALL_LOCK_WAIT bounds the wait for the install lock.

set -euo pipefail

PIN_VERSION=2.23.0
PKG=resend-cli
LOCK_WAIT=${RESEND_CLI_INSTALL_LOCK_WAIT:-600}

MODE=${1:-install}
case $MODE in
  install|--install) MODE=install ;;
  check|--check) MODE=check ;;
  *) echo "usage: resend-cli-install.sh [install|check]" >&2; exit 64 ;;
esac

fail() {
  echo "resend-cli-install: $*" >&2
  exit 1
}

PNPM=${RESEND_CLI_INSTALL_PNPM:-pnpm}
if [ "${RESEND_CLI_INSTALL_TEST_MODE:-0}" = 1 ]; then
  TEST_ROOT=${RESEND_CLI_INSTALL_TEST_ROOT:?RESEND_CLI_INSTALL_TEST_ROOT is required in test mode}
  TEST_ROOT=$(realpath -m "$TEST_ROOT")
  case $TEST_ROOT in
    /tmp/*) ;;
    *) fail "test root must stay below /tmp (got $TEST_ROOT)" ;;
  esac
  LIB_ROOT=$TEST_ROOT/lib/resend-cli
  BACKUP_ROOT=$TEST_ROOT/lib/tool-backups/resend-cli
else
  LIB_ROOT=$HOME/.local/lib/resend-cli
  BACKUP_ROOT=$HOME/.local/lib/tool-backups/resend-cli
fi
PREFIX=$LIB_ROOT/v$PIN_VERSION
# The lock sits beside the versioned prefix, never inside it: the prefix is
# what install moves aside and removes.
LOCK_FILE=$LIB_ROOT/.install.lock

for need in jq realpath mktemp; do
  command -v "$need" >/dev/null 2>&1 || fail "required executable not found: $need"
done

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/resend-cli-install.XXXXXX") || fail "no scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT

# package_version <prefix>: the installed package's own version from pnpm's
# layout (<prefix>/<layout>/node_modules/resend-cli/package.json), exactly one match.
package_version() {
  local -a matches=()
  local f
  for f in "$1"/*/node_modules/"$PKG"/package.json; do
    [ -f "$f" ] && matches+=("$f")
  done
  [ "${#matches[@]}" -eq 1 ] || return 1
  jq -er --arg pkg "$PKG" 'if .name == $pkg then .version else empty end' "${matches[0]}" 2>/dev/null
}

# converged <prefix>: executable shim, package.json at the pin, and the binary
# itself reporting the pin from an isolated, prompt-free environment.
converged() {
  local prefix=$1 out
  [ -x "$prefix/bin/resend" ] || return 1
  [ "$(package_version "$prefix" || true)" = "$PIN_VERSION" ] || return 1
  mkdir -p "$SCRATCH/xdg"
  out=$(cd "$SCRATCH" && env -i PATH="$PATH" HOME="$HOME" DO_NOT_TRACK=1 RESEND_TELEMETRY_DISABLED=1 \
    RESEND_NO_UPDATE_NOTIFIER=1 CI=1 NO_COLOR=1 XDG_CONFIG_HOME="$SCRATCH/xdg" \
    "$prefix/bin/resend" --version 2>/dev/null 9>&-) || return 1
  [ "$out" = "$PKG v$PIN_VERSION" ]
}

# show_log <file>: the tail of the pnpm log, registry credentials masked (pnpm
# can echo a registry URL or auth header taken from ~/.npmrc).
show_log() {
  tail -n 20 "$1" | sed -E -e 's#(://)[^/@[:space:]]+@#\1[redacted]@#g' \
    -e 's#((_authToken|_auth|_password|token)[=:][[:space:]]*)[^[:space:]]+#\1[redacted]#gI' \
    -e 's#((Bearer|Basic)[[:space:]]+)[^[:space:]]+#\1[redacted]#gI' -e 's/^/    /' >&2
}

if [ "$MODE" = check ]; then
  if converged "$PREFIX"; then
    echo "$PKG v$PIN_VERSION converged at $PREFIX"
    exit 0
  fi
  echo "$PKG v$PIN_VERSION is not converged at $PREFIX; run resend-cli-install.sh install" >&2
  exit 1
fi

# Install: everything from the convergence check to the cleanup touches
# $PREFIX, so it runs under one exclusive lock. Without it two runs that both
# saw an unconverged prefix would both pnpm-add into it, and the one whose
# validation failed would rm -rf what the other had just installed. A waiting
# run rechecks convergence once it holds the lock, so the usual outcome of two
# sessions bootstrapping at once is one install and one "already installed".
command -v flock >/dev/null 2>&1 || fail "required executable not found: flock"
mkdir -p "$LIB_ROOT" || fail "cannot create $LIB_ROOT"
exec 9>"$LOCK_FILE" || fail "cannot open the install lock $LOCK_FILE"
flock -w "$LOCK_WAIT" 9 || fail "another install has held $LOCK_FILE for over ${LOCK_WAIT}s; retry when it finishes"

if converged "$PREFIX"; then
  echo "$PKG v$PIN_VERSION already installed at $PREFIX"
  exit 0
fi

command -v "$PNPM" >/dev/null 2>&1 || fail "pnpm is required to install $PKG@$PIN_VERSION (mise-managed pnpm is absent from PATH)"

if [ -e "$PREFIX" ]; then
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$BACKUP_ROOT"
  mv -T "$PREFIX" "$BACKUP_ROOT/v$PIN_VERSION.$ts" || fail "could not set aside the unconverged prefix $PREFIX"
  echo "set aside unconverged $PREFIX -> $BACKUP_ROOT/v$PIN_VERSION.$ts"
fi

mkdir -p "$PREFIX/bin"
# pnpm refuses a global bin dir that is not on PATH, so it is on PATH for this
# one call only; the prefix never reaches the operator's PATH otherwise. The
# shim pnpm writes bakes in absolute paths, so the install lands in its final
# directory rather than a staging one. The operator's pnpm configuration
# (registry, minimum-release-age cooldown) applies unchanged. The lock fd is
# closed for the child so nothing pnpm leaves behind can keep the lock held.
if ! (cd "$SCRATCH" && PATH="$PREFIX/bin:$PATH" \
      "$PNPM" add -g --config.global-dir="$PREFIX" --config.global-bin-dir="$PREFIX/bin" \
      "$PKG@$PIN_VERSION" >"$SCRATCH/pnpm.log" 2>&1 9>&-); then
  show_log "$SCRATCH/pnpm.log"
  rm -rf "$PREFIX"
  fail "pnpm could not install $PKG@$PIN_VERSION; nothing was installed"
fi

if ! converged "$PREFIX"; then
  rm -rf "$PREFIX"
  fail "installed $PKG did not report v$PIN_VERSION; removed the unconverged prefix"
fi
echo "installed $PKG v$PIN_VERSION at $PREFIX"
